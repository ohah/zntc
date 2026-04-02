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
/// Flow의 `%checks` predicate도 여기서 소비한다 (타입 뒤에 붙을 수 있음).
pub fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    try self.advance();
    var ty = try parseType(self);
    // type predicate: value is Type — Flow type guard (TS와 동일 구문)
    if (self.current() == .identifier and self.isContextual("is")) {
        try self.advance(); // skip 'is'
        ty = try parseType(self);
    }
    // %checks — Flow type guard predicate. 타입 스트리핑에서는 무시.
    // `%`는 .percent 토큰, `checks`는 identifier.
    if (self.current() == .percent) {
        const next = try self.peekNextKind();
        if (next == .identifier) {
            // %checks만 유효 — %foo 같은 임의 identifier는 무시
            const saved = self.saveState();
            try self.advance(); // skip '%'
            if (!std.mem.eql(u8, self.tokenText(), "checks")) {
                self.restoreState(saved);
                return ty;
            }
            try self.advance(); // skip 'checks'
            // %checks(expr) 형태도 가능
            if (self.current() == .l_paren) {
                try self.advance(); // skip '('
                _ = try self.parseAssignmentExpression();
                try self.expect(.r_paren);
            }
        }
    }
    return ty;
}

/// Flow 타입을 파싱한다.
/// Babel: flowParseType → flowParseUnionType
pub fn parseType(self: *Parser) ParseError2!NodeIndex {
    const t = try parseUnionType(self);

    // conditional type: T extends X ? Y : Z
    if (self.current() == .kw_extends) {
        try self.advance(); // skip 'extends'
        _ = try parseType(self); // check type
        try self.expect(.question);
        _ = try parseType(self); // true branch
        try self.expect(.colon);
        _ = try parseType(self); // false branch
        return try self.ast.addNode(.{
            .tag = .flow_literal_type,
            .span = self.ast.getNode(t).span,
            .data = .{ .none = 0 },
        });
    }

    // shorthand 함수 타입: Type => ReturnType (괄호 없는 단일 파라미터)
    // arrow 파라미터의 반환 타입 컨텍스트에서는 금지 — (): any => {} / (): any => 1
    if (self.current() == .arrow and !self.flow_in_return_type) {
        try self.advance();
        _ = try parseType(self);
        return try self.ast.addNode(.{
            .tag = .flow_literal_type,
            .span = self.ast.getNode(t).span,
            .data = .{ .none = 0 },
        });
    }

    return t;
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
        const inner = try parsePrefixType(self);
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
                // Indexed access type: Type['key'] / Type[number]
                try self.advance(); // skip [
                _ = try parseType(self);
                try self.expect(.r_bracket);
                base = try self.ast.addNode(.{
                    .tag = .flow_literal_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .none = 0 },
                });
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

    // keyof T — 타입 연산자 (Flow 최신)
    if (self.current() == .identifier and self.isContextual("keyof")) {
        try self.advance(); // skip 'keyof'
        _ = try parsePrefixType(self);
        return try self.ast.addNode(.{
            .tag = .flow_literal_type,
            .span = span,
            .data = .{ .none = 0 },
        });
    }

    // infer T — conditional type의 타입 추론 변수
    if (self.current() == .identifier and self.isContextual("infer")) {
        try self.advance(); // skip 'infer'
        try self.advance(); // skip type variable name
        // infer T extends Bound (constrained infer)
        if (self.current() == .kw_extends) {
            try self.advance();
            _ = try parseType(self);
        }
        return try self.ast.addNode(.{
            .tag = .flow_literal_type,
            .span = span,
            .data = .{ .none = 0 },
        });
    }

    // Flow 키워드 타입 (mixed, empty, any, string 등)
    if (self.current() == .identifier) {
        const text = self.tokenText();

        // component(...) / hook(...) 타입 어노테이션
        // const Foo: component(ref?: any, ...props: Props) = ...
        if (std.mem.eql(u8, text, "component") or std.mem.eql(u8, text, "hook")) {
            const next = try self.peekNextKind();
            if (next == .l_paren or next == .l_angle) {
                return parseFlowComponentOrHookType(self);
            }
        }

        const flow_keyword_tag = flow_type_keywords.get(text);
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
        // interface {} — Flow inline interface type
        .kw_interface => {
            try self.advance();
            if (self.current() == .l_curly) {
                try skipBalancedBraces(self);
            }
            return try self.ast.addNode(.{
                .tag = .flow_literal_type,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
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
        // exact object type: {| key: Type |} 또는 일반 object type: { key: Type }
        .l_curly => {
            if (try self.peekNextKind() == .pipe) {
                return parseExactObjectType(self);
            }
            return parseObjectType(self);
        },
        // 제네릭 함수 타입: <T>(x: T) => R
        .l_angle => {
            const type_params = try parseTypeParameterDeclaration(self);
            try self.expect(.l_paren);
            const params = try parseFunctionTypeParamList(self);
            try self.expect(.r_paren);
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

    // Flow const type parameter: <const T: {...}> — const modifier를 건너뛴다.
    if (self.current() == .kw_const) {
        try self.advance(); // skip 'const'
    }

    try self.advance(); // type param name

    // constraint: T: Type (Flow 클래식) 또는 T extends Type (Flow 최신, RN 0.76+)
    var constraint = NodeIndex.none;
    if (self.current() == .colon) {
        try self.advance();
        constraint = try parseType(self);
    } else if (self.current() == .kw_extends) {
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

/// 괄호 타입 (Type) 또는 함수 타입 (a: Type) => Type (Babel 방식).
/// 1단계: `()`, `...`, `identifier:` → 확정적 function type
/// 2단계: 그 외 → grouped type으로 먼저 파싱, `,` 또는 `) =>` 따르면 function type
/// backtracking 없이 동작. 타입 스트리핑 전용이므로 결과는 flow_literal_type.
fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '('

    // 빈 괄호: () => Type
    if (self.current() == .r_paren) {
        try self.advance();
        try self.expect(.arrow);
        _ = try parseType(self);
        return makeLiteralType(self, start);
    }

    // ...rest 또는 identifier: → 확정적 named/rest function param
    const is_definite_fn = blk: {
        if (self.current() == .dot3) break :blk true;
        if (self.current() == .identifier or (self.current().isKeyword() and !self.current().isReservedKeyword())) {
            const next = try self.peekNextKind();
            break :blk (next == .colon or next == .question);
        }
        break :blk false;
    };

    if (is_definite_fn) {
        _ = try parseFunctionTypeParamList(self);
        try self.expect(.r_paren);
        try self.expect(.arrow);
        _ = try parseType(self);
        return makeLiteralType(self, start);
    }

    // grouped type으로 먼저 파싱
    _ = try parseType(self);

    // `,` → function type (positional params) — 나머지 params 소비
    if (try self.eat(.comma)) {
        while (self.current() != .r_paren and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            if (self.current() == .dot3) try self.advance();
            // named param 감지: identifier + (`:` | `?`)
            if (self.current() == .identifier or (self.current().isKeyword() and !self.current().isReservedKeyword())) {
                const next = try self.peekNextKind();
                if (next == .colon or next == .question) {
                    _ = try parseFunctionTypeParamList(self);
                    break;
                }
            }
            _ = try parseType(self);
            if (!try self.eat(.comma)) break;
            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }
        try self.expect(.r_paren);
        try self.expect(.arrow);
        _ = try parseType(self);
        return makeLiteralType(self, start);
    }

    // `) =>` → single positional param function type
    // return type context에서는 `=>` 가 arrow function body이므로 function type으로 해석하지 않는다.
    if (self.current() == .r_paren) {
        try self.advance();
        if (self.current() == .arrow and !self.flow_in_return_type) {
            try self.advance();
            _ = try parseType(self);
        }
        return makeLiteralType(self, start);
    }

    // 그 외: 단순 괄호 타입
    try self.expect(.r_paren);
    return makeLiteralType(self, start);
}

fn makeLiteralType(self: *Parser, start: u32) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .flow_literal_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .none = 0 },
    });
}

/// 함수 타입 파라미터 리스트: name: Type, name?: Type, ...rest: Type
/// Flow는 `(t: number) => void` 형태에서 `t`가 파라미터 이름.
/// 이름이 없는 `(number) => void` 형태도 허용 (positional).
fn parseFunctionTypeParamList(self: *Parser) ParseError2!ast_mod.NodeList {
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        // ...rest 파라미터
        if (self.current() == .dot3) {
            try self.advance();
        }

        // name: Type 또는 name?: Type — 이름 뒤에 : 또는 ?: 가 오면 named param
        if (self.current() == .identifier) {
            const next = try self.peekNextKind();
            if (next == .colon) {
                // name: Type
                try self.advance(); // skip name
                try self.advance(); // skip :
                const param_type = try parseType(self);
                try self.scratch.append(self.allocator, param_type);
                if (!try self.eat(.comma)) break;
                if (try self.ensureLoopProgress(loop_guard_pos)) break;
                continue;
            } else if (next == .question) {
                // name?: Type (optional)
                try self.advance(); // skip name
                try self.advance(); // skip ?
                if (try self.eat(.colon)) {
                    const param_type = try parseType(self);
                    try self.scratch.append(self.allocator, param_type);
                } else {
                    // name? without colon — treat as type
                    try self.scratch.append(self.allocator, try self.ast.addNode(.{
                        .tag = .flow_literal_type,
                        .span = .{ .start = loop_guard_pos, .end = self.currentSpan().start },
                        .data = .{ .none = 0 },
                    }));
                }
                if (!try self.eat(.comma)) break;
                if (try self.ensureLoopProgress(loop_guard_pos)) break;
                continue;
            }
        }

        // positional: Type (이름 없는 파라미터)
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
/// 타입 스트리핑 전용 — 내부 멤버를 개별 AST 노드로 만들지 않고,
/// balanced brace counting으로 전체를 소비한 뒤 단일 노드를 생성한다.
/// 메서드 시그니처, 인덱서, spread, variance 등 복잡한 멤버도 안전하게 소비.
fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '{'

    // balanced brace counting: 중첩된 { } 를 정확히 매칭
    var depth: u32 = 1;
    while (depth > 0 and self.current() != .eof) {
        switch (self.current()) {
            .l_curly => depth += 1,
            .r_curly => depth -= 1,
            else => {},
        }
        if (depth > 0) try self.advance();
    }

    try self.expect(.r_curly);
    return try self.ast.addNode(.{
        .tag = .flow_literal_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .none = 0 },
    });
}

/// Exact object type: {| key: Type, ... |}
/// balanced brace+pipe counting으로 전체를 소비. {| 뒤의 |} 까지.
fn parseExactObjectType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '{'
    try self.advance(); // skip '|'

    // |} 를 찾을 때까지 토큰 소비. 중첩된 {| |} 도 추적.
    var depth: u32 = 1;
    while (depth > 0 and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        if (self.current() == .l_curly) {
            // {| 중첩 감지
            if (try self.peekNextKind() == .pipe) {
                depth += 1;
                try self.advance(); // skip '{'
                try self.advance(); // skip '|'
                continue;
            }
        }
        if (self.current() == .pipe) {
            if (try self.peekNextKind() == .r_curly) {
                depth -= 1;
                try self.advance(); // skip '|'
                try self.advance(); // skip '}'
                if (depth == 0) break;
                continue;
            }
        }
        try self.advance();
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    return try self.ast.addNode(.{
        .tag = .flow_exact_object_type,
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

/// opaque type Foo = Type;
/// opaque type Foo: SuperType = Type;
/// export opaque type Foo: SuperType = Type;
pub fn parseFlowOpaqueType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'opaque'
    // 'type' 키워드가 와야 함
    if (!self.isContextual("type")) {
        try self.addError(self.currentSpan(), "Expected 'type' after 'opaque'");
        return try self.ast.addNode(.{ .tag = .invalid, .span = self.currentSpan(), .data = .{ .none = 0 } });
    }
    try self.advance(); // skip 'type'

    const name = try self.parseSimpleIdentifier();

    // 선택적 타입 파라미터: opaque type Foo<T>
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTypeParameterDeclaration(self);
    }

    // 선택적 supertype constraint: opaque type Foo: string
    var supertype = NodeIndex.none;
    if (self.current() == .colon) {
        try self.advance();
        supertype = try parseType(self);
    }

    try self.expect(.eq);
    const value = try parseType(self);
    _ = try self.eat(.semicolon);

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(type_params),
        @intFromEnum(supertype),
        @intFromEnum(value),
    });
    return try self.ast.addNode(.{
        .tag = .flow_opaque_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

// ================================================================
// Flow 공통 헬퍼
// ================================================================

const Kind = @import("../lexer/token.zig").Kind;

/// balanced token skip: 여는 토큰부터 닫는 토큰까지 전체를 소비.
/// 타입 스트리핑에서 내부 구조가 불필요한 경우 사용.
fn skipBalanced(self: *Parser, open: Kind, close: Kind) !void {
    if (self.current() != open) return;
    try self.advance();
    var depth: u32 = 1;
    while (depth > 0 and self.current() != .eof) {
        if (self.current() == open) {
            depth += 1;
        } else if (self.current() == close) {
            depth -= 1;
        }
        if (depth > 0) try self.advance();
    }
    try self.expect(close);
}

fn skipBalancedParens(self: *Parser) !void {
    return skipBalanced(self, .l_paren, .r_paren);
}

fn skipBalancedBraces(self: *Parser) !void {
    return skipBalanced(self, .l_curly, .r_curly);
}

/// `renders Type` / `renders? Type` / `renders* Type` 절이 있으면 소비.
fn trySkipRendersClause(self: *Parser) !void {
    if (self.current() == .identifier and self.isContextual("renders")) {
        try self.advance();
        _ = try self.eat(.question);
        _ = try self.eat(.star);
        _ = try parseType(self);
    }
}

// ================================================================
// Flow Component/Hook Type Annotation
// ================================================================

/// `component(ref?: any, ...props: Props)` / `hook(x: number)` 타입.
/// 타입 스트리핑이므로 balanced paren skip으로 소비하고 flow_literal_type 반환.
fn parseFlowComponentOrHookType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'component' / 'hook'

    // 선택적 타입 파라미터: component<T>(...)
    if (self.isAtOpeningAngleBracket()) {
        _ = try parseTypeParameterDeclaration(self);
    }

    try skipBalancedParens(self);
    try trySkipRendersClause(self);

    return try self.ast.addNode(.{
        .tag = .flow_literal_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .none = 0 },
    });
}

// ================================================================
// Flow Component/Hook Declaration
// ================================================================

/// Flow Component Syntax: `component View(ref?, ...props: Props) { ... }`
/// Hook Syntax: `hook useFoo(x: number) { ... }`
/// 타입 스트리핑 시 함수 선언으로 변환한다.
/// 파라미터의 타입 어노테이션, renders 절, 제네릭은 모두 제거된다.
pub fn parseFlowComponentDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'component' / 'hook'

    // 함수 이름
    const name = try self.parseSimpleIdentifier();

    // 선택적 제네릭 타입 파라미터: component Foo<T>(...)
    if (self.isAtOpeningAngleBracket()) {
        _ = try parseTypeParameterDeclaration(self);
    }

    // 파라미터 파싱: component의 파라미터를 일반 함수 파라미터로 변환
    // component 파라미터: ref?, propName: Type, ...rest: Type
    // → 함수 파라미터: ref, propName, ...rest (타입 제거)
    try self.expect(.l_paren);
    self.in_formal_parameters = true;
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(self.allocator, param);
        try self.checkRestParameterLast(param);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    const param_items = self.scratch.items[scratch_top..];
    const params = try self.ast.addNodeList(param_items);
    self.restoreScratch(scratch_top);
    self.in_formal_parameters = false;
    try self.expect(.r_paren);

    try trySkipRendersClause(self);

    // 반환 타입 어노테이션 스킵: component Foo(): Type { }
    _ = try tryParseReturnType(self);

    // 함수 컨텍스트 진입 (return 허용)
    const saved_ctx = self.enterFunctionContext(false, false);
    const body = try self.parseBlockStatement();
    self.restoreFunctionContext(saved_ctx);

    // 함수 선언 노드로 생성 (extra: [name, params_start, params_len, body, flags, return_type])
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(params.start);
    _ = try self.ast.addExtra(params.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(0); // flags: 0 (not async, not generator)
    _ = try self.ast.addExtra(@intFromEnum(NodeIndex.none)); // return_type: stripped

    return try self.ast.addNode(.{
        .tag = .function_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

// ================================================================
// Flow Declare Statement
// ================================================================

/// declare class/function/var/type/opaque type/module/module.exports/export
/// 타입 스트리핑에서는 전체를 제거하므로 내부를 파싱한 뒤 NodeIndex.none을 반환한다.
pub fn parseFlowDeclareStatement(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'declare'

    // declare module.exports: Type — Flow CJS 모듈 타입 선언
    if (self.current() == .identifier and self.isContextual("module")) {
        const next = try self.peekNextKind();
        if (next == .dot) {
            // declare module.exports: Type;
            try self.advance(); // skip 'module'
            try self.advance(); // skip '.'
            try self.advance(); // skip 'exports'
            if (self.current() == .colon) {
                try self.advance();
                _ = try parseType(self);
            }
            _ = try self.eat(.semicolon);
            return NodeIndex.none;
        }
        // declare module "name" { ... } — ambient module
        if (next == .string_literal or next == .identifier) {
            try self.advance(); // skip 'module'
            try self.advance(); // skip name
            if (self.current() == .l_curly) {
                // balanced brace skip
                try self.advance(); // skip '{'
                var depth: u32 = 1;
                while (depth > 0 and self.current() != .eof) {
                    switch (self.current()) {
                        .l_curly => depth += 1,
                        .r_curly => depth -= 1,
                        else => {},
                    }
                    if (depth > 0) try self.advance();
                }
                try self.expect(.r_curly);
            }
            return NodeIndex.none;
        }
    }

    // declare export — Flow 전용 (declare export type, declare export class 등)
    if (self.current() == .kw_export) {
        try self.advance(); // skip 'export'
        // declare export default — skip to semicolon
        if (try self.eat(.kw_default)) {
            _ = try parseType(self);
            _ = try self.eat(.semicolon);
            return NodeIndex.none;
        }
    }

    // declare component/hook — 선언만 있고 body 없음, 전체 스킵
    if (self.current() == .identifier and
        (self.isContextual("component") or self.isContextual("hook")))
    {
        const next_comp = try self.peekNextKind();
        if (next_comp == .identifier) {
            try self.advance(); // skip 'component'/'hook'
            try self.advance(); // skip name
            if (self.isAtOpeningAngleBracket()) {
                _ = try parseTypeParameterDeclaration(self);
            }
            try skipBalancedParens(self);
            try trySkipRendersClause(self);
            _ = try self.eat(.semicolon);
            return NodeIndex.none;
        }
    }

    // declare opaque type — opaque 키워드 후 type
    if (self.current() == .identifier and self.isContextual("opaque")) {
        _ = try parseFlowOpaqueType(self);
        return NodeIndex.none;
    }

    // declare type/class/function/var/interface — 공통 처리
    // 내부 선언을 파싱 (AST 노드 생성됨)하지만 반환값은 .none (전체 제거)
    const saved_ambient = self.ctx;
    self.ctx.in_ambient = true;
    _ = try self.parseStatement();
    self.ctx = saved_ambient;
    return NodeIndex.none;
}

// ================================================================
// Flow Interface Declaration
// ================================================================

/// interface Foo extends Bar { ... }
pub fn parseFlowInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'interface'

    const name = try self.parseSimpleIdentifier();

    // 선택적 타입 파라미터: interface Foo<T>
    var type_params = NodeIndex.none;
    if (self.isAtOpeningAngleBracket()) {
        type_params = try parseTypeParameterDeclaration(self);
    }

    // extends 절: interface Foo extends Bar, Baz
    var extends_start: u32 = 0;
    var extends_len: u32 = 0;
    if (try self.eat(.kw_extends)) {
        const scratch_top = self.saveScratch();
        const first = try parseType(self);
        try self.scratch.append(self.allocator, first);
        while (try self.eat(.comma)) {
            const next_type = try parseType(self);
            try self.scratch.append(self.allocator, next_type);
        }
        const items = self.scratch.items[scratch_top..];
        const list = try self.ast.addNodeList(items);
        self.scratch.shrinkRetainingCapacity(scratch_top);
        extends_start = list.start;
        extends_len = list.len;
    }

    // body: { ... } — balanced brace skip (타입 스트리핑이므로 내부 구조 불필요)
    const body_start = self.currentSpan().start;
    if (self.current() == .l_curly) {
        try self.advance();
        var depth: u32 = 1;
        while (depth > 0 and self.current() != .eof) {
            switch (self.current()) {
                .l_curly => depth += 1,
                .r_curly => depth -= 1,
                else => {},
            }
            if (depth > 0) try self.advance();
        }
        try self.expect(.r_curly);
    }
    _ = body_start;

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(type_params),
        extends_start,
        extends_len,
    });
    return try self.ast.addNode(.{
        .tag = .flow_interface_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}

// ================================================================
// Flow Match Expression
// ================================================================

/// Flow match expression: match (expr) { Pattern => body, ... }
/// discriminant와 arms를 재귀 파싱. transformer에서 if-else IIFE로 변환.
pub fn parseMatchExpression(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'match'

    // discriminant: (expr)
    try self.expect(.l_paren);
    const discriminant = try self.parseAssignmentExpression();
    try self.expect(.r_paren);

    // match body: { arm1, arm2, ... }
    try self.expect(.l_curly);
    const scratch_top = self.saveScratch();

    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        // pattern 파싱 — `_ =>` wildcard는 arrow function으로 해석되므로 별도 처리
        const pattern = blk: {
            // `_` wildcard: `_ =>` 패턴이면 식별자만 파싱하고 `=>` 는 caller에서 소비
            if (self.current() == .identifier) {
                const text = self.ast.source[self.currentSpan().start..self.currentSpan().end];
                if (std.mem.eql(u8, text, "_")) {
                    const s = self.currentSpan();
                    try self.advance();
                    break :blk try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = s,
                        .data = .{ .string_ref = s },
                    });
                }
            }
            break :blk try self.parseAssignmentExpression();
        };
        try self.expect(.arrow);

        // body: { ... } (block) 또는 expression
        var body: NodeIndex = .none;
        if (self.current() == .l_curly) {
            body = try self.parseBlockStatement();
        } else {
            body = try self.parseAssignmentExpression();
            _ = try self.eat(.comma);
        }

        // arm: binary { left=pattern, right=body }
        const arm = try self.ast.addNode(.{
            .tag = .flow_match_expression, // arm도 같은 태그 재사용 (구분은 위치로)
            .span = .{ .start = loop_guard_pos, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = pattern, .right = body, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, arm);

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    try self.expect(.r_curly);

    const arms = self.scratch.items[scratch_top..];
    const arms_list = try self.ast.addNodeList(arms);
    self.scratch.shrinkRetainingCapacity(scratch_top);

    // flow_match_expression: extra = [discriminant, arms_start, arms_len]
    const extra = try self.ast.addExtras(&.{
        @intFromEnum(discriminant),
        arms_list.start,
        arms_list.len,
    });
    return try self.ast.addNode(.{
        .tag = .flow_match_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
}
