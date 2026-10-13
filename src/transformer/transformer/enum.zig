//! TypeScript / Flow enum helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const cooked_name = @import("../cooked_name.zig");
const ast_walk = @import("../../parser/ast_walk.zig");
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const ConstEnumValue = Transformer.ConstEnumValue;
const ConstEnumMember = Transformer.ConstEnumMember;
const ConstEnumDecl = Transformer.ConstEnumDecl;

/// flow_enum_declaration: extra = [name, members_start, members_len, base_type]
/// codegen 단계에서 `const Name = Object.freeze({...})` 형태 emit. transformer 는
/// members 의 init expression 만 visit (define / global rename 등 일반 변환 적용).
pub fn visitFlowEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const new_name = try self.visitNode(self.readNodeIdx(e, 0));
    const new_members = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
    const base_type = self.readU32(e, 3);
    return self.addExtraNode(.flow_enum_declaration, node.span, &.{
        @intFromEnum(new_name), new_members.start, new_members.len, base_type,
    });
}

/// ts_enum_declaration: extra = [name, members_start, members_len, flags]
/// flags bit0=const enum (선언 삭제 + 멤버를 self.const_enums 에 보관 → literal 인라인),
/// bit1=ambient declare 문맥 (일반 enum은 런타임 선언 없음).
pub fn visitEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const flags = self.readU32(e, 3);

    if ((flags & 2) != 0) {
        if ((flags & 1) != 0) collectConstEnum(self, node) catch {};
        return .none;
    }

    if ((flags & 1) != 0) {
        // 평가 가능한 단순 케이스만 등록 — 이 파일 안의 `E.A` 는 literal 로 인라인된다.
        collectConstEnum(self, node) catch {};
        // (#5594) export 된 const enum 은 다른 모듈이 `E.A` 로 읽으므로 선언을 일반 enum 으로
        // 남긴다 — tsc `--isolatedModules`(preserveConstEnums 내포)·esbuild transform 과 같다.
        // 로컬 const enum 은 tsc 처럼 지운다.
        if (!constEnumIsExported(self, node)) return .none;
    }

    const new_name = try self.visitNode(self.readNodeIdx(e, 0));
    const new_members = try visitEnumMembers(self, node);
    return self.addExtraNode(.ts_enum_declaration, node.span, &.{
        @intFromEnum(new_name), new_members.start, new_members.len, flags & ~@as(u32, 1),
    });
}

/// 런타임 enum 멤버를 방문하며, 값이 정해진 두 경우 초기값을 숫자/문자열 리터럴로 채운다
/// (tsc·esbuild 와 같은 값, #5601):
///   - 계산식(`A = 1 << 1`, `A = 0x10`) 뒤의 자동 증가 멤버 — codegen 은 식을 평가하지 못해
///     직전 정수 리터럴 기준으로 세어 틀린 값(0 부터)을 냈다.
///   - 병합된 앞선 선언의 멤버를 이름만으로 쓰는 초기값(`enum E { B = A + 1 }`) — 이 선언의
///     IIFE 안에는 `A` 가 없어 ReferenceError 였다.
fn visitEnumMembers(self: *Transformer, node: Node) Error!ast_mod.NodeList {
    const e = node.data.extra;
    const list: ast_mod.NodeList = .{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) };
    const id = enumNameAndSymbol(self, node) orelse return self.visitExtraList(list);
    const prior_index = findEnumDecl(self.enum_values.items, id.name, id.sym);
    const prior_len = if (prior_index) |pi| self.enum_values.items[pi].members.len else 0;
    var ev = try evaluateEnum(self, node, if (prior_index) |pi| self.enum_values.items[pi].members else &.{});
    defer ev.deinit(self.allocator);

    var out: std.ArrayList(NodeIndex) = .empty;
    defer out.deinit(self.allocator);
    // codegen 이 자동 증가를 직접 셀 수 있는 상태(직전 멤버 값이 정수 리터럴/자동 증가)인지.
    var codegen_counts = true;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        const member = self.ast.getNode(member_idx);
        const value = ev.values.items[i];
        if (member.tag != .ts_enum_member) {
            try out.append(self.allocator, try self.visitNode(member_idx));
            codegen_counts = false;
            continue;
        }
        const init_idx = member.data.binary.right;
        const fold = if (value == null)
            false
        else if (init_idx.isNone())
            !codegen_counts
        else
            refersToPriorMember(self, init_idx, ev.known.items[0..prior_len]);
        if (fold) {
            const new_key = try self.visitNode(member.data.binary.left);
            const literal = try makeConstEnumLiteralNode(self, value.?, member.span);
            try out.append(self.allocator, try self.ast.addNode(.{
                .tag = .ts_enum_member,
                .span = member.span,
                .data = .{ .binary = .{ .left = new_key, .right = literal, .flags = member.data.binary.flags } },
            }));
            codegen_counts = isIntegral(value.?);
        } else {
            try out.append(self.allocator, try self.visitNode(member_idx));
            if (!init_idx.isNone()) {
                const init_node = self.ast.getNode(init_idx);
                codegen_counts = switch (init_node.tag) {
                    .numeric_literal => if (std.fmt.parseInt(i64, self.ast.getText(init_node.span), 10)) |_| true else |_| false,
                    .identifier_reference => value != null and isIntegral(value.?),
                    else => false,
                };
            } else if (value == null) codegen_counts = false;
        }
    }
    try storeEnumValues(self, &self.enum_values, node, prior_index, &ev);
    return self.ast.addNodeList(out.items);
}

fn isIntegral(value: ConstEnumValue) bool {
    return switch (value) {
        .number => |n| @floor(n) == n and !std.math.isInf(n),
        .string => false,
    };
}

/// 초기값이 병합된 앞선 선언의 멤버를 이름만으로 참조하는가. 멤버 접근의 속성 이름은 제외.
fn refersToPriorMember(self: *const Transformer, expr_idx: NodeIndex, prior: []const ConstEnumMember) bool {
    if (prior.len == 0 or expr_idx.isNone()) return false;
    const node = self.ast.getNode(expr_idx);
    switch (node.tag) {
        .identifier_reference => {
            const name = self.ast.getText(node.span);
            for (prior) |m| {
                if (cooked_name.eql(m.name, name)) return true;
            }
            return false;
        },
        .static_member_expression => return refersToPriorMember(self, self.readNodeIdx(node.data.extra, 0), prior),
        else => {},
    }
    var it = ast_walk.children(self.ast, node);
    while (it.next()) |child| {
        if (refersToPriorMember(self, child, prior)) return true;
    }
    return false;
}

/// Exported from the module, directly or through an exported namespace.
fn constEnumIsExported(self: *const Transformer, node: Node) bool {
    const sym_id = self.getSymbolIdAt(self.readNodeIdx(node.data.extra, 0)) orelse return false;
    if (sym_id >= self.symbols.len) return false;
    const sym = self.symbols[sym_id];
    if (!sym.isExported() or sym.scope_id.isNone()) return false;
    if (sym.scope_id.toIndex() == 0) return true;
    // Exported from a namespace that the module exports: another module reads
    // it as `N.E.A`, which this module cannot inline (#5600).
    if (self.namespace_path.items.len == 0) return false;
    const root_id = self.namespace_root_symbol_id orelse return false;
    if (root_id >= self.symbols.len) return false;
    const root = self.symbols[root_id];
    return root.isExported() and !root.scope_id.isNone() and root.scope_id.toIndex() == 0;
}

/// 한 enum 선언의 멤버 값 평가 결과.
const EnumEval = struct {
    /// 앞서 병합된 선언의 멤버 + 이 선언에서 값이 정해진 멤버 (이름·문자열 소유).
    known: std.ArrayList(ConstEnumMember) = .empty,
    /// 이 선언의 멤버별 값 (`known` 을 빌림). 상수가 아니면 null.
    values: std.ArrayList(?ConstEnumValue) = .empty,
    complete: bool = true,

    fn deinit(self: *EnumEval, allocator: std.mem.Allocator) void {
        freeMembers(allocator, self.known.items);
        self.known.deinit(allocator);
        self.values.deinit(allocator);
    }
};

fn freeMembers(allocator: std.mem.Allocator, members: []const ConstEnumMember) void {
    for (members) |m| {
        allocator.free(m.name);
        if (m.value == .string) allocator.free(m.value.string);
    }
}

fn enumMemberKeyName(self: *const Transformer, key_idx: NodeIndex) ?[]const u8 {
    if (key_idx.isNone()) return null;
    const key_node = self.ast.getNode(key_idx);
    return switch (key_node.tag) {
        .identifier_reference, .binding_identifier => self.ast.getText(key_node.span),
        .string_literal => blk: {
            const raw = self.ast.getText(key_node.data.string_ref);
            if (raw.len < 2) return null;
            break :blk raw[1 .. raw.len - 1];
        },
        else => null,
    };
}

/// 같은 enum 의 앞선 선언(병합, #5601) 멤버를 찾는다.
fn findEnumDecl(list: []const ConstEnumDecl, name: []const u8, sym: ?u32) ?usize {
    for (list, 0..) |decl, i| {
        if (enumDeclMatches(decl, name, sym)) return i;
    }
    return null;
}

/// enum 멤버 값을 평가한다. `prior` 는 앞서 병합된 선언의 멤버 — 뒤 선언의 초기값은
/// 그 이름을 그대로 쓸 수 있다(TS 병합 enum).
/// TypeScript spec 의 const enum expression subset 을 지원:
///   numeric/string/boolean literal · 단항(`+ - ~ !`) · 이항(산술/비트/비교/논리) · parenthesized ·
///   같은 enum 내 다른 멤버 참조(`B = A + 1`) · 외부 const enum 참조(`B = OtherEnum.X`) · 빈 init(auto-inc).
fn evaluateEnum(self: *Transformer, node: Node, prior: []const ConstEnumMember) Error!EnumEval {
    const e = node.data.extra;
    const name_idx = self.readNodeIdx(e, 0);
    const enum_name_src = self.ast.getText(self.ast.getNode(name_idx).span);
    const members_start = self.readU32(e, 1);
    const members_len = self.readU32(e, 2);

    var ev: EnumEval = .{};
    errdefer ev.deinit(self.allocator);
    for (prior) |m| {
        const owned_name = try self.allocator.dupe(u8, m.name);
        errdefer self.allocator.free(owned_name);
        const owned_value: ConstEnumValue = switch (m.value) {
            .number => |n| .{ .number = n },
            .string => |str| .{ .string = try self.allocator.dupe(u8, str) },
        };
        try ev.known.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }

    var prev_number: ?f64 = if (prior.len == 0) -1 else null;
    var i: u32 = 0;
    while (i < members_len) : (i += 1) {
        const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[members_start + i]);
        const member_node = self.ast.getNode(member_idx);
        const member_name_src = if (member_node.tag == .ts_enum_member) enumMemberKeyName(self, member_node.data.binary.left) else null;
        const init_idx = if (member_node.tag == .ts_enum_member) member_node.data.binary.right else NodeIndex.none;

        // #4232: concat 중간 문자열 수거 — 멤버 저장(아래 재-dupe) 후 일괄 해제.
        var temp_strings: std.ArrayList([]const u8) = .empty;
        defer {
            for (temp_strings.items) |ts| self.allocator.free(ts);
            temp_strings.deinit(self.allocator);
        }
        const value: ?ConstEnumValue = if (member_name_src == null)
            null
        else if (init_idx.isNone())
            (if (prev_number) |pv| ConstEnumValue{ .number = pv + 1 } else null)
        else
            try evalConstEnumExpr(self, init_idx, .{
                .current_members = ev.known.items,
                .current_name = enum_name_src,
                .current_symbol_id = self.getSymbolIdAt(name_idx),
                .temp_strings = &temp_strings,
            });
        const v = value orelse {
            ev.complete = false;
            prev_number = null;
            try ev.values.append(self.allocator, null);
            continue;
        };
        prev_number = switch (v) {
            .number => |n| n,
            .string => null,
        };

        const owned_name = try self.allocator.dupe(u8, member_name_src.?);
        errdefer self.allocator.free(owned_name);
        const owned_value: ConstEnumValue = switch (v) {
            .number => |n| .{ .number = n },
            .string => |str| .{ .string = try self.allocator.dupe(u8, str) },
        };
        errdefer if (owned_value == .string) self.allocator.free(owned_value.string);
        try ev.known.append(self.allocator, .{ .name = owned_name, .value = owned_value });
        try ev.values.append(self.allocator, owned_value);
    }
    return ev;
}

/// `ev.known` 을 enum 목록에 기록한다 — 병합된 앞선 선언 항목이 있으면 교체한다.
fn storeEnumValues(self: *Transformer, list: *std.ArrayList(ConstEnumDecl), node: Node, prior_index: ?usize, ev: *EnumEval) Error!void {
    const name_idx = self.readNodeIdx(node.data.extra, 0);
    const members_owned = try ev.known.toOwnedSlice(self.allocator);
    if (prior_index) |pi| {
        freeMembers(self.allocator, list.items[pi].members);
        self.allocator.free(list.items[pi].members);
        list.items[pi].members = members_owned;
        return;
    }
    errdefer {
        freeMembers(self.allocator, members_owned);
        self.allocator.free(members_owned);
    }
    const owned_enum_name = try self.allocator.dupe(u8, self.ast.getText(self.ast.getNode(name_idx).span));
    errdefer self.allocator.free(owned_enum_name);
    // shadowing 안전을 위해 enum binding 의 symbol_id 보관. visitMemberExpression 에서
    // identifier_reference.symbol_id == decl.symbol_id 일 때만 인라인.
    try list.append(self.allocator, .{
        .name = owned_enum_name,
        .members = members_owned,
        .symbol_id = self.getSymbolIdAt(name_idx),
    });
}

fn enumNameAndSymbol(self: *const Transformer, node: Node) ?struct { name: []const u8, sym: ?u32 } {
    const name_idx = self.readNodeIdx(node.data.extra, 0);
    if (name_idx.isNone()) return null;
    const name_node = self.ast.getNode(name_idx);
    if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return null;
    return .{ .name = self.ast.getText(name_node.span), .sym = self.getSymbolIdAt(name_idx) };
}

/// const enum 멤버를 평가하여 self.const_enums 에 추가.
/// 평가 불가 expression 이 있으면 해당 enum 전체 등록을 건너뜀 (인라인 미동작 → 기존 동작 유지).
fn collectConstEnum(self: *Transformer, node: Node) Error!void {
    const id = enumNameAndSymbol(self, node) orelse return;
    const prior_index = findEnumDecl(self.const_enums.items, id.name, id.sym);
    const prior: []const ConstEnumMember = if (prior_index) |pi| self.const_enums.items[pi].members else &.{};
    var ev = try evaluateEnum(self, node, prior);
    defer ev.deinit(self.allocator);
    if (!ev.complete) return;
    try storeEnumValues(self, &self.const_enums, node, prior_index, &ev);
    try recordNamespacedConstEnum(self, id.name, id.sym);
}

/// Remember the dotted path of a const enum declared inside a namespace so a
/// `N.E.A` read outside the namespace can be inlined (#5600).
fn recordNamespacedConstEnum(self: *Transformer, enum_name: []const u8, enum_sym: ?u32) Error!void {
    if (self.namespace_path.items.len == 0) return;
    for (self.namespaced_const_enums.items) |entry| {
        if (entry.enum_symbol_id == enum_sym and std.mem.eql(u8, entry.enum_name, enum_name)) return;
    }
    var path: std.ArrayList(u8) = .empty;
    errdefer path.deinit(self.allocator);
    for (self.namespace_path.items) |segment| {
        try path.appendSlice(self.allocator, segment);
        try path.append(self.allocator, '.');
    }
    try path.appendSlice(self.allocator, enum_name);
    const owned = try path.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned);
    try self.namespaced_const_enums.append(self.allocator, .{
        .path = owned,
        .root_symbol_id = self.namespace_root_symbol_id,
        .enum_name = enum_name,
        .enum_symbol_id = enum_sym,
    });
}

/// 평가 컨텍스트: 현재 collecting 중인 enum의 정보 (self-reference 해결용).
const ConstEnumEvalCtx = struct {
    current_members: []const ConstEnumMember,
    current_name: []const u8,
    current_symbol_id: ?u32,
    /// #4232: concat (`+`) 이 만드는 중간/결과 문자열 수거 리스트 — 평가
    /// 종료 후 호출자가 일괄 해제 (멤버 저장은 재-dupe). 없으면 GPA 에서
    /// 연산자당 1건 누수 (arena 호출처는 무해했으나 GPA-contract 위반).
    temp_strings: *std.ArrayList([]const u8),
};

/// const enum initializer expression 재귀 평가.
fn evalConstEnumExpr(
    self: *Transformer,
    expr_idx: NodeIndex,
    ctx: ConstEnumEvalCtx,
) Error!?ConstEnumValue {
    const node = self.ast.getNode(expr_idx);
    // 괄호 + TS/Flow 타입 wrapper — 값엔 영향 없으니 inner 만 평가 (#2193, #3129).
    // 누락 시 `Blue = "B" as any` 같은 cast 멤버 하나로 collectConstEnum 의
    // `orelse return` 이 enum 전체 등록을 실패시켜 ReferenceError 가 된다.
    if (Tag.isTransparentWrapper(node.tag)) {
        const inner = node.data.unary.operand;
        if (inner.isNone()) return null;
        return evalConstEnumExpr(self, inner, ctx);
    }
    switch (node.tag) {
        .numeric_literal => {
            const text = self.ast.getText(node.span);
            const n = std.fmt.parseFloat(f64, text) catch {
                // hex/octal/binary literal 등 parseFloat 실패 시 정수 파싱 시도
                const ni = std.fmt.parseInt(i64, text, 0) catch return null;
                return .{ .number = @floatFromInt(ni) };
            };
            return .{ .number = n };
        },
        .string_literal => {
            const raw = self.ast.getText(node.data.string_ref);
            if (raw.len < 2) return null;
            return .{ .string = raw[1 .. raw.len - 1] };
        },
        // A no-substitution template is a string constant too (#5665). Only text that reads the
        // same inside double quotes — no escape, quote or line break.
        .template_literal => {
            if (node.data.list.len != 0) return null;
            const raw = self.ast.getText(node.span);
            if (raw.len < 2) return null;
            const inner = raw[1 .. raw.len - 1];
            if (std.mem.indexOfAny(u8, inner, "\\\"'\n\r$") != null) return null;
            return .{ .string = inner };
        },
        .boolean_literal => {
            // ECMAScript: true=1, false=0 (Number 변환).
            return .{ .number = if (node.data.none == 1) 1 else 0 };
        },
        .unary_expression => {
            const ue = node.data.extra;
            if (ue + 1 >= self.ast.extra_data.items.len) return null;
            const operand_idx = self.readNodeIdx(ue, 0);
            const op = @as(token_mod.Kind, @enumFromInt(self.readU32(ue, 1) & 0xff));
            const v = (try evalConstEnumExpr(self, operand_idx, ctx)) orelse return null;
            if (v != .number) return null;
            const n = v.number;
            return switch (op) {
                .minus => .{ .number = -n },
                .plus => .{ .number = n },
                .tilde => .{ .number = @floatFromInt(~@as(i32, @intFromFloat(n))) },
                .bang => .{ .number = if (n == 0) 1 else 0 },
                else => null,
            };
        },
        .binary_expression => {
            const lv = (try evalConstEnumExpr(self, node.data.binary.left, ctx)) orelse return null;
            const rv = (try evalConstEnumExpr(self, node.data.binary.right, ctx)) orelse return null;
            const op = @as(token_mod.Kind, @enumFromInt(node.data.binary.flags));
            // 문자열 + 문자열은 concatenation (TS 가 허용).
            if (lv == .string and rv == .string and op == .plus) {
                const concat = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ lv.string, rv.string });
                errdefer self.allocator.free(concat);
                try ctx.temp_strings.append(self.allocator, concat);
                return .{ .string = concat };
            }
            if (lv != .number or rv != .number) return null;
            const ln = lv.number;
            const rn = rv.number;
            const li: i32 = @intFromFloat(ln);
            const ri: i32 = @intFromFloat(rn);
            return switch (op) {
                .plus => .{ .number = ln + rn },
                .minus => .{ .number = ln - rn },
                .star => .{ .number = ln * rn },
                .slash => .{ .number = ln / rn },
                .percent => .{ .number = @rem(ln, rn) },
                .star2 => .{ .number = std.math.pow(f64, ln, rn) },
                .shift_left => .{ .number = @floatFromInt(li << @intCast(@as(u5, @truncate(@as(u32, @bitCast(ri)))))) },
                .shift_right => .{ .number = @floatFromInt(li >> @intCast(@as(u5, @truncate(@as(u32, @bitCast(ri)))))) },
                .shift_right3 => .{ .number = @floatFromInt(@as(u32, @bitCast(li)) >> @intCast(@as(u5, @truncate(@as(u32, @bitCast(ri)))))) },
                .pipe => .{ .number = @floatFromInt(li | ri) },
                .amp => .{ .number = @floatFromInt(li & ri) },
                .caret => .{ .number = @floatFromInt(li ^ ri) },
                else => null,
            };
        },
        .identifier_reference => {
            // 같은 enum 안의 다른 멤버 참조 (예: `B = A + 1`)
            const name = self.ast.getText(node.span);
            for (ctx.current_members) |m| {
                if (cooked_name.eql(m.name, name)) return m.value;
            }
            return null;
        },
        .static_member_expression, .computed_member_expression => {
            // 다른 const enum 또는 자기 자신 (`Other.X` from `B = Other.X * 2` inside Other) 참조
            if (try tryEvalEnumMemberAccess(self, node, ctx)) |v| return v;
            return null;
        },
        else => return null,
    }
}

/// member access 가 다른 const enum 또는 현재 collecting 중인 enum 의 멤버를 참조하면 그 값을 반환.
/// `EnumName.Member`, `EnumName["Member"]` 모두 지원. shadowing 검사 적용.
fn tryEvalEnumMemberAccess(self: *const Transformer, node: Node, ctx: ConstEnumEvalCtx) Error!?ConstEnumValue {
    const e = node.data.extra;
    if (e + 1 >= self.ast.extra_data.items.len) return null;
    const obj_idx = self.readNodeIdx(e, 0);
    const prop_idx = self.readNodeIdx(e, 1);
    if (obj_idx.isNone() or prop_idx.isNone()) return null;

    const obj_node = self.ast.getNode(obj_idx);
    if (obj_node.tag != .identifier_reference) return null;
    const obj_name = self.ast.getText(obj_node.span);
    const obj_sym = self.getSymbolIdAt(obj_idx);

    const prop_name = (memberPropertyName(self, node.tag, prop_idx)) orelse return null;

    // 현재 collecting 중인 enum self-reference (예: `Other.X` from inside Other 정의)
    if (matchesEnumName(ctx.current_name, ctx.current_symbol_id, obj_name, obj_sym) or
        isEnumIifeParameter(self, obj_sym, obj_name, ctx.current_name))
    {
        for (ctx.current_members) |m| {
            if (cooked_name.eql(m.name, prop_name)) return m.value;
        }
    }

    for (self.const_enums.items) |decl| {
        if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
        for (decl.members) |m| {
            if (cooked_name.eql(m.name, prop_name)) return m.value;
        }
    }
    return null;
}

/// Inside its own body an enum's name resolves to the generated IIFE parameter.
fn isEnumIifeParameter(self: *const Transformer, ref_sym: ?u32, ref_name: []const u8, enum_name: []const u8) bool {
    const sid = ref_sym orelse return false;
    if (sid >= self.symbols.len) return false;
    return self.symbols[sid].synthetic_kind == .enum_iife_parameter and std.mem.eql(u8, ref_name, enum_name);
}

fn matchesEnumName(decl_name: []const u8, decl_sym: ?u32, ref_name: []const u8, ref_sym: ?u32) bool {
    if (decl_sym != null and ref_sym != null) return decl_sym.? == ref_sym.?;
    return std.mem.eql(u8, decl_name, ref_name);
}

/// `EnumName.Member` 또는 `EnumName["Member"]` 이면 미리 평가한 literal 노드로 치환.
/// shadowing 안전: identifier_reference 의 symbol_id 가 enum 선언의 symbol_id 와 일치할 때만 인라인.
pub fn tryInlineConstEnumMember(self: *Transformer, node: Node) Error!?NodeIndex {
    if (self.const_enums.items.len == 0) return null;
    if (node.tag != .static_member_expression and node.tag != .computed_member_expression) return null;
    const e = node.data.extra;
    if (e + 1 >= self.ast.extra_data.items.len) return null;
    const obj_idx = self.readNodeIdx(e, 0);
    const prop_idx = self.readNodeIdx(e, 1);
    if (obj_idx.isNone() or prop_idx.isNone()) return null;

    const obj_node = self.ast.getNode(obj_idx);
    const prop_name = memberPropertyName(self, node.tag, prop_idx) orelse return null;
    if (obj_node.tag == .static_member_expression) return inlineNamespacedConstEnumMember(self, obj_idx, prop_name, node.span);
    if (obj_node.tag != .identifier_reference) return null;
    const obj_name = self.ast.getText(obj_node.span);
    const obj_sym = self.getSymbolIdAt(obj_idx);

    for (self.const_enums.items) |decl| {
        if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
        for (decl.members) |m| {
            if (!cooked_name.eql(m.name, prop_name)) continue;
            return try makeConstEnumLiteralNode(self, m.value, node.span);
        }
    }
    return null;
}

/// `N.E.A` / `O.I.E["B"]`: the object is a static member chain rooted at the
/// namespace binding that declared const enum `E` (#5600). The const enum
/// declaration itself is erased, so inlining is the only way the read works.
fn inlineNamespacedConstEnumMember(self: *Transformer, obj_idx: NodeIndex, prop_name: []const u8, span: Span) Error!?NodeIndex {
    if (self.namespaced_const_enums.items.len == 0) return null;
    var segments: [16][]const u8 = undefined;
    var count: usize = 0;
    var cursor = obj_idx;
    while (true) {
        const n = self.ast.getNode(cursor);
        if (count == segments.len) return null;
        switch (n.tag) {
            .static_member_expression => {
                const e = n.data.extra;
                if (e + 1 >= self.ast.extra_data.items.len) return null;
                const prop = self.readNodeIdx(e, 1);
                if (prop.isNone() or self.ast.getNode(prop).tag != .identifier_reference) return null;
                segments[count] = self.ast.getText(self.ast.getNode(prop).span);
                count += 1;
                cursor = self.readNodeIdx(e, 0);
                if (cursor.isNone()) return null;
            },
            .identifier_reference => {
                segments[count] = self.ast.getText(n.span);
                count += 1;
                break;
            },
            else => return null,
        }
    }
    const root_sym = self.getSymbolIdAt(cursor);
    for (self.namespaced_const_enums.items) |entry| {
        // Compare the dotted path without allocating: segments are innermost-first.
        var rest = entry.path;
        var i = count;
        var matched = true;
        while (i > 0) : (i -= 1) {
            const seg = segments[i - 1];
            if (!std.mem.startsWith(u8, rest, seg)) {
                matched = false;
                break;
            }
            rest = rest[seg.len..];
            if (i > 1) {
                if (rest.len == 0 or rest[0] != '.') {
                    matched = false;
                    break;
                }
                rest = rest[1..];
            }
        }
        if (!matched or rest.len != 0) continue;
        if (entry.root_symbol_id != null and root_sym != null and entry.root_symbol_id.? != root_sym.?) continue;
        const decl_index = findEnumDecl(self.const_enums.items, entry.enum_name, entry.enum_symbol_id) orelse continue;
        for (self.const_enums.items[decl_index].members) |m| {
            if (!cooked_name.eql(m.name, prop_name)) continue;
            return try makeConstEnumLiteralNode(self, m.value, span);
        }
    }
    return null;
}

fn memberPropertyName(self: *const Transformer, member_tag: Tag, prop_idx: NodeIndex) ?[]const u8 {
    const prop_node = self.ast.getNode(prop_idx);
    if (member_tag == .static_member_expression) {
        if (prop_node.tag != .identifier_reference) return null;
        return self.ast.getText(prop_node.span);
    }
    // computed: string_literal 만 컴파일타임 평가 가능
    if (prop_node.tag != .string_literal) return null;
    const raw = self.ast.getText(prop_node.data.string_ref);
    if (raw.len < 2) return null;
    return raw[1 .. raw.len - 1];
}

/// shadowing 안전 매칭: symbol_id 가 둘 다 있으면 그것으로, 둘 중 하나라도 없으면 이름만으로.
/// (semantic analyzer 가 비활성인 테스트 환경에서도 동작하도록 fallback.)
fn enumDeclMatches(decl: ConstEnumDecl, ref_name: []const u8, ref_sym: ?u32) bool {
    if (decl.symbol_id != null and ref_sym != null) {
        return decl.symbol_id.? == ref_sym.?;
    }
    return std.mem.eql(u8, decl.name, ref_name);
}

fn makeConstEnumLiteralNode(self: *Transformer, value: ConstEnumValue, _: Span) Error!NodeIndex {
    switch (value) {
        .number => |n| {
            var buf: [64]u8 = undefined;
            // 정수면 정수 형식으로, 아니면 일반 형식으로.
            const s = if (@floor(n) == n and !std.math.isInf(n))
                std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch return Error.OutOfMemory
            else
                std.fmt.bufPrint(&buf, "{d}", .{n}) catch return Error.OutOfMemory;
            const num_span = try self.ast.addString(s);
            return self.ast.addNode(.{
                .tag = .numeric_literal,
                .span = num_span,
                .data = .{ .none = 0 },
            });
        },
        .string => |raw| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try buf.ensureTotalCapacity(self.allocator, raw.len + 2);
            try buf.append(self.allocator, '"');
            // #4228: raw body 는 escape 보존 슬라이스 (출처 quote 는 '/" 혼합 가능
            // — concat 포함). escape pair 는 원자 보존하고 unescaped `"` 만 추가
            // escape — verbatim 재인용은 `'say "hi"'` 류에서 전 타겟 SyntaxError.
            var i: usize = 0;
            while (i < raw.len) : (i += 1) {
                const ch = raw[i];
                if (ch == '\\' and i + 1 < raw.len) {
                    try buf.append(self.allocator, '\\');
                    try buf.append(self.allocator, raw[i + 1]);
                    i += 1;
                } else if (ch == '"') {
                    try buf.appendSlice(self.allocator, "\\\"");
                } else {
                    try buf.append(self.allocator, ch);
                }
            }
            try buf.append(self.allocator, '"');
            // #4214 동형: 합성 노드는 visit 우회라 \u{...} brace escape 를 직접
            // 다운레벨 (es5 등 unicode_brace 미지원 타겟).
            if (self.options.unsupported.unicode_brace_escape) {
                const unicode_escape_lower = @import("../unicode_escape_lower.zig");
                if (try unicode_escape_lower.lowerContent(self.allocator, buf.items[1 .. buf.items.len - 1])) |lowered| {
                    defer self.allocator.free(lowered);
                    buf.clearRetainingCapacity();
                    try buf.append(self.allocator, '"');
                    try buf.appendSlice(self.allocator, lowered);
                    try buf.append(self.allocator, '"');
                }
            }
            const str_span = try self.ast.addString(buf.items);
            return self.ast.addNode(.{
                .tag = .string_literal,
                .span = str_span,
                .data = .{ .string_ref = str_span },
            });
        },
    }
}
