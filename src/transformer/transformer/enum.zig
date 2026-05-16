//! TypeScript / Flow enum helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
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
/// flags: 0=일반 enum (codegen에서 IIFE), 1=const enum (선언 삭제 + 멤버를 self.const_enums 에 보관 → visitMemberExpression 에서 literal 인라인).
pub fn visitEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const flags = self.readU32(e, 3);

    if (flags == 1) {
        // 평가 가능한 단순 케이스만 등록. 실패해도 선언은 삭제 (참조는 그대로 남아 ReferenceError가 나지만,
        // 기존 동작과 동일하므로 회귀가 아님 — 인라인 가능 케이스만 새로 동작 추가).
        collectConstEnum(self, node) catch {};
        return .none;
    }

    const new_name = try self.visitNode(self.readNodeIdx(e, 0));
    const new_members = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
    return self.addExtraNode(.ts_enum_declaration, node.span, &.{
        @intFromEnum(new_name), new_members.start, new_members.len, flags,
    });
}

/// const enum 멤버를 평가하여 self.const_enums 에 추가.
/// TypeScript spec 의 const enum expression subset 을 지원:
///   numeric/string/boolean literal · 단항(`+ - ~ !`) · 이항(산술/비트/비교/논리) · parenthesized ·
///   같은 enum 내 다른 멤버 참조(`B = A + 1`) · 외부 const enum 참조(`B = OtherEnum.X`) · 빈 init(auto-inc).
/// 평가 불가 expression 은 해당 enum 전체 등록을 건너뜀 (인라인 미동작 → 기존 동작 유지, 회귀 아님).
fn collectConstEnum(self: *Transformer, node: Node) Error!void {
    const e = node.data.extra;
    const name_idx = self.readNodeIdx(e, 0);
    if (name_idx.isNone()) return;
    const name_node = self.ast.getNode(name_idx);
    if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return;
    const enum_name_src = self.ast.getText(name_node.span);

    const members_start = self.readU32(e, 1);
    const members_len = self.readU32(e, 2);

    var collected: std.ArrayList(ConstEnumMember) = .empty;
    errdefer {
        for (collected.items) |m| {
            self.allocator.free(m.name);
            if (m.value == .string) self.allocator.free(m.value.string);
        }
        collected.deinit(self.allocator);
    }

    var prev_number: ?f64 = null;
    var i: u32 = 0;
    while (i < members_len) : (i += 1) {
        const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[members_start + i]);
        const member_node = self.ast.getNode(member_idx);
        if (member_node.tag != .ts_enum_member) return;

        const key_idx = member_node.data.binary.left;
        const init_idx = member_node.data.binary.right;
        if (key_idx.isNone()) return;
        const key_node = self.ast.getNode(key_idx);
        const member_name_src = switch (key_node.tag) {
            .identifier_reference, .binding_identifier => self.ast.getText(key_node.span),
            .string_literal => blk: {
                const raw = self.ast.getText(key_node.data.string_ref);
                if (raw.len < 2) return;
                break :blk raw[1 .. raw.len - 1];
            },
            else => return,
        };

        var value: ConstEnumValue = undefined;
        if (init_idx.isNone()) {
            const next: f64 = if (prev_number) |pv| pv + 1 else 0;
            value = .{ .number = next };
        } else {
            value = (try evalConstEnumExpr(self, init_idx, .{
                .current_members = collected.items,
                .current_name = enum_name_src,
                .current_symbol_id = self.getSymbolIdAt(name_idx),
            })) orelse return;
        }
        switch (value) {
            .number => |n| prev_number = n,
            .string => prev_number = null,
        }

        const owned_name = try self.allocator.dupe(u8, member_name_src);
        errdefer self.allocator.free(owned_name);
        const owned_value: ConstEnumValue = switch (value) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = try self.allocator.dupe(u8, s) },
        };
        try collected.append(self.allocator, .{ .name = owned_name, .value = owned_value });
    }

    const owned_enum_name = try self.allocator.dupe(u8, enum_name_src);
    errdefer self.allocator.free(owned_enum_name);
    const members_owned = try collected.toOwnedSlice(self.allocator);

    // shadowing 안전을 위해 enum binding 의 symbol_id 보관. visitMemberExpression 에서
    // identifier_reference.symbol_id == decl.symbol_id 일 때만 인라인.
    const sym_id = self.getSymbolIdAt(name_idx);

    try self.const_enums.append(self.allocator, .{
        .name = owned_enum_name,
        .members = members_owned,
        .symbol_id = sym_id,
    });
}

/// 평가 컨텍스트: 현재 collecting 중인 enum의 정보 (self-reference 해결용).
const ConstEnumEvalCtx = struct {
    current_members: []const ConstEnumMember,
    current_name: []const u8,
    current_symbol_id: ?u32,
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
                defer self.allocator.free(concat);
                return .{ .string = try self.allocator.dupe(u8, concat) };
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
                if (std.mem.eql(u8, m.name, name)) return m.value;
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
    if (matchesEnumName(ctx.current_name, ctx.current_symbol_id, obj_name, obj_sym)) {
        for (ctx.current_members) |m| {
            if (std.mem.eql(u8, m.name, prop_name)) return m.value;
        }
    }

    for (self.const_enums.items) |decl| {
        if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
        for (decl.members) |m| {
            if (std.mem.eql(u8, m.name, prop_name)) return m.value;
        }
    }
    return null;
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
    if (obj_node.tag != .identifier_reference) return null;
    const obj_name = self.ast.getText(obj_node.span);
    const obj_sym = self.getSymbolIdAt(obj_idx);

    const prop_name = memberPropertyName(self, node.tag, prop_idx) orelse return null;

    for (self.const_enums.items) |decl| {
        if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
        for (decl.members) |m| {
            if (!std.mem.eql(u8, m.name, prop_name)) continue;
            return try makeConstEnumLiteralNode(self, m.value, node.span);
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
            try buf.appendSlice(self.allocator, raw);
            try buf.append(self.allocator, '"');
            const str_span = try self.ast.addString(buf.items);
            return self.ast.addNode(.{
                .tag = .string_literal,
                .span = str_span,
                .data = .{ .string_ref = str_span },
            });
        },
    }
}
