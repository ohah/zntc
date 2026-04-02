//! ES 다운레벨링 공통 헬퍼
//!
//! 임시 변수 생성, void 0, null 비교 등 여러 ES 버전 변환에서 공유하는 유틸리티.
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower_class.go (privateTempRef 패턴)
//! - `== null` vs `=== null`: JS에서 `x == null`은 null과 undefined 모두 체크 (loose equality)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

/// 인덱스로부터 임시 변수명 생성: _a, _b, _c, ..., _a2, _b2, ...
/// makeTempVarSpan과 hoistTempVars에서 공용.
pub fn tempVarName(idx: u32, buf: *[16]u8) []const u8 {
    const letter: u8 = 'a' + @as(u8, @intCast(idx % 26));
    const cycle = idx / 26;
    return if (cycle == 0)
        std.fmt.bufPrint(buf, "_{c}", .{letter}) catch "_"
    else
        std.fmt.bufPrint(buf, "_{c}{d}", .{ letter, cycle + 1 }) catch "_";
}

/// 임시 변수명 생성: _a, _b, _c, ..., _a2, _b2, ...
pub fn makeTempVarSpan(self: anytype) !Span {
    const idx = self.temp_var_counter;
    self.temp_var_counter += 1;
    var buf: [16]u8 = undefined;
    const name = tempVarName(idx, &buf);
    return self.new_ast.addString(name);
}

/// 임시 변수 identifier_reference 노드 생성.
pub fn makeTempVarRef(self: anytype, span: Span, node_span: Span) !NodeIndex {
    return self.new_ast.addNode(.{
        .tag = .identifier_reference,
        .span = node_span,
        .data = .{ .string_ref = span },
    });
}

/// left 노드가 단순 식별자(부작용 없음)인지 판단.
pub fn isSimpleIdentifier(self: anytype, left_idx: NodeIndex) bool {
    const left_node = self.old_ast.getNode(left_idx);
    return left_node.tag == .identifier_reference;
}

/// `void 0` 노드를 새 AST에 생성.
pub fn makeVoidZero(self: anytype, span: Span) !NodeIndex {
    const zero_span = try self.new_ast.addString("0");
    const zero_node = try self.new_ast.addNode(.{
        .tag = .numeric_literal,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const void_extra = try self.new_ast.addExtras(&.{
        @intFromEnum(zero_node),
        @intFromEnum(token_mod.Kind.kw_void),
    });
    return self.new_ast.addNode(.{
        .tag = .unary_expression,
        .span = span,
        .data = .{ .extra = void_extra },
    });
}

/// 이름 문자열로 identifier_reference 노드 생성.
/// addString + addNode를 한 번에 수행.
pub fn makeIdentifierRef(self: anytype, name: []const u8) !NodeIndex {
    const name_span = try self.new_ast.addString(name);
    return self.new_ast.addNode(.{
        .tag = .identifier_reference,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
}

/// Span으로 identifier_reference 노드 생성 (이미 addString된 span 사용).
pub fn makeIdentifierRefFromSpan(self: anytype, name_span: Span) !NodeIndex {
    return self.new_ast.addNode(.{
        .tag = .identifier_reference,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
}

/// obj.prop static member expression 생성.
/// extra = [object, property, flags=0]
pub fn makeStaticMember(self: anytype, obj: NodeIndex, prop: NodeIndex, span: Span) !NodeIndex {
    const me = try self.new_ast.addExtras(&.{ @intFromEnum(obj), @intFromEnum(prop), 0 });
    return self.new_ast.addNode(.{
        .tag = .static_member_expression,
        .span = span,
        .data = .{ .extra = me },
    });
}

/// obj[prop] computed member expression 생성.
/// 문자열 키("aria-busy")나 숫자 키처럼 dot notation이 불가능한 경우 사용.
/// extra = [object, property, flags=0]
pub fn makeComputedMember(self: anytype, obj: NodeIndex, prop: NodeIndex, span: Span) !NodeIndex {
    const me = try self.new_ast.addExtras(&.{ @intFromEnum(obj), @intFromEnum(prop), 0 });
    return self.new_ast.addNode(.{
        .tag = .computed_member_expression,
        .span = span,
        .data = .{ .extra = me },
    });
}

/// 프로퍼티 키의 타입에 따라 static(dot) 또는 computed(bracket) member expression 생성.
/// string_literal, numeric_literal → bracket notation (_ref["aria-busy"], _ref[0])
/// 그 외 (identifier 등) → dot notation (_ref.key)
pub fn makeMemberFromKey(self: anytype, obj: NodeIndex, prop: NodeIndex, key_tag: ast_mod.Node.Tag, span: Span) !NodeIndex {
    return switch (key_tag) {
        .string_literal, .numeric_literal => makeComputedMember(self, obj, prop, span),
        else => makeStaticMember(self, obj, prop, span),
    };
}

/// old_ast의 key_idx로부터 obj.key 또는 obj[key] member expression 생성.
/// computed_property_key → 내부 표현식을 unwrap하여 bracket notation.
/// string_literal, numeric_literal → bracket notation.
/// 그 외 (identifier) → dot notation.
pub fn makeMemberFromKeyIdx(self: anytype, obj: NodeIndex, key_idx: NodeIndex, span: Span) !NodeIndex {
    const key_node = self.old_ast.getNode(key_idx);
    if (key_node.tag == .computed_property_key) {
        const inner = try self.visitNode(key_node.data.unary.operand);
        return makeComputedMember(self, obj, inner, span);
    } else {
        const new_key = try self.visitNode(key_idx);
        return makeMemberFromKey(self, obj, new_key, key_node.tag, span);
    }
}

/// callee(args...) call expression 생성.
/// extra = [callee, args_start, args_len, flags=0]
pub fn makeCallExpr(self: anytype, callee: NodeIndex, args: []const NodeIndex, span: Span) !NodeIndex {
    const args_list = try self.new_ast.addNodeList(args);
    const call_extra = try self.new_ast.addExtras(&.{
        @intFromEnum(callee), args_list.start, args_list.len, 0,
    });
    return self.new_ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = call_extra },
    });
}

/// u32 값으로 numeric_literal 노드 생성.
pub fn makeNumericLiteral(self: anytype, value: u32) !NodeIndex {
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
    const num_span = try self.new_ast.addString(str);
    return self.new_ast.addNode(.{
        .tag = .numeric_literal,
        .span = num_span,
        .data = .{ .none = 0 },
    });
}

/// `base == null` 노드를 새 AST에 생성.
pub fn makeEqNull(self: anytype, base: NodeIndex, span: Span) !NodeIndex {
    const null_span = try self.new_ast.addString("null");
    const null_node = try self.new_ast.addNode(.{
        .tag = .null_literal,
        .span = null_span,
        .data = .{ .none = 0 },
    });
    return self.new_ast.addNode(.{
        .tag = .binary_expression,
        .span = span,
        .data = .{ .binary = .{
            .left = base,
            .right = null_node,
            .flags = @intFromEnum(token_mod.Kind.eq2),
        } },
    });
}

/// binding_identifier 노드 생성 (변수 바인딩용).
/// span은 이미 addString된 이름 span.
pub fn makeBindingIdentifier(self: anytype, name_span: Span) !NodeIndex {
    return self.new_ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
}

/// variable_declarator 노드 생성 (binding + optional init).
/// extra = [binding, type_annotation(none), init]
pub fn makeDeclarator(self: anytype, binding: NodeIndex, init: NodeIndex, span: Span) !NodeIndex {
    const de = try self.new_ast.addExtras(&.{
        @intFromEnum(binding), @intFromEnum(NodeIndex.none), @intFromEnum(init),
    });
    return self.new_ast.addNode(.{
        .tag = .variable_declarator,
        .span = span,
        .data = .{ .extra = de },
    });
}

/// variable_declaration 노드 생성 (var 키워드, declarators 배열).
/// kind_flags: 0 = var, 1 = let, 2 = const
pub fn makeVarDeclaration(self: anytype, declarators: []const NodeIndex, kind_flags: u32, span: Span) !NodeIndex {
    const decl_list = try self.new_ast.addNodeList(declarators);
    const var_extra = try self.new_ast.addExtras(&.{ kind_flags, decl_list.start, decl_list.len });
    return self.new_ast.addNode(.{
        .tag = .variable_declaration,
        .span = span,
        .data = .{ .extra = var_extra },
    });
}

/// expression을 expression_statement로 감싸기.
pub fn makeExprStmt(self: anytype, expr: NodeIndex, span: Span) !NodeIndex {
    return self.new_ast.addNode(.{
        .tag = .expression_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
}
