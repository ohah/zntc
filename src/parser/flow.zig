//! Flow Type Parser
//!
//! Flow 타입 어노테이션을 파싱한다.
//! TS 타입 파싱(ts.zig)과 독립적인 파싱 체인으로, flow_ 접두사 AST 태그를 사용한다.
//!
//! 파싱 우선순위 (Babel flowParseType 참고):
//!   Union > Intersection > Prefix(?Type) > Postfix(T[]) > Primary
//!
//! 참고:
//! - references/babel/packages/babel-parser/src/plugins/flow/index.ts
//! - references/hermes/lib/Parser/JSParserImpl-flow.cpp

const std = @import("std");
const ast_mod = @import("ast.zig");
const Tag = ast_mod.Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

/// Flow 타입 키워드 → AST 태그 매핑.
/// TS와 달리 mixed, empty가 추가되고, unknown/object/undefined/intrinsic는 없다.
const flow_type_keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "any", .flow_any_keyword },
    .{ "string", .flow_string_keyword },
    .{ "number", .flow_number_keyword },
    .{ "boolean", .flow_boolean_keyword },
    .{ "bool", .flow_boolean_keyword }, // Flow에서는 bool도 허용
    .{ "bigint", .flow_bigint_keyword },
    .{ "symbol", .flow_symbol_keyword },
    .{ "never", .flow_never_keyword },
    .{ "mixed", .flow_mixed_keyword },
    .{ "empty", .flow_empty_keyword },
});

// ================================================================
// Flow Type 파싱 진입점
// ================================================================

/// `: Type` 어노테이션이 있으면 파싱하고 노드 반환. 없으면 none.
/// binding pattern/variable declarator 컨텍스트에서만 호출되므로 colon이 안전.
pub fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    try self.advance(); // skip ':'
    return parseType(self);
}

/// 리턴 타입 어노테이션 (`: Type`). 함수 선언에서 사용.
/// Flow는 TS의 type predicate 대신 %checks를 사용하지만, 여기서는 타입만 파싱.
pub fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    try self.advance();
    return parseType(self);
}

/// Flow 타입을 파싱한다.
/// Babel: flowParseType → flowParseUnionType
pub fn parseType(self: *Parser) ParseError2!NodeIndex {
    return parseUnionType(self);
}

// ================================================================
// Union / Intersection
// ================================================================

/// Union 타입: A | B | C
/// 선행 | 허용: | A | B
fn parseUnionType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .pipe) try self.advance();
    var left = try parseIntersectionType(self);

    while (self.current() == .pipe) {
        const start = self.ast.getNode(left).span.start;
        try self.advance();
        const right = try parseIntersectionType(self);
        left = try self.ast.addNode(.{
            .tag = .flow_union_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
        });
    }

    return left;
}

/// Intersection 타입: A & B & C
/// 선행 & 허용: & A & B
fn parseIntersectionType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .amp) try self.advance();
    var left = try parsePrefixType(self);

    while (self.current() == .amp) {
        const start = self.ast.getNode(left).span.start;
        try self.advance();
        const right = try parsePrefixType(self);
        left = try self.ast.addNode(.{
            .tag = .flow_intersection_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
        });
    }

    return left;
}

// ================================================================
// Prefix / Postfix
// ================================================================

/// Prefix 타입: ?Type (Flow nullable)
/// Babel: flowParsePrefixType
fn parsePrefixType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .question) {
        const start = self.currentSpan().start;
        try self.advance(); // skip '?'
        const inner = try parsePrefixType(self); // 재귀: ??Type도 가능
        return try self.ast.addNode(.{
            .tag = .flow_nullable_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
        });
    }
    return parsePostfixType(self);
}

/// Postfix 타입: T[], T[K]
fn parsePostfixType(self: *Parser) ParseError2!NodeIndex {
    var base = try parsePrimaryType(self);

    while (true) {
        if (self.current() == .l_bracket) {
            if (self.scanner.token.has_newline_before) break;
            const start = self.ast.getNode(base).span.start;
            if (try self.peekNextKind() == .r_bracket) {
                // 배열 타입: T[]
                try self.advance(); // [
                try self.advance(); // ]
                base = try self.ast.addNode(.{
                    .tag = .flow_array_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = base, .flags = 0 } },
                });
            } else {
                break; // 인덱스 접근은 후속 PR에서 구현
            }
        } else break;
    }

    return base;
}

// ================================================================
// Primary Type
// ================================================================

/// 기본 타입을 파싱한다.
/// Babel: flowParsePrimaryType
fn parsePrimaryType(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // Flow 키워드 타입 (mixed, empty, any, string 등)
    if (self.current() == .identifier) {
        const flow_keyword_tag = flow_type_keywords.get(self.tokenText());
        if (flow_keyword_tag) |tag| {
            try self.advance();
            // 키워드 뒤에 '.'이 오면 qualified name → type reference로 처리
            if (self.current() == .dot) {
                var name_end = span.end;
                while (try self.eat(.dot)) {
                    name_end = self.currentSpan().end;
                    try self.advance();
                }
                var type_args = NodeIndex.none;
                if (self.isAtOpeningAngleBracket() and !self.scanner.token.has_newline_before) {
                    type_args = try parseTypeArguments(self);
                }
                const extra_start = try self.ast.addExtra(span.start);
                _ = try self.ast.addExtra(name_end);
                _ = try self.ast.addExtra(@intFromEnum(type_args));
                return try self.ast.addNode(.{
                    .tag = .flow_type_reference,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .extra = extra_start },
                });
            }
            return try self.ast.addNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .none = 0 },
            });
        }
    }

    switch (self.current()) {
        // void
        .kw_void => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .flow_void_keyword,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // null
        .kw_null => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .flow_null_keyword,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // this
        .kw_this => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .flow_this_type,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // 리터럴 타입 (true, false, 숫자, 문자열)
        .kw_true, .kw_false => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .flow_literal_type,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .decimal,
        .float,
        .hex,
        .string_literal,
        .decimal_bigint,
        .hex_bigint,
        .octal_bigint,
        .binary_bigint,
        => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .flow_literal_type,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .string_ref = span },
            });
        },
        // 타입 참조: Foo, Foo.Bar, Foo<T>
        .identifier => return parseTypeReference(self),
        // 괄호 타입: (Type) 또는 함수 타입: (a: Type) => Type
        .l_paren => return parseParenOrFunctionType(self),
        // 객체 타입 리터럴: { key: Type, ... }
        .l_curly => return parseObjectType(self),
        // 제네릭 함수 타입: <T>(x: T) => R
        .l_angle => {
            const type_params = try parseTypeParameterDeclaration(self);
            try self.expect(.l_paren);
            const params = try parseFunctionTypeParamList(self);
            try self.expect(.arrow);
            const return_type = try parseType(self);
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(type_params),
                params.start,
                params.len,
                @intFromEnum(return_type),
            });
            return try self.ast.addNode(.{
                .tag = .flow_function_type,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .extra = extra },
            });
        },
        // 튜플 타입: [T, U]
        .l_bracket => return parseTupleType(self),
        // typeof T
        .kw_typeof => {
            try self.advance();
            const operand = try parseTypeReference(self);
            return try self.ast.addNode(.{
                .tag = .flow_type_query,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
            });
        },
        // 음수 리터럴 타입: -1
        .minus => {
            try self.advance(); // skip -
            if (self.current() == .decimal or self.current() == .float or self.current() == .hex or
                self.current() == .decimal_bigint or self.current() == .hex_bigint or
                self.current() == .octal_bigint or self.current() == .binary_bigint)
            {
                try self.advance();
                return try self.ast.addNode(.{
                    .tag = .flow_literal_type,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .string_ref = span },
                });
            }
            return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
        },
        // * (existential type — deprecated in Flow, but Metro uses it 1 time)
        .star => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .flow_any_keyword, // * → any로 취급
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        else => {
            if (self.current().isKeyword()) {
                return parseTypeReference(self);
            }
            try self.addError(span, "Type expected");
            try self.advance();
            return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
        },
    }
}

// ================================================================
// Type Reference / Arguments
// ================================================================

/// 타입 참조: Foo, Foo.Bar, Foo<T>
fn parseTypeReference(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name_span = self.currentSpan();
    try self.advance(); // type name

    // Foo.Bar 형태
    var name_end = name_span.end;
    while (try self.eat(.dot)) {
        name_end = self.currentSpan().end;
        try self.advance();
    }

    // 제네릭: Foo<T, U>
    var type_args = NodeIndex.none;
    if (self.isAtOpeningAngleBracket() and !self.scanner.token.has_newline_before) {
        type_args = try parseTypeArguments(self);
    }

    const extra_start = try self.ast.addExtra(name_span.start);
    _ = try self.ast.addExtra(name_end);
    _ = try self.ast.addExtra(@intFromEnum(type_args));

    return try self.ast.addNode(.{
        .tag = .flow_type_reference,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// 타입 인자: <T, U>
pub fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.expectOpeningAngleBracket();

    const scratch_top = self.saveScratch();
    while (!self.isAtClosingAngleBracket() and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const ty = try parseType(self);
        try self.scratch.append(self.allocator, ty);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    try self.expectClosingAngleBracket();
    const items = self.scratch.items[scratch_top..];
    const extra = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return try self.ast.addNode(.{
        .tag = .flow_type_parameter_instantiation,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra.start },
    });
}

/// 타입 인자 (식 컨텍스트, speculative).
/// TS의 parseTypeArgumentsInExpression과 동일한 역할.
pub fn parseTypeArgumentsInExpression(self: *Parser) ParseError2!NodeIndex {
    return parseTypeArguments(self);
}

// ================================================================
// Type Parameter Declaration
// ================================================================

/// 타입 파라미터 선언: <T, U extends V, +W, -X>
/// Flow는 variance(+/-)를 타입 파라미터에 직접 지정할 수 있다.
pub fn parseTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.expectOpeningAngleBracket();

    const scratch_top = self.saveScratch();
    while (!self.isAtClosingAngleBracket() and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try parseTypeParameter(self);
        try self.scratch.append(self.allocator, param);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    try self.expectClosingAngleBracket();
    const items = self.scratch.items[scratch_top..];
    const extra = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return try self.ast.addNode(.{
        .tag = .flow_type_parameter_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra.start },
    });
}

/// 개별 타입 파라미터: T, T: SuperType, T = DefaultType, +T, -T
fn parseTypeParameter(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // variance: +T (covariant) 또는 -T (contravariant)
    var flags: u16 = 0;
    if (self.current() == .plus) {
        flags = 1; // covariant
        try self.advance();
    } else if (self.current() == .minus) {
        flags = 2; // contravariant
        try self.advance();
    }

    try self.advance(); // type param name

    // constraint: T: Type (Flow는 extends 대신 : 사용)
    var constraint = NodeIndex.none;
    if (self.current() == .colon) {
        try self.advance();
        constraint = try parseType(self);
    }

    // default: T = Type
    if (try self.eat(.eq)) {
        _ = try parseType(self); // default type (파싱만 하고 스킵)
    }

    return try self.ast.addNode(.{
        .tag = .flow_type_parameter,
        .span = .{ .start = span.start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = constraint, .flags = flags } },
    });
}

// ================================================================
// Parenthesized / Function Type
// ================================================================

/// 괄호 타입 (Type) 또는 함수 타입 (a: Type) => Type
fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '('

    // 빈 괄호: () => Type (함수 타입)
    if (self.current() == .r_paren) {
        try self.advance(); // skip ')'
        try self.expect(.arrow);
        const return_type = try parseType(self);
        const extra = try self.ast.addExtras(&.{
            @intFromEnum(NodeIndex.none), // no type params
            0, // params start
            0, // params len
            @intFromEnum(return_type),
        });
        return try self.ast.addNode(.{
            .tag = .flow_function_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra },
        });
    }

    // 첫 요소 파싱 후 → 화살표가 오면 함수 타입, 아니면 괄호 타입
    // speculative: 함수 파라미터인지 단순 타입인지 판별
    const saved = self.saveState();
    const err_count = self.errors.items.len;

    // 함수 타입 시도: (a: T, b: U) => R
    const params = parseFunctionTypeParamList(self) catch {
        self.restoreState(saved);
        self.errors.shrinkRetainingCapacity(err_count);
        // 단순 괄호 타입으로 폴백
        const inner = try parseType(self);
        try self.expect(.r_paren);
        return try self.ast.addNode(.{
            .tag = .flow_parenthesized_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
        });
    };

    if (self.current() == .r_paren) {
        try self.advance(); // skip ')'
        if (self.current() == .arrow) {
            // 함수 타입: (params) => ReturnType
            try self.advance(); // skip '=>'
            const return_type = try parseType(self);
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(NodeIndex.none), // no type params
                params.start,
                params.len,
                @intFromEnum(return_type),
            });
            return try self.ast.addNode(.{
                .tag = .flow_function_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra },
            });
        }
    }

    // 화살표가 없으면 — 파싱 상태 복원 후 괄호 타입으로 재시도
    self.restoreState(saved);
    self.errors.shrinkRetainingCapacity(err_count);
    try self.advance(); // skip '(' again
    const inner = try parseType(self);
    try self.expect(.r_paren);
    return try self.ast.addNode(.{
        .tag = .flow_parenthesized_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
    });
}

/// 함수 타입 파라미터 리스트: name: Type, name?: Type, ...rest: Type
fn parseFunctionTypeParamList(self: *Parser) ParseError2!ast_mod.NodeList {
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        // ...rest 파라미터
        if (self.current() == .dot3) {
            try self.advance();
        }

        // name: Type 또는 Type (이름 없는 파라미터도 Flow에서 허용)
        const param_type = try parseType(self);
        try self.scratch.append(self.allocator, param_type);

        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    const items = self.scratch.items[scratch_top..];
    const result = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return result;
}

// ================================================================
// Object Type
// ================================================================

/// 객체 타입: { key: Type, ... }
fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '{'

    // 빈 객체: {}
    if (self.current() == .r_curly) {
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .flow_literal_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .none = 0 },
        });
    }

    // 멤버들 파싱 (간단한 버전: key: Type 패턴만)
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        // 프로퍼티 이름 스킵
        try self.advance();
        // optional: ?
        _ = try self.eat(.question);
        // : Type
        if (self.current() == .colon) {
            try self.advance();
            _ = try parseType(self);
        }
        // 구분자: , 또는 ;
        if (!try self.eat(.comma) and !try self.eat(.semicolon)) {
            if (self.current() != .r_curly) break;
        }
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    try self.expect(.r_curly);
    return try self.ast.addNode(.{
        .tag = .flow_literal_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .none = 0 },
    });
}

// ================================================================
// Tuple Type
// ================================================================

/// 튜플 타입: [T, U]
fn parseTupleType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '['

    const scratch_top = self.saveScratch();
    while (self.current() != .r_bracket and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const ty = try parseType(self);
        try self.scratch.append(self.allocator, ty);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    try self.expect(.r_bracket);
    const items = self.scratch.items[scratch_top..];
    const extra = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return try self.ast.addNode(.{
        .tag = .flow_tuple_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra.start },
    });
}

// ================================================================
// Flow Type Alias Declaration
// ================================================================

/// type Foo = Type;
pub fn parseFlowTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'type'

    const name = try self.parseSimpleIdentifier();

    // 선택적 타입 파라미터: type Foo<T> = ...
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTypeParameterDeclaration(self);
    }

    try self.expect(.eq);
    const value = try parseType(self);
    _ = try self.eat(.semicolon);

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(type_params),
        @intFromEnum(value),
    });
    return try self.ast.addNode(.{
        .tag = .flow_type_alias_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}
