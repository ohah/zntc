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
const profile = @import("../profile.zig");
const generic_arrow = @import("expression/generic_arrow.zig");
const scan = @import("expression/scan.zig");
const type_args = @import("expression/type_args.zig");

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
    var scope = profile.begin(.parse_expression_assignment);
    defer scope.end();

    // TS 제네릭 arrow function: <T>() => body, <const T>() => body
    // TSX 모드에서는 trailing comma(<T,>), constraint(<T extends X>), default(<T = X>)가
    // 있을 때만 제네릭 arrow로 시도 (oxc arrow.rs:166-197 참고)
    if (self.current() == .l_angle) {
        if (!self.is_jsx or try generic_arrow.isTsxGenericArrow(self)) {
            if (try generic_arrow.tryParseGenericArrow(self, false)) |arrow| return arrow;
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
                if (!self.is_jsx or try generic_arrow.isTsxGenericArrowAfterAsync(self)) {
                    const saved = self.saveState();
                    try self.advance(); // skip 'async'
                    if (try generic_arrow.tryParseGenericArrow(self, true)) |arrow| return arrow;
                    self.restoreState(saved);
                }
            }

            // 형태 1: async x => body (단순 식별자)
            if (peek.kind.canBeBindingName()) {
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
    // PR perf: arrow prefilter — 매 identifier expression 마다 saveState/advance/restoreState
    // (count 44k+) 가 hot. 다음 byte 가 `=` 가 아니면 arrow 가능성 0 → block 자체 skip.
    // `=` 인 경우: arrow (`=>`), assignment (`=`), equality (`==`) — full lookahead 그대로.
    if (self.current() == .identifier and self.scanner.peekIsNextByteSameLine('=')) {
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
        if (self.enable_scan and self.scan_dead_depth == 0) {
            scan.scanAssignmentCjs(self, left);
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
        // `__DEV__ ? requireA : requireB` 처럼 define 으로 평가되는 ternary 의
        // dead branch 안에서는 inline scan 의 require/import 등록을 차단해야
        // 한다. parseIfStatement 와 동일 패턴. 누락 시 collectDeadIfRanges 가
        // 후처리로 잡아도 graph 는 inline scan 결과를 우선 사용하므로 dead
        // require 가 graph 에 진입한다.
        const known_scan_condition = self.evalScanCondition(expr);

        // ECMAScript: ConditionalExpression[In] →
        //   ... ? AssignmentExpression[+In] : AssignmentExpression[?In]
        // consequent는 항상 `in` 허용, alternate는 외부 context 유지
        const cond_saved = self.enterAllowInContext(true);
        // ternary consequent에서 `(x): T =>` 패턴의 typed arrow 감지를 억제한다.
        // `:` 가 return type annotation인지 ternary separator인지 모호하기 때문.
        // 대신 아래 tryReinterpretAsTypedArrow에서 speculative하게 시도한다.
        const saved_in_ternary = self.in_ternary_consequent;
        self.in_ternary_consequent = true;
        if (known_scan_condition == false) self.scan_dead_depth += 1;
        var consequent = try parseAssignmentExpression(self);
        if (known_scan_condition == false) self.scan_dead_depth -= 1;
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
        if (known_scan_condition == true) self.scan_dead_depth += 1;
        const alternate = try parseAssignmentExpression(self);
        if (known_scan_condition == true) self.scan_dead_depth -= 1;
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
    const checkpoint = Parser.SpeculationCheckpoint.save(self);

    // Consume `:` (speculatively — might be return type or ternary separator)
    try self.advance(); // skip :

    // Parse the return type. Use disallow_conditional_types to prevent the type
    // parser from consuming `?` that belongs to an outer ternary.
    // parseType 가 ParseError 를 throw 하면 catch — speculative 이므로 caller
    // 로 propagate 시키면 안 된다 (예: `a ? (x) : (y => y)` 에서 `(y =>` 가
    // function type param 파싱 실패).
    const ctx_saved = self.ctx;
    self.ctx.disallow_conditional_types = true;
    const type_result = self.parseType();
    self.ctx = ctx_saved;

    if (type_result == error.OutOfMemory) return error.OutOfMemory;

    const arrow_ok = (type_result catch null) != null and
        self.current() == .arrow and !self.scanner.token.has_newline_before and
        !checkpoint.errorAdded(self);

    if (!arrow_ok) {
        // Not a typed arrow (or parseType errored) — restore and let the caller treat `:` as ternary separator
        checkpoint.rollback(self);
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

        const prec = type_args.getBinaryPrecedence(self.current());
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

pub fn parseUnaryExpression(self: *Parser) ParseError2!NodeIndex {
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
        .kw_yield => {
            // generator 가 아닌 함수 본문에서 yield 사용 → 명확한 진단 (#2210).
            // await 패턴 (in_async / in_module 비교) 과 동일하게 in_generator
            // 검사 후 fail 하면 yield 키워드 위치에 진단 emit. fallthrough 로
            // identifier 처리는 유지해 후속 토큰에 cascade 에러가 나지 않도록.
            if (self.is_module and !self.in_namespace and self.ctx.in_function and !self.ctx.in_generator) {
                try self.addErrorCode(self.currentSpan(), "'yield' is not allowed outside generator function", .yield_outside_generator);
            }
            return parsePostfixExpression(self);
        },
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
        // match pattern 안의 `as` 는 type-cast 가 아니라 binding 구분자.
        if (is_as and self.flow_in_match_pattern) break;
        const is_satisfies = !is_as and !self.is_flow and std.mem.eql(u8, text, "satisfies");
        if (!is_as and !is_satisfies) break;
        const expr_start = self.ast.getNode(expr).span.start;
        try self.advance();
        _ = try self.parseType();
        const tag: @import("ast.zig").Node.Tag = if (is_satisfies)
            .ts_satisfies_expression
        else if (self.is_flow)
            .flow_as_expression
        else
            .ts_as_expression;
        // codegen 은 operand 만 출력하고 type annotation 은 스트리핑하므로
        // type 참조는 저장하지 않는다. layout=.unary (ast.zig getLayout 참고).
        expr = try self.ast.addUnaryNode(
            tag,
            .{ .start = expr_start, .end = self.currentSpan().start },
            expr,
            0,
        );
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
                if (self.enable_scan and self.scan_dead_depth == 0) {
                    scan.scanRequireCall(self, expr, arg_list);
                    scan.scanGlobCall(self, expr, arg_list);
                    scan.scanRequireContextCall(self, expr, arg_list, call_span);
                    scan.scanObjectDefinePropertyCjs(self, expr, arg_list);
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
                if (self.ast.getNode(expr).tag == .super_expression) {
                    try self.addErrorCode(self.ast.getNode(expr).span, "'super' cannot be used as the base of an optional chain", .super_in_optional_chain);
                }
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
                    // no-substitution template — text 는 span 에서 직접 읽으므로
                    // 자식 리스트는 비어 있다. layout=.list 에 맞춰 빈 NodeList 저장.
                    break :blk try self.ast.addListNode(
                        .template_literal,
                        tmpl_span,
                        .{ .start = 0, .len = 0 },
                    );
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
                //
                // 두 단계 가드:
                //   1. literal LHS — generic-call target 불가 (TSC 의
                //      `canTryReparseTypeArguments`). 진입 자체 차단해 일반
                //      `1 << N` 도 빠르게 통과.
                //   2. 이미 outer speculation 안 — inner `<T>(x = expr) => R`
                //      generic function type 의 parameter default 가 다시
                //      expression-mode 로 재진입한 상황. 그 안의 `<<` 가 또
                //      speculation 을 발화하면 O(2^N) nest 폭주
                //      (TSC conformance `parserRealSource2.ts`). esbuild/oxc 는
                //      inner type-parser 가 expression-mode 로 가지 않게 설계.
                if (self.ast.getNode(expr).tag.isLiteralTag()) break;
                if (self.in_type_args_speculation) break;
                if (!trySkipTypeArgsSpeculative(self, true, type_args.canFollowTypeArgumentsInExpression)) break;
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
    const checkpoint = Parser.SpeculationCheckpoint.save(self);
    const saved_in_spec = self.in_type_args_speculation;
    self.in_type_args_speculation = true;
    defer self.in_type_args_speculation = saved_in_spec;

    const type_args_ok = blk: {
        _ = (if (strict) self.parseTypeArgumentsInExpression() else self.parseTypeArguments()) catch {
            break :blk false;
        };
        if (checkpoint.errorAdded(self)) break :blk false;
        break :blk follow(self);
    };

    // Flow: `f<T>( name : Type )` 의 `( name :` 는 parenthesized typecast 으로,
    // generic-call argument 로는 유효하지 않다(call arg 에 `name:` 불가). 따라서
    // 이 형태는 generic-call 이 아니라 relational `(f < T) > (name: Type)` 이
    // 유일 해석(babel 동일: type-generics/async-arrow-like 는 BinaryExpression).
    // type-args 확정을 취소해 `<`/`>` 가 비교 연산자로 처리되게 한다.
    if (type_args_ok and self.is_flow and self.current() == .l_paren and
        flowTypecastParenFollows(self))
    {
        checkpoint.rollback(self);
        return false;
    }

    if (type_args_ok) {
        checkpoint.rollbackKeepScanner(self);
    } else {
        checkpoint.rollback(self);
    }
    return type_args_ok;
}

/// 현재 `(` 직후가 `<simple> :` (parenthesized Flow typecast) 인지 — 2-token
/// lookahead. call argument 는 `name:` 로 시작할 수 없으므로, 이 형태면
/// 선행 `<...>` 는 type-args 가 아니라 비교 연산자다. `advance()` 로 전진하나
/// SpeculationCheckpoint + `defer rollback` 으로 전 경로 scanner/parser 복원.
fn flowTypecastParenFollows(self: *Parser) bool {
    const cp = Parser.SpeculationCheckpoint.save(self);
    defer cp.rollback(self);
    self.advance() catch return false; // skip '('
    // typecast 피연산자 시작: identifier / 비예약 keyword / this / string literal
    const t = self.current();
    const operand_ok = t == .identifier or t == .kw_this or t == .string_literal or
        (t.isKeyword() and !t.isReservedKeyword());
    if (!operand_ok) return false;
    self.advance() catch return false; // skip operand
    return self.current() == .colon; // `( name :` → typecast paren
}

fn followedByParenOnly(self: *const Parser) bool {
    return self.current() == .l_paren;
}

fn finishNewExpressionWithArgs(self: *Parser, start: u32, callee: NodeIndex, arg_list: NodeList) !NodeIndex {
    const ne = try self.ast.addExtras(&.{
        @intFromEnum(callee), arg_list.start, arg_list.len, 0,
    });
    const new_expr = try self.ast.addNode(.{
        .tag = .new_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = ne },
    });
    if (self.enable_scan and self.scan_dead_depth == 0) {
        scan.scanWorkerNewExpression(self, callee, arg_list);
    }
    return new_expr;
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
        _ = trySkipTypeArgsSpeculative(self, true, type_args.canFollowTypeArgumentsInExpression);
        if (self.current() == .l_paren) {
            try self.advance();
            const arg_list = try parseArgumentList(self);
            return try finishNewExpressionWithArgs(self, span.start, callee, arg_list);
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
    // new callee 에 optional chain(`a?.b`)이 있으면 SyntaxError — 진단은 callee 당 1회만.
    var reported_optional_new = false;
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
                // computed-member subscript 는 항상 [+In] (ECMAScript MemberExpression
                // `[ Expression ]`). for-init 등 allow_in=false 컨텍스트에서도 `new a[b in c]`
                // 의 `in` 을 허용해야 한다 — postfix `.l_bracket` 경로와 동일.
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
                // ECMAScript: new 의 callee(MemberExpression)는 OptionalExpression 일 수 없다
                // (`new a?.b()` / `new a.b?.c()` = SyntaxError). 진단은 callee 당 1회만 내고
                // (`reported_optional_new`), `?.`와 뒤따르는 멤버를 일반 멤버처럼 소비해 postfix
                // 루프가 `(new ...)?.x` 로 잘못 재해석하는 것을 막는다. paren 으로 감싼
                // `new (a?.b)()` 는 `?.`가 paren 내부라 이 루프에 도달하지 않아 유효 통과.
                if (!reported_optional_new) {
                    try self.addErrorCode(self.currentSpan(), "Invalid optional chain in 'new' expression", .optional_chain_new);
                    reported_optional_new = true;
                }
                try self.advance(); // consume `?.`
                if (self.current() == .l_bracket) {
                    // `?.[expr]` → computed (subscript 는 [+In]).
                    try self.advance();
                    const cm_saved = self.enterAllowInContext(true);
                    const prop = try parseExpression(self);
                    self.restoreContext(cm_saved);
                    try self.expect(.r_bracket);
                    const me = try self.ast.addExtras(&.{ @intFromEnum(expr), @intFromEnum(prop), 0 });
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .extra = me },
                    });
                } else if (self.current() == .identifier or self.current() == .escaped_keyword or
                    self.current() == .escaped_strict_reserved or self.current() == .private_identifier or
                    self.current().isKeyword())
                {
                    // `?.name` → 일반 멤버명으로 소비. parseIdentifierName 이 멤버명을 받을 때만
                    // 호출하므로 "Identifier expected" 2차 에러(노이즈)가 안 붙는다.
                    const prop = try parseIdentifierName(self);
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
                } else {
                    // 멤버명 없음(`?.(` optional call / `?.\`tpl\`` / `?.<T>` / EOF / `;` 등) →
                    // break. 상위가 `(`/template/type-args 를 소비하거나 `new <callee>` 로
                    // 종료한다. 단일 623 진단 유지(2차 에러·dangling `.invalid` prop 없음).
                    break;
                }
            },
            else => break,
        }
    }
    return expr;
}

fn isFlowMatchExpressionStart(self: *Parser) ParseError2!bool {
    const saved = self.saveState();
    defer self.restoreState(saved);

    try self.scanner.next(); // skip 'match'
    if (self.current() != .l_paren) return false;

    var paren_depth: u32 = 1;
    while (paren_depth > 0) {
        try self.scanner.next();
        switch (self.current()) {
            .eof => return false,
            .l_paren => paren_depth += 1,
            .r_paren => paren_depth -= 1,
            else => {},
        }
    }

    try self.scanner.next();
    return self.current() == .l_curly;
}

fn parsePrimaryExpression(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // contextual keyword도 expression 위치에서 식별자로 유효.
    // async는 제외 — async function/arrow에서 특수 처리 (아래 switch에서).
    // literal keyword (true, false, null)는 제외 — 아래 switch에서 boolean_literal/null_literal로 처리.
    if (self.current().canBeBindingName() and
        !self.current().isLiteralKeyword() and self.current() != .kw_async)
    {
        // Flow match expression: match (expr) { Pattern => expr, ... }
        if (self.is_flow and self.isContextual("match")) {
            if (try isFlowMatchExpressionStart(self)) {
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
            _ = trySkipTypeArgsSpeculative(self, true, type_args.canFollowTypeArgumentsInExpression);

            // 인자: (args) — 있으면 소비, 없으면 인자 없는 new (new Foo)
            if (self.current() == .l_paren) {
                try self.advance(); // skip (
                const arg_list = try parseArgumentList(self);
                return try finishNewExpressionWithArgs(self, span.start, callee, arg_list);
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
            // `in_decorator` 도 괄호 안에서는 해제 — `@(inst["foo"])` 같은 패턴에서
            // 안쪽 computed member access 가 다음 멤버 key 와 혼동될 일 없음.

            // TS 모드: `(a: Type, b?: Type) => body` — 타입 어노테이션이 있는 arrow function.
            // lookahead로 감지: `(` 뒤에 identifier + `:` 또는 `?` 패턴이면 speculative 파싱.
            if (try self.isTypedArrowFunction()) {
                if (try self.parseTypedArrowParams(span.start, false)) |arrow| return arrow;
            }

            try self.advance(); // skip (

            // 빈 괄호: () → arrow function의 빈 파라미터 리스트 (operand 없음).
            if (self.current() == .r_paren) {
                try self.advance(); // skip )
                return try self.ast.addUnaryNode(
                    .parenthesized_expression,
                    .{ .start = span.start, .end = self.currentSpan().start },
                    .none,
                    0,
                );
            }

            // `(a, ...b) => {}` 형태의 rest 파라미터를 cover grammar으로 지원.
            // `...`는 일반 expression에서는 나올 수 없으므로 arrow 파라미터로만 해석된다.
            const paren_saved = self.enterAllowInContext(true);
            const saved_in_decorator = self.ctx.in_decorator;
            self.ctx.in_decorator = false;
            // D22: parenthesized expression 안은 새 expression 컨텍스트 — 바깥
            // ternary separator 무관 (oxc allow_return_type 복원). isTypedArrowFunction
            // 이 false 라 여기 도달했으므로 이 `(`는 arrow params 가 아님. 안의
            // `((b): T => b)` 같은 inner arrow 가 D22 commit gate 에 잘못 걸리지
            // 않도록 reset.
            const saved_paren_ternary = self.in_ternary_consequent;
            self.in_ternary_consequent = false;
            const expr = try parseExpressionOrRest(self);
            self.in_ternary_consequent = saved_paren_ternary;
            self.ctx.in_decorator = saved_in_decorator;
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
            // no-substitution template — text 는 span 에서 직접 읽으므로
            // 자식 리스트는 비어 있다. layout=.list 에 맞춰 빈 NodeList 저장.
            return try self.ast.addListNode(
                .template_literal,
                span,
                .{ .start = 0, .len = 0 },
            );
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
        // D22: template substitution 도 새 expression 컨텍스트 — 바깥 ternary
        // separator 무관 (oxc allow_return_type 복원).
        const tmpl_saved = self.enterAllowInContext(true);
        const saved_tmpl_ternary = self.in_ternary_consequent;
        self.in_ternary_consequent = false;
        const expr = try parseExpression(self);
        self.in_ternary_consequent = saved_tmpl_ternary;
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

    // D22: array element 는 새 expression 컨텍스트 — 바깥 ternary separator `:`
    // 무관 (oxc allow_return_type 복원). `cond ? [(b): T => b] : 0` 의 element
    // arrow 가 D22 commit gate 에 잘못 걸리지 않도록 reset (call-args/paren 과 동일).
    const saved_in_ternary = self.in_ternary_consequent;
    self.in_ternary_consequent = false;
    defer self.in_ternary_consequent = saved_in_ternary;

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
    // D22: call/new argument 는 새 expression 컨텍스트 — 바깥 ternary 의 separator
    // `:` 영향을 받지 않는다 (oxc allow_return_type_in_arrow_function 복원).
    // `cond ? f((b): T => b) : 0` 에서 인자 arrow 의 `: T` 는 return type 이고
    // body 다음은 `)` 이므로, in_ternary_consequent 를 reset 하지 않으면 D22
    // commit gate 가 잘못 rollback 한다.
    const saved_in_ternary = self.in_ternary_consequent;
    self.in_ternary_consequent = false;
    defer self.in_ternary_consequent = saved_in_ternary;

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

/// TS type assertion: <T>expr → expr (타입 스트리핑)
/// .ts 파일에서만 호출 (TSX에서는 JSX가 우선)
/// oxc parse_ts_type_assertion 대응
///
/// esbuild 호환: <{}>() => {} 및 <[]>(y, z) => {} 같은 패턴에서
/// <Type>이 type assertion이고 뒤따르는 () => {} 가 arrow function인 경우,
/// type assertion은 스트리핑되므로 arrow function만 반환한다.
/// esbuild는 parsePrefix를 호출해서 arrow를 직접 감지하지만, ZNTC는
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
