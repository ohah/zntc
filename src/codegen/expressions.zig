//! Expression and member-expression emit helpers for Codegen.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Kind = @import("../lexer/token.zig").Kind;
const unicode = @import("../lexer/unicode.zig");
const calls = @import("calls.zig");

/// minify_syntax 시 string_literal 객체 키를 따옴표 없이 emit 가능한지.
/// `raw` 는 따옴표 포함 리터럴 텍스트. escape 없는 단순 리터럴이고 valid ES
/// IdentifierName 이며 `__proto__` 가 아닐 때만 true. 객체 키는 reserved
/// word 도 valid 라 reserved 검사 불필요; `{"__proto__":v}` 는 일반 프로퍼티,
/// `{__proto__:v}` 는 proto setter 라 semantic 이 달라져 반드시 제외.
fn objectKeyUnquotable(raw: []const u8) bool {
    if (raw.len < 2) return false;
    const q = raw[0];
    if ((q != '"' and q != '\'') or raw[raw.len - 1] != q) return false;
    const s = raw[1 .. raw.len - 1];
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, '\\') != null) return false;
    if (std.mem.eql(u8, s, "__proto__")) return false;
    if (!unicode.isIdentifierStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!unicode.isIdentifierContinue(c)) return false;
    }
    return true;
}

pub fn emitUnary(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e + 1 >= extras.len) return;
    const operand: NodeIndex = @enumFromInt(extras[e]);
    const op: Kind = @enumFromInt(@as(u8, @truncate(extras[e + 1])));
    if (op == .bang and self.options.linking_metadata != null) {
        if (self.evalBooleanCondition(operand)) |v| {
            try self.write(if (!v) "true" else "false");
            return;
        }
    }
    try self.write(op.symbol());
    if (op == .kw_typeof or op == .kw_void or op == .kw_delete) try self.writeByte(' ');
    try self.emitNode(operand);
}

pub fn emitUpdate(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e + 1 >= extras.len) return;
    const operand: NodeIndex = @enumFromInt(extras[e]);
    const flags = extras[e + 1];
    const is_postfix = (flags & ast_mod.UnaryFlags.postfix) != 0;
    const op: Kind = @enumFromInt(@as(u8, @truncate(flags)));
    if (!is_postfix) try self.write(op.symbol());
    // operand 는 update 의 lvalue 타겟 — 미존재 ns 멤버를 `(void 0)` 으로 바꾸면
    // `(void 0)++` SyntaxError 가 되므로 emitStaticMember 가 재작성을 건너뛰게 한다.
    self.member_assign_target = true;
    try self.emitNode(operand);
    self.member_assign_target = false;
    if (is_postfix) try self.write(op.symbol());
}

pub fn emitBinary(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const op: Kind = @enumFromInt(node.data.binary.flags);
    if (self.options.linking_metadata != null and node.tag == .logical_expression) {
        if (self.evalBooleanCondition(node.data.binary.left)) |left_val| {
            if ((op == .amp2 and !left_val) or
                (op == .pipe2 and left_val))
            {
                try self.write(if (left_val) "true" else "false");
                return;
            }
            try self.emitNode(node.data.binary.right);
            return;
        }
    }
    try self.emitNode(node.data.binary.left);
    if (op == .kw_in or op == .kw_instanceof) {
        // 영문 키워드 연산자는 양옆 공백 필수 (`a in b` ≠ `ainb`) — minify 와 무관.
        try self.writeByte(' ');
        try self.write(op.symbol());
        try self.writeByte(' ');
    } else {
        const sym = op.symbol();
        // `+`/`-` 도 minify 시엔 tight (`a+b`). 단 RHS 가 unary `+`/`-` 또는 prefix
        // `++`/`--` 로 시작하면 `++`/`--` 로 토큰이 잘못 합쳐지므로(`a+ +b` → `a++b`)
        // 그 경우에만 한 칸 삽입. 좌측은 합쳐질 일 없음 — postfix `a++` + `+b` 는
        // `a+++b` 로 다시 lex 해도 `(a++)+b` 라 의미 동일.
        try self.writeSpace();
        try self.write(sym);
        if (self.options.minify_whitespace and (op == .plus or op == .minus) and
            rhsLeadingSignChar(self, node.data.binary.right) == sym[0])
        {
            try self.writeByte(' ');
        } else {
            try self.writeSpace();
        }
    }
    try self.emitNode(node.data.binary.right);
}

/// unary_expression / update_expression 의 extra = [operand, flags]. flags 의 low byte 가
/// 연산자 Kind. extra 범위 밖이면 null.
pub fn unaryOpKind(self: anytype, extra_base: u32) ?Kind {
    const extras = self.ast.extra_data.items;
    if (extra_base + 1 >= extras.len) return null;
    return @enumFromInt(@as(u8, @truncate(extras[extra_base + 1])));
}

/// binary `+`/`-` 의 RHS 가 출력 시 `+` 또는 `-` 로 시작하는지 — 시작하면 그 문자 반환,
/// 아니면 null. minify 시 `++`/`--` 토큰 오결합 방지용. unary `+`/`-`, prefix `++`/`--`,
/// 그리고 (상수 폴딩으로 생긴) 음수 numeric/bigint literal 만 해당. 더 높은 우선순위
/// 이항식은 codegen 이 paren 없이 출력하므로 leftmost leaf 로 내려가 검사한다.
fn rhsLeadingSignChar(self: anytype, idx: NodeIndex) ?u8 {
    var cur = idx;
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        const n = self.ast.getNode(cur);
        switch (n.tag) {
            .unary_expression => return switch (unaryOpKind(self, n.data.extra) orelse return null) {
                .plus => '+',
                .minus => '-',
                else => null, // !x, ~x, typeof/void/delete x → 다른 글자로 시작
            },
            .update_expression => {
                const extras = self.ast.extra_data.items;
                const e = n.data.extra;
                if (e + 1 >= extras.len) return null;
                if ((extras[e + 1] & ast_mod.UnaryFlags.postfix) != 0) {
                    cur = @enumFromInt(extras[e]); // `x++` → operand 의 첫 글자로 시작 → 내려감
                    continue;
                }
                return switch (@as(Kind, @enumFromInt(@as(u8, @truncate(extras[e + 1]))))) {
                    .plus2 => '+',
                    .minus2 => '-',
                    else => null,
                };
            },
            .numeric_literal, .bigint_literal => {
                const text = self.ast.getText(n.span);
                return if (text.len > 0 and text[0] == '-') '-' else null;
            },
            // 같은/낮은 우선순위 RHS 는 paren 으로 감싸져 `(` 로 시작 → 안전(null).
            // 더 높은 우선순위(`a + b*c` 의 `b*c`)면 leftmost leaf 로 내려가 검사.
            .binary_expression, .logical_expression => {
                cur = n.data.binary.left;
                continue;
            },
            else => return null,
        }
    }
    return null;
}

pub fn emitAssignment(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    // left 는 assignment 의 lvalue 타겟 — 미존재 ns 멤버를 `(void 0)` 으로 바꾸면
    // `(void 0) = x` SyntaxError 가 되므로 emitStaticMember 가 재작성을 건너뛰게 한다.
    // emitStaticMember 가 진입 즉시 리셋하므로 중첩 object 위치(rvalue)는 영향 없음.
    self.member_assign_target = true;
    try self.emitNode(node.data.binary.left);
    self.member_assign_target = false;
    try self.writeSpace();
    if (node.data.binary.flags != 0) {
        const op: Kind = @enumFromInt(node.data.binary.flags);
        try self.write(op.symbol());
    } else {
        try self.writeByte('=');
    }
    try self.writeSpace();
    const right = node.data.binary.right;
    const is_simple_assign = node.data.binary.flags == 0 or
        @as(Kind, @enumFromInt(node.data.binary.flags)) == .eq;
    if (self.fn_map_builder != null and is_simple_assign and self.isFunctionLike(right)) {
        const saved = self.pending_fn_name;
        self.pending_fn_name = try self.resolveMemberLeafName(node.data.binary.left);
        defer {
            if (self.pending_fn_name) |s| self.allocator.free(s);
            self.pending_fn_name = saved;
        }
        try self.emitNode(right);
    } else {
        try self.emitNode(right);
    }
}

pub fn emitConditional(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const t = node.data.ternary;
    if (self.options.linking_metadata != null) {
        if (self.evalBooleanCondition(t.a)) |cond| {
            try self.emitNode(if (cond) t.b else t.c);
            return;
        }
    }
    try self.emitNode(t.a);
    try self.writeSpace();
    try self.writeByte('?');
    try self.writeSpace();
    try self.emitNode(t.b);
    try self.writeSpace();
    try self.writeByte(':');
    try self.writeSpace();
    try self.emitNode(t.c);
}

pub fn emitSequence(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.emitList(node, ",");
}

pub fn emitParen(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.writeByte('(');
    try self.emitNode(node.data.unary.operand);
    try self.writeByte(')');
}

pub fn emitSpread(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("...");
    try self.emitNode(node.data.unary.operand);
}

pub fn emitAwait(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("await ");
    try self.emitNode(node.data.unary.operand);
}

pub fn emitYield(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("yield");
    if (node.data.unary.flags & 1 != 0) try self.writeByte('*');
    if (!node.data.unary.operand.isNone()) {
        try self.writeByte(' ');
        try self.emitNode(node.data.unary.operand);
    }
}

pub fn emitArray(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.writeByte('[');
    try self.emitExpressionList(node, self.listSep());
    try self.writeByte(']');
}

pub fn emitObject(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const list = node.data.list;
    if (list.len == 0) {
        try self.write("{}");
        return;
    }
    if (self.options.minify_whitespace) {
        try self.writeByte('{');
        try self.emitList(node, ",");
        try self.writeByte('}');
    } else {
        try self.write("{ ");
        try self.emitList(node, ", ");
        try self.write(" }");
    }
}

pub fn emitObjectProperty(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const key = node.data.binary.left;
    const value = node.data.binary.right;
    if (key.isNone()) return;
    if (value.isNone()) {
        if (identifierHasRename(self, key) or identifierHasConstValue(self, key)) {
            const key_node = self.ast.getNode(key);
            try self.writeSpan(key_node.data.string_ref);
            if (self.options.minify_whitespace) {
                try self.writeByte(':');
            } else {
                try self.write(": ");
            }
            try self.emitNode(key);
        } else {
            try self.emitNode(key);
        }
    } else {
        const key_node = self.ast.getNode(key);
        if (key_node.tag == .identifier_reference) {
            try self.writeSpan(key_node.data.string_ref);
        } else if (key_node.tag == .string_literal and self.options.minify_syntax) {
            const raw = self.ast.getText(key_node.span);
            if (objectKeyUnquotable(raw)) {
                try self.write(ast_mod.Ast.stripStringQuotes(raw));
            } else {
                try self.emitNode(key);
            }
        } else {
            try self.emitNode(key);
        }
        if (self.options.minify_whitespace) {
            try self.writeByte(':');
        } else {
            try self.write(": ");
        }
        if (self.fn_map_builder != null and self.isFunctionLike(value)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = try self.ast.staticKeyName(self.allocator, key);
            defer {
                if (self.pending_fn_name) |s| self.allocator.free(s);
                self.pending_fn_name = saved;
            }
            try self.emitNode(value);
        } else {
            try self.emitNode(value);
        }
    }
}

pub fn identifierHasRename(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const key_node = self.ast.getNode(idx);
    if (self.options.linking_metadata) |meta| {
        if (self.resolveSymbolId(idx, meta)) |sym_id| {
            if (meta.renames.get(sym_id) != null) return true;
        }
    }
    if (self.ns_prefix) |_| {
        if (key_node.tag == .identifier_reference or key_node.tag == .assignment_target_identifier) {
            const name = self.ast.getText(key_node.data.string_ref);
            if (self.ns_exports) |exports| {
                if (exports.contains(name)) return true;
            }
        }
    }
    return false;
}

fn identifierHasConstValue(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    if (self.options.linking_metadata) |meta| {
        if (self.resolveSymbolId(idx, meta)) |sym_id| {
            if (meta.const_values.get(sym_id)) |cv| return cv.isSafeToInline();
        }
    }
    return false;
}

pub fn emitComputedKey(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.writeByte('[');
    try self.emitNode(node.data.unary.operand);
    try self.writeByte(']');
}

pub fn emitStaticMember(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return;
    const object = self.ast.readExtraNode(e, 0);
    const property = self.ast.readExtraNode(e, 1);
    const flags = self.ast.readExtra(e, 2);
    const MemberFlags = ast_mod.MemberFlags;

    // 이 member 가 assignment/update 의 lvalue 타겟인지. 진입 즉시 읽고 리셋해
    // object(중첩 member) 재귀 emit 은 rvalue 로 처리되게 한다.
    const is_assign_target = self.member_assign_target;
    self.member_assign_target = false;

    if (self.options.linking_metadata) |meta| {
        // optional chain(`ns?.prop`)도 포함한다. module namespace 객체는 절대 nullish 가
        // 아니므로 ns 위치의 선행 `?.` 는 단락(short-circuit)되지 않는 no-op — 치환 시
        // `?.` 를 안전히 제거할 수 있다(`ns?.x` ≡ `ns.x`). 체인 뒤쪽(`ns?.a?.b`)의 `?.`
        // 는 각자의 base 기준이라 영향 없음. (이 블록이 fire 하지 않으면 아래 일반 emit 이
        // `?.` 를 그대로 보존한다.)
        const obj_node_i = @intFromEnum(object);
        if (obj_node_i < meta.symbol_ids.len) {
            if (meta.symbol_ids[obj_node_i]) |obj_sym_id| {
                if (meta.ns_member_rewrites.get(obj_sym_id)) |inner_map| {
                    const prop_node = self.ast.getNode(property);
                    const prop_text = self.ast.getText(prop_node.data.string_ref);
                    if (inner_map.get(prop_text)) |canonical_name| {
                        if (canonical_name.len > 0 and canonical_name[0] == '{') {
                            try self.writeByte('(');
                            try self.write(canonical_name);
                            try self.writeByte(')');
                        } else {
                            try self.write(canonical_name);
                        }
                        return;
                    }
                    // 멤버가 rewrite map 에 없음 = 그 export 가 존재하지 않음(static ESM).
                    // ns 객체가 member-rewrite 로 materialize 되지 않았다면(ns_inline_objects
                    // 미등록) `ns.prop` 은 선언된 적 없는 ns 식별자를 참조해 ReferenceError 가
                    // 된다 — ESM 은 미존재 멤버를 undefined 로 평가하므로 `void 0` 으로 재작성한다
                    // (#3982 ambiguous 멤버와 동형, esbuild parity). materialize 된 경우(값 사용/
                    // shadow)는 ns 가 renamed 변수로 선언돼 있어 fall-through(`var.prop`→undefined)
                    // 가 안전하고, CJS namespace 는 copyProps+rename 경로라 inner_map 자체가 없어
                    // 이 분기에 도달하지 않는다(동적 멤버를 void 0 으로 잘못 가리지 않음).
                    //
                    // 두 가드:
                    //  - lvalue 타겟(`ns.x = 1`/`ns.x++`)이면 `(void 0)=1` 은 SyntaxError →
                    //    재작성 skip, 기존 fall-through 유지(런타임 throw, namespace 멤버
                    //    대입은 어차피 ESM 에러). optional chain(`ns?.x`)은 LHS 가 될 수 없어
                    //    이 가드와 무관.
                    //  - dev 번들은 모듈이 항상 wrapper 로 선언돼 `ns` 가 존재하므로 dangling
                    //    이 발생하지 않는다. 재작성 불필요 + CJS 동적 멤버 오인 방지 위해 skip.
                    if (!is_assign_target and
                        self.options.dev_module_id == null and
                        meta.ns_inline_objects.get(obj_sym_id) == null)
                    {
                        // `(void 0)` — paren 필수. 이 멤버 식은 call/member 의 피연산자가
                        // 될 수 있어(`ns.x()`, `ns.x.y`) bare `void 0` 은 `void 0()`(=
                        // `void(0())`) / `void 0.y`(SyntaxError) 로 잘못 파싱된다. paren 으로
                        // 감싸면 모든 컨텍스트에서 undefined 의미가 보존된다.
                        try self.write("(void 0)");
                        return;
                    }
                }
            }
        }
    }

    if (self.options.dev_module_id != null or self.options.module_format == .cjs or self.options.replace_import_meta) {
        if (self.resolveImportMetaProp(object, property)) |prop_text| {
            if (self.options.dev_module_id) |dev_id| {
                if (std.mem.eql(u8, prop_text, "hot")) {
                    try self.write("__zntc_make_hot(\"");
                    try self.write(dev_id);
                    try self.write("\")");
                    return;
                }
            }
            if (self.options.module_format == .cjs or self.options.replace_import_meta) {
                if (std.mem.eql(u8, prop_text, "url")) {
                    try self.writeImportMetaUrl();
                    return;
                }
                if (self.options.platform == .node) {
                    if (std.mem.eql(u8, prop_text, "dirname")) {
                        try self.write("__dirname");
                        return;
                    } else if (std.mem.eql(u8, prop_text, "filename")) {
                        try self.write("__filename");
                        return;
                    }
                } else {
                    if (std.mem.eql(u8, prop_text, "dirname") or std.mem.eql(u8, prop_text, "filename")) {
                        try self.write("\"\"");
                        return;
                    }
                }
            }
        }
    }

    try calls.emitNodeMaybeUndefParen(self, object);
    if (flags & MemberFlags.optional_chain != 0) {
        try self.write("?.");
    } else {
        try self.writeByte('.');
    }
    // property name 슬롯은 reserved word 도 valid identifier 로 취급되므로 peephole
    // 치환 (예: `undefined` → `void 0`) 이 적용되면 안 된다 — `obj.undefined` 가
    // `obj.void 0` 로 깨지면 SyntaxError. emitNode 우회 시 sourcemap mapping 이
    // 같이 빠지므로 명시 발행 후 raw span 출력.
    const prop_node = self.ast.getNode(property);
    try self.addSourceMapping(prop_node.span);
    try self.writeNodeSpan(prop_node);
}

pub fn emitComputedMember(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return;
    const object = self.ast.readExtraNode(e, 0);
    const property = self.ast.readExtraNode(e, 1);
    const flags = self.ast.readExtra(e, 2);
    const MemberFlags = ast_mod.MemberFlags;
    try calls.emitNodeMaybeUndefParen(self, object);
    if (flags & MemberFlags.optional_chain != 0) {
        try self.write("?.");
    }
    try self.writeByte('[');
    try self.emitNode(property);
    try self.writeByte(']');
}

test "objectKeyUnquotable: valid IdentifierName 만 unquote (semantic-preserving)" {
    const t = std.testing;
    // valid: 따옴표 벗겨도 동일 — reserved word 도 객체 키로는 valid
    try t.expect(objectKeyUnquotable("\"source\""));
    try t.expect(objectKeyUnquotable("\"extensions\""));
    try t.expect(objectKeyUnquotable("'compressible'"));
    try t.expect(objectKeyUnquotable("\"_x\""));
    try t.expect(objectKeyUnquotable("\"$a\""));
    try t.expect(objectKeyUnquotable("\"a1\""));
    try t.expect(objectKeyUnquotable("\"if\"")); // reserved word: {if:1} 은 valid JS
    // invalid: quote 유지해야 정확성 보존
    try t.expect(!objectKeyUnquotable("\"\"")); // 빈 키
    try t.expect(!objectKeyUnquotable("\"1a\"")); // 숫자 시작
    try t.expect(!objectKeyUnquotable("\"a-b\"")); // 하이픈
    try t.expect(!objectKeyUnquotable("\"application/json\"")); // 슬래시
    try t.expect(!objectKeyUnquotable("\"a b\"")); // 공백
    try t.expect(!objectKeyUnquotable("\"a\\nb\"")); // escape — 디코드 회피(보수적)
    try t.expect(!objectKeyUnquotable("\"__proto__\"")); // proto setter semantic 보존
    try t.expect(!objectKeyUnquotable("source")); // 따옴표 없는 raw 는 대상 아님
    try t.expect(!objectKeyUnquotable("\"")); // 길이 부족
    try t.expect(!objectKeyUnquotable("\"a'")); // quote 불일치
}
