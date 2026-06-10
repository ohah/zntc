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
                if (cookedNameEql(m.name, name)) return m.value;
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
            if (cookedNameEql(m.name, prop_name)) return m.value;
        }
    }

    for (self.const_enums.items) |decl| {
        if (!enumDeclMatches(decl, obj_name, obj_sym)) continue;
        for (decl.members) |m| {
            if (cookedNameEql(m.name, prop_name)) return m.value;
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
            if (!cookedNameEql(m.name, prop_name)) continue;
            return try makeConstEnumLiteralNode(self, m.value, node.span);
        }
    }
    return null;
}

/// escape-보존 표기에서 다음 cooked 코드포인트를 디코드 (#4231).
/// string escape (\n \t \r \b \f \v \0 \xHH \uHHHH[pair] \u{...}
/// NonEscape identity, LineContinuation=문자 없음) + raw UTF-8.
/// 디코드 실패 시 null — 호출자는 raw eql 폴백.
fn nextCookedCp(t: []const u8, i: *usize) ?u21 {
    const c = t[i.*];
    if (c != '\\') {
        const len = std.unicode.utf8ByteSequenceLength(c) catch return null;
        if (i.* + len > t.len) return null;
        const cp = std.unicode.utf8Decode(t[i.* .. i.* + len]) catch return null;
        i.* += len;
        return cp;
    }
    if (i.* + 1 >= t.len) return null;
    const e = t[i.* + 1];
    i.* += 2;
    switch (e) {
        'n' => return '\n',
        't' => return '\t',
        'r' => return '\r',
        'b' => return 0x08,
        'f' => return 0x0C,
        'v' => return 0x0B,
        '0' => {
            // \0 + digit 은 legacy octal — strict 금지, 보수적으로 실패 처리.
            if (i.* < t.len and t[i.*] >= '0' and t[i.*] <= '9') return null;
            return 0;
        },
        'x' => {
            if (i.* + 2 > t.len) return null;
            var cp: u21 = 0;
            for (t[i.* .. i.* + 2]) |h| {
                const d = std.fmt.charToDigit(h, 16) catch return null;
                cp = cp * 16 + d;
            }
            i.* += 2;
            return cp;
        },
        'u' => {
            if (i.* < t.len and t[i.*] == '{') {
                var j = i.* + 1;
                const hs = j;
                var cp: u32 = 0;
                while (j < t.len and t[j] != '}') : (j += 1) {
                    const d = std.fmt.charToDigit(t[j], 16) catch return null;
                    cp = cp * 16 + d;
                    if (cp > 0x10FFFF) return null;
                }
                if (j >= t.len or j == hs) return null;
                i.* = j + 1;
                return @intCast(cp);
            }
            if (i.* + 4 > t.len) return null;
            var cp: u32 = 0;
            for (t[i.* .. i.* + 4]) |h| {
                const d = std.fmt.charToDigit(h, 16) catch return null;
                cp = cp * 16 + d;
            }
            i.* += 4;
            if (cp >= 0xD800 and cp <= 0xDBFF and i.* + 6 <= t.len and
                t[i.*] == '\\' and t[i.* + 1] == 'u' and t[i.* + 2] != '{')
            {
                var lo: u32 = 0;
                var ok = true;
                for (t[i.* + 2 .. i.* + 6]) |h| {
                    const d = std.fmt.charToDigit(h, 16) catch {
                        ok = false;
                        break;
                    };
                    lo = lo * 16 + d;
                }
                if (ok and lo >= 0xDC00 and lo <= 0xDFFF) {
                    i.* += 6;
                    return @intCast(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
                }
            }
            return @intCast(cp);
        },
        '1', '2', '3', '4', '5', '6', '7' => {
            // legacy octal escape — TS 는 거부(TS1487)하나 우리 파서가 수용하는
            // 입력에서 identity 오쿡 방지: 보수적으로 실패 → raw 폴백.
            return null;
        },
        '\n', '\r' => {
            // LineContinuation: cooked 기여 없음 — CRLF pair skip 후 다음 문자.
            if (e == '\r' and i.* < t.len and t[i.*] == '\n') i.* += 1;
            if (i.* >= t.len) return null;
            return nextCookedCp(t, i);
        },
        else => {
            // NonEscapeCharacter: identity (\' \" \\ \` 포함, 멀티바이트 lead 도 그대로)
            const len = std.unicode.utf8ByteSequenceLength(e) catch return null;
            if (i.* - 1 + len > t.len) return null;
            const cp = std.unicode.utf8Decode(t[i.* - 1 .. i.* - 1 + len]) catch return null;
            i.* += len - 1;
            return cp;
        },
    }
}

/// LineContinuation (`\` + LF/CR[LF]/U+2028/9) 연쇄를 소거 — cooked 기여 0.
/// end 검사 전에 호출해야 trailing continuation ('q\<LF>' vs 'q') 이 정확.
fn skipLineContinuations(t: []const u8, i: *usize) void {
    while (i.* + 1 < t.len and t[i.*] == '\\') {
        const n1 = t[i.* + 1];
        if (n1 == '\n') {
            i.* += 2;
        } else if (n1 == '\r') {
            i.* += 2;
            if (i.* < t.len and t[i.*] == '\n') i.* += 1;
        } else if (n1 == 0xe2 and i.* + 4 <= t.len and
            t[i.* + 2] == 0x80 and (t[i.* + 3] == 0xa8 or t[i.* + 3] == 0xa9))
        {
            i.* += 4;
        } else break;
    }
}

const CookedIter = struct {
    t: []const u8,
    i: usize = 0,
    /// astral cp 의 low surrogate 보류분 — UTF-16 code unit 단위 비교용.
    pending_lo: ?u21 = null,

    /// u21 범위 밖은 불가하므로 surrogate-범위 위 값으로 디코드 실패 표시.
    const error_marker: u21 = 0x1FFFFF;

    /// 다음 UTF-16 code unit. 혼합 escape 표기(`\uD83D\u{DE00}` vs 😀)도
    /// unit 시퀀스로는 동일해져 정확 비교 (#4231 리뷰).
    fn next(self: *@This()) ?u21 {
        if (self.pending_lo) |lo| {
            self.pending_lo = null;
            return lo;
        }
        skipLineContinuations(self.t, &self.i);
        if (self.i >= self.t.len) return null;
        const cp = nextCookedCp(self.t, &self.i) orelse return error_marker;
        if (cp > 0xFFFF) {
            self.pending_lo = @intCast(0xDC00 + ((cp - 0x10000) & 0x3FF));
            return @intCast(0xD800 + ((cp - 0x10000) >> 10));
        }
        return cp;
    }

    fn atEnd(self: *@This()) bool {
        if (self.pending_lo != null) return false;
        skipLineContinuations(self.t, &self.i);
        return self.i >= self.t.len;
    }
};

/// 두 escape-보존 이름이 cooked(UTF-16 unit 시퀀스) 기준으로 같은가 (#4231).
/// 디코드 실패 시 raw-byte 비교 폴백 (이전 동작 보존 방어선).
/// NOTE: escape 디코더는 string_escape.decodeUnicodeHexEscape /
/// regexp/group_name.zig nextCodepoint 와 의도적 별도 구현 — 여기는 string
/// escape 전 문법(superset)이 필요하다. escape 처리 수정 시 셋을 교차 점검.
fn cookedNameEql(a: []const u8, b: []const u8) bool {
    // 공통 케이스 fast-path: byte-identical 이름 (escape 무관하게 동일 cooked).
    if (std.mem.eql(u8, a, b)) return true;
    var xa = CookedIter{ .t = a };
    var xb = CookedIter{ .t = b };
    while (true) {
        const ae = xa.atEnd();
        const be = xb.atEnd();
        if (ae and be) return true;
        if (ae != be) return false;
        const ua = xa.next() orelse return false;
        const ub = xb.next() orelse return false;
        if (ua == CookedIter.error_marker or ub == CookedIter.error_marker)
            return std.mem.eql(u8, a, b);
        if (ua != ub) return false;
    }
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
