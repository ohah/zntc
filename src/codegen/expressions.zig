//! Expression and member-expression emit helpers for Codegen.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Kind = @import("../lexer/token.zig").Kind;

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
    try self.emitNode(operand);
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
fn unaryOpKind(self: anytype, extra_base: u32) ?Kind {
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
    try self.emitNode(node.data.binary.left);
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

    if (self.options.linking_metadata) |meta| {
        if (flags & MemberFlags.optional_chain == 0) {
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

    try self.emitNode(object);
    if (flags & MemberFlags.optional_chain != 0) {
        try self.write("?.");
    } else {
        try self.writeByte('.');
    }
    // property name 슬롯은 reserved word 도 valid identifier 로 취급되므로 peephole
    // 치환 (예: `undefined` → `(void 0)`) 이 적용되면 안 된다 — `obj.undefined` 가
    // `obj.(void 0)` 로 깨지면 SyntaxError. emitNode 우회 시 sourcemap mapping 이
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
    try self.emitNode(object);
    if (flags & MemberFlags.optional_chain != 0) {
        try self.write("?.");
    }
    try self.writeByte('[');
    try self.emitNode(property);
    try self.writeByte(']');
}
