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
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const Span = @import("../lexer/token.zig").Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;
const PropertySignatureFlags = @import("ts.zig").PropertySignatureFlags;

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
        const return_type = try parseType(self);
        // shorthand 의 단일 positional param 은 t (이미 파싱된 type) 자체 — name 없음.
        const params = try self.ast.addNodeList(&.{t});
        return makeFunctionType(self, self.ast.getNode(t).span.start, NodeIndex.none, params, return_type);
    }

    return t;
}

// ================================================================
// Union / Intersection
// ================================================================

/// Union 타입: A | B | C
/// 선행 | 허용: | A | B
///
/// Exact object close 보호 (#2447): `{| count: number |}` 같이 prop position 의 inner
/// exact object 가 union 처리 시 close `|` 까지 흡수되면 outer parser 가 깨짐. `|` 다음
/// 토큰이 `}` 면 exact object close 로 간주하고 union 종료 (단순 type alias 의 trailing
/// `|` 는 valid Flow syntax 가 아님 — Babel `flowParseUnionType` 도 동일 정책).
fn parseUnionType(self: *Parser) ParseError2!NodeIndex {
    if (try pipeIsExactClose(self)) return parseIntersectionType(self);
    if (self.current() == .pipe) try self.advance();
    const first = try parseIntersectionType(self);
    if (self.current() != .pipe or try pipeIsExactClose(self)) return first;

    // `A | B | C` — flat NodeList 로 저장 (layout=.list).
    const scratch_top = self.saveScratch();
    defer self.restoreScratch(scratch_top);
    try self.scratch.append(self.allocator, first);
    const start = self.ast.getNode(first).span.start;
    while (self.current() == .pipe and !try pipeIsExactClose(self)) {
        try self.advance();
        const next = try parseIntersectionType(self);
        try self.scratch.append(self.allocator, next);
    }
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return try self.ast.addListNode(
        .flow_union_type,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
}

/// 현재 토큰이 `|` 이고 직후가 `}` — exact object (`{| ... |}`) 의 close marker. union
/// operator 로 흡수하면 안 됨 (#2447).
fn pipeIsExactClose(self: *Parser) ParseError2!bool {
    return self.current() == .pipe and try self.peekNextKind() == .r_curly;
}

/// Intersection 타입: A & B & C
/// 선행 & 허용: & A & B
fn parseIntersectionType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .amp) try self.advance();
    const first = try parsePrefixType(self);
    if (self.current() != .amp) return first;

    // `A & B & C` — flat NodeList 로 저장 (layout=.list).
    const scratch_top = self.saveScratch();
    defer self.restoreScratch(scratch_top);
    try self.scratch.append(self.allocator, first);
    const start = self.ast.getNode(first).span.start;
    while (self.current() == .amp) {
        try self.advance();
        const next = try parsePrefixType(self);
        try self.scratch.append(self.allocator, next);
    }
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return try self.ast.addListNode(
        .flow_intersection_type,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
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
                // 배열 타입: T[]. element 를 extra[0] 으로 보존 — dataKind 는 그대로
                // .extra (child_offsets = &.{} 라 ast_walk 미접근). TS parser 와 동일.
                try self.advance(); // [
                try self.advance(); // ]
                const extra_idx = try self.ast.addExtras(&.{@intFromEnum(base)});
                base = try self.ast.addNode(.{
                    .tag = .flow_array_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = extra_idx },
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
        // exact object type: `{| key: Type |}` (또는 빈 `{||}`) vs 일반 object type: `{ key: Type }`.
        // 빈 `{||}` 는 lexer 가 `||` 를 `pipe2` 단일 토큰으로 토크나이즈하므로 dispatch 시 pipe2 도 인식.
        .l_curly => {
            const next = try self.peekNextKind();
            if (next == .pipe or next == .pipe2) {
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
            return makeFunctionType(self, span.start, type_params, params, return_type);
        },
        // 튜플 타입: [T, U]
        .l_bracket => return parseTupleType(self),
        // typeof T
        .kw_typeof => {
            try self.advance();
            _ = try parseTypeReference(self);
            return try self.ast.addEmptyExtraNode(
                .flow_type_query,
                .{ .start = span.start, .end = self.currentSpan().start },
            );
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
            try self.addErrorCode(span, "Type expected", .ts_type_expected);
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
    const list = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return try self.ast.addListNode(
        .flow_type_parameter_instantiation,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
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
    const list = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return try self.ast.addListNode(
        .flow_type_parameter_declaration,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
}

/// 개별 타입 파라미터: T, T: SuperType, T = DefaultType, +T, -T
fn parseTypeParameter(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // variance: +T (covariant) 또는 -T (contravariant)
    if (self.current() == .plus or self.current() == .minus) {
        try self.advance();
    }

    // Flow const type parameter: <const T: {...}> — const modifier를 건너뛴다.
    if (self.current() == .kw_const) {
        try self.advance(); // skip 'const'
    }

    try self.advance(); // type param name

    // constraint: T: Type (Flow 클래식) 또는 T extends Type (Flow 최신, RN 0.76+)
    if (self.current() == .colon or self.current() == .kw_extends) {
        try self.advance();
        _ = try parseType(self);
    }

    // default: T = Type
    if (try self.eat(.eq)) {
        _ = try parseType(self); // default type (파싱만 하고 스킵)
    }

    return try self.ast.addEmptyExtraNode(
        .flow_type_parameter,
        .{ .start = span.start, .end = self.currentSpan().start },
    );
}

// ================================================================
// Parenthesized / Function Type
// ================================================================

/// 괄호 타입 (Type) 또는 함수 타입 (a: Type) => Type (Babel 방식).
/// 1단계: `()`, `...`, `identifier:` → 확정적 function type
/// 2단계: 그 외 → grouped type으로 먼저 파싱, `,` 또는 `) =>` 따르면 function type
/// backtracking 없이 동작. function type 형태는 `flow_function_type` 노드 (정보 보존),
/// 단순 grouped type 은 `flow_literal_type` strip — TS 와 일관성.
fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '('

    // 빈 괄호: () => Type
    if (self.current() == .r_paren) {
        try self.advance();
        try self.expect(.arrow);
        const return_type = try parseType(self);
        return makeFunctionType(self, start, NodeIndex.none, .{ .start = 0, .len = 0 }, return_type);
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
        const params = try parseFunctionTypeParamList(self);
        try self.expect(.r_paren);
        try self.expect(.arrow);
        const return_type = try parseType(self);
        return makeFunctionType(self, start, NodeIndex.none, params, return_type);
    }

    // grouped type으로 먼저 파싱
    const first_type = try parseType(self);

    // `,` → function type (positional params) — 나머지 params 소비
    if (try self.eat(.comma)) {
        const scratch_top = self.saveScratch();
        try self.scratch.append(self.allocator, first_type);
        while (self.current() != .r_paren and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            if (self.current() == .dot3) try self.advance();
            // named param 감지: identifier + (`:` | `?`)
            if (self.current() == .identifier or (self.current().isKeyword() and !self.current().isReservedKeyword())) {
                const next = try self.peekNextKind();
                if (next == .colon or next == .question) {
                    const named = try parseFunctionTypeParamList(self);
                    var i: u32 = 0;
                    while (i < named.len) : (i += 1) {
                        const idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[named.start + i]);
                        try self.scratch.append(self.allocator, idx);
                    }
                    break;
                }
            }
            const param_type = try parseType(self);
            try self.scratch.append(self.allocator, param_type);
            if (!try self.eat(.comma)) break;
            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }
        try self.expect(.r_paren);
        try self.expect(.arrow);
        const return_type = try parseType(self);
        const items = self.scratch.items[scratch_top..];
        const params = try self.ast.addNodeList(items);
        self.scratch.shrinkRetainingCapacity(scratch_top);
        return makeFunctionType(self, start, NodeIndex.none, params, return_type);
    }

    // `) =>` → single positional param function type
    // return type context에서는 `=>` 가 arrow function body이므로 function type으로 해석하지 않는다.
    if (self.current() == .r_paren) {
        try self.advance();
        if (self.current() == .arrow and !self.flow_in_return_type) {
            try self.advance();
            const return_type = try parseType(self);
            const params = try self.ast.addNodeList(&.{first_type});
            return makeFunctionType(self, start, NodeIndex.none, params, return_type);
        }
        return makeLiteralType(self, start);
    }

    // 그 외: 단순 괄호 타입
    try self.expect(.r_paren);
    return makeLiteralType(self, start);
}

fn makeFunctionType(
    self: *Parser,
    start: u32,
    type_params: NodeIndex,
    params: ast_mod.NodeList,
    return_type: NodeIndex,
) !NodeIndex {
    const extra = try self.ast.addExtras(&.{
        @intFromEnum(type_params),
        params.start,
        params.len,
        @intFromEnum(return_type),
    });
    return self.ast.addNode(.{
        .tag = .flow_function_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
    });
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
///
/// 각 param 은 `flow_property_signature` 노드로 보존 — `[key, type_ann, flags]` layout
/// (TS 의 `parseTypeMemberParam` 와 일관성). codegen plugin 등 type-level function
/// param 의 name 이 필요한 consumer 가 AST 직접 접근 가능 (#2462 source-text fallback
/// 제거).
fn parseFunctionTypeParamList(self: *Parser) ParseError2!ast_mod.NodeList {
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param_start = self.currentSpan().start;

        // ...rest 파라미터 — name 정보 안 가짐, 단순 strip.
        if (self.current() == .dot3) {
            try self.advance();
        }

        // name: Type 또는 name?: Type — 이름 뒤에 : 또는 ?: 가 오면 named param.
        // 호출처 `parseParenOrFunctionType` 가 contextual keyword (async/from/of/target/meta/let 등)
        // 도 named-param 후보로 분류하므로 여기 condition 도 동일하게 받아야 한다 — 더 좁게 받으면
        // fall-through 후 positional path 가 키워드를 type expression 으로 잘못 파싱해 fail한다.
        const can_be_param_name = self.current() == .identifier or
            (self.current().isKeyword() and !self.current().isReservedKeyword());
        if (can_be_param_name) {
            const next = try self.peekNextKind();
            if (next == .colon or next == .question) {
                const name_span = self.scanner.token.span;
                const name_node = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = name_span,
                    .data = .{ .string_ref = name_span },
                });
                try self.advance(); // skip name
                const is_optional = try self.eat(.question);
                var type_ann: NodeIndex = NodeIndex.none;
                if (try self.eat(.colon)) {
                    type_ann = try parseType(self);
                }
                const flags: PropertySignatureFlags = .{
                    .optional = is_optional,
                    .readonly = false,
                };
                const extra = try self.ast.addExtras(&.{
                    @intFromEnum(name_node),
                    @intFromEnum(type_ann),
                    flags.toU32(),
                });
                try self.scratch.append(self.allocator, try self.ast.addNode(.{
                    .tag = .flow_property_signature,
                    .span = .{ .start = param_start, .end = self.currentSpan().start },
                    .data = .{ .extra = extra },
                }));
                if (!try self.eat(.comma)) break;
                if (try self.ensureLoopProgress(loop_guard_pos)) break;
                continue;
            }
        }

        // positional: Type (이름 없는 파라미터) — strip-only.
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

    const members = try parseFlowObjectMembers(self, .r_curly);
    try self.expect(.r_curly);

    return try self.ast.addListNode(
        .flow_object_type,
        .{ .start = start, .end = self.currentSpan().start },
        members,
    );
}

/// Exact object type: `{| key: Type, ... |}` (또는 빈 `{||}`).
///
/// 토크나이즈 주의:
///   `{| ... |}` 는 `{`, `|`, ..., `|`, `}` (5+ 토큰) 로 분해
///   `{||}` (빈) 는 `{`, `||`, `}` (3 토큰) — lexer 가 `||` 를 `pipe2` 단일 토큰으로 처리
///
/// 후자 케이스를 별도 분기로 처리.
fn parseExactObjectType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip '{'

    // 빈 `{||}` — pipe2 한 토큰만 소비.
    if (self.current() == .pipe2) {
        try self.advance(); // skip '||'
        try self.expect(.r_curly);
        return try self.ast.addListNode(
            .flow_exact_object_type,
            .{ .start = start, .end = self.currentSpan().start },
            .{ .start = 0, .len = 0 },
        );
    }

    // 일반 케이스: `{|` 다음 멤버 다음 `|}`.
    try self.expect(.pipe); // skip '|'
    const members = try parseFlowObjectMembers(self, .pipe);
    try self.expect(.pipe);
    try self.expect(.r_curly);

    return try self.ast.addListNode(
        .flow_exact_object_type,
        .{ .start = start, .end = self.currentSpan().start },
        members,
    );
}

/// `{...}` / `{|...|}` 양쪽 공통: 멤버를 `,` 또는 `;` 구분으로 반복 파싱하다가
/// `terminator` 토큰을 만나면 멈춘다 (caller 가 terminator 소비).
///
/// 지원되지 않는 멤버 (spread, indexer, method, call signature) 는 `parseFlowTypeMember`
/// 가 토큰만 소비하고 `.none` 반환 — 여기선 list 에 추가하지 않음. codegen
/// (#2348 PR #3b) 은 알려진 property 만 처리하면 됨.
fn parseFlowObjectMembers(self: *Parser, terminator: Kind) ParseError2!ast_mod.NodeList {
    const scratch_top = self.saveScratch();
    while (self.current() != terminator and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const member = try parseFlowTypeMember(self);
        if (member != .none) try self.scratch.append(self.allocator, member);
        // 멤버 구분자: `,` 또는 `;`. 둘 다 없으면 종료 (단, terminator 인 경우 자연 종료).
        if (!try self.eat(.comma) and !try self.eat(.semicolon)) {
            if (self.current() != terminator) break;
        }
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    const items = self.scratch.items[scratch_top..];
    const list = try self.ast.addNodeList(items);
    self.restoreScratch(scratch_top);
    return list;
}

/// Flow object type 의 단일 멤버 파싱.
///
/// 지원 (`flow_property_signature` 반환):
///   - `key: Type`
///   - `key?: Type`        — optional
///   - `+key: Type`        — covariant (readonly mapping)
///   - `-key: Type`        — contravariant (변환기/codegen 미사용, 비트 미설정)
///   - `+key?: Type`       — combined
///
/// 미지원 (토큰만 소비, `.none` 반환):
///   - `...Type`           — spread (PR #3b 에서 별도 처리)
///   - `[key: T]: U`       — indexer
///   - `key(args): R`      — method
///   - `(args): R`         — call signature
///   - `new (args): R`     — construct signature
///
/// 미지원 케이스도 정상 파싱돼야 type alias 전체 파싱이 진행됨 — 그래서 토큰 소비
/// 후 `.none` 반환 (silent skip). caller 가 list 에서 제외.
fn parseFlowTypeMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // Variance marker: `+key` covariant (output position) → readonly 등가로 매핑.
    // `-key` contravariant (input position) → 현재 PropertySignatureFlags 에 별도 비트
    // 없음, 무시 (codegen view config 미사용 — RN spec 에서 거의 안 쓰임).
    //
    // 의미 차이 주의: TS readonly = "재할당 불가", Flow `+` = "covariant" (반환만 가능).
    // 출력 위치에서는 동등하게 read-only 처럼 동작하므로 동일 비트로 매핑 가능.
    var is_readonly = false;
    if (self.current() == .plus) {
        is_readonly = true;
        try self.advance();
    } else if (self.current() == .minus) {
        try self.advance();
    }

    // `...` 처리. 두 형태:
    //   1. inexact marker: `{ name: T, ... }` — `...` 가 단독 (`}`/`|`/`,`/`;` 직전).
    //      → silent skip (`.none` 반환).
    //   2. spread: `...Type` — `...` 다음에 type. `flow_object_spread_property` 노드 반환
    //      (Flow 공식 parser `Type.Object.SpreadProperty` 동등, #2348 후속).
    //
    // spread 시 `parsePrimaryType` 사용 (full `parseType` 아님) — `...A` 이후의 `|`
    // 을 union 으로 잘못 흡수하면 outer object type 의 `|}` 종료를 깨뜨림. spread 에는
    // 보통 단순 type reference 만 와서 primary 로 충분.
    if (self.current() == .dot3) {
        try self.advance();
        const next = self.current();
        const is_terminator = next == .r_curly or next == .pipe or
            next == .comma or next == .semicolon;
        if (is_terminator) return NodeIndex.none;
        const argument = try parsePrimaryType(self);
        return try self.ast.addUnaryNode(
            .flow_object_spread_property,
            .{ .start = start, .end = self.currentSpan().start },
            argument,
            0,
        );
    }

    // Indexer (`[key: T]: U`) 또는 call/construct signature (`(args): R`) — skip.
    if (self.current() == .l_bracket) {
        try skipBalanced(self, .l_bracket, .r_bracket);
        if (try self.eat(.colon)) _ = try parseType(self);
        return NodeIndex.none;
    }
    if (self.current() == .l_paren) {
        try skipBalancedParens(self);
        if (try self.eat(.colon)) _ = try parseType(self);
        return NodeIndex.none;
    }

    // Property key — identifier, keyword, 또는 quoted (`'aria-label'?: ?string`).
    // Flow object body 에선 reserved keyword (`delete`, `class`, ...) 도 property
    // 이름으로 허용되므로 `parseSimpleIdentifier` 의 `checkKeywordBinding` 검사를
    // 우회 (`binding.zig:309` 가 reserved keyword 에 에러). 직접 노드 생성.
    //
    // 그 외 (`[computed]` / spread 등은 위에서 분기) → unknown — fail-safe skip.
    const c = self.current();
    const is_ident_like = c == .identifier or c == .escaped_keyword or
        c == .escaped_strict_reserved or c.isKeyword();
    const is_string_key = c == .string_literal;
    if (!is_ident_like and !is_string_key) return NodeIndex.none;
    const key_span = self.currentSpan();
    try self.advance();
    const key = try self.ast.addNode(.{
        .tag = if (is_string_key) Tag.string_literal else Tag.binding_identifier,
        .span = key_span,
        .data = .{ .string_ref = key_span },
    });

    // method signature: `key(args): R` 또는 `key<T>(args): R` — skip.
    // 제네릭 type parameter (`<T>`) 가 앞에 올 수 있으므로 angle bracket 도 감지.
    if (self.isAtOpeningAngleBracket()) {
        try skipBalanced(self, .l_angle, .r_angle);
    }
    if (self.current() == .l_paren) {
        try skipBalancedParens(self);
        if (try self.eat(.colon)) _ = try parseType(self);
        return NodeIndex.none;
    }

    const is_optional = try self.eat(.question);

    var type_ann: NodeIndex = NodeIndex.none;
    if (try self.eat(.colon)) {
        type_ann = try parseType(self);
    }

    const flags: PropertySignatureFlags = .{
        .optional = is_optional,
        .readonly = is_readonly,
    };

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(key),
        @intFromEnum(type_ann),
        flags.toU32(),
    });
    return try self.ast.addNode(.{
        .tag = .flow_property_signature,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra },
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
    const list = try self.ast.addNodeList(items);
    self.scratch.shrinkRetainingCapacity(scratch_top);
    return try self.ast.addListNode(
        .flow_tuple_type,
        .{ .start = start, .end = self.currentSpan().start },
        list,
    );
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
        try self.addErrorCode(self.currentSpan(), "Expected 'type' after 'opaque'", .flow_opaque_type);
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
    // angle bracket 컨텍스트에선 lexer 가 `<<`/`>>`/`>>>` 를 단일 멀티 char 토큰으로 묶지만,
    // nested generic (`<T<U>>` 등) 의 닫힘에 해당. 단일 close 로만 카운트하면 depth 가
    // 0 까지 안 떨어져 EOF 까지 소비 → outer parser 깨짐 (rn EventEmitter.js #2420).
    const is_angle = open == .l_angle and close == .r_angle;
    while (depth > 0 and self.current() != .eof) {
        const cur = self.current();
        if (cur == open) {
            depth += 1;
            try self.advance();
        } else if (cur == close) {
            depth -= 1;
            if (depth > 0) try self.advance();
        } else if (is_angle and cur == .shift_left) {
            depth += 2;
            try self.advance();
        } else if (is_angle and (cur == .shift_right or cur == .shift_right3)) {
            // `>>` = 2 close, `>>>` = 3 close. depth >= n_close 면 토큰 통째 소비.
            // 미달 (defensive — 정상 syntax 에선 발생 X) 은 depth = 0 + 토큰 미소비 →
            // 외부 expect(close) 에서 에러 통일. 비대칭 동작 회피.
            const n_close: u32 = if (cur == .shift_right) 2 else 3;
            if (depth >= n_close) {
                depth -= n_close;
                try self.advance();
                if (depth == 0) return;
            } else {
                depth = 0;
            }
        } else {
            try self.advance();
        }
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
///
/// 변환 규칙 (hermes-parser 호환):
/// - ref 파라미터가 있으면:
///   `const View = React.forwardRef(View_withRef);`
///   `function View_withRef({...props}, ref) { ... }`
///   → ref는 두 번째 인자, 나머지는 props object destructuring
/// - ref 없으면:
///   `function View({name, ...props}) { ... }`
/// - rest만 있으면 (...props):
///   `function View(props) { ... }` (destructuring 아닌 단일 param)
/// - hook은 ref 처리 없이 일반 함수 (component와 동일한 파라미터 파싱)
pub fn parseFlowComponentDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const keyword_text = self.ast.source[self.currentSpan().start..self.currentSpan().end];
    const is_hook = std.mem.eql(u8, keyword_text, "hook");
    try self.advance(); // skip 'component' / 'hook'

    // 함수 이름
    const name = try self.parseSimpleIdentifier();

    // 선택적 제네릭 타입 파라미터: component Foo<T>(...)
    if (self.isAtOpeningAngleBracket()) {
        _ = try parseTypeParameterDeclaration(self);
    }

    // component 파라미터를 파싱.
    // ref 파라미터가 있으면 분리하고, 나머지는 props object destructuring으로 변환.
    try self.expect(.l_paren);
    const scratch_top = self.saveScratch();
    const param_start_span = self.currentSpan();

    var has_ref = false;
    var ref_node: NodeIndex = .none;
    var has_rest = false;
    var rest_node: NodeIndex = .none;
    var prop_count: u32 = 0;

    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        // rest: ...props: Type → binding_rest_element
        if (self.current() == .dot3) {
            try self.advance();
            const rest_name = try self.parseSimpleIdentifier();
            if (self.current() == .colon) {
                try self.advance();
                _ = try parseType(self);
            }
            has_rest = true;
            rest_node = try self.ast.addNode(.{
                .tag = .binding_rest_element,
                .span = .{ .start = loop_guard_pos, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = rest_name, .flags = 0 } },
            });
        } else {
            // propName: Type = default → binding_property
            const prop_name = try self.parseSimpleIdentifier();
            const prop_text = self.ast.source[self.ast.getNode(prop_name).span.start..self.ast.getNode(prop_name).span.end];
            _ = try self.eat(.question);
            if (self.current() == .colon) {
                try self.advance();
                _ = try parseType(self);
            }

            const right_node = if (try self.eat(.eq)) blk: {
                const default_val = try self.parseAssignmentExpression();
                break :blk try self.ast.addNode(.{
                    .tag = .assignment_pattern,
                    .span = .{ .start = loop_guard_pos, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = prop_name, .right = default_val, .flags = 0 } },
                });
            } else prop_name;

            // ref 파라미터는 분리 (hook에서는 ref도 일반 prop으로 취급)
            if (!is_hook and std.mem.eql(u8, prop_text, "ref")) {
                has_ref = true;
                ref_node = right_node; // ref 또는 assignment_pattern(ref = default)
            } else {
                try self.scratch.append(self.allocator, try self.ast.addNode(.{
                    .tag = .binding_property,
                    .span = .{ .start = loop_guard_pos, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = prop_name, .right = right_node, .flags = 0 } },
                }));
                prop_count += 1;
            }
        }

        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    // 파라미터 구성:
    // - rest만 있고 다른 prop 없으면 → 단일 파라미터 (function Name(props))
    // - prop이 있으면 → object_pattern ({ name, ...rest })
    // - ref가 있으면 → 두 번째 파라미터로 추가
    var params: ast_mod.NodeList = undefined;

    if (prop_count == 0 and has_rest and !has_ref) {
        // rest만 있으면 destructuring 없이 단일 param: function Baz(props)
        const rest_inner = self.ast.getNode(rest_node).data.unary.operand;
        params = try self.ast.addNodeList(&.{rest_inner});
    } else if (prop_count == 0 and !has_rest and !has_ref) {
        // 파라미터 없음
        params = try self.ast.addNodeList(&.{});
    } else {
        // object_pattern 생성 (ref 제외한 props)
        if (has_rest) {
            try self.scratch.append(self.allocator, rest_node);
        }
        const all_prop_items = self.scratch.items[scratch_top..];
        const prop_list = try self.ast.addNodeList(all_prop_items);

        const obj_pattern = try self.ast.addNode(.{
            .tag = .object_pattern,
            .span = .{ .start = param_start_span.start, .end = self.currentSpan().start },
            .data = .{ .list = prop_list },
        });

        if (has_ref) {
            // 두 번째 파라미터로 ref 추가: function Name_withRef({...props}, ref)
            params = try self.ast.addNodeList(&.{ obj_pattern, ref_node });
        } else {
            params = try self.ast.addNodeList(&.{obj_pattern});
        }
    }

    self.restoreScratch(scratch_top);
    try self.expect(.r_paren);

    try trySkipRendersClause(self);

    // 반환 타입 어노테이션 스킵: component Foo(): Type { }
    _ = try tryParseReturnType(self);

    // 함수 컨텍스트 진입 (return 허용)
    const saved_ctx = self.enterFunctionContext(false, false);
    const body = try self.parseBlockStatement();
    self.restoreFunctionContext(saved_ctx);

    if (has_ref) {
        // ref가 있으면 파서에서 2개 statement를 직접 생성:
        //   1) function Name_withRef({...props}, ref) { body }
        //   2) const Name = React.forwardRef(Name_withRef)
        // flow_component_wrapper: extra = [func_decl, const_decl]
        // transformer는 func_decl을 pending_nodes, const_decl을 반환��� 하면 됨.

        const span: Span = .{ .start = start, .end = self.currentSpan().start };

        // Name_withRef 합성 이름 → addString 으로 통합 (intern map 등록 + STRING_TABLE_BIT 자동).
        // addString 이 byte 본문을 string_table 로 복사한 후 임시 buffer 는 free.
        const name_node = self.ast.getNode(name);
        const name_text = self.ast.source[name_node.span.start..name_node.span.end];
        const combined = try std.fmt.allocPrint(self.ast.allocator, "{s}_withRef", .{name_text});
        defer self.ast.allocator.free(combined);
        const with_ref_full = try self.ast.addString(combined);

        const with_ref_name = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = with_ref_full,
            .data = .{ .string_ref = with_ref_full },
        });

        // 1) function Name_withRef({...props}, ref) { body }
        const none = @intFromEnum(NodeIndex.none);
        const params_node = try self.wrapAsFormalParametersFromList(params, .{ .start = 0, .end = 0 });
        const func_extra = try self.ast.addExtra(@intFromEnum(with_ref_name));
        _ = try self.ast.addExtra(@intFromEnum(params_node));
        _ = try self.ast.addExtra(@intFromEnum(body));
        _ = try self.ast.addExtra(0); // flags
        _ = try self.ast.addExtra(none); // return_type
        const func_decl = try self.ast.addNode(.{
            .tag = .function_declaration,
            .span = span,
            .data = .{ .extra = func_extra },
        });

        // 2) const Name = React.forwardRef(Name_withRef)
        const react_span = try self.ast.addString("React");
        const react_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = react_span,
            .data = .{ .string_ref = react_span },
        });
        const fwd_span = try self.ast.addString("forwardRef");
        const fwd_id = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = fwd_span,
            .data = .{ .string_ref = fwd_span },
        });
        // static_member_expression: extra = [object, property, flags]
        const member_extra = try self.ast.addExtras(&.{
            @intFromEnum(react_ref), @intFromEnum(fwd_id), 0,
        });
        const callee = try self.ast.addNode(.{
            .tag = .static_member_expression,
            .span = span,
            .data = .{ .extra = member_extra },
        });
        const arg_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = with_ref_full,
            .data = .{ .string_ref = with_ref_full },
        });
        const args_list = try self.ast.addNodeList(&.{arg_ref});
        const call_extra = try self.ast.addExtras(&.{
            @intFromEnum(callee), args_list.start, args_list.len, 0,
        });
        const call_node = try self.ast.addNode(.{
            .tag = .call_expression,
            .span = span,
            .data = .{ .extra = call_extra },
        });

        // #1751: 원본 `component Name(...)` 의 name 노드 span 을 재사용.
        // `addString(name_text)` 로 string_table 에 중복 저장하면 bit-31 tagged span
        // 이 되어, 이후 semantic 이 이 binding 을 const 선언 심볼로 등록할 때
        // `Symbol.name` 이 string_table 참조가 된다. mangler 가 `source[span.start..]`
        // 를 naive slice 하면서 OOB 크래시 (RN + --minify + Flow component 조합).
        // 이름이 이미 원본 source 에 존재하므로 원본 span 그대로 재사용한다.
        const binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_node.span,
            .data = .{ .string_ref = name_node.span },
        });
        // variable_declarator: extra = [name, type_ann, init]
        const decl_extra = try self.ast.addExtras(&.{
            @intFromEnum(binding), none, @intFromEnum(call_node),
        });
        const declarator = try self.ast.addNode(.{
            .tag = .variable_declarator,
            .span = span,
            .data = .{ .extra = decl_extra },
        });
        // variable_declaration: extra = [kind_flags, list_start, list_len]
        const decl_list = try self.ast.addNodeList(&.{declarator});
        const var_extra = try self.ast.addExtras(&.{ @intFromEnum(VariableDeclarationKind.@"const"), decl_list.start, decl_list.len });
        const const_decl = try self.ast.addNode(.{
            .tag = .variable_declaration,
            .span = span,
            .data = .{ .extra = var_extra },
        });

        // wrapper: extra = [func_decl, const_decl]
        const wrapper_extra = try self.ast.addExtras(&.{
            @intFromEnum(func_decl), @intFromEnum(const_decl),
        });
        return try self.ast.addNode(.{
            .tag = .flow_component_wrapper,
            .span = span,
            .data = .{ .extra = wrapper_extra },
        });
    }

    // ref가 없으면 일반 함수 선언
    const none = @intFromEnum(NodeIndex.none);
    const params_node = try self.wrapAsFormalParametersFromList(params, .{ .start = 0, .end = 0 });
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(@intFromEnum(params_node));
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(0);
    _ = try self.ast.addExtra(none);

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

    // body: { ... } — Flow 공식 parser 와 동일하게 본문 멤버 보존 (#2348 후속).
    // codegen schema_builder 가 flow_interface_declaration 멤버를 직접 참조 (TS interface
    // body 와 동일 패턴, ts.zig:99). body 가 없으면 .none.
    const body: NodeIndex = if (self.current() == .l_curly)
        try parseObjectType(self)
    else
        NodeIndex.none;

    const extra = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(type_params),
        extends_start,
        extends_len,
        @intFromEnum(body),
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

        // arm: binary { left=pattern, right=body }. 별도 tag (`flow_match_arm`)
        // 로 outer `flow_match_expression` (extra layout) 과 분리 — 이전엔 tag
        // 를 재사용해서 audit cosmetic exemption 이 필요했다 (#1802). #1822
        // 에서 분리 후 audit exemption 제거.
        const arm = try self.ast.addBinaryNode(
            .flow_match_arm,
            .{ .start = loop_guard_pos, .end = self.currentSpan().start },
            pattern,
            body,
            0,
        );
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

// ===== Flow enum (#2401) =====

pub const FlowEnumBaseType = enum(u32) {
    none = 0,
    string = 1,
    number = 2,
    boolean = 3,
    symbol = 4,
};

pub fn parseFlowEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'enum'

    const name = try self.parseSimpleIdentifier();

    // optional `of <base>` — `of` 는 ZNTC 에서 kw_of (`for...of` 와 공유).
    var base_type: FlowEnumBaseType = .none;
    if (self.current() == .kw_of) {
        try self.advance();
        base_type = try parseFlowEnumBaseType(self);
    }

    try self.expect(.l_curly);

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;

        // `...,` ellipsis (open enum) — 인식만, 멤버 추가 없음.
        if (self.current() == .dot3) {
            try self.advance();
            _ = try self.eat(.comma);
            if (try self.ensureLoopProgress(loop_guard_pos)) break;
            continue;
        }

        const member = try parseFlowEnumMember(self);
        try self.scratch.append(self.allocator, member);
        if (!try self.eat(.comma) and !try self.eat(.semicolon)) break;

        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name),
        members.start,
        members.len,
        @intFromEnum(base_type),
    });

    self.ast.has_flow_enum_declaration = true;
    return try self.ast.addNode(.{
        .tag = .flow_enum_declaration,
        .span = .{ .start = start, .end = end },
        .data = .{ .extra = extra_start },
    });
}

fn parseFlowEnumBaseType(self: *Parser) ParseError2!FlowEnumBaseType {
    if (self.current() != .identifier) return .none;
    const text = self.scanner.tokenText();
    const kind: FlowEnumBaseType = if (std.mem.eql(u8, text, "string"))
        .string
    else if (std.mem.eql(u8, text, "number"))
        .number
    else if (std.mem.eql(u8, text, "boolean"))
        .boolean
    else if (std.mem.eql(u8, text, "symbol"))
        .symbol
    else
        .none;
    if (kind != .none) try self.advance();
    return kind;
}

fn parseFlowEnumMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name = try self.parsePropertyKey();

    var init_val = NodeIndex.none;
    if (try self.eat(.eq)) {
        init_val = try self.parseAssignmentExpression();
    }

    return try self.ast.addNode(.{
        .tag = .flow_enum_member,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = init_val, .flags = 0 } },
    });
}
