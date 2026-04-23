//! Expression 파싱
//!
//! 모든 표현식 타입(assignment, binary, unary, call, member access 등)과
//! 프로퍼티 키, 리터럴을 파싱하는 함수들.
//! 바인딩 패턴(destructuring)은 binding.zig, 객체 리터럴은 object.zig로 분리됨.
//! oxc의 js/expression.rs + js/arrow.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/js/expression.rs
//! - object.zig (js/object.rs 대응)
//! - binding.zig (js/binding.rs 대응)

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;
const flow = @import("flow.zig");
const scan_results_mod = @import("scan_results.zig");
const import_scanner = @import("../bundler/import_scanner.zig");

/// TypeScript의 canFollowTypeArgumentsInExpression 대응 (esbuild tsCanFollowTypeArgumentsInExpression).
/// `f<Type>` 다음에 올 수 있는 토큰인지 판별한다.
/// esbuild 3단계 로직:
/// 1. 호출/템플릿 토큰 → true (확실히 type args)
/// 2. `<`, `>`, `+`, `-` (및 `>`로 시작하는 복합 토큰) → false (확실히 비교)
/// 3. newline_before || isBinaryOperator || !isStartOfExpression → true
fn canFollowTypeArgumentsInExpression(self: *const Parser) bool {
    const kind = self.current();
    return switch (kind) {
        // 호출, 멤버 접근, tagged template — 확실히 type args 뒤에 올 수 있음
        .l_paren, .dot, .question_dot => true,
        .no_substitution_template, .template_head => true,

        // `<` 뒤에 또 `<`는 의미 없고, `>`는 re-scan된 `>>`와 모호하므로 불허.
        // `+`, `-`는 이 컨텍스트에서 단항 연산자이므로 불허.
        // `>`로 시작하는 복합 토큰(>=, >>, >>>, >>=, >>>=)도 불허 (esbuild 동일).
        .l_angle,
        .r_angle,
        .plus,
        .minus,
        .gt_eq,
        .shift_right,
        .shift_right_eq,
        .shift_right3,
        .shift_right3_eq,
        => false,

        // 그 외: newline || binary operator || not start of expression → true
        else => self.scanner.token.has_newline_before or
            tsIsBinaryOperator(self, kind) or
            !tsIsStartOfExpression(self, kind),
    };
}

/// TypeScript 컴파일러의 isBinaryOperator 대응.
/// 현재 토큰이 이항 연산자인지 판별한다.
fn tsIsBinaryOperator(self: *const Parser, kind: Kind) bool {
    if (kind == .kw_in) return self.ctx.allow_in;
    if (getBinaryPrecedence(kind) > 0) return true;
    if (kind == .identifier) {
        const text = self.tokenText();
        return std.mem.eql(u8, text, "as") or std.mem.eql(u8, text, "satisfies");
    }
    return false;
}

/// TypeScript 컴파일러의 isStartOfExpression 대응.
/// 현재 토큰이 expression의 시작이 될 수 있는지 판별한다.
fn tsIsStartOfExpression(self: *const Parser, kind: Kind) bool {
    if (tsIsStartOfLeftHandSideExpression(kind)) return true;
    return switch (kind) {
        .plus, .minus, .tilde, .bang => true,
        .kw_delete, .kw_typeof, .kw_void => true,
        .plus2, .minus2 => true,
        .l_angle => true,
        .private_identifier => true,
        .at => true,
        .kw_await, .kw_yield => true,
        else => tsIsBinaryOperator(self, kind),
    };
}

/// TypeScript 컴파일러의 isStartOfLeftHandSideExpression 대응.
fn tsIsStartOfLeftHandSideExpression(kind: Kind) bool {
    return switch (kind) {
        .kw_this, .kw_super => true,
        .kw_null, .kw_true, .kw_false => true,
        .string_literal,
        .no_substitution_template,
        .template_head,
        => true,
        .l_paren, .l_bracket, .l_curly => true,
        .kw_function, .kw_class, .kw_new => true,
        .slash, .slash_eq => true, // regex
        .identifier => true,
        .kw_import => true,
        else => kind.isNumericLiteral(), // decimal, float, hex, bigint 등
    };
}

/// 콤마 연산자(sequence expression)를 포함한 최상위 표현식 파싱.
/// ECMAScript: Expression = AssignmentExpression (',' AssignmentExpression)*
/// 콤마가 없으면 단일 AssignmentExpression을 그대로 반환하고,
/// 콤마가 있으면 sequence_expression 노드로 감싼다.
/// parseExpression과 동일하지만 `...`(rest) 요소도 허용한다.
/// arrow function 파라미터의 cover grammar: `(a, ...b) => {}`.
/// 일반 expression 위치에서 `...`는 invalid이지만, arrow 파라미터로 재해석될 수 있으므로
/// 여기서 parseSpreadOrAssignment을 사용하여 spread_element 노드를 생성한다.
fn parseExpressionOrRest(self: *Parser) ParseError2!NodeIndex {
    const first = try parseSpreadOrAssignment(self);

    if (self.current() != .comma) return first;

    const scratch_top = self.saveScratch();
    try self.scratch.append(self.allocator, first);
    var had_trailing_comma = false;
    while (try self.eat(.comma)) {
        if (self.current() == .r_paren) {
            had_trailing_comma = true;
            break;
        }
        const elem = try parseSpreadOrAssignment(self);
        try self.scratch.append(self.allocator, elem);
    }
    // rest element 뒤 trailing comma 감지: (...a,) → SyntaxError
    // 마지막 요소가 spread이고 while이 trailing comma 때문에 break했으면 플래그 설정
    if (had_trailing_comma) {
        const items = self.scratch.items[scratch_top..];
        if (items.len > 0) {
            const last_idx = items[items.len - 1];
            if (!last_idx.isNone() and self.ast.getNode(last_idx).tag == .spread_element) {
                self.ast.nodes.items[@intFromEnum(last_idx)].data = .{
                    .unary = .{ .operand = self.ast.getNode(last_idx).data.unary.operand, .flags = Parser.spread_trailing_comma },
                };
            }
        }
    }
    const first_span = self.ast.getNode(first).span;
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    return try self.ast.addNode(.{
        .tag = .sequence_expression,
        .span = .{ .start = first_span.start, .end = self.currentSpan().start },
        .data = .{ .list = list },
    });
}

pub fn parseExpression(self: *Parser) ParseError2!NodeIndex {
    const first = try parseAssignmentExpression(self);

    // 콤마가 없으면 단순 표현식
    if (self.current() != .comma) return first;

    // 콤마 연산자 → sequence expression
    const scratch_top = self.saveScratch();
    try self.scratch.append(self.allocator, first);
    while (try self.eat(.comma)) {
        // trailing comma: 콤마 뒤에 )가 오면 arrow function 파라미터 trailing comma
        if (self.current() == .r_paren) break;
        const elem = try parseAssignmentExpression(self);
        try self.scratch.append(self.allocator, elem);
    }
    const first_span = self.ast.getNode(first).span;
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    return try self.ast.addNode(.{
        .tag = .sequence_expression,
        .span = .{ .start = first_span.start, .end = self.currentSpan().start },
        .data = .{ .list = list },
    });
}

/// arrow function의 body를 파싱한다.
/// arrow function은 함수이므로 in_function=true, loop/switch 리셋.
/// block body면 parseFunctionBody(), expression body면 parseAssignmentExpression().
pub fn parseArrowBody(self: *Parser, is_async: bool, param_idx: NodeIndex) ParseError2!NodeIndex {
    // arrow function은 generator가 될 수 없으므로 is_generator=false
    const saved_ctx = self.enterFunctionContext(is_async, false);
    // arrow function은 자체 바인딩이 없으므로 외부 컨텍스트를 상속:
    // - in_class_field: arguments 사용 제한 (arrow에는 자체 arguments 없음)
    // - allow_new_target: new.target 허용 여부 (global arrow에서는 false)
    // - allow_super_call/allow_super_property: super 접근 허용 여부 (메서드 내 arrow에서 super 사용)
    // in_static_initializer: arguments 사용 제한을 위해 상속 (arrow에는 자체 arguments 없음)
    // await은 ctx.in_async=true (static block에서 설정)로 별도 처리
    self.in_class_field = saved_ctx.in_class_field;
    self.in_static_initializer = saved_ctx.in_static_initializer;
    self.allow_new_target = saved_ctx.allow_new_target;
    self.allow_super_call = saved_ctx.allow_super_call;
    self.allow_super_property = saved_ctx.allow_super_property;
    // ECMAScript 14.2.1: non-simple params + "use strict" body → SyntaxError
    // cover grammar에서 파라미터가 simple인지 확인하여 parseFunctionBody에서 검증.
    self.has_simple_params = self.isSimpleArrowParams(param_idx);
    const body = if (self.current() == .l_curly)
        try self.parseFunctionBodyExpr()
    else blk: {
        // expression body에서는 외부 ternary context를 유지해야 함.
        // enterFunctionContext가 in_ternary_consequent를 false로 리셋하지만,
        // 화살표 expression body에서 `:` 를 만나면 외부 삼항의 separator일 수 있음.
        // `a ? v => (expr) : v => (expr2)` — `:` 는 외부 삼항의 separator.
        self.in_ternary_consequent = saved_ctx.in_ternary_consequent;
        break :blk try parseAssignmentExpression(self);
    };
    self.restoreFunctionContext(saved_ctx);
    return body;
}

pub fn parseAssignmentExpression(self: *Parser) ParseError2!NodeIndex {
    // TS 제네릭 arrow function: <T>() => body, <const T>() => body
    // TSX 모드에서는 trailing comma(<T,>), constraint(<T extends X>), default(<T = X>)가
    // 있을 때만 제네릭 arrow로 시도 (oxc arrow.rs:166-197 참고)
    if (self.current() == .l_angle) {
        if (!self.is_jsx or try isTsxGenericArrow(self)) {
            if (try tryParseGenericArrow(self, false)) |arrow| return arrow;
        }
    }

    // async arrow function 감지 (2가지 형태)
    if (self.current() == .kw_async) {
        const async_span = self.currentSpan();
        const peek = try self.peekNext();

        if (!peek.has_newline_before) {
            // TS async 제네릭 arrow: async <T>() => body
            // TSX에서는 disambiguating signal이 있을 때만 시도
            if (peek.kind == .l_angle) {
                if (!self.is_jsx or try isTsxGenericArrowAfterAsync(self)) {
                    const saved = self.saveState();
                    try self.advance(); // skip 'async'
                    if (try tryParseGenericArrow(self, true)) |arrow| return arrow;
                    self.restoreState(saved);
                }
            }

            // 형태 1: async x => body (단순 식별자)
            if (peek.kind == .identifier or (peek.kind.isKeyword() and !peek.kind.isReservedKeyword())) {
                const saved = self.saveState();
                try self.advance(); // skip 'async'
                const id_span = self.currentSpan();
                try self.advance(); // skip identifier
                if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                    // ECMAScript 14.2.1: strict mode에서 eval/arguments를 arrow 파라미터로 사용 금지
                    try self.checkStrictBinding(id_span);
                    try self.advance(); // skip =>
                    const param = try self.ast.addNode(.{
                        .tag = .binding_identifier,
                        .span = id_span,
                        .data = .{ .string_ref = id_span },
                    });
                    const params_node = try self.wrapAsFormalParameters(&.{param}, id_span);
                    const body = try parseArrowBody(self, true, params_node);
                    {
                        const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), 0x01 });
                        return try self.ast.addNode(.{
                            .tag = .arrow_function_expression,
                            .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                            .data = .{ .extra = ae },
                        });
                    }
                }
                self.restoreState(saved);
            }

            // 형태 2: async (...) => body (괄호 형태)
            // async () => {} — 빈 파라미터도 포함
            if (peek.kind == .l_paren) {
                const saved = self.saveState();
                try self.advance(); // skip 'async'

                // TS typed arrow 먼저 시도: async (a: Type): ReturnType => body
                // 빈 파라미터 + 리턴 타입 (async (): void => {})도 isTypedArrowFunction이 감지
                if (try self.isTypedArrowFunction()) {
                    if (try self.parseTypedArrowParams(async_span.start, true)) |arrow| return arrow;
                    self.restoreState(saved);
                } else if (self.current() == .l_paren and try self.peekNextKind() == .r_paren) {
                    // () 빈 파라미터 체크 (타입 없는 경우)
                    const empty_paren_start = self.currentSpan().start;
                    try self.advance(); // skip (
                    try self.advance(); // skip )
                    if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                        try self.advance(); // skip =>
                        const params_node = try self.wrapAsFormalParameters(&.{}, .{ .start = empty_paren_start, .end = empty_paren_start });
                        const body = try parseArrowBody(self, true, params_node);
                        {
                            const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), 0x01 });
                            return try self.ast.addNode(.{
                                .tag = .arrow_function_expression,
                                .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                                .data = .{ .extra = ae },
                            });
                        }
                    }
                    self.restoreState(saved);
                } else {
                    // 괄호를 expression으로 파싱 (parenthesized_expression)
                    const params_expr = try parseConditionalExpression(self);
                    if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                        const normalized_params = try self.coverExpressionToArrowParams(params_expr);
                        // async arrow: 파라미터에 'await' 식별자 사용 금지
                        try self.checkAsyncArrowParamsForAwait(params_expr);
                        try self.advance(); // skip =>
                        const body = try parseArrowBody(self, true, normalized_params);
                        {
                            const ae = try self.ast.addExtras(&.{ @intFromEnum(normalized_params), @intFromEnum(body), 0x01 });
                            return try self.ast.addNode(.{
                                .tag = .arrow_function_expression,
                                .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                                .data = .{ .extra = ae },
                            });
                        }
                    }
                    self.restoreState(saved);
                }
            }
        }
    }

    // 단일 식별자 + => → arrow function (간단한 형태: x => x + 1)
    if (self.current() == .identifier) {
        const id_span = self.currentSpan();
        const saved = self.saveState();

        try self.advance(); // skip identifier
        if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
            // identifier => body
            // ECMAScript 14.2.1: strict mode에서 eval/arguments를 arrow 파라미터로 사용 금지
            try self.checkStrictBinding(id_span);
            try self.advance(); // skip =>
            const param = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = id_span,
                .data = .{ .string_ref = id_span },
            });
            // 모든 arrow는 formal_parameters list로 정규화 (ESTree 계약)
            const params_node = try self.wrapAsFormalParameters(&.{param}, id_span);
            const body = try parseArrowBody(self, false, params_node);

            {
                const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), 0 });
                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = id_span.start, .end = self.currentSpan().start },
                    .data = .{ .extra = ae },
                });
            }
        }

        // arrow가 아님 → 되돌리기
        self.restoreState(saved);
    }

    // () => body — 빈 파라미터 arrow function
    if (self.current() == .l_paren and try self.peekNextKind() == .r_paren) {
        const arrow_start = self.currentSpan().start;
        const saved = self.saveState();
        try self.advance(); // skip (
        try self.advance(); // skip )
        if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
            try self.advance(); // skip =>
            const params_node = try self.wrapAsFormalParameters(&.{}, .{ .start = arrow_start, .end = arrow_start });
            const body = try parseArrowBody(self, false, params_node);
            {
                const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), 0 });
                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = arrow_start, .end = self.currentSpan().start },
                    .data = .{ .extra = ae },
                });
            }
        }
        self.restoreState(saved);
    }

    // yield expression — AssignmentExpression 레벨에서만 유효 (ECMAScript 14.4)
    // UnaryExpression 위치에서는 yield가 IdentifierReference로 해석되어야 함
    if (self.current() == .kw_yield and self.ctx.in_generator) {
        // formal parameter 안에서 yield expression 금지 (ECMAScript 14.1.2)
        if (self.in_formal_parameters) {
            try self.addErrorCode(self.currentSpan(), "'yield' expression is not allowed in formal parameters", .yield_in_parameters);
        }
        const yield_start = self.currentSpan().start;
        try self.advance();
        // yield* delegate — * 전에 줄바꿈이 있으면 delegate 아님
        var yield_flags: u16 = 0;
        if (!self.scanner.token.has_newline_before and try self.eat(.star)) {
            yield_flags = 1; // delegate
        }
        var operand = NodeIndex.none;
        // yield 뒤에 줄바꿈 없이 expression이 오면 yield의 인자
        // 뒤따르는 토큰이 expression 시작이 아니면 bare yield (operand 없음)
        if (!self.scanner.token.has_newline_before and
            self.current() != .semicolon and self.current() != .r_curly and
            self.current() != .r_paren and self.current() != .r_bracket and
            self.current() != .colon and self.current() != .comma and
            self.current() != .kw_in and self.current() != .kw_of and
            self.current() != .template_middle and self.current() != .template_tail and
            self.current() != .eof)
        {
            // yield 뒤의 /는 regexp로 재스캔 (division이 아님)
            // yield의 RHS에서 /abc/i 같은 regexp가 올 수 있다
            if (self.current() == .slash or self.current() == .slash_eq) {
                self.scanner.rescanAsRegexp();
            }
            operand = try parseAssignmentExpression(self);
        }
        return try self.ast.addNode(.{
            .tag = .yield_expression,
            .span = .{ .start = yield_start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = operand, .flags = yield_flags } },
        });
    }

    var left = try parseConditionalExpression(self);

    // TS typed arrow with return type after ternary alternate:
    // `a ? b : (e = f) : T => g` — the alternate `(e = f)` followed by `: T =>` is a typed arrow.
    // Only try this when NOT inside a ternary consequent (to avoid consuming
    // the outer ternary's `:` separator in nested ternaries).
    if (self.current() == .colon and !self.in_ternary_consequent and !left.isNone()) {
        const left_node = self.ast.getNode(left);
        if (left_node.tag == .parenthesized_expression) {
            if (try tryReinterpretAsTypedArrow(self, left)) |arrow| {
                return arrow;
            }
        }
    }

    // => 를 만나면 arrow function (괄호 형태)
    // left가 parenthesized_expression이면 파라미터 리스트로 취급
    // ECMAScript 14.2: [no LineTerminator here] => ConciseBody
    // call_expression 등은 arrow 파라미터가 될 수 없음 (e.g., async() => {})
    if (self.current() == .arrow and !self.scanner.token.has_newline_before and
        self.isValidArrowParamForm(left))
    {
        // arrow 파라미터 cover grammar 검증 + formal_parameters 노드로 정규화
        const left_start = self.ast.getNode(left).span.start;
        const normalized_params = try self.coverExpressionToArrowParams(left);
        try self.advance(); // skip =>
        const body = try parseArrowBody(self, false, normalized_params);

        {
            const ae = try self.ast.addExtras(&.{ @intFromEnum(normalized_params), @intFromEnum(body), 0 });
            return try self.ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .extra = ae },
            });
        }
    }

    if (self.current().isAssignment()) {
        // cover grammar: expression → assignment target 검증 (ECMAScript 13.15.1)
        // 구조적 유효성 + rest-init + escaped keyword + strict eval/arguments를 단일 walk로 검증
        _ = try self.coverExpressionToAssignmentTarget(left, true);
        const left_start = self.ast.getNode(left).span.start;
        const flags: u16 = @intFromEnum(self.current());
        try self.advance();
        const right = try parseAssignmentExpression(self);

        // Inline scan: CJS pattern detection (module.exports = ..., exports.x = ...)
        if (self.enable_scan) {
            scanAssignmentCjs(self, left);
        }

        return try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = .{ .start = left_start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = left, .right = right, .flags = flags } },
        });
    }

    return left;
}

fn parseConditionalExpression(self: *Parser) ParseError2!NodeIndex {
    const expr = try parseBinaryExpression(self, 0);

    if (try self.eat(.question)) {
        const expr_start = self.ast.getNode(expr).span.start;
        // ECMAScript: ConditionalExpression[In] →
        //   ... ? AssignmentExpression[+In] : AssignmentExpression[?In]
        // consequent는 항상 `in` 허용, alternate는 외부 context 유지
        const cond_saved = self.enterAllowInContext(true);
        // ternary consequent에서 `(x): T =>` 패턴의 typed arrow 감지를 억제한다.
        // `:` 가 return type annotation인지 ternary separator인지 모호하기 때문.
        // 대신 아래 tryReinterpretAsTypedArrow에서 speculative하게 시도한다.
        const saved_in_ternary = self.in_ternary_consequent;
        self.in_ternary_consequent = true;
        var consequent = try parseAssignmentExpression(self);
        self.in_ternary_consequent = saved_in_ternary;
        self.restoreContext(cond_saved); // alternate는 원래 context로 복원

        // TS typed arrow in ternary consequent:
        // `a ? (b = c) : T => d : (e = f)` → `a ? ((b = c): T => d) : (e = f)`
        // The first `:` is a return type annotation for the typed arrow, not the ternary separator.
        // After parsing the consequent as a parenthesized expression and seeing `:`,
        // speculatively try `: Type => body` to see if it forms a typed arrow.
        // If successful, the arrow becomes the consequent; the next `:` is the ternary separator.
        if (self.current() == .colon and !consequent.isNone()) {
            const cons_node = self.ast.getNode(consequent);
            if (cons_node.tag == .parenthesized_expression) {
                if (try tryReinterpretAsTypedArrow(self, consequent)) |arrow| {
                    consequent = arrow;
                }
            }
        }

        try self.expect(.colon);
        const alternate = try parseAssignmentExpression(self);
        return try self.ast.addNode(.{
            .tag = .conditional_expression,
            .span = .{ .start = expr_start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = expr, .b = consequent, .c = alternate } },
        });
    }

    return expr;
}

/// Speculatively try to reinterpret a parenthesized expression followed by `: Type =>`
/// as a typed arrow function. Used in ternary consequent position where `:` is ambiguous
/// between return type annotation and ternary separator.
/// Returns the arrow node on success, null on failure (state fully restored).
fn tryReinterpretAsTypedArrow(self: *Parser, paren_expr: NodeIndex) ParseError2!?NodeIndex {
    const saved = self.saveState();
    const errors_before = self.errors.items.len;

    // Consume `:` (speculatively — might be return type or ternary separator)
    try self.advance(); // skip :

    // Parse the return type. Use disallow_conditional_types to prevent the type
    // parser from consuming `?` that belongs to an outer ternary.
    const ctx_saved = self.ctx;
    self.ctx.disallow_conditional_types = true;
    const type_node = try self.parseType();
    _ = type_node;
    self.ctx = ctx_saved;

    // Check for `=>` — if present, this is a typed arrow function
    if (self.current() != .arrow or self.scanner.token.has_newline_before) {
        // Not a typed arrow — restore and let the caller treat `:` as ternary separator
        self.rollbackErrors(errors_before);
        self.restoreState(saved);
        return null;
    }

    // Confirmed typed arrow! Determine params from the parenthesized expression.
    const paren_node = self.ast.getNode(paren_expr);
    const arrow_start = paren_node.span.start;

    // Empty parens `()` are stored with data.none = 0 (no inner expression).
    // Non-empty parens `(expr)` store data.unary.operand = inner expression node index.
    // data.none reads the same bytes as unary.operand via extern union — 0 means empty
    // because node index 0 is always the program root, never a valid sub-expression.
    const is_empty_paren = (paren_node.data.none == 0);
    const normalized_params: NodeIndex = if (is_empty_paren)
        try self.coverExpressionToArrowParams(.none)
    else
        try self.coverExpressionToArrowParams(paren_expr);

    try self.advance(); // skip =>
    const body = try parseArrowBody(self, false, normalized_params);

    const ae = try self.ast.addExtras(&.{ @intFromEnum(normalized_params), @intFromEnum(body), 0 });
    return try self.ast.addNode(.{
        .tag = .arrow_function_expression,
        .span = .{ .start = arrow_start, .end = self.currentSpan().start },
        .data = .{ .extra = ae },
    });
}

/// 이항 연산자를 precedence climbing으로 파싱.
fn parseBinaryExpression(self: *Parser, min_prec: u8) ParseError2!NodeIndex {
    var left = try parseUnaryExpression(self);

    // ECMAScript: PrivateIdentifier는 독립 표현식이 아니라 `#field in obj` 형태로만 유효.
    // bare #field가 `in` 연산자 없이 사용되면 SyntaxError.
    if (!left.isNone() and self.ast.getNode(left).tag == .private_identifier) {
        if (self.current() != .kw_in or !self.ctx.allow_in) {
            try self.addErrorCode(self.ast.getNode(left).span, "Private name '#' is not valid outside of `in` expression", .private_outside_in);
        }
    }

    // ?? 와 &&/|| 혼합 감지용 — 괄호 없이 혼합하면 SyntaxError
    var has_coalesce = false;
    var has_logical_or_and = false;

    while (true) {
        // allow_in이 false면 `in`을 이항 연산자로 취급하지 않는다.
        // ECMAScript 13.7.4: for 초기화절에서 `in`은 for-in 키워드이지 연산자가 아니다.
        if (self.current() == .kw_in and !self.ctx.allow_in) break;

        const prec = getBinaryPrecedence(self.current());
        if (prec == 0 or prec <= min_prec) break;

        // ECMAScript 12.6: unary expression ** exponentiation → SyntaxError
        // delete/void/typeof/+/-/~/! 의 결과에 **를 적용할 수 없음
        if (self.current() == .star2 and !left.isNone()) {
            const left_tag = self.ast.getNode(left).tag;
            if (left_tag == .unary_expression) {
                try self.addErrorCode(self.currentSpan(), "Unary expression cannot be the left operand of '**'", .unary_exponentiation);
            }
        }

        const left_start = self.ast.getNode(left).span.start;
        const op_kind = self.current();
        const is_logical = (op_kind == .amp2 or op_kind == .pipe2 or op_kind == .question2);

        // ?? 와 &&/|| 혼합 감지 (ECMAScript: 괄호 없이 혼합 금지)
        if (op_kind == .question2) {
            if (has_logical_or_and) {
                try self.addErrorCode(self.currentSpan(), "Cannot mix '??' with '&&' or '||' without parentheses", .nullish_mix_logical);
            }
            has_coalesce = true;
        } else if (op_kind == .amp2 or op_kind == .pipe2) {
            if (has_coalesce) {
                try self.addErrorCode(self.currentSpan(), "Cannot mix '??' with '&&' or '||' without parentheses", .nullish_mix_logical);
            }
            has_logical_or_and = true;
        }

        try self.advance();

        // ** (star2)는 우결합: prec - 1로 재귀하여 같은 우선순위를 오른쪽에 허용
        const next_prec = if (op_kind == .star2) prec - 1 else prec;
        const right = try parseBinaryExpression(self, next_prec);

        // ECMAScript: `#field in obj` — RHS는 ShiftExpression이어야 함.
        // bare `#field`은 ShiftExpression이 아니므로 RHS에 올 수 없다.
        // 예: `#field in #field in this` → 내부 `#field in #field`의 RHS `#field`이 bare → 에러
        if (op_kind == .kw_in and !right.isNone()) {
            if (self.ast.getNode(right).tag == .private_identifier) {
                try self.addErrorCode(self.ast.getNode(right).span, "Private name '#' is not valid as right-hand side of `in` expression", .private_rhs_in);
            }
        }

        // ?? 의 오른쪽에 괄호 없는 &&/|| 이 있으면 에러 (재귀 호출로 감지 못한 케이스)
        // 예: 0 ?? 0 && true → right = (0 && true) = logical_expression
        if (op_kind == .question2 and !right.isNone()) {
            const right_node = self.ast.getNode(right);
            if (right_node.tag == .logical_expression) {
                const right_op: Kind = @enumFromInt(right_node.data.binary.flags);
                if (right_op == .amp2 or right_op == .pipe2) {
                    try self.addErrorCode(right_node.span, "Cannot mix '??' with '&&' or '||' without parentheses", .nullish_mix_logical);
                }
            }
        }

        const tag: Tag = if (is_logical) .logical_expression else .binary_expression;

        left = try self.ast.addNode(.{
            .tag = tag,
            .span = .{ .start = left_start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = left, .right = right, .flags = @intFromEnum(op_kind) } },
        });
    }

    return left;
}

fn parseUnaryExpression(self: *Parser) ParseError2!NodeIndex {
    const kind = self.current();
    switch (kind) {
        .bang, .tilde, .minus, .plus, .kw_typeof, .kw_void, .kw_delete => {
            const start = self.currentSpan().start;
            const is_delete = kind == .kw_delete;
            try self.advance();
            const operand = try parseUnaryExpression(self);
            // strict mode: delete identifier → SyntaxError (ECMAScript 12.5.3.1)
            // delete of private field → always SyntaxError (ECMAScript 13.5.1.1)
            // delete (this.#x), delete this?.#x 도 포함
            if (is_delete and !operand.isNone()) {
                var del_target = operand;
                // 괄호 unwrap
                while (!del_target.isNone()) {
                    const dt = self.ast.getNode(del_target);
                    if (dt.tag == .parenthesized_expression) {
                        del_target = dt.data.unary.operand;
                    } else break;
                }
                if (!del_target.isNone()) {
                    const del_node = self.ast.getNode(del_target);
                    if (del_node.tag == .static_member_expression or
                        del_node.tag == .computed_member_expression or
                        del_node.tag == .private_field_expression)
                    {
                        const de = del_node.data.extra;
                        const right_idx: NodeIndex = if (de + 1 < self.ast.extra_data.items.len) @enumFromInt(self.ast.extra_data.items[de + 1]) else NodeIndex.none;
                        if (!right_idx.isNone() and @intFromEnum(right_idx) < self.ast.nodes.items.len) {
                            if (self.ast.getNode(right_idx).tag == .private_identifier) {
                                try self.addErrorCode(del_node.span, "Private fields cannot be deleted", .private_delete);
                            }
                        }
                    }
                }
            }
            // delete (x) 도 괄호를 통과하여 체크
            if (is_delete and self.is_strict_mode and !operand.isNone()) {
                var target = operand;
                while (!target.isNone()) {
                    const t = self.ast.getNode(target);
                    if (t.tag == .identifier_reference) {
                        try self.addErrorCode(t.span, "Deleting an identifier is not allowed in strict mode", .delete_identifier_strict);
                        break;
                    } else if (t.tag == .parenthesized_expression) {
                        target = t.data.unary.operand;
                    } else break;
                }
            }
            {
                const ue = try self.ast.addExtras(&.{ @intFromEnum(operand), @intFromEnum(kind) });
                return try self.ast.addNode(.{
                    .tag = .unary_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = ue },
                });
            }
        },
        .plus2, .minus2 => {
            const start = self.currentSpan().start;
            try self.advance();
            const operand = try parseUnaryExpression(self);
            // ++/-- operand는 유효한 assignment target이어야 함
            _ = try self.coverExpressionToAssignmentTarget(operand, true);
            {
                const ue = try self.ast.addExtras(&.{ @intFromEnum(operand), @intFromEnum(kind) });
                return try self.ast.addNode(.{
                    .tag = .update_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = ue },
                });
            }
        },
        .kw_await => {
            // enum 초기값에서 await은 다른 멤버를 참조하는 식별자로 취급한다.
            // 예: enum X { await = 1, y = await } → y의 초기값은 await 멤버 참조
            if (self.in_enum_initializer) {
                return parsePostfixExpression(self);
            }
            // static initializer에서 await 사용 금지 (ECMAScript 15.7.14)
            // module mode에서 await expression으로 파싱되기 전에 체크해야 함
            if (self.in_static_initializer) {
                try self.addErrorCode(self.currentSpan(), "'await' is not allowed in class static initializer", .await_in_static_initializer);
            }
            // formal parameter 안에서 await expression 금지 (ECMAScript 14.1.2)
            if (self.in_formal_parameters and self.ctx.in_async) {
                try self.addErrorCode(self.currentSpan(), "'await' expression is not allowed in formal parameters", .await_in_parameters);
            }
            // async 함수 안에서는 항상 await_expression.
            // module top-level(함수 밖)에서는 top-level await.
            // module 안 일반 함수 body에서는 await을 식별자로 취급 → strict mode 에러.
            // ECMAScript: FunctionBody[~Yield, ~Await] → await은 keyword가 아님.
            if (self.ctx.in_async or (self.is_module and !self.in_namespace and !self.ctx.in_function)) {
                const start = self.currentSpan().start;
                try self.advance();
                const operand = try parseUnaryExpression(self);
                return try self.ast.addNode(.{
                    .tag = .await_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                });
            }
            // module 안 일반 함수에서 await 사용 → strict mode 위반 에러
            if (self.is_module and !self.in_namespace and self.ctx.in_function and !self.ctx.in_async) {
                try self.addErrorCode(self.currentSpan(), "'await' is not allowed in non-async function in module code", .await_in_non_async_module);
            }
            // async 밖 + script mode에서는 식별자로 파싱
            return parsePostfixExpression(self);
        },
        // yield expression은 parseAssignmentExpression에서 처리됨 (ECMAScript 14.4)
        // generator 안에서 여기에 도달하면 identifier reference로 해석 → 에러
        .kw_yield => return parsePostfixExpression(self),
        else => return parsePostfixExpression(self),
    }
}

fn parsePostfixExpression(self: *Parser) ParseError2!NodeIndex {
    var expr = try parseCallExpression(self);

    // 후위 ++/--
    if ((self.current() == .plus2 or self.current() == .minus2) and
        !self.scanner.token.has_newline_before)
    {
        // ++/-- operand는 유효한 assignment target이어야 함
        _ = try self.coverExpressionToAssignmentTarget(expr, true);
        const expr_start = self.ast.getNode(expr).span.start;
        const kind = self.current();
        try self.advance();
        {
            const ue = try self.ast.addExtras(&.{ @intFromEnum(expr), @as(u32, @intFromEnum(kind)) | ast_mod.UnaryFlags.postfix });
            expr = try self.ast.addNode(.{
                .tag = .update_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .extra = ue },
            });
        }
    }

    // TS non-null assertion (expr!) — parseCallExpression 내부에서 처리
    // (체이닝 지원: foo()!.bar!.baz)

    // TS/Flow: as Type / satisfies Type (체이닝 가능: x as A as B)
    // Flow는 as만 지원 (satisfies 없음)
    // ASI: `bar\nas(null)` → 줄바꿈 뒤의 as는 타입 캐스트가 아니라 함수 호출
    while (self.current() == .identifier and !self.scanner.token.has_newline_before) {
        const text = self.tokenText();
        const is_as = std.mem.eql(u8, text, "as");
        const is_satisfies = !is_as and !self.is_flow and std.mem.eql(u8, text, "satisfies");
        if (!is_as and !is_satisfies) break;
        const expr_start = self.ast.getNode(expr).span.start;
        try self.advance();
        const ty = try self.parseType();
        const tag: @import("ast.zig").Node.Tag = if (is_satisfies)
            .ts_satisfies_expression
        else if (self.is_flow)
            .flow_as_expression
        else
            .ts_as_expression;
        expr = try self.ast.addNode(.{
            .tag = tag,
            .span = .{ .start = expr_start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = expr, .right = ty, .flags = 0 } },
        });
    }

    return expr;
}

pub fn parseCallExpression(self: *Parser) ParseError2!NodeIndex {
    // @__PURE__ / #__PURE__ 주석이 바로 앞에 있으면 캡처 (esbuild/Bun 패턴).
    // 첫 번째 call/new expression에만 적용하고 소비함.
    var had_pure_comment = self.scanner.token.has_pure_comment_before;
    var expr = try parsePrimaryExpression(self);

    // parsePrimaryExpression이 new_expression을 반환했으면 pure 플래그 사후 설정
    if (had_pure_comment and !expr.isNone()) {
        const result_tag = self.ast.getNode(expr).tag;
        if (result_tag == .new_expression or result_tag == .call_expression) {
            const e = self.ast.getNode(expr).data.extra;
            if (self.ast.hasExtra(e, 3)) {
                self.ast.extra_data.items[e + 3] |= ast_mod.CallFlags.is_pure;
            }
            had_pure_comment = false;
        }
    }

    var after_optional_chain = false;

    while (true) {
        const expr_start = self.ast.getNode(expr).span.start;
        switch (self.current()) {
            .l_paren => {
                // super() 호출은 constructor에서만 허용
                if (self.ast.getNode(expr).tag == .super_expression and !self.allow_super_call) {
                    try self.addErrorCode(self.ast.getNode(expr).span, "'super()' is only allowed in a class constructor", .super_call_outside_constructor);
                }
                // 함수 호출
                try self.advance();
                const arg_list = try parseArgumentList(self);
                const Flags = ast_mod.CallFlags;
                var call_flags: u32 = 0;
                if (had_pure_comment) {
                    call_flags |= Flags.is_pure;
                    had_pure_comment = false; // 소비: 첫 call에만 적용
                }
                const call_extra = try self.ast.addExtras(&.{
                    @intFromEnum(expr), arg_list.start, arg_list.len, call_flags,
                });

                // Inline scan: require("specifier") → CJS import record
                const call_span = Span{ .start = expr_start, .end = self.currentSpan().start };
                if (self.enable_scan) {
                    scanRequireCall(self, expr, arg_list);
                    scanGlobCall(self, expr, arg_list);
                    scanRequireContextCall(self, expr, arg_list, call_span);
                }

                expr = try self.ast.addNode(.{
                    .tag = .call_expression,
                    .span = call_span,
                    .data = .{ .extra = call_extra },
                });
            },
            .dot => {
                // 멤버 접근: a.b
                try self.advance();
                const prop = try parseIdentifierName(self);
                // super.#private → SyntaxError (ECMAScript: SuperProperty doesn't include PrivateName)
                if (!prop.isNone() and self.ast.getNode(prop).tag == .private_identifier) {
                    const obj_node = self.ast.getNode(expr);
                    if (obj_node.tag == .super_expression) {
                        try self.addErrorCode(self.ast.getNode(prop).span, "Private field access on super is not allowed", .private_super_access);
                    }
                }
                {
                    const prop_end = if (!prop.isNone()) self.ast.getNode(prop).span.end else self.currentSpan().start;
                    const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 0 });
                    expr = try self.ast.addNode(.{
                        .tag = if (!prop.isNone() and self.ast.getNode(prop).tag == .private_identifier)
                            .private_field_expression
                        else
                            .static_member_expression,
                        .span = .{ .start = expr_start, .end = prop_end },
                        .data = .{ .extra = me },
                    });
                }
            },
            .l_bracket => {
                // decorator 안에서는 computed member access 금지
                // @dec ["method"]() → ["method"]은 다음 class member의 computed key
                if (self.ctx.in_decorator) break;
                // 계산된 멤버 접근: a[b] — `in` 연산자 허용 (ECMAScript: [+In])
                try self.advance();
                const cm_saved = self.enterAllowInContext(true);
                const prop = try parseExpression(self);
                self.restoreContext(cm_saved);
                try self.expect(.r_bracket);
                {
                    const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 0 });
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .extra = me },
                    });
                }
            },
            .question_dot => {
                // optional chaining: a?.b, a?.[b], a?.()
                try self.advance(); // skip ?.
                if (self.current() == .l_bracket) {
                    // a?.[expr] — `in` 연산자 허용 (ECMAScript: [+In])
                    try self.advance();
                    const oc_saved = self.enterAllowInContext(true);
                    const prop = try parseExpression(self);
                    self.restoreContext(oc_saved);
                    try self.expect(.r_bracket);
                    {
                        const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 1 }); // 1 = optional
                        expr = try self.ast.addNode(.{
                            .tag = .computed_member_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .extra = me },
                        });
                    }
                } else if (self.current() == .l_paren or self.isAtOpeningAngleBracket()) {
                    // a?.() or a?.<Type>()
                    // TS type arguments: speculatively parse, skip if followed by (
                    if (self.isAtOpeningAngleBracket()) {
                        if (!trySkipTypeArgsSpeculative(self, false, followedByParenOnly)) {
                            // type args failed, fall through to a?.b (identifier)
                            const prop = try parseIdentifierName(self);
                            {
                                const prop_end = if (!prop.isNone()) self.ast.getNode(prop).span.end else self.currentSpan().start;
                                const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 1 }); // 1 = optional
                                expr = try self.ast.addNode(.{
                                    .tag = .static_member_expression,
                                    .span = .{ .start = expr_start, .end = prop_end },
                                    .data = .{ .extra = me },
                                });
                            }
                            after_optional_chain = true;
                            continue;
                        }
                    }
                    // Now at '(' — parse call
                    try self.advance();
                    const arg_list = try parseArgumentList(self);
                    var oc_flags: u32 = ast_mod.CallFlags.optional_chain;
                    if (had_pure_comment) {
                        oc_flags |= ast_mod.CallFlags.is_pure;
                        had_pure_comment = false;
                    }
                    const oc_extra = try self.ast.addExtras(&.{
                        @intFromEnum(expr), arg_list.start, arg_list.len, oc_flags,
                    });
                    expr = try self.ast.addNode(.{
                        .tag = .call_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .extra = oc_extra },
                    });
                } else {
                    // a?.b (또는 a?.#x)
                    const prop = try parseIdentifierName(self);
                    {
                        const prop_end = if (!prop.isNone()) self.ast.getNode(prop).span.end else self.currentSpan().start;
                        const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 1 }); // 1 = optional
                        // 비-optional `.` 경로와 동일하게 prop이 private_identifier이면 private_field_expression.
                        // 이 분기 누락 시 `a?.#x` 가 static_member_expression 으로 잘못 태깅되어
                        // private field lowering이 안 돌고 codegen 그대로 `o.#x` 출력 → 런타임 에러 (#1492).
                        expr = try self.ast.addNode(.{
                            .tag = if (!prop.isNone() and self.ast.getNode(prop).tag == .private_identifier)
                                .private_field_expression
                            else
                                .static_member_expression,
                            .span = .{ .start = expr_start, .end = prop_end },
                            .data = .{ .extra = me },
                        });
                    }
                }
                after_optional_chain = true;
                continue;
            },
            .no_substitution_template, .template_head => {
                // tagged template 금지: a?.b`template` (ECMAScript 12.3.1.1)
                if (after_optional_chain) {
                    try self.addErrorCode(self.currentSpan(), "Tagged template cannot be used in optional chain", .tagged_template_optional);
                }
                // tagged template: expr`text` 또는 expr`text${...}...`
                // tagged template에서는 잘못된 이스케이프 허용 (cooked가 undefined)
                const tmpl = if (self.current() == .template_head)
                    try parseTemplateLiteral(self, true)
                else blk: {
                    const tmpl_span = self.currentSpan();
                    try self.advance();
                    break :blk try self.ast.addNode(.{
                        .tag = .template_literal,
                        .span = tmpl_span,
                        .data = .{ .none = 0 },
                    });
                };
                {
                    const te = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(tmpl), 0 });
                    expr = try self.ast.addNode(.{
                        .tag = .tagged_template_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .extra = te },
                    });
                }
            },
            .l_angle, .shift_left => {
                // TS generic type arguments: foo<Type>() or foo<<T>() => T>()
                // Speculative parse: try parsing <Type>, check if followed by ( or `
                // If not, restore state and let binary expression handle < as comparison.
                if (!trySkipTypeArgsSpeculative(self, true, canFollowTypeArgumentsInExpression)) break;
            },
            .bang => {
                // TS non-null assertion: expr!
                // `!` 뒤에 `.`, `[`, `(` 가 오면 체이닝 (foo()!.bar)
                // 줄바꿈 뒤의 `!`는 논리 NOT으로 해석해야 하므로 제외
                if (self.scanner.token.has_newline_before) break;
                // non-null assertion은 postfix 연산자이므로 뒤의 `/`는 division이어야 한다.
                // .bang은 slashIsRegex()에서 regex로 판정되므로 .r_paren으로 오버라이드한다.
                self.scanner.prev_token_kind = .r_paren;
                try self.advance();
                expr = try self.ast.addNode(.{
                    .tag = .ts_non_null_expression,
                    .span = .{ .start = expr_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
            },
            else => break,
        }
        after_optional_chain = false;
    }

    return expr;
}

/// type argument를 speculatively 파싱하고 AST를 롤백한다.
/// 성공하면 스캐너를 type argument 뒤로 전진시킨 채 true 반환.
/// 실패하면 원래 위치로 복원하고 false 반환.
/// strict=true: parseTypeArgumentsInExpression (>=/>>/>>>를 비교로 처리)
/// strict=false: parseTypeArguments (optional chaining 등 모호하지 않은 컨텍스트)
fn trySkipTypeArgsSpeculative(self: *Parser, comptime strict: bool, comptime follow: fn (*const Parser) bool) bool {
    if (!self.isAtOpeningAngleBracket()) return false;
    const saved_scanner = self.saveState();
    const saved_nodes_len = self.ast.nodes.items.len;
    const saved_extra_len = self.ast.extra_data.items.len;
    const saved_scratch = self.saveScratch();
    const saved_errors_len = self.errors.items.len;

    const type_args_ok = blk: {
        _ = (if (strict) self.parseTypeArgumentsInExpression() else self.parseTypeArguments()) catch {
            break :blk false;
        };
        if (self.errors.items.len > saved_errors_len) break :blk false;
        break :blk follow(self);
    };

    const scanner_after = if (type_args_ok) self.saveState() else saved_scanner;
    self.ast.nodes.items.len = saved_nodes_len;
    self.ast.extra_data.items.len = saved_extra_len;
    self.restoreScratch(saved_scratch);
    self.rollbackErrors(saved_errors_len);
    self.restoreState(scanner_after);
    return type_args_ok;
}

fn followedByParenOnly(self: *const Parser) bool {
    return self.current() == .l_paren;
}

/// new 표현식의 callee를 파싱한다.
/// new는 중첩 가능하므로 new를 만나면 재귀한다.
/// member access (.prop, [expr])만 허용하고 호출 ()은 상위에서 처리.
fn parseNewCallee(self: *Parser) ParseError2!NodeIndex {
    // ECMAScript: new import(...) / new import.source(...) / new import.defer(...) は금지
    // 단, new import.meta 는 허용 (import.meta는 MemberExpression)
    if (self.current() == .kw_import) {
        const import_span = self.currentSpan();
        // parsePrimaryExpression이 import를 파싱한 뒤 결과 tag를 확인:
        // - meta_property (import.meta) → 유효
        // - import_expression (import(...)) → 에러
        // - call_expression (import.source/defer(...)) → 에러
        // 미리 에러를 보고하되, import.meta인 경우만 통과시킴
        const next = try self.peekNextKind();
        if (next != .dot) {
            // import( → 동적 import는 new 불가
            try self.addErrorCode(import_span, "'import' cannot be used with 'new'", .import_cannot_new);
        }
        // import. → parsePrimaryExpression에서 처리
        // 결과를 확인하여 import.source/defer면 에러
    }
    if (self.current() == .kw_new) {
        const span = self.currentSpan();
        try self.advance(); // skip 'new'
        const callee = try parseNewCallee(self);
        _ = trySkipTypeArgsSpeculative(self, true, canFollowTypeArgumentsInExpression);
        if (self.current() == .l_paren) {
            try self.advance();
            const arg_list = try parseArgumentList(self);
            const ne = try self.ast.addExtras(&.{
                @intFromEnum(callee), arg_list.start, arg_list.len, 0,
            });
            return try self.ast.addNode(.{
                .tag = .new_expression,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .extra = ne },
            });
        }
        const ne_no_args = try self.ast.addExtras(&.{
            @intFromEnum(callee), 0, 0, 0,
        });
        return try self.ast.addNode(.{
            .tag = .new_expression,
            .span = .{ .start = span.start, .end = self.currentSpan().start },
            .data = .{ .extra = ne_no_args },
        });
    }

    // primary expression + member chain (호출 제외)
    var expr = try parsePrimaryExpression(self);
    // import.source(...) / import.defer(...)는 ImportCall (CallExpression)이므로 new 불가
    // parsePrimaryExpression이 전체 호출을 소비하므로 결과 tag를 확인
    if (!expr.isNone()) {
        const result_tag = self.ast.getNode(expr).tag;
        if (result_tag == .import_expression) {
            try self.addErrorCode(self.ast.getNode(expr).span, "'import' cannot be used with 'new'", .import_cannot_new);
        }
    }
    while (true) {
        const expr_start = self.ast.getNode(expr).span.start;
        switch (self.current()) {
            .dot => {
                try self.advance();
                const prop = try parseIdentifierName(self);
                {
                    const prop_end = if (!prop.isNone()) self.ast.getNode(prop).span.end else self.currentSpan().start;
                    const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 0 });
                    // `new obj.#priv()` — prop 이 private_identifier 면 private_field_expression 태그를
                    // 써야 transformer 가 `_priv.get(obj)` 로 lowering 함. 일반 `.dot` 경로와 동기화 (#1507).
                    expr = try self.ast.addNode(.{
                        .tag = if (!prop.isNone() and self.ast.getNode(prop).tag == .private_identifier)
                            .private_field_expression
                        else
                            .static_member_expression,
                        .span = .{ .start = expr_start, .end = prop_end },
                        .data = .{ .extra = me },
                    });
                }
            },
            .l_bracket => {
                try self.advance();
                const prop = try parseExpression(self);
                try self.expect(.r_bracket);
                {
                    const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 0 });
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .extra = me },
                    });
                }
            },
            else => break,
        }
    }
    return expr;
}

fn parsePrimaryExpression(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // contextual keyword도 expression 위치에서 식별자로 유효.
    // async는 제외 — async function/arrow에서 특수 처리 (아래 switch에서).
    // literal keyword (true, false, null)는 제외 — 아래 switch에서 boolean_literal/null_literal로 처리.
    if (self.current() == .identifier or
        (self.current().isKeyword() and !self.current().isReservedKeyword() and
            !self.current().isLiteralKeyword() and self.current() != .kw_async))
    {
        // Flow match expression: match (expr) { Pattern => expr, ... }
        if (self.is_flow and self.isContextual("match")) {
            const next_kind = try self.peekNextKind();
            if (next_kind == .l_paren) {
                return try flow.parseMatchExpression(self);
            }
        }

        if (self.current() == .identifier) {
            if (self.in_class_field or self.in_static_initializer) {
                const text = self.resolveIdentifierText(span);
                if (std.mem.eql(u8, text, "arguments")) {
                    if (self.in_static_initializer) {
                        try self.addErrorCode(span, "'arguments' is not allowed in class static initializer", .arguments_class_static);
                    } else {
                        try self.addErrorCode(span, "'arguments' is not allowed in class field initializer", .arguments_class_field);
                    }
                }
            }
        }
        try self.checkIdentifierKeywordUse(span);
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }

    switch (self.current()) {
        .decimal, .float, .hex, .octal, .binary, .positive_exponential, .negative_exponential => {
            // strict mode에서 legacy octal 숫자 금지 (ECMAScript 12.8.3.1)
            if (self.scanner.token.has_legacy_octal and self.is_strict_mode) {
                try self.addErrorCode(span, "Octal literals are not allowed in strict mode", .octal_literal_strict);
            }
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .numeric_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .decimal_bigint, .binary_bigint, .octal_bigint, .hex_bigint => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .bigint_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .string_literal => {
            // strict mode에서 legacy octal escape 금지 (ECMAScript 12.8.4.1)
            if (self.scanner.token.has_legacy_octal and self.is_strict_mode) {
                try self.addErrorCode(span, "Octal escape sequences are not allowed in strict mode", .octal_escape_strict);
            }
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .string_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .kw_true, .kw_false => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .boolean_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .kw_null => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .null_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .kw_this => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .kw_new => {
            // new expression: new Callee(args)
            // new는 중첩 가능: new new Foo()()
            try self.advance(); // skip 'new'

            // new.target — 메타 프로퍼티 (함수 안에서만 유효)
            if (self.current() == .dot) {
                const peek = try self.peekNextKind();
                if (peek == .kw_target) {
                    try self.advance(); // skip '.'
                    const target_span = self.currentSpan();
                    try self.advance(); // skip 'target'
                    // ECMAScript 15.1.1: new.target은 함수 본문 안에서만 허용
                    // arrow function은 외부의 allow_new_target을 상속
                    if (!self.allow_new_target) {
                        try self.addErrorCode(.{ .start = span.start, .end = target_span.end }, "'new.target' is not allowed outside of functions", .new_target_outside_function);
                    }
                    return try self.ast.addNode(.{
                        .tag = .meta_property,
                        .span = .{ .start = span.start, .end = target_span.end },
                        .data = .{ .none = 1 }, // 1 = new.target (0 = import.meta)
                    });
                }
            }

            // callee: 재귀적으로 new 또는 primary + member chain
            const callee = try parseNewCallee(self);

            // TS/Flow: new X<T>() — type argument를 speculatively 파싱하여 skip
            _ = trySkipTypeArgsSpeculative(self, true, canFollowTypeArgumentsInExpression);

            // 인자: (args) — 있으면 소비, 없으면 인자 없는 new (new Foo)
            if (self.current() == .l_paren) {
                try self.advance(); // skip (
                const arg_list = try parseArgumentList(self);
                const ne2 = try self.ast.addExtras(&.{
                    @intFromEnum(callee), arg_list.start, arg_list.len, 0,
                });
                return try self.ast.addNode(.{
                    .tag = .new_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .extra = ne2 },
                });
            }

            // 인자 없는 new: new Foo
            const ne2_no = try self.ast.addExtras(&.{
                @intFromEnum(callee), 0, 0, 0,
            });
            return try self.ast.addNode(.{
                .tag = .new_expression,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .extra = ne2_no },
            });
        },
        .kw_super => {
            // super expression: super() 또는 super.prop 또는 super[expr]
            // ECMAScript 12.3.7: super는 메서드 안에서만 허용
            // allow_super_property는 메서드 진입 시 true, 일반 함수 진입 시 false로 리셋
            // arrow function은 외부의 allow_super_property를 상속
            if (!self.allow_super_property and !self.allow_super_call) {
                try self.addErrorCode(span, "'super' is not allowed outside of a method", .super_outside_method);
            }
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .super_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .l_paren => {
            // 괄호 표현식 또는 arrow function 파라미터 리스트.
            // 괄호 안에서는 `in` 연산자가 항상 허용된다 (ECMAScript: [+In] 컨텍스트).

            // TS 모드: `(a: Type, b?: Type) => body` — 타입 어노테이션이 있는 arrow function.
            // lookahead로 감지: `(` 뒤에 identifier + `:` 또는 `?` 패턴이면 speculative 파싱.
            if (try self.isTypedArrowFunction()) {
                if (try self.parseTypedArrowParams(span.start, false)) |arrow| return arrow;
            }

            try self.advance(); // skip (

            // 빈 괄호: () → arrow function의 빈 파라미터 리스트
            if (self.current() == .r_paren) {
                try self.advance(); // skip )
                return try self.ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .none = 0 },
                });
            }

            // `(a, ...b) => {}` 형태의 rest 파라미터를 cover grammar으로 지원.
            // `...`는 일반 expression에서는 나올 수 없으므로 arrow 파라미터로만 해석된다.
            const paren_saved = self.enterAllowInContext(true);
            const expr = try parseExpressionOrRest(self);
            self.restoreContext(paren_saved);

            // Flow TypeCast: (expr: Type) — 괄호 안에서 expression 뒤에 `: Type`이 오면
            if (self.is_flow and self.current() == .colon) {
                try self.advance(); // skip ':'
                // 타입을 파싱하여 스캐너 위치를 진행시킴 (AST 노드는 스트리핑됨)
                _ = try self.parseType();
                try self.expect(.r_paren);
                return try self.ast.addNode(.{
                    .tag = .flow_type_cast_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
            }

            try self.expect(.r_paren);
            return try self.ast.addNode(.{
                .tag = .parenthesized_expression,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        },
        .kw_class => return self.parseClassExpression(),
        // Decorator on class expression: @decorator class {}
        // ECMAScript: ClassExpression includes optional DecoratorList
        .at => {
            const scratch_top = self.saveScratch();
            while (self.current() == .at) {
                const dec = try self.parseDecorator();
                try self.scratch.append(self.allocator, dec);
            }
            const decorators = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            self.restoreScratch(scratch_top);
            if (self.current() != .kw_class) {
                try self.addErrorCode(self.currentSpan(), "Class expected after decorator", .class_after_decorator);
            }
            return self.parseClassWithDecorators(.class_expression, decorators);
        },
        .kw_function => return self.parseFunctionExpression(),
        .l_angle => {
            if (self.is_jsx) {
                return self.parseJSXElement();
            }
            // .ts: TS type assertion <T>expr → expr (타입 스트리핑)
            return try parseTSTypeAssertion(self);
        },
        .kw_import => {
            try self.advance(); // skip 'import'
            if (self.current() == .dot) {
                try self.advance(); // skip '.'
                const prop_span = self.currentSpan();
                const prop_name = try parseIdentifierName(self);
                _ = prop_name;

                // import.meta — module code에서만 허용
                // import.source(...), import.defer(...) — script에서도 허용 (dynamic import)
                const prop_text = self.ast.source[prop_span.start..prop_span.end];
                if (std.mem.eql(u8, prop_text, "meta")) {
                    if (self.is_unambiguous) self.has_module_syntax = true;
                    if (!self.is_module) {
                        try self.addErrorCode(.{ .start = span.start, .end = prop_span.end }, "'import.meta' is only allowed in module code", .import_meta_in_script);
                    }
                    return try self.ast.addNode(.{
                        .tag = .meta_property,
                        .span = .{ .start = span.start, .end = prop_span.end },
                        .data = .{ .none = 0 },
                    });
                }

                // import.source / import.defer — source phase imports (Stage 3)
                // 그 외 import.UNKNOWN은 SyntaxError (ECMAScript ImportCall 문법)
                const is_source = std.mem.eql(u8, prop_text, "source");
                const is_defer = std.mem.eql(u8, prop_text, "defer");
                if (!is_source and !is_defer) {
                    try self.addErrorCode(.{ .start = span.start, .end = prop_span.end }, "Expected 'import.meta', 'import.source', or 'import.defer'", .import_meta_expected);
                    return try self.ast.addNode(.{
                        .tag = .meta_property,
                        .span = .{ .start = span.start, .end = prop_span.end },
                        .data = .{ .none = 0 },
                    });
                }

                // import.source(...) / import.defer(...) — dynamic import 변형
                if (self.current() == .l_paren) {
                    return self.parseImportCallArgs(span.start);
                }

                // import.source/defer without () → 에러
                try self.addErrorCode(.{ .start = span.start, .end = prop_span.end }, "'import.source'/'import.defer' requires arguments", .import_source_requires_args);
                return try self.ast.addNode(.{
                    .tag = .meta_property,
                    .span = .{ .start = span.start, .end = prop_span.end },
                    .data = .{ .none = 0 },
                });
            }
            // dynamic import: import("module") or import("module", options)
            return self.parseImportCallArgs(span.start);
        },
        .no_substitution_template => {
            // 보간 없는 템플릿 리터럴: `text`
            // untagged template에서 잘못된 이스케이프는 SyntaxError (ECMAScript 13.2.8.1)
            if (self.scanner.token.has_invalid_escape) {
                try self.addErrorCode(span, "Invalid escape sequence in template literal", .template_invalid_escape);
            }
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .template_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .template_head => {
            // 보간 있는 템플릿 리터럴: `text${expr}...`
            // untagged template에서 잘못된 이스케이프는 SyntaxError
            if (self.scanner.token.has_invalid_escape) {
                try self.addErrorCode(span, "Invalid escape sequence in template literal", .template_invalid_escape);
            }
            return parseTemplateLiteral(self, false);
        },
        .regexp_literal => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .regexp_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .l_bracket => {
            // 배열 리터럴 — 내부에서 `in` 연산자 항상 허용
            const arr_saved = self.enterAllowInContext(true);
            const arr = try parseArrayExpression(self);
            self.restoreContext(arr_saved);
            return arr;
        },
        .l_curly => {
            // 객체 리터럴 — 내부에서 `in` 연산자 항상 허용
            const obj_saved = self.enterAllowInContext(true);
            const obj = try object.parseObjectExpression(self);
            self.restoreContext(obj_saved);
            return obj;
        },
        .private_identifier => {
            // ECMAScript Ergonomic Brand Checks: `#field in obj`
            // private identifier가 `in` 연산자의 좌변으로 사용되는 경우.
            // 예: `#foo in obj` — obj에 private field #foo가 존재하는지 확인.
            // 멤버 표현식(this.#foo, obj.#foo)이 아닌 독립적인 #identifier를
            // primary expression으로 파싱하면, 이후 parseBinaryExpression에서
            // `in` 연산자와 자연스럽게 결합된다.
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .kw_async => {
            // async function expression 또는 async arrow
            const peek = try self.peekNext();
            if (peek.kind == .kw_function and !peek.has_newline_before) {
                // async function expression
                try self.advance(); // skip 'async'
                return self.parseFunctionExpressionWithFlags(ast_mod.FunctionFlags.is_async);
            }
            // async를 일반 식별자로 취급 (async arrow는 parseAssignmentExpression에서 처리)
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        else => {
            // escaped strict reserved → strict mode에서 에러, non-strict에서 identifier
            if (self.current() == .escaped_strict_reserved) {
                if (self.is_strict_mode) {
                    try self.addErrorCode(span, "Escaped reserved word cannot be used as identifier in strict mode", .escaped_reserved_word_strict);
                }
                _ = try self.checkYieldAwaitUse(span, "identifier");
                try self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            }
            // contextual keyword, strict mode reserved, TS keyword는
            // expression에서 식별자로 사용 가능 (reserved keyword만 불가)
            if (self.current().isKeyword() and
                (!self.current().isReservedKeyword() or self.current() == .kw_await or self.current() == .kw_yield))
            {
                if (self.is_strict_mode and self.current().isStrictModeReserved() and !self.in_enum_initializer) {
                    try self.addErrorCode(span, "Reserved word in strict mode cannot be used as identifier", .reserved_word_identifier_strict);
                } else {
                    _ = try self.checkYieldAwaitUse(span, "identifier");
                }
                try self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            }
            // 에러 복구: 알 수 없는 토큰 → 에러 노드 생성 후 건너뜀
            try self.addErrorCode(span, "Expression expected", .expression_expected);
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .invalid,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
    }
}

/// 보간이 있는 템플릿 리터럴을 파싱한다: `head${expr}middle${expr}tail`
/// is_tagged가 true이면 tagged template이므로 잘못된 이스케이프를 허용한다.
fn parseTemplateLiteral(self: *Parser, is_tagged: bool) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const scratch_top = self.saveScratch();

    // template_head: `text${
    try self.scratch.append(self.allocator, try self.ast.addNode(.{
        .tag = .template_element,
        .span = self.currentSpan(),
        .data = .{ .none = 0 },
    }));
    try self.advance(); // skip template_head

    while (true) {
        // expression inside ${} — `in` 연산자 항상 허용 (ECMAScript: TemplateMiddleList[+In])
        const tmpl_saved = self.enterAllowInContext(true);
        const expr = try parseExpression(self);
        self.restoreContext(tmpl_saved);
        try self.scratch.append(self.allocator, expr);

        // template_middle: }text${ 또는 template_tail: }text`
        if (self.current() == .template_middle) {
            // untagged template에서 잘못된 이스케이프는 SyntaxError
            if (!is_tagged and self.scanner.token.has_invalid_escape) {
                try self.addErrorCode(self.currentSpan(), "Invalid escape sequence in template literal", .template_invalid_escape);
            }
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .template_element,
                .span = self.currentSpan(),
                .data = .{ .none = 0 },
            }));
            try self.advance();
        } else if (self.current() == .template_tail) {
            // untagged template에서 잘못된 이스케이프는 SyntaxError
            if (!is_tagged and self.scanner.token.has_invalid_escape) {
                try self.addErrorCode(self.currentSpan(), "Invalid escape sequence in template literal", .template_invalid_escape);
            }
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .template_element,
                .span = self.currentSpan(),
                .data = .{ .none = 0 },
            }));
            try self.advance();
            break;
        } else {
            // 에러 복구: 닫히지 않은 템플릿
            try self.addErrorCode(self.currentSpan(), "Expected template continuation", .template_continuation_expected);
            break;
        }
    }

    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .template_literal,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = list },
    });
}

fn parseArrayExpression(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip [

    var elements: std.ArrayList(NodeIndex) = .empty;
    defer elements.deinit(self.allocator);

    while (self.current() != .r_bracket and self.current() != .eof) {
        if (self.current() == .comma) {
            // elision (빈 슬롯)
            const hole_span = self.currentSpan();
            try elements.append(self.allocator, try self.ast.addNode(.{
                .tag = .elision,
                .span = hole_span,
                .data = .{ .none = 0 },
            }));
            try self.advance();
            continue;
        }
        const elem = try parseSpreadOrAssignment(self);
        try elements.append(self.allocator, elem);
        if (!try self.eat(.comma)) break;
        // spread 뒤에 trailing comma가 있고 바로 ]가 오면 플래그를 설정.
        // 이 정보는 coverArrayExpressionToTarget에서 rest trailing comma 에러에 사용된다.
        if (!elem.isNone() and self.ast.getNode(elem).tag == .spread_element and self.current() == .r_bracket) {
            self.ast.nodes.items[@intFromEnum(elem)].data.unary.flags = Parser.spread_trailing_comma;
        }
    }

    const end = self.currentSpan().end;
    try self.expect(.r_bracket);

    const list = try self.ast.addNodeList(elements.items);
    return try self.ast.addNode(.{
        .tag = .array_expression,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = list },
    });
}

const object = @import("object.zig");

pub fn parseIdentifierName(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .identifier or self.current() == .escaped_keyword or
        self.current() == .escaped_strict_reserved or self.current().isKeyword())
    {
        // IdentifierName: 예약어도 property name으로 사용 가능 (escaped 포함)
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    if (self.current() == .private_identifier) {
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .private_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    try self.addErrorCode(span, "Identifier expected", .identifier_expected);
    try self.advance();
    return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
}

/// ModuleExportName을 파싱한다.
/// ECMAScript: ModuleExportName = IdentifierName | StringLiteral
/// export { "☿" }, import { "☿" as x } 등에서 사용.
/// StringLiteral의 경우 IsStringWellFormedUnicode 검사를 수행한다 (lone surrogate 금지).
pub fn parseModuleExportName(self: *Parser) ParseError2!NodeIndex {
    if (self.current() == .string_literal) {
        const span = self.currentSpan();
        // lone surrogate 검사: \uD800-\uDFFF가 쌍을 이루지 않으면 에러
        const str_content = self.ast.source[span.start + 1 .. if (span.end > 0) span.end - 1 else span.end];
        if (containsLoneSurrogate(str_content)) {
            try self.addErrorCode(span, "String literal contains lone surrogate", .string_lone_surrogate);
        }
        try self.advance();
        return try self.ast.addNode(.{
            .tag = .string_literal,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    return parseIdentifierName(self);
}

/// 문자열에 lone surrogate escape (\uD800-\uDFFF)가 있는지 검사한다.
/// \uHHHH 형태의 escape만 체크 (raw UTF-8은 이미 인코딩됨).
fn containsLoneSurrogate(s: []const u8) bool {
    var i: usize = 0;
    while (i + 5 < s.len) : (i += 1) {
        if (s[i] == '\\' and s[i + 1] == 'u' and s[i + 2] != '{') {
            // \uHHHH — 4자리 hex 파싱
            if (i + 5 < s.len) {
                const codepoint = parseHex4(s[i + 2 .. i + 6]) orelse continue;
                if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                    // high surrogate — 뒤에 \uDC00-\uDFFF가 있으면 쌍
                    if (i + 11 < s.len and s[i + 6] == '\\' and s[i + 7] == 'u') {
                        const low = parseHex4(s[i + 8 .. i + 12]) orelse {
                            return true; // invalid low → lone
                        };
                        if (low >= 0xDC00 and low <= 0xDFFF) {
                            i += 11; // skip surrogate pair
                            continue;
                        }
                    }
                    return true; // lone high surrogate
                } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                    return true; // lone low surrogate
                }
            }
        }
    }
    // 마지막 몇 바이트도 체크
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 5 < s.len and s[i + 1] == 'u' and s[i + 2] != '{') {
            const codepoint = parseHex4(s[i + 2 .. i + 6]) orelse continue;
            if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
                if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                    // check for low surrogate
                    if (i + 11 < s.len and s[i + 6] == '\\' and s[i + 7] == 'u') {
                        const low = parseHex4(s[i + 8 .. i + 12]) orelse return true;
                        if (low >= 0xDC00 and low <= 0xDFFF) {
                            i += 11;
                            continue;
                        }
                    }
                }
                return true;
            }
        }
    }
    return false;
}

/// 4자리 hex 문자열을 u16으로 파싱한다.
fn parseHex4(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var result: u16 = 0;
    for (s[0..4]) |c| {
        const digit: u16 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            return null;
        result = result * 16 + digit;
    }
    return result;
}

/// 객체 프로퍼티 키를 파싱한다.
/// 허용: identifier, string literal, numeric literal, computed [expr].
/// spread (...expr) 또는 assignment expression을 파싱. ...가 있으면 spread_element로 감싼다.
/// 인자 리스트를 파싱한다: (arg1, arg2, ...) → NodeList
/// 여는 괄호 `(`는 이미 소비된 상태에서 호출.
/// 닫는 괄호 `)`까지 소비한다.
fn parseArgumentList(self: *Parser) ParseError2!NodeList {
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const arg = try parseSpreadOrAssignment(self);
        try self.scratch.append(self.allocator, arg);
        if (!try self.eat(.comma)) break;
    }
    try self.expect(.r_paren);
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    return list;
}

/// 함수 인자 하나를 파싱한다. `in` 연산자 허용 (ECMAScript: Arguments[+In]).
fn parseSpreadOrAssignment(self: *Parser) ParseError2!NodeIndex {
    const arg_saved = self.enterAllowInContext(true);
    defer self.restoreContext(arg_saved);
    if (self.current() == .dot3) {
        const start = self.currentSpan().start;
        try self.advance(); // skip ...
        const arg = try parseAssignmentExpression(self);
        return try self.ast.addNode(.{
            .tag = .spread_element,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
    }
    return parseAssignmentExpression(self);
}

pub fn parsePropertyKey(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    switch (self.current()) {
        .identifier, .escaped_keyword, .escaped_strict_reserved => {
            // property key: 예약어도 사용 가능 (obj.let, class { yield() {} })
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .private_identifier => {
            // #private 필드/메서드
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .string_literal => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .string_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .decimal, .float, .hex, .octal, .binary, .positive_exponential, .negative_exponential => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .numeric_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .decimal_bigint, .binary_bigint, .octal_bigint, .hex_bigint => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .bigint_literal,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .l_bracket => {
            // computed property: [expr] — `in` 연산자 허용 (ECMAScript: ComputedPropertyName[+In])
            try self.advance();
            const cpk_saved = self.enterAllowInContext(true);
            const expr = try parseAssignmentExpression(self);
            self.restoreContext(cpk_saved);
            try self.expect(.r_bracket);
            return try self.ast.addNode(.{
                .tag = .computed_property_key,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        },
        else => {
            // 다른 키워드도 프로퍼티 키로 허용 (class, return 등)
            if (self.current().isKeyword()) {
                try self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            }
            try self.addErrorCode(span, "Property key expected", .property_key_expected);
            try self.advance();
            return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
        },
    }
}

// ================================================================
// 연산자 우선순위
// ================================================================

fn getBinaryPrecedence(kind: Kind) u8 {
    return switch (kind) {
        .pipe2 => 1, // ||
        .question2 => 1, // ??
        .amp2 => 2, // &&
        .pipe => 3, // |
        .caret => 4, // ^
        .amp => 5, // &
        .eq2, .neq, .eq3, .neq2 => 6, // == != === !==
        .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_instanceof, .kw_in => 7, // < > <= >= instanceof in
        .shift_left, .shift_right, .shift_right3 => 8, // << >> >>>
        .plus, .minus => 9, // + -
        .star, .slash, .percent => 10, // * / %
        .star2 => 11, // ** (우결합)
        else => 0, // 이항 연산자 아님
    };
}

/// TS type assertion: <T>expr → expr (타입 스트리핑)
/// .ts 파일에서만 호출 (TSX에서는 JSX가 우선)
/// oxc parse_ts_type_assertion 대응
///
/// esbuild 호환: <{}>() => {} 및 <[]>(y, z) => {} 같은 패턴에서
/// <Type>이 type assertion이고 뒤따르는 () => {} 가 arrow function인 경우,
/// type assertion은 스트리핑되므로 arrow function만 반환한다.
/// esbuild는 parsePrefix를 호출해서 arrow를 직접 감지하지만, ZTS는
/// arrow 감지가 parseAssignmentExpression 레벨에서 일어나므로
/// 여기서 직접 감지해야 한다.
fn parseTSTypeAssertion(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip <
    _ = try self.parseType();
    try self.expectClosingAngleBracket();

    // esbuild 호환: <Type> 뒤에 arrow function이 오는 경우 감지.
    // <{}>() => {}, <[]>(y, z) => {} 등 — type assertion + arrow function.
    // type assertion은 변환 시 스트리핑되므로 arrow function만 반환.
    if (self.current() == .l_paren) {
        const saved = self.saveState();
        const err_count = self.errors.items.len;

        // typed arrow 먼저 시도: <Type>(a: T): R => body
        if (try self.isTypedArrowFunction()) {
            if (try self.parseTypedArrowParams(self.currentSpan().start, false)) |arrow| return arrow;
            self.restoreState(saved);
            self.rollbackErrors(err_count);
        }

        // 빈 파라미터 arrow: <Type>() => body
        if (self.current() == .l_paren and try self.peekNextKind() == .r_paren) {
            try self.advance(); // skip (
            try self.advance(); // skip )
            if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                try self.advance(); // skip =>
                const body = try parseArrowBody(self, false, .none);
                const ae = try self.ast.addExtras(&.{ @intFromEnum(NodeIndex.none), @intFromEnum(body), 0 });
                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = ae },
                });
            }
            self.restoreState(saved);
            self.rollbackErrors(err_count);
        }

        // 파라미터가 있는 arrow: <Type>(x, y) => body
        // 괄호 표현식을 파싱하고 => 가 따르면 arrow로 변환
        {
            const paren_expr = try parseUnaryExpression(self);
            if (self.current() == .arrow and !self.scanner.token.has_newline_before and
                self.isValidArrowParamForm(paren_expr))
            {
                const normalized_params = try self.coverExpressionToArrowParams(paren_expr);
                try self.advance(); // skip =>
                const body = try parseArrowBody(self, false, normalized_params);
                const ae = try self.ast.addExtras(&.{ @intFromEnum(normalized_params), @intFromEnum(body), 0 });
                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = ae },
                });
            }
            // arrow가 아니면 일반 type assertion
            return try self.ast.addNode(.{
                .tag = .ts_type_assertion,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = paren_expr, .flags = 0 } },
            });
        }
    }

    // 괄호가 아닌 경우: 기존 동작 — <T>expr
    const expr = try parseUnaryExpression(self);
    return try self.ast.addNode(.{
        .tag = .ts_type_assertion,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
}

/// TSX 모드에서 `<`가 제네릭 arrow function인지 JSX인지 구별 (oxc arrow.rs:166-197).
/// trailing comma(<T,>), constraint(<T extends X>), default(<T = X>) → 제네릭 arrow.
/// 그 외 (`<T>` 등) → JSX. 현재 토큰이 `<`인 상태에서 호출.
fn isTsxGenericArrow(self: *Parser) ParseError2!bool {
    const saved = self.saveState();
    defer self.restoreState(saved);
    try self.advance(); // skip <
    return try checkTsxGenericArrowTypeParam(self);
}

/// async <T>() => body 형태에서의 TSX 제네릭 arrow 감지.
/// 현재 토큰이 `async`인 상태에서 호출.
fn isTsxGenericArrowAfterAsync(self: *Parser) ParseError2!bool {
    const saved = self.saveState();
    defer self.restoreState(saved);
    try self.advance(); // skip async
    if (self.current() != .l_angle) return false;
    try self.advance(); // skip <
    return try checkTsxGenericArrowTypeParam(self);
}

/// `<` 다음 위치에서 generic arrow function의 type parameter 패턴을 확인.
/// `[const] Ident (,|=|extends|:)` 또는 Flow에서 `Ident > (` (단일 무제약 param).
fn checkTsxGenericArrowTypeParam(self: *Parser) ParseError2!bool {
    if (self.current() == .kw_const) try self.advance();
    if (self.current() != .identifier and !self.current().isKeyword()) return false;
    try self.advance();
    const kind = self.current();
    if (kind == .comma or kind == .eq or kind == .kw_extends) return true;
    if (self.is_flow and kind == .colon) return true;
    // Flow: <T>(...) => body — `>` 뒤에 `(` 가 오면 generic arrow로 판별.
    // TSX에서는 <T> 가 JSX element일 수 있으므로, Flow 모드에서만 허용.
    if (self.is_flow and kind == .r_angle) {
        const after = try self.peekNextKind();
        return after == .l_paren;
    }
    return false;
}

/// TS 제네릭 arrow function 파싱 시도: <T>() => body, <const T>() => body
/// 현재 토큰이 < 인 상태에서 호출.
/// 성공하면 arrow_function_expression 노드를 반환, 실패하면 null.
/// saveState/restoreState를 사용하여 실패 시 복구.
fn tryParseGenericArrow(self: *Parser, is_async: bool) ParseError2!?NodeIndex {
    const start = self.currentSpan().start;
    const saved = self.saveState();
    const err_count = self.errors.items.len;

    // 제네릭 타입 파라미터 파싱 시도 — 에러 발생 또는 에러 추가 시 rollback
    const saved_nodes_len = self.ast.nodes.items.len;
    const saved_extra_len: u32 = @intCast(self.ast.extra_data.items.len);
    const type_param_failed = blk: {
        _ = self.parseTsTypeParameterDeclaration() catch break :blk true;
        // expect()는 에러를 추가하되 계속 진행하므로, 에러 수 증가로 실패 감지
        break :blk self.errors.items.len > err_count;
    };
    if (type_param_failed or self.current() != .l_paren) {
        self.ast.nodes.items.len = saved_nodes_len;
        self.ast.extra_data.shrinkRetainingCapacity(saved_extra_len);
        self.restoreState(saved);
        self.rollbackErrors(err_count);
        return null;
    }

    // 파라미터 리스트 파싱 (parseTypedArrowParams와 동일 패턴)
    try self.advance(); // skip (
    self.in_formal_parameters = true;
    const scratch_top = self.saveScratch();

    while (self.current() != .r_paren and self.current() != .eof) {
        const loop_guard_pos = self.scanner.token.span.start;
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(self.allocator, param);
        if (!try self.eat(.comma)) break;
        if (try self.ensureLoopProgress(loop_guard_pos)) break;
    }
    self.in_formal_parameters = false;

    if (self.current() != .r_paren) {
        self.restoreScratch(scratch_top);
        self.restoreState(saved);
        self.rollbackErrors(err_count);
        return null;
    }
    try self.advance(); // skip )

    // 선택적 리턴 타입: <T>(): R => body
    // Flow: return type에서 `=>` 를 function type arrow로 해석하지 않도록 플래그 설정
    const saved_flow_flag = self.flow_in_return_type;
    self.flow_in_return_type = true;
    defer self.flow_in_return_type = saved_flow_flag;
    _ = try self.tryParseReturnType();

    // => 가 와야 arrow function
    if (self.current() != .arrow or self.scanner.token.has_newline_before) {
        self.restoreScratch(scratch_top);
        self.restoreState(saved);
        self.rollbackErrors(err_count);
        return null;
    }

    // arrow function은 항상 UniqueFormalParameters — 중복 파라미터 이름 금지.
    try self.checkDuplicateArrowFormalParams(scratch_top);

    // 파라미터 노드 리스트 생성
    const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const params_node = try self.ast.addNode(.{
        .tag = .formal_parameters,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = params },
    });

    try self.advance(); // skip =>
    const body = try parseArrowBody(self, is_async, params_node);
    const flags: u32 = if (is_async) 0x01 else 0;
    const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), flags });
    return try self.ast.addNode(.{
        .tag = .arrow_function_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = ae },
    });
}

// ============================================================
// Inline scan helpers — enable_scan=true일 때 CJS 패턴 감지
// ============================================================

/// require("specifier") 호출을 감지하여 CJS import record를 추가한다.
/// call_expression이 생성되기 직전, callee(expr)와 arg_list가 확정된 시점에서 호출.
/// import_scanner.tryExtractRequire와 동일한 패턴을 인라인으로 검사한다.
fn scanRequireCall(self: *Parser, callee: NodeIndex, arg_list: NodeList) void {
    // callee가 identifier_reference "require"인지 확인
    if (callee.isNone()) return;
    if (@intFromEnum(callee) >= self.ast.nodes.items.len) return;
    const callee_node = self.ast.nodes.items[@intFromEnum(callee)];
    if (callee_node.tag != .identifier_reference) return;
    const callee_text = self.ast.source[callee_node.span.start..callee_node.span.end];
    if (!std.mem.eql(u8, callee_text, "require")) return;

    // 인수가 정확히 1개인지 확인
    if (arg_list.len != 1) return;

    // 인수가 string_literal인지 확인
    if (arg_list.start >= self.ast.extra_data.items.len) return;
    const arg_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[arg_list.start]);
    if (arg_idx.isNone()) return;
    if (@intFromEnum(arg_idx) >= self.ast.nodes.items.len) return;
    const arg_node = self.ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg_node.tag != .string_literal) return;

    const raw = self.ast.source[arg_node.span.start..arg_node.span.end];
    const specifier = import_scanner.stripQuotes(raw) orelse raw;

    self.scan_import_records.append(self.allocator, .{
        .specifier = specifier,
        .kind = .require,
        .span = arg_node.span,
    }) catch {};
    self.scan_result.has_cjs_require = true;
}

/// import.meta.glob("pattern") 호출을 감지하여 glob import 레코드를 생성한다.
fn scanGlobCall(self: *Parser, callee: NodeIndex, arg_list: NodeList) void {
    if (callee.isNone() or @intFromEnum(callee) >= self.ast.nodes.items.len) return;
    const callee_node = self.ast.nodes.items[@intFromEnum(callee)];
    if (callee_node.tag != .static_member_expression) return;

    const extras = self.ast.extra_data.items;
    if (callee_node.data.extra + 2 >= extras.len) return;

    // object: meta_property (import.meta)
    const obj_idx: NodeIndex = @enumFromInt(extras[callee_node.data.extra]);
    if (obj_idx.isNone() or @intFromEnum(obj_idx) >= self.ast.nodes.items.len) return;
    const obj_node = self.ast.nodes.items[@intFromEnum(obj_idx)];
    if (obj_node.tag != .meta_property) return;
    if (obj_node.data.none != 0) return;

    // property: "glob"
    const prop_idx: NodeIndex = @enumFromInt(extras[callee_node.data.extra + 1]);
    if (prop_idx.isNone() or @intFromEnum(prop_idx) >= self.ast.nodes.items.len) return;
    const prop_node = self.ast.nodes.items[@intFromEnum(prop_idx)];
    const prop_name = self.ast.source[prop_node.span.start..prop_node.span.end];
    if (!std.mem.eql(u8, prop_name, "glob")) return;

    // 첫 번째 인수가 string_literal인지
    if (arg_list.len == 0) return;
    if (arg_list.start >= extras.len) return;
    const arg_idx: NodeIndex = @enumFromInt(extras[arg_list.start]);
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= self.ast.nodes.items.len) return;
    const arg_node = self.ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg_node.tag != .string_literal) return;

    const raw = self.ast.source[arg_node.span.start..arg_node.span.end];
    const specifier = import_scanner.stripQuotes(raw) orelse raw;

    const opts = import_scanner.parseGlobOptions(
        self.ast.nodes.items,
        self.ast.extra_data.items,
        self.ast.source,
        extras,
        arg_list.start,
        arg_list.len,
    );

    self.scan_import_records.append(self.allocator, .{
        .specifier = specifier,
        .kind = .glob,
        .span = callee_node.span,
        .glob_eager = opts.eager,
        .glob_import_name = opts.import_name,
    }) catch {};
}

/// require.context(...) 호출을 감지하여 require_context 레코드를 생성한다. (#1579)
/// inline scan 시점에는 call_expression 노드가 아직 안 만들어져 있어 callee+args 직접 전달.
/// import_scanner.tryExtractRequireContextFromCallee 에 위임 후 ScanImportRecord 로 변환.
fn scanRequireContextCall(self: *Parser, callee: NodeIndex, arg_list: NodeList, call_span: Span) void {
    const ir = import_scanner.tryExtractRequireContextFromCallee(
        &self.ast,
        callee,
        arg_list.start,
        arg_list.len,
        call_span,
        self.scan_defines,
    ) orelse return;

    const mode: scan_results_mod.RequireContextMode = @enumFromInt(@intFromEnum(ir.context_mode));
    self.scan_import_records.append(self.allocator, .{
        .specifier = ir.specifier,
        .kind = .require_context,
        .span = ir.span,
        .context_recursive = ir.context_recursive,
        .context_filter = ir.context_filter,
        .context_filter_flags = ir.context_filter_flags,
        .context_mode = mode,
        .context_invalid_reason = ir.context_invalid_reason,
    }) catch {};
    self.scan_result.has_cjs_require = true;
}

/// assignment_expression의 left에서 module.exports = ... / exports.x = ... 패턴을 감지한다.
/// import_scanner.isModuleExportsAssign / isExportsDotAssign와 동일한 로직.
fn scanAssignmentCjs(self: *Parser, left: NodeIndex) void {
    if (left.isNone()) return;
    if (@intFromEnum(left) >= self.ast.nodes.items.len) return;
    const left_node = self.ast.nodes.items[@intFromEnum(left)];
    if (left_node.tag != .static_member_expression) return;

    const me = left_node.data.extra;
    if (me + 1 >= self.ast.extra_data.items.len) return;

    // object: extra[0], property: extra[1]
    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
    if (obj_idx.isNone()) return;
    if (@intFromEnum(obj_idx) >= self.ast.nodes.items.len) return;
    const obj = self.ast.nodes.items[@intFromEnum(obj_idx)];
    if (obj.tag != .identifier_reference) return;

    const obj_text = self.ast.source[obj.span.start..obj.span.end];

    if (std.mem.eql(u8, obj_text, "module")) {
        // module.exports = ...
        const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
        if (prop_idx.isNone()) return;
        if (@intFromEnum(prop_idx) >= self.ast.nodes.items.len) return;
        const prop = self.ast.nodes.items[@intFromEnum(prop_idx)];
        const prop_text = self.ast.source[prop.span.start..prop.span.end];
        if (std.mem.eql(u8, prop_text, "exports")) {
            self.scan_result.has_module_exports = true;
        }
    } else if (std.mem.eql(u8, obj_text, "exports")) {
        // exports.x = ...
        self.scan_result.has_exports_dot = true;
    }
}

/// 문자열 리터럴에서 따옴표를 제거한다.
/// import_scanner.stripQuotes에 위임한다.
fn stripRequireQuotes(text: []const u8) []const u8 {
    return import_scanner.stripQuotes(text) orelse text;
}
