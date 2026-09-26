//! ES2015 다운레벨링: generator function → 상태 머신
//!
//! --target < es2015 일 때 활성화.
//!
//! function* gen() { yield 1; var x = yield 2; return x; }
//! → function gen() {
//!     return __generator(function(_state) {
//!       switch (_state.label) {
//!         case 0: return [4, 1];
//!         case 1: x = _state.sent(); return [4, 2];
//!         case 2: return [2, _state.sent()];
//!       }
//!     });
//!   }
//!
//! 상태 머신 instruction 코드:
//!   [4, value] — yield (일시정지, value 반환)
//!   [2, value] — return (완료)
//!   [3, label] — break/jump (다른 case로 이동)
//!   [5, iter]  — yield* (위임)
//!
//! __generator 런타임 헬퍼:
//!   _state.label — 현재 case 번호
//!   _state.sent() — .next(value)로 전달된 값
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-generator-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/generator.rs (~3778줄)
//! - TypeScript: src/compiler/transformers/generators.ts
//! - esbuild: 미지원

const std = @import("std");
const ast_walk = @import("../parser/ast_walk.zig");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const es2015_destructuring = @import("es2015_destructuring.zig");
const es2015_scan = @import("es2015_generator/scan.zig");
const es2015_block_scoping = @import("es2015_block_scoping.zig");

/// 상태 머신의 개별 연산.
const OpCode = enum {
    statement, // 일반 문
    yield_op, // yield value → [4, value]
    yield_star, // yield* iter → [5, iter]
    return_op, // return value → [2, value]
    break_op, // goto label → [3, label]
    break_when_true, // if (expr) goto label
    break_when_false, // if (!expr) goto label
    nop, // case 경계 강제 (빈 연산)
};

/// 연산의 인자.
const OpArg = union(enum) {
    none: void,
    node: NodeIndex, // statement, yield, return의 값
    label: u32, // break_op의 대상 label
    label_and_node: struct { label: u32, node: NodeIndex }, // break_when_true/false
};

/// 하나의 연산 (opcode + 인자).
const Operation = struct {
    code: OpCode,
    arg: OpArg,
};

/// yield_expression / await_expression 노드를 대응되는 OpCode로 변환.
/// yield* delegate는 `unary.flags & 1`로 식별된다 (parser에서 설정).
/// await_expression은 always yield_op (delegate 의미 없음).
fn yieldOpCodeFor(node: Node) OpCode {
    if (node.tag == .yield_expression and (node.data.unary.flags & 1) != 0) return .yield_star;
    return .yield_op;
}

pub fn ES2015Generator(comptime Transformer: type) type {
    return struct {
        /// generator function을 상태 머신으로 변환.
        /// function*: extra = [name(0), params(1), body(2), flags(3), return_type(4)]
        pub fn lowerGeneratorFunction(self: *Transformer, source_owner: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const params_list_old = self.ast.functionParamsList(node);
            const params_start = params_list_old.start;
            const params_len = params_list_old.len;
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);

            // An extracted per-iteration generator is an implementation
            // function, not a lexical boundary for arrows in the source loop
            // body. Their `this`/`arguments` belong to the enclosing source
            // generator; keep that frame so its wrapper owns the aliases.
            const extracted_loop = self.deferred_generator_loop_owners.contains(@intFromEnum(source_owner));
            const arrow_env: ?es_helpers.ArrowEnvSnapshot = if (extracted_loop) null else es_helpers.pushArrowEnv(self);
            defer if (arrow_env) |env| es_helpers.popArrowEnv(self, env);
            const saved_extracted_body = self.in_extracted_fn_body;
            self.in_extracted_fn_body = false;
            defer self.in_extracted_fn_body = saved_extracted_body;

            const new_name = try self.visitNode(name_idx);

            const parameter_temp_start = self.temp_var_counter;
            const new_params = try self.visitExtraList(.{ .start = params_start, .len = params_len });
            const parameter_temp_end = self.temp_var_counter;
            const param_needs_this = if (extracted_loop) false else self.needs_this_var;
            const param_needs_arguments = if (extracted_loop) false else self.needs_arguments_var;

            const saved_temp_counter = self.temp_var_counter;

            // body 가 `__generator(this, function(_state){…})` 안쪽으로 옮겨진다 →
            // `arguments` 가 그 안쪽 함수 것(= `[_state]`)을 가리키므로 캡처가 필요하다.
            const saved_ext = self.in_extracted_fn_body;
            self.in_extracted_fn_body = true;
            // ⚠️ 이 리스트는 **상태 기계 하나당** 쓰는 것이라 중첩 lowering 이 서로를
            // 덮으면 안 된다. 예전에는 끝에서 통째로 clear 했는데, 바깥 상태 기계를
            // 수집하는 도중에 안쪽 generator 가 낮아지면(#4716 의 `_loopN` 추출이 그렇다)
            // 바깥이 쌓아 둔 temp 가 같이 지워져 선언이 사라진다. 저장 후 복원한다.
            var frame = try enterStateMachineTemps(self);
            defer leaveStateMachineTemps(self, &frame);
            // 함수 경계 — 바깥 함수의 라벨은 여기서 보이지 않는다 (#4722).
            try self.label_scope.append(self.allocator, null);
            defer _ = self.label_scope.pop();

            const sm_result = try buildStateMachine(self, body_idx, span);
            self.in_extracted_fn_body = saved_ext;
            if (sm_result.body.isNone()) return .none;
            const sm_body = try self.hoistStateMachineTempsAndRestore(sm_result.body, saved_temp_counter, span, &frame.callback_temps);

            // generator function 이름이 있으면 프로토타입 체인 설정을 위해 __generator에 전달.
            // #1756: makeIdentifierRefFromSpan 만 쓰면 symbol_id 가 전파되지 않아
            // 번들 모드에서 mangler rename (`function foo → function t`) 이 반영 안 됨.
            // `__generator(body, foo)` 의 `foo` 가 원본 이름 그대로 emit → ReferenceError.
            // makeIdentifierRefWithSymbol 로 원본 binding 의 symbol_id 까지 전파해야
            // codegen 이 `meta.renames.get(sid)` 로 mangled name 을 찾아 emit 함.
            const genFn_ref: NodeIndex = if (!new_name.isNone())
                try self.makeIdentifierRefWithSymbol(self.ast.getNode(new_name).data.string_ref, new_name)
            else
                .none;
            const gen = try buildGeneratorHelperCallWithProto(self, sm_body, genFn_ref, span);
            const source_scope = self.originalFunctionScope(source_owner);
            try self.bindGeneratedState(source_scope, source_scope, gen.callback, gen.state_param, frame.state_ref_start, frame.callback_temps.items, span);
            const gen_call = gen.call;

            // return __generator(...) 문
            const ret_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = gen_call, .flags = 0 } },
            });

            // hoisted var + return __generator(...)
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            if (!extracted_loop) {
                var capture_stmts: [2]NodeIndex = undefined;
                const count = try es_helpers.fillThisArgumentsCaptures(self, &capture_stmts, span);
                try es_helpers.recordParameterCaptures(self, capture_stmts[0..count], param_needs_this, param_needs_arguments);
                try self.scratch.appendSlice(self.allocator, capture_stmts[0..count]);
            }
            if (!sm_result.var_decl.isNone()) {
                try self.scratch.append(self.allocator, sm_result.var_decl);
            }
            try self.scratch.append(self.allocator, ret_stmt);

            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const wrapper_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });
            const new_body = try self.hoistParameterTempsAndRestore(wrapper_body, parameter_temp_start, parameter_temp_end, span);

            // 일반 function으로 변환 (generator 플래그 제거)
            const new_flags = flags & ~@as(u32, ast_mod.FunctionFlags.is_generator);
            const none = @intFromEnum(NodeIndex.none);
            const new_params_node = try self.ast.addFormalParameters(new_params, span);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_name),
                @intFromEnum(new_params_node),
                @intFromEnum(new_body),
                new_flags,
                none,
            });
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        pub const StateMachineResult = struct {
            body: NodeIndex, // switch 문 (또는 switch를 포함하는 block)
            var_decl: NodeIndex, // 호이스팅된 var 선언 (없으면 .none)
        };

        /// generator body를 switch 문 기반 상태 머신으로 변환.
        /// es2017 결합 변환에서도 호출 (async body의 await를 yield처럼 처리).
        /// 상태 기계 하나를 만들기 **전에** 부른다: 바깥 상태 기계가 쌓아 둔 temp 목록을
        /// 떼어 두고 빈 목록으로 시작한다. 짝인 `leaveStateMachineTemps` 가 되돌린다.
        ///
        /// `generator_temp_var_spans` 는 상태 기계 하나당 쓰는 목록이다. 예전엔 각 호출부가
        /// 끝에서 통째로 clear 했는데, 바깥 상태 기계를 수집하는 도중에 안쪽 함수(중첩 async
        /// 화살표, 추출된 `_loop` generator …)가 낮아지면 **바깥 temp 까지 지워져** 선언이
        /// 사라졌다(`_loop is not defined` — #4716 에서 한 곳, #4722 에서 나머지 셋).
        pub const StateMachineFrame = struct {
            saved_temp_spans: std.ArrayListUnmanaged(Span),
            state_ref_start: usize,
            callback_temps: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty,
        };

        pub fn enterStateMachineTemps(self: *Transformer) Transformer.Error!StateMachineFrame {
            var saved: std.ArrayListUnmanaged(Span) = .empty;
            try saved.appendSlice(self.allocator, self.generator_temp_var_spans.items);
            self.generator_temp_var_spans.clearRetainingCapacity();
            return .{ .saved_temp_spans = saved, .state_ref_start = self.generator_state_refs.items.len };
        }

        pub fn leaveStateMachineTemps(self: *Transformer, frame: *StateMachineFrame) void {
            self.generator_state_refs.shrinkRetainingCapacity(frame.state_ref_start);
            self.generator_temp_var_spans.clearRetainingCapacity();
            self.generator_temp_var_spans.appendSlice(self.allocator, frame.saved_temp_spans.items) catch {};
            frame.saved_temp_spans.deinit(self.allocator);
            frame.callback_temps.deinit(self.allocator);
        }

        pub fn buildStateMachine(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!StateMachineResult {
            if (body_idx.isNone()) return .{ .body = .none, .var_decl = .none };

            const body = self.ast.getNode(body_idx);

            // expression body (arrow function): implicit return으로 처리
            if (body.tag != .block_statement and body.tag != .function_body) {
                return buildExpressionBodyStateMachine(self, body_idx, body, span);
            }

            const body_list = try rewriteUsingForStateMachine(self, body.data.list);
            const stmts_start = body_list.start;
            const stmts_len = body_list.len;

            // Phase 1: 연산 수집 (yield/return/statement를 Operation으로 변환)
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);

            var next_label: u32 = 1; // label 0은 시작

            // 변수 호이스팅: generator body의 모든 var 선언을 수집.
            // JS의 var는 function-scoped이므로 switch case 안에 두면 안 됨.
            var hoisted_vars: std.ArrayList(NodeIndex) = .empty;
            defer hoisted_vars.deinit(self.allocator);
            // collectBindingIdentifiers가 visitNode를 호출하므로 인덱스 기반 접근 사용
            try collectHoistedVarsRange(self, stmts_start, stmts_len, &hoisted_vars);

            // collectOperations는 AST를 변형하므로 인덱스 루프 사용
            var i_stmts: u32 = 0;
            while (i_stmts < stmts_len) : (i_stmts += 1) {
                const raw_idx = self.ast.extra_data.items[stmts_start + i_stmts];
                try collectOperations(self, @enumFromInt(raw_idx), &ops, &next_label);
            }

            // 암시적 return (마지막에 return이 없으면 추가)
            if (ops.items.len == 0 or ops.items[ops.items.len - 1].code != .return_op) {
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .none = {} } });
            }

            // Phase 2: 연산을 switch case로 변환
            const switch_node = try buildSwitchFromOps(self, ops.items, span);
            const var_decl_node = try buildHoistedVarDecl(self, hoisted_vars.items, span);
            return .{ .body = switch_node, .var_decl = var_decl_node };
        }

        fn spanKey(span: Span) u64 {
            return (@as(u64, span.start) << 32) | span.end;
        }

        /// 사용자 바인딩(`origin`)에서 온 이름을 wrapper 최상단 `var` 목록에 등록한다. 목록은 이름만
        /// 담으므로, 선언을 만들 때 심볼을 물려줄 수 있게 원래 바인딩을 따로 기록한다.
        fn registerGeneratorVar(self: *Transformer, span: Span, origin: NodeIndex) Transformer.Error!void {
            try self.generator_temp_var_spans.append(self.allocator, span);
            try self.generator_var_origins.put(self.allocator, spanKey(span), origin);
        }

        /// generator body 의 hoisted `var` 선언과 for-of/await 변환에서 생성한 임시 변수를
        /// 하나의 `var` 선언으로 합쳐 반환. __generator 콜백 밖(함수 스코프)에 배치해야 한다 —
        /// 콜백 안에 두면 매 호출마다 재선언되어 상태가 리셋된다. 합칠 변수가 없으면 `.none`.
        fn buildHoistedVarDecl(self: *Transformer, hoisted_vars: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (hoisted_vars.len == 0 and self.generator_temp_var_spans.items.len == 0) return .none;
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            // 같은 이름을 두 번 선언하지 않는다 — 합성 선언 등록(#4722)이 소스 선언과 겹칠 수 있다.
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(self.allocator);
            for (hoisted_vars) |binding| {
                const bnode = self.ast.getNode(binding);
                if (bnode.tag == .binding_identifier) try seen.put(self.allocator, self.ast.getText(bnode.data.string_ref), {});
                const declarator = try es_helpers.makeDeclarator(self, binding, .none, span);
                try self.scratch.append(self.allocator, declarator);
            }
            for (self.generator_temp_var_spans.items) |temp_span| {
                const gop = try seen.getOrPut(self.allocator, self.ast.getText(temp_span));
                if (gop.found_existing) continue;
                // 사용자 바인딩에서 온 이름이면 그 심볼을 물려준다 — 대입·참조만 심볼을 갖고
                // 이 선언이 없으면 minify 가 둘을 다른 이름으로 찍는다 (#4760).
                const binding = if (self.generator_var_origins.get(spanKey(temp_span))) |origin|
                    try self.makeUserBinding(temp_span, origin)
                else
                    try es_helpers.makeSyntheticBinding(self, temp_span);
                const declarator = try es_helpers.makeDeclarator(self, binding, .none, span);
                try self.scratch.append(self.allocator, declarator);
            }
            return es_helpers.makeVarDeclaration(self, self.scratch.items[scratch_top..], .@"var", span);
        }

        /// `return`/`throw` 의 피연산자 식을 yield 추출과 함께 처리한 뒤, 그 자리에 들어갈
        /// 최종 식 노드를 반환한다.
        ///  - `await x` / `yield x` 자체: yield 연산 + nop 을 ops 에 방출하고 `_state.sent()` 반환.
        ///  - 중첩 yield (`f(await x)` 등): yield 들을 추출한 뒤 남은 식 반환.
        ///  - yield 없음: 그냥 visitNode 결과 반환.
        fn lowerYieldingOperand(self: *Transformer, value_idx: NodeIndex, span: Span, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const value_node = self.ast.getNode(value_idx);
            if (value_node.tag == .yield_expression or value_node.tag == .await_expression) {
                const inner_value = value_node.data.unary.operand;
                const new_inner = try visitExprWithYieldExtraction(self, inner_value, ops, next_label);
                try ops.append(self.allocator, .{ .code = yieldOpCodeFor(value_node), .arg = .{ .node = new_inner } });
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                return buildSentCall(self, span);
            }
            if (es2015_scan.containsYield(self, value_idx)) {
                return visitExprWithYieldExtraction(self, value_idx, ops, next_label);
            }
            return self.visitNode(value_idx);
        }

        /// AST 문을 순회하며 연산을 수집.
        fn collectOperations(self: *Transformer, stmt_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (stmt_idx.isNone()) return;
            const stmt = self.ast.getNode(stmt_idx);

            switch (stmt.tag) {
                .expression_statement => {
                    // expression_statement 안의 yield/await 감지
                    const expr_idx = stmt.data.unary.operand;
                    const expr = self.ast.getNode(expr_idx);

                    if (expr.tag == .yield_expression or expr.tag == .await_expression) {
                        const value_idx = expr.data.unary.operand;
                        const new_value = try visitExprWithYieldExtraction(self, value_idx, ops, next_label);
                        try ops.append(self.allocator, .{ .code = yieldOpCodeFor(expr), .arg = .{ .node = new_value } });
                        next_label.* += 1;
                        try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                        // _state.sent() — resume 시 throw된 에러를 발생시키기 위해 필수
                        const sent_stmt = try buildSentExprStmt(self, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = sent_stmt } });
                    } else if (expr.tag == .assignment_expression) {
                        // x = yield value / x = await value / x += await value 패턴 감지.
                        // compound (`+=`, `-=`, ...) 의 경우 expr.data.binary.flags 가 op kind
                        // (Kind.plus_eq 등) 를 보존 — assignment node 만들 때 그대로 전달해야
                        // `sum += _state.sent()` 가 `sum = _state.sent()` 로 떨어지지 않음 (#1896).
                        const right_idx = expr.data.binary.right;
                        const right = self.ast.getNode(right_idx);
                        if (right.tag == .yield_expression or right.tag == .await_expression) {
                            const yield_value_idx = right.data.unary.operand;
                            const new_yield_value = try visitExprWithYieldExtraction(self, yield_value_idx, ops, next_label);
                            try ops.append(self.allocator, .{ .code = .yield_op, .arg = .{ .node = new_yield_value } });
                            next_label.* += 1;
                            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                            const new_left = try self.visitNode(expr.data.binary.left);
                            const sent_call = try buildSentCall(self, stmt.span);
                            const new_left_node = self.ast.getNode(new_left);
                            const is_destructuring = new_left_node.tag == .object_pattern or new_left_node.tag == .array_pattern;
                            // Destructuring 은 spec 상 compound op 불가 (`{a} += x` invalid) → 전용 helper (flags=0 + paren wrap).
                            const assign_stmt = if (is_destructuring)
                                try makeDestructuringAssignStmt(self, new_left, sent_call, stmt.span)
                            else
                                try es_helpers.makeAssignStmt(self, new_left, sent_call, stmt.span, expr.data.binary.flags);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                        } else if (es2015_scan.containsYield(self, expr_idx)) {
                            // x = [yield 5, yield 6] — 중첩 yield가 있는 assignment.
                            // ⚠️ 우변만 보면 `o[yield k] = 1` 처럼 **좌변**에 있는 yield 를
                            // 놓쳐 raw `yield` 가 남는다 (#4721).
                            // visitExprWithYieldExtraction으로 전체 assignment를 처리하여
                            // 각 yield를 temp 변수로 추출하고 _state.sent()로 대체
                            const new_expr = try visitExprWithYieldExtraction(self, expr_idx, ops, next_label);
                            const new_stmt = try es_helpers.makeExprStmt(self, new_expr, stmt.span);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        } else {
                            const new_stmt = try self.visitNode(stmt_idx);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    } else if (es2015_scan.containsYield(self, expr_idx)) {
                        // foo(await x) — 중첩 yield를 추출 후 expression statement
                        const new_expr = try visitExprWithYieldExtraction(self, expr_idx, ops, next_label);
                        const new_stmt = try es_helpers.makeExprStmt(self, new_expr, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
                .return_statement => {
                    const value_idx = stmt.data.unary.operand;
                    const new_value = if (value_idx.isNone())
                        NodeIndex.none
                    else
                        try lowerYieldingOperand(self, value_idx, stmt.span, ops, next_label);
                    try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
                },
                .throw_statement => {
                    const value_idx = stmt.data.unary.operand;
                    if (value_idx.isNone() or !es2015_scan.containsYield(self, value_idx)) {
                        const new_stmt = try self.visitNode(stmt_idx);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    } else {
                        const new_value = try lowerYieldingOperand(self, value_idx, stmt.span, ops, next_label);
                        const throw_stmt = try self.ast.addNode(.{
                            .tag = .throw_statement,
                            .span = stmt.span,
                            .data = .{ .unary = .{ .operand = new_value, .flags = 0 } },
                        });
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = throw_stmt } });
                    }
                },
                .variable_declaration => {
                    // 모든 var는 호이스팅됨. init를 assignment로 변환.
                    try collectVarDeclWithYield(self, stmt, ops, next_label);
                },
                .block_statement, .function_body => {
                    try collectBodyOperations(self, stmt_idx, ops, next_label);
                },
                .if_statement => {
                    try collectIfOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .for_statement => {
                    try collectForOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .while_statement => {
                    try collectWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .do_while_statement => {
                    try collectDoWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .try_statement => {
                    try collectTryOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .labeled_statement => {
                    // 라벨 붙은 for-of: 라벨을 풀이 결과 안쪽 for 에 붙여 수집한다 — 라벨이 풀이
                    // 블록에 붙으면 `continue <label>` 이 루프를 못 찾는다 (#4746).
                    const child = stmt.data.binary.right;
                    if (!child.isNone()) {
                        _ = try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, child);
                        const child_node = self.ast.getNode(child);
                        if (child_node.tag == .for_of_statement) {
                            const rewritten = try ForOf.rewriteForOf(self, child, child_node, stmt.data.binary.left, true);
                            return collectOperations(self, rewritten, ops, next_label);
                        }
                    }
                    try collectLabeledOperations(self, stmt, ops, next_label);
                },
                .switch_statement => {
                    try collectSwitchOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .for_of_statement, .for_in_statement => {
                    if (try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, stmt_idx))
                        return collectOperations(self, stmt_idx, ops, next_label);
                    if (es2015_scan.hasYieldOrReturn(self, stmt_idx)) {
                        // for-of 는 일반 경로와 같은 풀이(반복자 for + 닫기 try/finally), for-in 은 키
                        // 스냅샷 + 인덱스 for 풀이로 바꿔 그 구조를 수집한다 (#4746).
                        const rewritten = if (stmt.tag == .for_in_statement)
                            try ForOf.rewriteForIn(self, stmt)
                        else
                            try ForOf.rewriteForOf(self, stmt_idx, stmt, .none, true);
                        try collectOperations(self, rewritten, ops, next_label);
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        if (!new_stmt.isNone()) {
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    }
                },
                .for_await_of_statement => {
                    if (try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, stmt_idx))
                        return collectOperations(self, stmt_idx, ops, next_label);
                    // for-await 는 방문 없는 풀이(반복자 while + 닫기 try/finally)로 바꿔 그 구조를
                    // 수집한다 (#4746 3단계). 본문이 상태 기계로 수집되므로 안쪽 for-of/for-in 의
                    // yield 도 제대로 접히고, 반복별 바인딩은 while 의 본문 캡처 추출이 맡는다.
                    // async generator 는 본문 전처리에서 이미 제자리 풀이돼 여기 오지 않는다.
                    const rewritten = try @import("es2018_for_await.zig").ES2018ForAwait(Transformer).rewriteForAwait(self, stmt, .none);
                    try collectOperations(self, rewritten, ops, next_label);
                },
                .break_statement, .continue_statement => {
                    const target = resolveBreakContinueTarget(self, stmt);
                    if (target) |t| {
                        try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = t } });
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        if (!new_stmt.isNone()) {
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    }
                },
                .class_declaration => {
                    // 헤더에 yield 가 있으면 먼저 꺼내 둔다 (#4723). 없으면 평소대로.
                    const target = if (es2015_scan.containsYield(self, stmt_idx))
                        try extractClassHeaderYields(self, stmt_idx, ops, next_label)
                    else
                        stmt_idx;
                    try appendVisitedStatement(self, target, ops, next_label);
                },
                else => try appendVisitedStatement(self, stmt_idx, ops, next_label),
            }
        }

        /// 문장을 visit 해 op 로 넣되, visit 이 `pending_nodes`/`trailing_nodes` 로 **보류한
        /// 문장까지** 같은 자리에 넣는다. (#4723)
        ///
        /// es5 클래스 선언은 `var C = (function () {…})()` 를 `pending_nodes` 에 넣고 `.none` 을
        /// 돌려준다. 보통은 감싼 `visitExtraList` 가 그걸 비워 제자리에 꽂지만, 상태 기계
        /// 수집기는 `visitExtraList` 를 거치지 않는다 — 그래서 보류 노드가 **바깥(모듈 최상위)
        /// 목록**으로 새어 클래스가 generator 밖으로 끌려 나갔다. 클로저(`tag` 등)를 잃고
        /// 모듈 로드 시점에 평가된다.
        fn appendVisitedStatement(self: *Transformer, stmt_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const pending_top = self.pending_nodes.items.len;
            const trailing_top = self.trailing_nodes.items.len;
            const new_stmt = try self.visitNode(stmt_idx);

            // 보류 노드는 복사해 두고 즉시 되돌린다 — 아래 처리 중 또 쌓일 수 있다.
            var pending: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            try pending.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
            self.pending_nodes.shrinkRetainingCapacity(pending_top);
            var trailing: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer trailing.deinit(self.allocator);
            try trailing.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
            self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

            for (pending.items) |n| try appendHoistedStatement(self, n, ops, next_label);
            if (!new_stmt.isNone()) {
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
            }
            for (trailing.items) |n| try appendHoistedStatement(self, n, ops, next_label);
        }

        /// 이미 visit 된 보류 문장을 op 로 넣는다. `var` 선언이면 대입으로 접고 이름을
        /// **바깥 함수**의 var 리스트에 등록한다 — 콜백 안 `var` 는 resume 마다 리셋된다.
        fn appendHoistedStatement(self: *Transformer, node_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (node_idx.isNone()) return;
            const node = self.ast.getNode(node_idx);
            if (node.tag != .variable_declaration) {
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = node_idx } });
                return;
            }
            try collectVarDeclWithYield(self, node, ops, next_label);
            // 등록은 collectVarDeclWithYield **뒤** — 그 안에서 다른 상태 기계가 만들어지면
            // 먼저 넣은 이름이 그쪽 리스트로 빨려 들어간다(#4716 에서 밟음).
            const e = node.data.extra;
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[list_start + i]));
                if (decl.tag != .variable_declarator) continue;
                const binding_idx = self.readNodeIdx(decl.data.extra, 0);
                const binding = self.ast.getNode(binding_idx);
                if (binding.tag == .binding_identifier) {
                    try registerGeneratorVar(self, binding.data.string_ref, binding_idx);
                }
            }
        }

        /// if문의 연산 수집.
        fn collectIfOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.ternary.a;
            const then_body = stmt.data.ternary.b;
            const else_body = stmt.data.ternary.c;

            // body 는 statement → hasYieldOrReturn (yield + return 둘 다 검사),
            // condition 은 expression → return 불가, containsYield 만.
            const has_yield_in_cond = es2015_scan.containsYield(self, condition);
            if (!es2015_scan.hasYieldOrReturn(self, then_body) and !es2015_scan.hasYieldOrReturn(self, else_body) and !has_yield_in_cond) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 조건식에 yield/await가 있으면 먼저 추출 (short-circuit 미보존)
            const new_cond = if (has_yield_in_cond)
                try visitExprWithYieldExtraction(self, condition, ops, next_label)
            else
                try self.visitNode(condition);
            const has_else = !else_body.isNone();

            // `collectForOperations` 와 동일 sentinel/fixup 패턴 — end_label 을 미리 할당
            // 하면 then body 안 yield 가 같은 label 값을 yield-resume 으로 사용해 self-loop
            // 발생 (#1887). for/while/switch 는 이미 sentinel pattern, if 만 누락이었음.
            //
            // else_label 은 sentinel 안 씀 — `break_when_false` 의 ops 인덱스를 알므로 직접
            // patch (linear scan 회피). end_label 만 fixupSentinel 1 회.
            const if_ops_start = ops.items.len;
            const break_when_false_idx = if_ops_start;

            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = IF_END_SENTINEL, .node = new_cond } },
            });

            try collectBodyOperations(self, then_body, ops, next_label);

            // goto end (sentinel) — then body가 return/break로 끝나면 생략 (dead code 방지)
            if (ops.items.len == 0 or (ops.items[ops.items.len - 1].code != .return_op and ops.items[ops.items.len - 1].code != .break_op)) {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = IF_END_SENTINEL } });
            }

            if (has_else) {
                const else_label = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                // 직접 patch — break_when_false 가 인덱스 위치에 있음을 보장.
                ops.items[break_when_false_idx].arg.label_and_node.label = else_label;
                try collectBodyOperations(self, else_body, ops, next_label);
            }

            // end_label: then/else body 처리 *후* 에 할당 → yield 와 충돌 안 함.
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
            fixupSentinel(ops.items[if_ops_start..], IF_END_SENTINEL, end_label);
        }

        /// 상태 기계로 접히는 루프에서 `let`/`const` 의 **반복별 바인딩**을 복원한다. (#4716)
        ///
        /// es5 상태 기계는 지역 변수를 전부 함수 최상단 `var` 로 호이스트한다. 그러면
        /// 반복마다 새로 만들어져야 할 `let`/`const` 바인딩이 하나로 합쳐져, 루프 안에서
        /// 만든 클로저가 **전부 마지막 값을 캡처**한다(에러 없이 값만 틀린다).
        ///
        /// 일반 경로는 body 를 `var _loopN = function (x) {…}` 로 추출해 이를 복원한다.
        /// 상태 기계 경로는 body 에 `yield`/`await` 이 있어 평범한 함수로 못 뽑는다 —
        /// 그래서 **generator 로 뽑고 `yield*` 로 위임**한다. 상태 기계가 그 위임을
        /// `[5, __values(_loopN(x))]` 로 접고, `yield*` 의 값이 `_loopN` 의 return 값이라
        /// break/continue/return 신호(`call_and_check`)도 그대로 실려 온다.
        ///
        /// 추출이 필요 없으면 `.none` 을 돌려주고 호출부는 원래 노드를 그대로 쓴다.
        /// 추출하면 `var _loopN = function* (x) {…}` 문을 ops 에 먼저 방출하고, body 가
        /// 호출문으로 바뀐 **새 루프 노드**를 돌려준다.
        fn extractPerIterationLoopBody(
            self: *Transformer,
            stmt_idx: NodeIndex,
            stmt: Node,
            decl_idx: NodeIndex,
            body_idx: NodeIndex,
            ops: *std.ArrayList(Operation),
            next_label: *u32,
        ) Transformer.Error!NodeIndex {
            if (!self.options.unsupported.block_scoping) return .none;
            if (body_idx.isNone()) return .none;

            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var lexical_names = try BlockScoping.collectLexicalVarNames(self, decl_idx);
            defer lexical_names.deinit(self.allocator);
            // 헤더 let/const 에 더해 본문 선언(let/const/class)과 catch 파라미터도 본다 — 상태
            // 기계는 이들을 wrapper var 로 올리므로 캡처되면 반복별로 뽑아야 한다 (#4743).
            var capture_names: std.ArrayList([]const u8) = .empty;
            defer capture_names.deinit(self.allocator);
            try capture_names.appendSlice(self.allocator, lexical_names.items);
            try BlockScoping.collectLoopBodyLexicalNames(self, body_idx, true, &capture_names);
            if (!BlockScoping.hasCapturedClosure(self, body_idx, capture_names.items)) return .none;
            var var_names: std.ArrayList([]const u8) = .empty;
            defer var_names.deinit(self.allocator);
            try BlockScoping.collectLoopBodyVarNames(self, body_idx, &var_names);
            var lexical_bindings: std.ArrayList(NodeIndex) = .empty;
            defer lexical_bindings.deinit(self.allocator);
            try BlockScoping.collectLexicalVarBindings(self, decl_idx, &lexical_bindings);
            // 헤더 수집에서 정한 이름으로 생성해야 후속 상태 기계 방문이 인자를
            // 다시 리네임하지 않는다. 캡처 판정은 위에서 원래 이름으로 마쳤다.
            for (lexical_names.items, lexical_bindings.items) |*name, binding| {
                name.* = self.renamedNameOf(binding) orelse name.*;
            }
            var var_bindings: std.ArrayList(NodeIndex) = .empty;
            defer var_bindings.deinit(self.allocator);
            try BlockScoping.collectLoopBodyVarBindings(self, body_idx, &var_bindings);

            var flow = BlockScoping.FlowResult{};
            defer flow.labels.deinit(self.allocator);
            BlockScoping.analyzeControlFlow(self, body_idx, &flow, 0, 0);

            // 라벨 붙은 break/continue 가 바깥 루프를 겨냥해도 추출한다. 호출부 검사가 신호를
            // `continue <label>` 문으로 되살리고(#4722), 상태 기계가 라벨 스택으로 해석한다.
            // (예전엔 검사가 `return` 으로 전달해 라벨 점프가 사라졌기에 여기서 포기했다.)

            const result = try BlockScoping.buildLoopClosureWithFlow(
                self,
                body_idx,
                lexical_names.items,
                &flow,
                null,
                stmt.span,
                false, // is_async — 상태 기계 안에서는 await 도 yield 로 낮아진다
                BlockScoping.hasLexicalThisReference(self, body_idx),
                true, // is_generator
                null, // 본문은 아직 visit 전 — 추출된 generator 가 나중에 자기 temp 를 가진다
                var_names.items,
                lexical_bindings.items,
                var_bindings.items,
                loopCallScope(self, stmt_idx, lexical_bindings.items),
            );
            // `_loop` is an assignment inside the callback being built, but
            // that callback has no NodeIndex/ScopeId yet. Keep its exact owner
            // identity for the later generator-loop migration. An arbitrary
            // missing owner must still fail instead of using current_scope.
            // This also marks the synthetic boundary as transparent to source
            // lexical arrow captures during its later generator visit.
            try self.deferred_generator_loop_owners.put(self.allocator, @intFromEnum(result.loop_function), {});

            // `var _loopN = function* (x) {…}` 은 대입문으로 접히므로, 이름을 **바깥 함수**
            // 의 var 리스트에 등록해야 한다. 상태 기계가 만들어진 뒤에 생긴 이름이라
            // 일반 호이스팅 스캔(`collectHoistedVars`)에 안 잡힌다 — 등록을 빠뜨리면
            // `ReferenceError: _loop is not defined`.
            const loop_fn_node = self.ast.getNode(result.loop_fn);
            const loop_name_span = blk: {
                const decl_start = self.readU32(loop_fn_node.data.extra, 1);
                const decl_raw = self.ast.extra_data.items[decl_start];
                const declarator = self.ast.getNode(@as(NodeIndex, @enumFromInt(decl_raw)));
                const binding = self.ast.getNode(self.readNodeIdx(declarator.data.extra, 0));
                break :blk binding.data.string_ref;
            };
            // ⚠️ 등록은 **collectVarDeclWithYield 뒤**에 해야 한다. 그 안에서 `_loopN` 의
            // generator 본문이 낮아지며 자기 상태 기계를 만드는데, 먼저 넣어 두면 그
            // 안쪽 리스트로 들어가 `var _loop;` 이 엉뚱한 함수에 선언된다.
            try collectVarDeclWithYield(self, loop_fn_node, ops, next_label);
            try self.generator_temp_var_spans.append(self.allocator, loop_name_span);
            // break/continue/return 신호를 받는 `_ret` 도 같은 이유로 등록한다.
            if (flow.needsRetVar()) {
                try self.generator_temp_var_spans.append(self.allocator, try self.ast.addString(try es_helpers.resolveSyntheticName(self, "_ret")));
            }

            // body 만 교체한 새 루프 노드.
            return switch (stmt.tag) {
                .for_statement => blk: {
                    const e = stmt.data.extra;
                    const new_extra = try self.ast.addExtras(&.{
                        @intFromEnum(self.readNodeIdx(e, 0)),
                        @intFromEnum(self.readNodeIdx(e, 1)),
                        @intFromEnum(self.readNodeIdx(e, 2)),
                        @intFromEnum(result.call_and_check),
                    });
                    break :blk try self.ast.addNode(.{
                        .tag = .for_statement,
                        .span = stmt.span,
                        .data = .{ .extra = new_extra },
                    });
                },
                .for_of_statement, .for_in_statement, .for_await_of_statement => try self.ast.addNode(.{
                    .tag = stmt.tag,
                    .span = stmt.span,
                    .data = .{ .ternary = .{
                        .a = stmt.data.ternary.a,
                        .b = stmt.data.ternary.b,
                        .c = result.call_and_check,
                    } },
                }),
                .while_statement, .do_while_statement => try self.ast.addNode(.{
                    .tag = stmt.tag,
                    .span = stmt.span,
                    .data = .{ .binary = .{ .left = stmt.data.binary.left, .right = result.call_and_check, .flags = stmt.data.binary.flags } },
                }),
                else => .none,
            };
        }

        /// 제어흐름 재작성은 중첩 루프 노드를 복사하지만 헤더 바인딩은 유지한다.
        /// owner가 없는 복사본도 보존된 SymbolId의 선언 스코프로 호출 위치를 정한다.
        fn loopCallScope(self: *Transformer, stmt_idx: NodeIndex, bindings: []const NodeIndex) @import("../semantic/scope.zig").ScopeId {
            if (!self.semantic_edit_enabled) return self.current_scope;
            if (self.scope_owner_map.get(@intFromEnum(stmt_idx)) orelse self.transformed_scope_owner_map.get(@intFromEnum(stmt_idx))) |scope|
                return @enumFromInt(scope);
            for (bindings) |binding| {
                const id = self.getSymbolIdAt(binding) orelse continue;
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                return symbols[id].scope_id;
            }
            return self.current_scope;
        }

        /// for문의 연산 수집.
        fn collectForOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const e = stmt.data.extra;
            const init_idx: NodeIndex = self.readNodeIdx(e, 0);
            const test_idx: NodeIndex = self.readNodeIdx(e, 1);
            const update_idx: NodeIndex = self.readNodeIdx(e, 2);
            const body_idx: NodeIndex = self.readNodeIdx(e, 3);
            // 헤더의 let/const 는 루프 스코프 — 고유 이름으로 바꿔 wrapper 에 등록한다 (#4712).
            try registerLoopHeadBindings(self, init_idx);

            // body 는 statement → hasYieldOrReturn, 헤더 세 칸은 expression → containsYield.
            // ⚠️ init/update 를 빼면 헤더에만 yield 가 있을 때 루프가 상태 기계를 안 타고
            // raw `yield` 가 남아 **산출물이 파싱조차 안 된다** (#4721).
            if (!es2015_scan.hasYieldOrReturn(self, body_idx) and
                !es2015_scan.containsYield(self, test_idx) and
                !es2015_scan.containsYield(self, init_idx) and
                !es2015_scan.containsYield(self, update_idx))
            {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 반복별 바인딩 복원(#4716) — 필요하면 body 를 `yield* _loopN(x)` 로 바꾼 새
            // 노드로 다시 수집한다. 이 검사는 위 early-return **뒤**라, 상태 기계로 접히는
            // 루프에만 적용된다.
            {
                const rewritten = try extractPerIterationLoopBody(self, stmt_idx, stmt, init_idx, body_idx, ops, next_label);
                if (!rewritten.isNone()) {
                    return collectForOperations(self, rewritten, self.ast.getNode(rewritten), ops, next_label);
                }
            }

            // init: var는 호이스팅 후 assignment로 변환, expression은 그대로
            if (!init_idx.isNone()) {
                const init_node = self.ast.getNode(init_idx);
                if (init_node.tag == .variable_declaration) {
                    // var i = 0 → i = 0 (var는 이미 호이스팅됨)
                    try collectVarDeclWithYield(self, init_node, ops, next_label);
                } else {
                    const new_init = try self.visitNode(init_idx);
                    if (!new_init.isNone()) {
                        const init_stmt = try es_helpers.makeExprStmt(self, new_init, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = init_stmt } });
                    }
                }
            }

            // cond_label만 미리 할당. end_label은 body 처리 후 결정 (sentinel+fixup).
            const cond_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // 중첩 루프에서 충돌 방지를 위해 label_stack 깊이 기반 sentinel 사용.
            const depth = self.generator_label_stack.items.len;
            const for_break_sent = breakSentinel(depth);
            const for_continue_sent = continueSentinel(depth);
            const for_ops_start = ops.items.len;

            // test (for_break_sent는 body 처리 후 fixup)
            if (!test_idx.isNone()) {
                const new_test = if (es2015_scan.containsYield(self, test_idx))
                    try visitExprWithYieldExtraction(self, test_idx, ops, next_label)
                else
                    try self.visitNode(test_idx);
                try ops.append(self.allocator, .{
                    .code = .break_when_false,
                    .arg = .{ .label_and_node = .{ .label = for_break_sent, .node = new_test } },
                });
            }

            // unlabeled break/continue를 이 루프로 라우팅. 중첩 루프는 스택으로 분리.
            try self.generator_label_stack.append(self.allocator, .{
                .name = "",
                .break_label = for_break_sent,
                .continue_label = for_continue_sent,
            });
            defer _ = self.generator_label_stack.pop();

            // body
            try collectBodyOperations(self, body_idx, ops, next_label);

            // update (별도 label — continue의 대상)
            const update_label = next_label.*;
            next_label.* += 1;
            self.generator_loop_continue_label = update_label;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark update_label
            if (!update_idx.isNone()) {
                // update 절에도 yield 가 올 수 있다 — 추출하지 않으면 raw `yield` 가
                // 남아 산출물이 파싱되지 않는다 (#4721).
                const new_update = if (es2015_scan.containsYield(self, update_idx))
                    try visitExprWithYieldExtraction(self, update_idx, ops, next_label)
                else
                    try self.visitNode(update_idx);
                if (!new_update.isNone()) {
                    const update_stmt = try es_helpers.makeExprStmt(self, new_update, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = update_stmt } });
                }
            }

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // end_label: body 처리 완료 후 할당
            const end_label = next_label.*;
            next_label.* += 1;

            // fixup: break/continue sentinel → 실제 label
            fixupSentinel(ops.items[for_ops_start..], for_break_sent, end_label);
            fixupSentinel(ops.items[for_ops_start..], for_continue_sent, update_label);

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// for-of/for-in 문의 연산 수집.
        /// for (const x of arr) { yield ... }
        /// → for (var _i = 0, _arr = arr; _i < _arr.length; _i++) { var x = _arr[_i]; yield ... }
        /// for-in은 Object.keys(obj) snapshot을 순회하는 동일한 배열 기반 루프로 낮춘다.
        /// while문의 연산 수집.
        fn collectWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            // body 는 statement → hasYieldOrReturn, condition 은 expression → containsYield 만.
            if (!es2015_scan.hasYieldOrReturn(self, body_idx) and !es2015_scan.containsYield(self, condition)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 본문 선언이 클로저에 캡처되면 반복별로 뽑는다 (#4743).
            {
                const rewritten = try extractPerIterationLoopBody(self, stmt_idx, stmt, .none, body_idx, ops, next_label);
                if (!rewritten.isNone()) return collectWhileOperations(self, rewritten, self.ast.getNode(rewritten), ops, next_label);
            }

            const cond_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            const depth = self.generator_label_stack.items.len;
            const while_break_sent = breakSentinel(depth);
            const ops_start = ops.items.len;

            const new_cond = if (es2015_scan.containsYield(self, condition))
                try visitExprWithYieldExtraction(self, condition, ops, next_label)
            else
                try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = while_break_sent, .node = new_cond } },
            });

            try self.generator_label_stack.append(self.allocator, .{
                .name = "",
                .break_label = while_break_sent,
                .continue_label = cond_label,
            });
            defer _ = self.generator_label_stack.pop();

            // body (yield가 nop를 생성하여 next_label이 증가할 수 있음)
            try collectBodyOperations(self, body_idx, ops, next_label);

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // 바깥 labeled statement 가 `continue <label>` 타겟을 찾을 수 있게 남긴다.
            // for-await 는 여기 while 로 낮아지므로, 그 라벨의 continue 타겟이 곧 이
            // while 의 cond_label(= 다음 `await _iter.next()`) 이다. body 수집 **뒤**에
            // 써야 중첩 루프가 아니라 자기 자신이 마지막에 남는다. (#4710)
            self.generator_loop_continue_label = cond_label;

            // end_label을 body 처리 후에 할당 (yield로 인한 label 증가 반영)
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark end_label

            fixupSentinel(ops.items[ops_start..], while_break_sent, end_label);
        }

        /// break/continue 문의 대상 sentinel을 결정.
        /// labeled → generator_label_stack에서 name 매칭 (없으면 null).
        /// unlabeled → 스택 top에서 가장 가까운 적절한 entry 선택
        ///   · break: 가장 안쪽 루프 또는 switch 진입 시 push된 entry
        ///   · continue: continue_label이 있는 가장 안쪽 loop entry (switch 스킵)
        fn resolveBreakContinueTarget(self: *Transformer, stmt: Node) ?u32 {
            const label_idx = stmt.data.unary.operand;
            const stack = self.generator_label_stack.items;
            if (stack.len == 0) return null;

            if (!label_idx.isNone()) {
                const label_text = self.ast.getText(self.ast.getNode(label_idx).span);
                var i = stack.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, stack[i].name, label_text)) {
                        if (stmt.tag == .continue_statement)
                            return stack[i].continue_label orelse stack[i].break_label;
                        return stack[i].break_label;
                    }
                }
                return null;
            }

            // unlabeled
            if (stmt.tag == .continue_statement) {
                var i = stack.len;
                while (i > 0) {
                    i -= 1;
                    if (stack[i].continue_label) |c| return c;
                }
                return null;
            }
            return stack[stack.len - 1].break_label;
        }

        const LABEL_SENTINEL_BASE = std.math.maxInt(u32);

        // Sentinel reserved ranges (모두 LABEL_SENTINEL_BASE 의 offset). fixupSentinel 가
        // ops_start 이후만 처리하므로 nested scope 끼리는 충돌 안 함.
        //   0..depth*2  → break/continue (nesting depth 별 — `breakSentinel`/`continueSentinel`)
        //   100..       → switch case fall-through (`collectSwitchOperations`)
        //   200         → if-end (`collectIfOperations`)
        //   if-else 는 break_when_false 의 인덱스 직접 patch — sentinel 불필요.
        const IF_END_SENTINEL = LABEL_SENTINEL_BASE - 200;

        /// nesting depth에 따라 고유한 break/continue sentinel 생성.
        /// 중첩 labeled scope에서 sentinel 충돌을 방지.
        fn breakSentinel(depth: usize) u32 {
            return LABEL_SENTINEL_BASE - @as(u32, @intCast(depth * 2));
        }
        fn continueSentinel(depth: usize) u32 {
            return LABEL_SENTINEL_BASE - @as(u32, @intCast(depth * 2)) - 1;
        }

        /// ops 슬라이스에서 sentinel 값을 실제 label로 교체.
        fn fixupSentinel(ops_slice: []Operation, sentinel: u32, actual: u32) void {
            for (ops_slice) |*op| {
                switch (op.code) {
                    .break_op => {
                        if (op.arg == .label and op.arg.label == sentinel) {
                            op.arg = .{ .label = actual };
                        }
                    },
                    .break_when_false, .break_when_true => {
                        if (op.arg == .label_and_node and op.arg.label_and_node.label == sentinel) {
                            op.arg = .{ .label_and_node = .{ .label = actual, .node = op.arg.label_and_node.node } };
                        }
                    },
                    else => {},
                }
            }
        }

        /// labeled statement의 연산 수집.
        /// break/continue label은 body 처리 후에 결정 (sentinel+fixup).
        fn collectLabeledOperations(self: *Transformer, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const label_idx = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            const label_name = if (!label_idx.isNone()) blk: {
                const label_node = self.ast.getNode(label_idx);
                break :blk self.ast.getText(label_node.span);
            } else "";

            const body_node = self.ast.getNode(body_idx);
            const is_loop = body_node.tag == .for_statement or
                body_node.tag == .while_statement or
                body_node.tag == .do_while_statement or
                body_node.tag == .for_in_statement or
                body_node.tag == .for_of_statement or
                // ⚠️ for-await 가 빠져 있었다 (#4710). 빠지면 `continue <label>` 이
                // `continue_label orelse break_label` 로 떨어져 **바깥 루프를 끊는다**.
                body_node.tag == .for_await_of_statement;

            // while 을 제외한 모든 루프(for/for-of/for-in/do-while)는 `continue` 타겟
            // (증분·iterator advance·조건 평가)이 body 수집 *후*에야 정해지므로 sentinel +
            // generator_loop_continue_label 로 지연 fixup 한다. while 만 `continue` = cond_label
            // (루프 최상단)이라 즉시 결정.
            const continue_via_update_label = is_loop and body_node.tag != .while_statement;
            const depth = self.generator_label_stack.items.len;
            const break_sent = breakSentinel(depth);
            const continue_sent = continueSentinel(depth);

            const continue_label: ?u32 = if (!is_loop)
                null
            else if (continue_via_update_label)
                continue_sent // body 처리 후 generator_loop_continue_label 로 fixup
            else
                next_label.*; // while: cond_label

            const ops_start = ops.items.len;
            const saved_update_label = self.generator_loop_continue_label;
            self.generator_loop_continue_label = null;

            try self.generator_label_stack.append(self.allocator, .{
                .name = label_name,
                .break_label = break_sent,
                .continue_label = continue_label,
            });

            try self.label_scope.append(self.allocator, label_name);
            try collectOperations(self, body_idx, ops, next_label);
            _ = self.label_scope.pop();

            _ = self.generator_label_stack.pop();

            const actual_continue = if (continue_via_update_label) self.generator_loop_continue_label orelse @as(u32, 0) else @as(u32, 0);
            self.generator_loop_continue_label = saved_update_label;

            const end_label = next_label.*;
            next_label.* += 1;

            // fixup: break sentinel → end_label, continue sentinel → actual_continue
            const ops_slice = ops.items[ops_start..];
            fixupSentinel(ops_slice, break_sent, end_label);
            if (continue_via_update_label) {
                fixupSentinel(ops_slice, continue_sent, actual_continue);
            }

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// switch문의 연산 수집.
        /// switch(x) { case 1: yield a; break; default: yield b; }
        /// → if-else 체인으로 분해 + 각 case body를 순서대로 배치.
        /// case_labels는 sentinel+fixup으로 body 처리 후 결정.
        fn collectSwitchOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const e = stmt.data.extra;
            const disc_idx: NodeIndex = self.readNodeIdx(e, 0);
            const cases_start_val = self.readU32(e, 1);
            const cases_len_val = self.readU32(e, 2);

            if (!es2015_scan.hasYieldOrReturn(self, stmt_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const new_disc = try self.visitNode(disc_idx);

            // 각 case에 고유 sentinel 할당 (body 처리 후 실제 label로 fixup)
            const sentinel_base = LABEL_SENTINEL_BASE - 100; // 충분히 떨어진 sentinel 영역
            var case_sentinels = try self.allocator.alloc(u32, cases_len_val);
            defer self.allocator.free(case_sentinels);
            var default_case_idx: ?usize = null;

            // Pass 1: sentinel 할당 + default 감지 (visitNode 호출 없음)
            for (0..cases_len_val) |i| {
                case_sentinels[i] = sentinel_base - @as(u32, @intCast(i));

                // default case 감지
                const raw_idx = self.ast.extra_data.items[cases_start_val + i];
                const case_node = self.ast.getNode(@enumFromInt(raw_idx));
                const ce = case_node.data.extra;
                const test_idx: NodeIndex = self.readNodeIdx(ce, 0);
                if (test_idx.isNone()) {
                    default_case_idx = i;
                }
            }

            const end_sentinel = sentinel_base - @as(u32, @intCast(cases_len_val));
            const ops_start = ops.items.len;

            // 분기 코드: if (disc === caseTest) goto case_sentinel
            // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            for (0..cases_len_val) |i| {
                const raw_idx = self.ast.extra_data.items[cases_start_val + i];
                const case_node = self.ast.getNode(@enumFromInt(raw_idx));
                const ce = case_node.data.extra;
                const test_idx: NodeIndex = self.readNodeIdx(ce, 0);

                if (test_idx.isNone()) continue; // default

                const new_test = try self.visitNode(test_idx);
                const eq_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = stmt.span,
                    .data = .{ .binary = .{
                        .left = new_disc,
                        .right = new_test,
                        .flags = @intFromEnum(token_mod.Kind.eq3),
                    } },
                });

                try ops.append(self.allocator, .{
                    .code = .break_when_true,
                    .arg = .{ .label_and_node = .{ .label = case_sentinels[i], .node = eq_check } },
                });
            }

            // default가 있으면 goto default, 없으면 goto end
            if (default_case_idx) |di| {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = case_sentinels[di] } });
            } else {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_sentinel } });
            }

            // 각 case body 출력 + 실제 label 할당
            var actual_labels = try self.allocator.alloc(u32, cases_len_val);
            defer self.allocator.free(actual_labels);

            // visitNode/collectOperations가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            for (0..cases_len_val) |i| {
                // case body 시작 지점에 실제 label 할당
                actual_labels[i] = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                const raw_idx = self.ast.extra_data.items[cases_start_val + i];
                const case_node = self.ast.getNode(@enumFromInt(raw_idx));
                const ce = case_node.data.extra;
                const stmts_s = self.readU32(ce, 1);
                const stmts_l = self.readU32(ce, 2);

                // visitNode/collectOperations가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var j_loop: u32 = 0;
                while (j_loop < stmts_l) : (j_loop += 1) {
                    const case_stmt_raw = self.ast.extra_data.items[stmts_s + j_loop];
                    const case_stmt = self.ast.getNode(@enumFromInt(case_stmt_raw));
                    if (case_stmt.tag == .break_statement and case_stmt.data.unary.operand.isNone()) {
                        try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_sentinel } });
                    } else {
                        try collectOperations(self, @enumFromInt(case_stmt_raw), ops, next_label);
                    }
                }
            }

            // end label
            const actual_end = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            // fixup: sentinel → actual labels
            const ops_slice = ops.items[ops_start..];
            for (case_sentinels, 0..) |sent, i| {
                fixupSentinel(ops_slice, sent, actual_labels[i]);
            }
            fixupSentinel(ops_slice, end_sentinel, actual_end);
        }

        /// do-while문의 연산 수집. body → condition 순서.
        fn collectDoWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            // body 는 statement → hasYieldOrReturn, condition 은 expression → containsYield 만.
            if (!es2015_scan.hasYieldOrReturn(self, body_idx) and !es2015_scan.containsYield(self, condition)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // 본문 선언이 클로저에 캡처되면 반복별로 뽑는다 (#4743).
            {
                const rewritten = try extractPerIterationLoopBody(self, stmt_idx, stmt, .none, body_idx, ops, next_label);
                if (!rewritten.isNone()) return collectDoWhileOperations(self, rewritten, self.ast.getNode(rewritten), ops, next_label);
            }

            const body_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark body_label

            const depth = self.generator_label_stack.items.len;
            const dw_break_sent = breakSentinel(depth);
            const dw_continue_sent = continueSentinel(depth);
            const ops_start = ops.items.len;

            // unlabeled break/continue를 이 do-while로 라우팅.
            try self.generator_label_stack.append(self.allocator, .{
                .name = "",
                .break_label = dw_break_sent,
                .continue_label = dw_continue_sent,
            });
            {
                defer _ = self.generator_label_stack.pop();
                // body
                try collectBodyOperations(self, body_idx, ops, next_label);
            }

            // continue는 condition 평가 지점으로 점프
            const cond_label = next_label.*;
            next_label.* += 1;
            // 라벨된 `continue label;` 도 (unlabeled 와 동일하게) 조건 평가 지점으로 가도록
            // cond_label 을 generator_loop_continue_label 로 노출 — 이전엔 라벨 경로가 body_label 로
            // 잘못 점프해 조건을 재평가하지 않았다 (#4281).
            self.generator_loop_continue_label = cond_label;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // condition → if true, goto body_label
            const new_cond = if (es2015_scan.containsYield(self, condition))
                try visitExprWithYieldExtraction(self, condition, ops, next_label)
            else
                try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_true,
                .arg = .{ .label_and_node = .{ .label = body_label, .node = new_cond } },
            });

            // end label (break 대상)
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            fixupSentinel(ops.items[ops_start..], dw_break_sent, end_label);
            fixupSentinel(ops.items[ops_start..], dw_continue_sent, cond_label);
        }

        /// try/catch/finally 안의 yield를 상태 머신으로 변환.
        /// try_statement: ternary { a=block, b=catch_clause, c=finally_block }
        /// catch_clause: binary { left=param, right=body }
        ///
        /// 변환 패턴:
        ///   _state.trys.push([try_label, catch_label, finally_label, end_label])
        ///   try body → yield points
        ///   goto end
        ///   catch: param = _state.sent(); catch body
        ///   finally: finally body + return [7] (endfinally)
        fn collectTryOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const try_body = stmt.data.ternary.a;
            const catch_clause = stmt.data.ternary.b;
            const finally_body = stmt.data.ternary.c;

            // try/catch/finally body 모두 statement → hasYieldOrReturn 으로 일관.
            const requires_lowering = es2015_scan.hasYieldOrReturn(self, try_body) or
                es2015_scan.hasYieldOrReturn(self, catch_clause) or
                es2015_scan.hasYieldOrReturn(self, finally_body);

            // yield/await 없이도 return은 __generator callback 안에서 raw return으로
            // 남으면 안 된다. __generator body는 [op, value] instruction을 반환해야
            // 하므로 try/catch/finally 안 return도 state-machine op로 수집한다.
            if (!requires_lowering) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // try_label = 현재 case 번호. next_label은 1에서 시작하고
            // 각 nop append 직전에 +1되므로, next_label - 1 == 현재 case 번호.
            const try_label = next_label.* - 1;

            // trys.push placeholder — body 처리 후 실제 label로 교체
            const trys_push_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = .none } });

            try collectBodyOperations(self, try_body, ops, next_label);

            const catch_label: ?u32 = if (!catch_clause.isNone()) blk: {
                const label = next_label.*;
                next_label.* += 1;
                break :blk label;
            } else null;

            // try body 끝 break placeholder
            const try_break_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = 0 } });

            if (!catch_clause.isNone()) {
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                const catch_node = self.ast.getNode(catch_clause);
                const catch_param = catch_node.data.binary.left;
                const catch_body_idx = catch_node.data.binary.right;

                // catch 파라미터를 고유 이름으로 — 상태 기계는 wrapper 최상단 var 로 올리므로
                // 원래 이름이면 바깥 동명 바인딩·중첩 catch 의 같은 이름을 덮는다 (#4712).
                var param_bindings: std.ArrayList(NodeIndex) = .empty;
                defer param_bindings.deinit(self.allocator);
                if (!catch_param.isNone()) try collectBindingNodes(self, catch_param, &param_bindings);
                // 컴파일러가 만든 catch 임시 변수(for-of 닫기의 `_f` 등)는 이미 wrapper 에 등록된
                // 고유 이름이라 바꿀 필요가 없다.
                if (param_bindings.items.len == 1 and isRegisteredGeneratorTemp(self, self.ast.getText(self.ast.getNode(param_bindings.items[0]).span))) param_bindings.clearRetainingCapacity();
                try registerStateMachineBindings(self, param_bindings.items);

                const param_is_pattern = !catch_param.isNone() and self.ast.getNode(catch_param).tag != .binding_identifier;
                if (param_is_pattern) {
                    // `catch ({ message })` — 받은 값을 임시 변수에 담고 `let <패턴> = 임시변수` 를
                    // 일반 선언 수집으로 넘긴다. 패턴을 대입 좌변에 그대로 쓰면 (a) es5 에 구조분해
                    // 문법이 남고 (b) 축약형 키가 리네임되고 (c) minify 가 값 자리를 선언과 연결하지
                    // 못한다. 선언 경로는 셋 다 처리한다 (#4712).
                    const tmp = try es_helpers.makeTempVarSpan(self);
                    try self.generator_temp_var_spans.append(self.allocator, tmp);
                    try appendAssignTempStmt(self, ops, tmp, try buildSentCall(self, stmt.span), stmt.span);
                    const decl = try es_helpers.makeVarDeclaration(self, &.{
                        try es_helpers.makeDeclarator(self, catch_param, try es_helpers.makeTempVarRef(self, tmp, tmp), stmt.span),
                    }, .let, stmt.span);
                    try collectVarDeclWithYield(self, self.ast.getNode(decl), ops, next_label);
                } else if (!catch_param.isNone()) {
                    const visited_param = try self.visitNode(catch_param);
                    // `catch (e) {…}` → `case N: e = _state.sent();` 로 접을 때, catch 의
                    // **바인딩** 노드를 그대로 대입 좌변에 재사용하면 안 된다. 좌변은 선언이
                    // 아니라 **참조**다. 소스에서 온 catch param 은 스코프 분석이 이미 등록해
                    // 둬서 우연히 해석되지만, 트랜스포머가 합성한 temp(예: for-await 의 `_e`)는
                    // 분석 이후에 만들어져 바인딩 노드가 심볼로 해석되지 않는다 → minify 때
                    // 호이스트된 `var` 선언만 리네임되고 이 좌변은 원래 이름으로 남아
                    // `ReferenceError: _e is not defined` (#4703).
                    const new_param = try bindingToAssignTarget(self, visited_param);
                    const sent = try buildSentCall(self, stmt.span);
                    const assign = try self.ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = stmt.span,
                        .data = .{ .binary = .{ .left = new_param, .right = sent, .flags = 0 } },
                    });
                    const assign_stmt = try es_helpers.makeExprStmt(self, assign, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                }

                try collectBodyOperations(self, catch_body_idx, ops, next_label);
            }

            // catch body 끝 break placeholder
            const catch_break_slot: ?usize = if (!catch_clause.isNone()) blk: {
                const slot = ops.items.len;
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = 0 } });
                break :blk slot;
            } else null;

            var finally_label: ?u32 = null;
            if (!finally_body.isNone()) {
                finally_label = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                try collectBodyOperations(self, finally_body, ops, next_label);

                const endfinally_ret = try buildInstructionReturn(self, 7, .none, stmt.span);
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = endfinally_ret } });
            }

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            // fixup: try/catch body 끝 → 항상 end_label로 break.
            // finally가 있으면 __generator 런타임이 _.label < t[2] 체크로
            // finally로 자동 우회 + _.ops.push(op)로 원래 목적지 보존.
            ops.items[try_break_slot] = .{ .code = .break_op, .arg = .{ .label = end_label } };
            if (catch_break_slot) |slot| {
                ops.items[slot] = .{ .code = .break_op, .arg = .{ .label = end_label } };
            }

            const trys_push = try buildTrysPush(self, try_label, catch_label, finally_label, end_label, stmt.span);
            ops.items[trys_push_slot] = .{ .code = .statement, .arg = .{ .node = trys_push } };
        }

        /// _state.trys.push([try_label, catch_label, finally_label, end_label]) expression_statement 생성.
        /// finally_label이 null이면 void 0을 출력하여 런타임의 _.label < t[2] 체크를 skip시킨다.
        fn buildTrysPush(self: *Transformer, try_label: u32, catch_label: ?u32, finally_label: ?u32, end_label: u32, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try makePendingStateRef(self);

            // _state.trys
            const trys_prop = try es_helpers.makePropertyName(self, "trys");
            const trys_member = try es_helpers.makeStaticMember(self, state_ref, trys_prop, span);

            // _state.trys.push
            const push_prop = try es_helpers.makePropertyName(self, "push");
            const push_member = try es_helpers.makeStaticMember(self, trys_member, push_prop, span);

            // [try_label, catch_label, finally_label, end_label] 배열 (TypeScript __generator 스펙)
            const n0 = try es_helpers.makeNumericLiteral(self, try_label);
            const n1 = if (catch_label) |cl|
                try es_helpers.makeNumericLiteral(self, cl)
            else
                try es_helpers.makeVoidZero(self, span);
            const n2 = if (finally_label) |fl|
                try es_helpers.makeNumericLiteral(self, fl)
            else
                try es_helpers.makeVoidZero(self, span);
            const n3 = try es_helpers.makeNumericLiteral(self, end_label);
            const arr_list = try self.ast.addNodeList(&.{ n0, n1, n2, n3 });
            const arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_list },
            });

            // _state.trys.push([...])
            const call = try es_helpers.makeCallExpr(self, push_member, &.{arr}, span);
            return es_helpers.makeExprStmt(self, call, span);
        }

        /// generator body에서 모든 var 선언의 binding name을 수집 (호이스팅).
        /// let/const는 block-scoped이므로 호이스팅하지 않음 (ES2015 변환에서 var로 바뀌므로 포함).
        /// destructuring 패턴은 개별 identifier로 분해하여 호이스팅.
        /// (var {a, b} = expr → var a, b; 로 호이스팅. var {a, b}; 는 문법 에러)
        fn collectHoistedVarsRange(self: *Transformer, stmts_start: u32, stmts_len: u32, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            // 모든 stmt 를 collectHoistedVarFromNode 에 위임 — single source of truth
            // (이전엔 두 함수가 별도 case 분기 가지고 있어 변경 시 한쪽만 update 되어 누락
            // 발생. #1901 의 for_await_of 가 그 예).
            var i_loop: u32 = 0;
            while (i_loop < stmts_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[stmts_start + i_loop];
                try collectHoistedVarFromNode(self, @enumFromInt(raw_idx), hoisted);
            }
        }

        /// 단일 노드에서 호이스팅할 var를 수집 (block이면 재귀).
        fn collectHoistedVarFromNode(self: *Transformer, idx: NodeIndex, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (idx.isNone()) return;
            const node = self.ast.getNode(idx);
            if (node.tag == .block_statement) {
                // 중첩 블록의 let/const 는 블록 스코프다 — 원래 이름 그대로 wrapper 최상단에
                // 올리면 바깥 동명 바인딩을 가린다. 상태 기계가 그 블록을 실제로 수집할 때
                // 고유 이름으로 바꿔 등록한다(`registerStateMachineBindings`). 수집하지 않는 블록은
                // 일반 방문이 블록 스코핑 규칙대로 처리한다 (#4712).
                var i: u32 = 0;
                while (i < node.data.list.len) : (i += 1) {
                    const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.list.start + i]);
                    if (stateMachineRenamesBlockScope(self) and isLexicalDeclaration(self, child)) continue;
                    try collectHoistedVarFromNode(self, child, hoisted);
                }
            } else if (node.tag == .function_body) {
                try collectHoistedVarsRange(self, node.data.list.start, node.data.list.len, hoisted);
            } else if (node.tag == .variable_declaration) {
                // for-in/for-of의 left가 variable_declaration인 경우
                const e = node.data.extra;
                const list_start = self.readU32(e, 1);
                const list_len = self.readU32(e, 2);
                // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var j_loop: u32 = 0;
                while (j_loop < list_len) : (j_loop += 1) {
                    const decl_raw = self.ast.extra_data.items[list_start + j_loop];
                    const decl = self.ast.getNode(@enumFromInt(decl_raw));
                    if (decl.tag != .variable_declarator) continue;
                    const binding: NodeIndex = self.readNodeIdx(decl.data.extra, 0);
                    if (!binding.isNone()) {
                        try collectBindingIdentifiers(self, binding, hoisted);
                    }
                }
            } else if (node.tag == .labeled_statement) {
                try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
            } else if (node.tag == .for_statement) {
                const e = node.data.extra;
                // 헤더의 let/const 는 상태 기계가 루프를 수집할 때 리네임·등록한다 (#4712).
                if (!stateMachineRenamesBlockScope(self) or !isLexicalDeclaration(self, self.readNodeIdx(e, 0))) try collectHoistedVarFromNode(self, self.readNodeIdx(e, 0), hoisted);
                try collectHoistedVarFromNode(self, self.readNodeIdx(e, 3), hoisted);
            } else if (node.tag == .while_statement or node.tag == .do_while_statement) {
                try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
            } else if (node.tag == .for_in_statement or node.tag == .for_of_statement) {
                if (!stateMachineRenamesBlockScope(self) or !isLexicalDeclaration(self, node.data.ternary.a)) try collectHoistedVarFromNode(self, node.data.ternary.a, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            } else if (node.tag == .if_statement) {
                try collectHoistedVarFromNode(self, node.data.ternary.b, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            } else if (node.tag == .try_statement) {
                // try.a = try block, try.b = catch_clause, try.c = finalizer block.
                try collectHoistedVarFromNode(self, node.data.ternary.a, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.b, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            } else if (node.tag == .catch_clause) {
                // catch 파라미터는 블록 스코프다 — 여기서 원래 이름으로 올리면 바깥 동명
                // 바인딩을 가린다(yield 없는 평범한 catch 까지). 상태 기계가 catch 를 수집할
                // 때 고유 이름으로 바꿔 등록한다 (#4712).
                if (!stateMachineRenamesBlockScope(self) and !node.data.binary.left.isNone()) {
                    try collectBindingIdentifiers(self, node.data.binary.left, hoisted);
                }
                try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
            } else if (node.tag == .switch_statement) {
                // switch_statement: extra = [discriminant, cases.start, cases.len].
                // 이전엔 `node.data.binary.right` 로 access 했지만 switch_statement 의 data
                // kind 는 .extra — binary.right 는 union padding 영역의 undefined 값. main
                // 에선 우연히 valid index 였지만 새 AST tag 추가 시 padding 변동으로 panic.
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 < extras.len) {
                    const cases_start = extras[e + 1];
                    const cases_len = extras[e + 2];
                    var i: u32 = 0;
                    while (i < cases_len) : (i += 1) {
                        try collectHoistedVarFromNode(self, @enumFromInt(extras[cases_start + i]), hoisted);
                    }
                }
            } else if (node.tag == .for_await_of_statement) {
                // ternary.a = left (var 헤더만 — lexical 은 풀이 후 본문 선언이라 수집 때 리네임),
                // c = body. 풀이의 임시 변수는 초기값 있는 var 라 선언 수집이 등록한다 (#4746).
                if (!stateMachineRenamesBlockScope(self) or !isLexicalDeclaration(self, node.data.ternary.a)) try collectHoistedVarFromNode(self, node.data.ternary.a, hoisted);
                try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
            }
        }

        /// binding 패턴에서 모든 binding_identifier를 추출.
        /// destructuring 패턴(object_pattern, array_pattern)은 재귀적으로 분해.
        /// `var {a, b}` → `var a, b` (destructuring 없이 개별 identifier로 호이스팅)
        fn collectBindingIdentifiers(self: *Transformer, binding_idx: NodeIndex, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (binding_idx.isNone()) return;
            const node = self.ast.getNode(binding_idx);
            switch (node.tag) {
                .binding_identifier => {
                    const new_binding = try self.visitNode(binding_idx);
                    try hoisted.append(self.allocator, new_binding);
                },
                .object_pattern => {
                    const props_start = node.data.list.start;
                    const split = self.ast.nodeListSplitRest(node.data.list);
                    const non_rest_len: u32 = @intCast(split.elements.len);
                    // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                    var p_loop: u32 = 0;
                    while (p_loop < non_rest_len) : (p_loop += 1) {
                        const raw_idx = self.ast.extra_data.items[props_start + p_loop];
                        const prop = self.ast.getNode(@enumFromInt(raw_idx));
                        if (prop.tag == .binding_property) {
                            // {key: value} → value 쪽에서 identifier 추출
                            try collectBindingIdentifiers(self, prop.data.binary.right, hoisted);
                        } else if (prop.tag == .assignment_pattern) {
                            // {x = default} → x
                            try collectBindingIdentifiers(self, prop.data.binary.left, hoisted);
                        }
                    }
                    if (split.rest_operand) |op| {
                        try collectBindingIdentifiers(self, op, hoisted);
                    }
                },
                .array_pattern => {
                    const elems_start = node.data.list.start;
                    const split = self.ast.nodeListSplitRest(node.data.list);
                    const non_rest_len: u32 = @intCast(split.elements.len);
                    // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                    var e_loop: u32 = 0;
                    while (e_loop < non_rest_len) : (e_loop += 1) {
                        const raw_idx = self.ast.extra_data.items[elems_start + e_loop];
                        const elem_idx: NodeIndex = @enumFromInt(raw_idx);
                        if (elem_idx.isNone()) continue; // array hole
                        // `[a, , b]` 의 빈 칸은 `.elision` 노드다 — 이름이 없다. `else => unreachable`
                        // 로 떨어지면 릴리스 빌드에서 빈 이름이 들어가 `var a,,b` 가 된다 (#4791).
                        if (self.ast.getNode(elem_idx).tag == .elision) continue;
                        try collectBindingIdentifiers(self, elem_idx, hoisted);
                    }
                    if (split.rest_operand) |op| {
                        try collectBindingIdentifiers(self, op, hoisted);
                    }
                },
                .assignment_pattern => {
                    // [x = default] → x
                    try collectBindingIdentifiers(self, node.data.binary.left, hoisted);
                },
                // 외부 첫 호출이 직접 rest 노드일 수 있는 경로 안전망 (함수 파라미터 등).
                .rest_element, .binding_rest_element => {
                    try collectBindingIdentifiers(self, node.data.unary.operand, hoisted);
                },
                else => unreachable,
            }
        }

        /// assignment_expression을 expression_statement로 만들되,
        /// object_pattern이 좌변이면 괄호로 감싸서 block statement와 구분.
        /// ({a, b} = expr); vs {a, b} = expr; (후자는 syntax error)
        ///
        /// ES2015 destructuring 이 unsupported 면 binding pattern 좌변을
        /// `(_ref = rhs, x = _ref.x, ..., _ref)` sequence expression 으로 분해해
        /// ES5 호환 statement 로 변환 (#1960). state machine 이 만든 binding pattern
        /// LHS 는 visitNode 트래버설을 거치지 않아 일반 destructuring lowering 이
        /// 도달하지 못하므로 emit 시점에 명시적으로 호출.
        fn makeDestructuringAssignStmt(self: *Transformer, lhs: NodeIndex, rhs: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const lhs_node = self.ast.getNode(lhs);
            // 구조분해가 native 인 타겟(Hermes 등)에서도 단순 대입으로 낮춘다. 바인딩 패턴을
            // 대입 좌변에 그대로 두면 minify 의 스코프 재해석이 패턴 안을 **선언**으로 봐서,
            // 호이스트된 선언만 맹글되고 대입 대상은 원래 이름으로 남는다(블록 바인딩이
            // `x$N` 으로 리네임될 때 드러남, #4712).
            if (lhs_node.tag == .object_pattern or lhs_node.tag == .array_pattern) {
                const Es2015D = es2015_destructuring.ES2015Destructuring(Transformer);
                const seq = try Es2015D.lowerBindingPatternAssignment(self, lhs_node, rhs, span);
                return es_helpers.makeExprStmt(self, seq, span);
            }
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = lhs, .right = rhs, .flags = 0 } },
            });
            // object_pattern assign 의 paren 은 precedence 재유도가 처리 (#4042 PR8)
            return es_helpers.makeExprStmt(self, assign, span);
        }

        /// yield가 있는 variable_declaration의 각 declarator를 개별 연산으로 변환.
        /// var x = yield 1 → yield 1 (op) + x = _state.sent() (op)
        /// var x = expr (no yield) → x = expr (statement op)
        fn collectVarDeclWithYield(self: *Transformer, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const e = stmt.data.extra;
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);

            // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < list_len) : (i_loop += 1) {
                const decl_raw = self.ast.extra_data.items[list_start + i_loop];
                const decl = self.ast.getNode(@enumFromInt(decl_raw));
                if (decl.tag != .variable_declarator) continue;

                const binding: NodeIndex = self.readNodeIdx(decl.data.extra, 0);
                const init_idx: NodeIndex = self.readNodeIdx(decl.data.extra, 2);

                if (init_idx.isNone()) continue;

                const init_node = self.ast.getNode(init_idx);
                if (init_node.tag == .yield_expression or init_node.tag == .await_expression) {
                    // var x = yield/await value → yield value + x = _state.sent()
                    const yield_val = init_node.data.unary.operand;
                    const new_val = try visitExprWithYieldExtraction(self, yield_val, ops, next_label);
                    try ops.append(self.allocator, .{ .code = yieldOpCodeFor(init_node), .arg = .{ .node = new_val } });
                    next_label.* += 1;
                    try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                    // x = _state.sent()
                    const new_binding = try bindingToAssignTarget(self, try self.visitNode(binding));
                    const sent_call = try buildSentCall(self, stmt.span);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, sent_call, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                } else if (es2015_scan.containsYield(self, init_idx)) {
                    // var x = foo(await y) → 중첩 yield 추출 후 x = foo(_state.sent())
                    const new_binding = try bindingToAssignTarget(self, try self.visitNode(binding));
                    const new_init = try visitExprWithYieldExtraction(self, init_idx, ops, next_label);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, new_init, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                } else {
                    // var x = expr (no yield) → x = expr
                    const new_binding = try bindingToAssignTarget(self, try self.visitNode(binding));
                    const new_init = try self.visitNode(init_idx);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, new_init, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                }

                // `var` 는 대입으로 접혔으니 이름을 **바깥 함수** var 리스트에 등록한다 (#4722).
                // 소스에 있던 선언은 사전 스캔(collectHoistedVars)이 이미 잡지만, 다른 lowering
                // 이 **만들어 낸** 선언(예: 일반 경로 for-of 의 `var _loop = function* …`)은
                // 그 스캔 이후에 생겨 빠진다 → `ReferenceError: _loop is not defined`.
                // 중복은 buildHoistedVarDecl 이 이름으로 걸러 낸다. 등록은 init visit **뒤**
                // (그 안에서 다른 상태 기계가 만들어질 수 있다 — #4716).
                // 블록 스코프 바인딩이 `x$N` 으로 바뀌었으면 바뀐 이름을 등록한다 — 원래 이름을
                // 올리면 바깥 동명 바인딩을 가린다 (#4712).
                const bnode = self.ast.getNode(binding);
                if (bnode.tag == .binding_identifier) {
                    const span_to_declare = if (self.renamedNameOf(binding)) |renamed| try self.ast.addString(renamed) else bnode.data.string_ref;
                    try registerGeneratorVar(self, span_to_declare, binding);
                }
            }
        }

        /// 선언 바인딩을 **대입 좌변**으로 쓸 수 있는 노드로 바꾼다. (#4703 · #4716)
        ///
        /// 상태 기계는 `var x = init` 을 `x = init` 으로 접는다. 이때 좌변은 선언이 아니라
        /// **참조**다. 소스에서 온 이름은 스코프 분석이 이미 등록해 둬서 바인딩 노드
        /// 그대로도 우연히 해석되지만, 트랜스포머가 합성한 이름(`_loopN`, `_ret`,
        /// for-await 의 `_e` …)은 분석 이후에 생겨 해석되지 않는다 → minify 때 호이스트된
        /// `var` 선언만 리네임되고 좌변만 원래 이름으로 남아 `ReferenceError`.
        /// 구조분해 패턴은 바인딩 노드가 아니므로 그대로 둔다 — 상태 기계의 구조분해 대입은
        /// `makeDestructuringAssignStmt` 가 항상 단순 대입으로 낮춘다.
        fn bindingToAssignTarget(self: *Transformer, binding: NodeIndex) Transformer.Error!NodeIndex {
            if (binding.isNone()) return binding;
            const node = self.ast.getNode(binding);
            if (node.tag != .binding_identifier) return binding;
            return self.makeIdentifierRefWithSymbol(node.data.string_ref, binding);
        }

        /// 클래스 **헤더**(extends 식 · computed 키)를 소스 순서대로 temp 에 미리 평가하고,
        /// 그 자리를 temp 참조로 바꾼 **새 클래스 노드**를 돌려준다(아직 visit 안 함). (#4723)
        ///
        /// es5 는 클래스를 `(function () { var _a = <키>; … })()` IIFE 로 낮춘다. 키 식에
        /// `yield` 가 있으면 그대로 IIFE — 새 함수 — 안으로 들어가 raw `yield` 가 남고
        /// **산출물이 파싱조차 안 된다**. 그래서 상태 기계 쪽에서 키를 먼저 꺼내 둔다.
        ///
        /// yield 가 없는 키도 **같이** temp 로 뺀다 — 일부만 빼면 `[f()]` 와 `[yield x]` 의
        /// 평가 순서가 뒤바뀐다(스펙: heritage → 멤버 키, 소스 순서).
        fn extractClassHeaderYields(self: *Transformer, class_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const class_node = self.ast.getNode(class_idx);
            const ce = class_node.data.extra;
            var class_slots: [8]u32 = undefined;
            for (0..8) |k| class_slots[k] = self.ast.extra_data.items[ce + k];

            // 1. extends 식
            const super_idx: NodeIndex = @enumFromInt(class_slots[ast_mod.ClassExtra.super]);
            if (!super_idx.isNone()) {
                class_slots[ast_mod.ClassExtra.super] = @intFromEnum(try evalIntoGeneratorTemp(self, super_idx, ops, next_label));
            }

            // 2. 멤버의 computed 키 (소스 순서)
            const body_idx: NodeIndex = @enumFromInt(class_slots[ast_mod.ClassExtra.body]);
            if (!body_idx.isNone()) {
                const body = self.ast.getNode(body_idx);
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                var i: u32 = 0;
                while (i < body.data.list.len) : (i += 1) {
                    // evalIntoGeneratorTemp 가 extra_data 를 재할당할 수 있으므로 매번 다시 읽는다.
                    const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[body.data.list.start + i]);
                    try self.scratch.append(self.allocator, try rewriteMemberComputedKey(self, member_idx, ops, next_label));
                }
                const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_body = try self.ast.addNode(.{ .tag = .class_body, .span = body.span, .data = .{ .list = new_list } });
                class_slots[ast_mod.ClassExtra.body] = @intFromEnum(new_body);
            }

            const new_extra = try self.ast.addExtras(&class_slots);
            return self.ast.addNode(.{ .tag = class_node.tag, .span = class_node.span, .data = .{ .extra = new_extra } });
        }

        /// 멤버의 key 가 computed 면 그 식을 temp 로 평가해 `[_t]` 로 바꾼 새 멤버를 돌려준다.
        fn rewriteMemberComputedKey(self: *Transformer, member_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const member = self.ast.getNode(member_idx);
            const slot_count: usize = switch (member.tag) {
                .method_definition => 6, // MethodExtra: key, params, body, flags, deco_start, deco_len
                .property_definition, .accessor_property => 5, // PropertyExtra: key, init, flags, deco_start, deco_len
                else => return member_idx,
            };
            const me = member.data.extra;
            const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
            if (key_idx.isNone() or self.ast.getNode(key_idx).tag != .computed_property_key) return member_idx;

            const key_node = self.ast.getNode(key_idx);
            const temp_ref = try evalIntoGeneratorTemp(self, key_node.data.unary.operand, ops, next_label);
            const new_key = try self.ast.addNode(.{
                .tag = .computed_property_key,
                .span = key_node.span,
                .data = .{ .unary = .{ .operand = temp_ref, .flags = key_node.data.unary.flags } },
            });

            var slots: [6]u32 = undefined;
            for (0..slot_count) |k| slots[k] = self.ast.extra_data.items[me + k];
            slots[0] = @intFromEnum(new_key);
            const new_extra = try self.ast.addExtras(slots[0..slot_count]);
            return self.ast.addNode(.{ .tag = member.tag, .span = member.span, .data = .{ .extra = new_extra } });
        }

        /// 식을 (yield 추출을 거쳐) 평가해 resume 사이에 살아남는 temp 에 담고 그 참조를 돌려준다.
        fn evalIntoGeneratorTemp(self: *Transformer, expr_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const value = try visitExprWithYieldExtraction(self, expr_idx, ops, next_label);
            const temp_span = try es_helpers.makeTempVarSpan(self);
            try self.generator_temp_var_spans.append(self.allocator, temp_span);
            const lhs = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = temp_span,
                .data = .{ .binary = .{ .left = lhs, .right = value, .flags = 0 } },
            });
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = try es_helpers.makeExprStmt(self, assign, temp_span) } });
            return es_helpers.makeTempVarRef(self, temp_span, temp_span);
        }

        /// expression body (arrow function 등)를 state machine으로 변환.
        /// expression을 implicit return으로 처리.
        /// expression 내부의 yield/await를 별도 yield operation으로 추출하고
        /// 해당 위치를 _state.sent()로 치환한 expression을 반환.
        /// 조건식(if, while, for test) 등에서 yield/await가 중첩된 경우 사용.
        fn visitExprWithYieldExtraction(self: *Transformer, expr_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            if (expr_idx.isNone()) return .none;
            const node = self.ast.getNode(expr_idx);

            // yield/await → yield operation 추출 + temp 변수에 결과 저장
            // 하나의 expression에 여러 yield가 있으면 각 결과를 temp에 저장해야 함
            if (node.tag == .yield_expression or node.tag == .await_expression) {
                const value_idx = node.data.unary.operand;
                const new_value = if (!value_idx.isNone())
                    try visitExprWithYieldExtraction(self, value_idx, ops, next_label)
                else
                    NodeIndex.none;
                try ops.append(self.allocator, .{ .code = yieldOpCodeFor(node), .arg = .{ .node = new_value } });
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                // temp 변수에 _state.sent() 결과 저장
                // temp_span을 node.span 대신 사용 — 번들러에서 다른 모듈의 source span과 충돌 방지
                const temp_span = try es_helpers.makeTempVarSpan(self);
                // 임시 변수를 호이스팅 리스트에 등록 — 기존엔 외부 binding (var x = await ...)
                // 이 있을 때만 hoist 됐지만, nested await 또는 for-await-of 의 cond 안 await
                // (#1901) 의 경우 외부 binding 이 없어서 temp 가 어디에도 declare 안 됐음.
                try self.generator_temp_var_spans.append(self.allocator, temp_span);
                const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
                const sent_call = try buildSentCall(self, temp_span);
                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = temp_span,
                    .data = .{ .binary = .{ .left = temp_ref, .right = sent_call, .flags = 0 } },
                });
                const assign_stmt = try es_helpers.makeExprStmt(self, assign, temp_span);
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                return es_helpers.makeTempVarRef(self, temp_span, temp_span);
            }

            // yield를 포함하지 않으면 일반 visit
            if (!es2015_scan.containsYield(self, expr_idx)) {
                return self.visitNode(expr_idx);
            }

            // parenthesized_expression: 내부 재귀. paren 은 precedence 재유도가 처리 (#4042 PR8)
            if (node.tag == .parenthesized_expression) {
                return visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
            }

            // TS/Flow 타입 wrapper 는 런타임상 noop 이므로 통과한다. 그러지 않으면 타입 스트립
            // 이후 `(await x) as T` 가 추출되지 못한 raw `(yield x)` 로 남는다.
            if (Tag.isTransparentTypeWrapper(node.tag)) {
                return visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
            }

            // computed key 는 `computed_property_key` 래퍼 안에 있다. 래퍼를 유지한 채
            // 안쪽만 추출해야 `{ [_a]: 2 }` 로 나온다 (#4721).
            // 객체 리터럴 메서드/접근자: 본문은 별도 스코프지만 computed 키는 이 문맥에서
            // 평가된다 — 키만 추출하고 나머지는 평소대로 visit (#4723).
            if (node.tag == .method_definition) {
                const me = node.data.extra;
                const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
                if (!key_idx.isNone() and self.ast.getNode(key_idx).tag == .computed_property_key) {
                    const new_key = try visitExprWithYieldExtraction(self, key_idx, ops, next_label);
                    var slots: [6]u32 = undefined;
                    for (0..6) |k| slots[k] = self.ast.extra_data.items[me + k];
                    slots[0] = @intFromEnum(new_key);
                    const new_extra = try self.ast.addExtras(&slots);
                    return self.visitNode(try self.ast.addNode(.{ .tag = .method_definition, .span = node.span, .data = .{ .extra = new_extra } }));
                }
            }

            // 클래스 식: 헤더의 yield 를 먼저 꺼낸 뒤 평소대로 낮춘다 (#4723).
            if (node.tag == .class_expression) {
                return self.visitNode(try extractClassHeaderYields(self, expr_idx, ops, next_label));
            }

            if (node.tag == .computed_property_key) {
                const new_inner = try visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
                return self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = new_inner, .flags = node.data.unary.flags } },
                });
            }

            // logical expression: short-circuit / nullish lazy branch 보존.
            if (node.tag == .logical_expression) {
                const op_kind: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                switch (op_kind) {
                    .amp2, .pipe2, .question2 => return lowerLogicalExprWithYieldExtraction(self, node, ops, next_label, op_kind),
                    else => {},
                }
            }

            // binary expression: 양쪽 재귀
            if (node.tag == .binary_expression) {
                const new_left = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
                const new_right = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = node.data.binary.flags } },
                });
            }

            // conditional expression (ternary): a ? b : c
            if (node.tag == .conditional_expression) {
                return lowerConditionalExprWithYieldExtraction(self, node, ops, next_label);
            }

            // sequence expression: a(), await b(), c()
            // 앞쪽 expression은 순서 보존을 위해 statement operation으로 먼저 방출하고,
            // 마지막 expression만 원래 expression 자리의 값으로 반환한다.
            if (node.tag == .sequence_expression) {
                const list_start = node.data.list.start;
                const list_len = node.data.list.len;
                if (list_len == 0) return self.visitNode(expr_idx);

                var i_seq: u32 = 0;
                while (i_seq < list_len) : (i_seq += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start + i_seq]);
                    const is_last = i_seq + 1 == list_len;
                    const new_elem = if (es2015_scan.containsYield(self, elem_idx))
                        try visitExprWithYieldExtraction(self, elem_idx, ops, next_label)
                    else
                        try self.visitNode(elem_idx);

                    if (is_last) return new_elem;
                    if (!new_elem.isNone()) {
                        const elem_node = self.ast.getNode(elem_idx);
                        const stmt = try es_helpers.makeExprStmt(self, new_elem, elem_node.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = stmt } });
                    }
                }
                return .none;
            }

            // unary/update expression: extra = [operand, operator_and_flags]
            if (node.tag == .unary_expression or node.tag == .update_expression) {
                const e = node.data.extra;
                const operand_idx: NodeIndex = self.readNodeIdx(e, 0);
                const op_flags = self.readU32(e, 1);
                const new_operand = try visitExprWithYieldExtraction(self, operand_idx, ops, next_label);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_operand),
                    op_flags, // operator_and_flags
                });
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // assignment expression: left = right
            if (node.tag == .assignment_expression) {
                const new_left = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
                const new_right = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
                return self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = node.data.binary.flags } },
                });
            }

            // extra = [child0, child1, flags] — member expression, tagged template
            if (node.tag == .static_member_expression or node.tag == .computed_member_expression or
                node.tag == .tagged_template_expression)
            {
                const e = node.data.extra;
                const child0_idx: NodeIndex = self.readNodeIdx(e, 0);
                const child1_idx: NodeIndex = self.readNodeIdx(e, 1);
                const flags = self.readU32(e, 2);
                const new_child0 = try visitExprWithYieldExtraction(self, child0_idx, ops, next_label);
                const new_child1 = try visitExprWithYieldExtraction(self, child1_idx, ops, next_label);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_child0),
                    @intFromEnum(new_child1),
                    flags,
                });
                return self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // call/new expression: callee + args 재귀
            if (node.tag == .call_expression or node.tag == .new_expression) {
                const e = node.data.extra;
                const callee_idx: NodeIndex = self.readNodeIdx(e, 0);
                const args_start = self.readU32(e, 1);
                const args_len = self.readU32(e, 2);
                const call_flags = self.readU32(e, 3);

                const new_callee = try visitExprWithYieldExtraction(self, callee_idx, ops, next_label);

                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                // visitExprWithYieldExtraction이 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var i_arg: u32 = 0;
                while (i_arg < args_len) : (i_arg += 1) {
                    const arg_raw = self.ast.extra_data.items[args_start + i_arg];
                    const new_arg = try visitExprWithYieldExtraction(self, @enumFromInt(arg_raw), ops, next_label);
                    try self.scratch.append(self.allocator, new_arg);
                }
                const new_args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_callee),
                    new_args.start,
                    new_args.len,
                    call_flags,
                });
                return self.ast.addNode(.{
                    .tag = node.tag, // call_expression or new_expression
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // list 기반: array, object, sequence, template literal
            if (node.tag == .array_expression or node.tag == .object_expression or
                node.tag == .sequence_expression or node.tag == .template_literal)
            {
                // 객체 리터럴 메서드의 `super` home 배정 — 이 경로는 object_expression 방문을
                // 거치지 않고 멤버를 직접 방문하므로 여기서도 해야 한다 (#4729).
                const object_super = @import("object_super.zig");
                const home_mark = self.object_super_homes.items.len;
                defer object_super.release(self, home_mark);
                const home = if (node.tag == .object_expression) try object_super.prepareHome(self, node) else null;

                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                const list_start = node.data.list.start;
                const list_len = node.data.list.len;
                // visitExprWithYieldExtraction이 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var i_elem: u32 = 0;
                while (i_elem < list_len) : (i_elem += 1) {
                    const raw_idx = self.ast.extra_data.items[list_start + i_elem];
                    const new_elem = try visitExprWithYieldExtraction(self, @enumFromInt(raw_idx), ops, next_label);
                    try self.scratch.append(self.allocator, new_elem);
                }
                const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const rebuilt = try self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .list = new_list },
                });
                if (home) |h| return object_super.wrapWithHome(self, h, rebuilt, node.span);
                return rebuilt;
            }

            // object_property: binary (key: value)
            if (node.tag == .object_property) {
                const new_key = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
                const new_value = if (!node.data.binary.right.isNone())
                    try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label)
                else
                    NodeIndex.none;
                return self.ast.addNode(.{
                    .tag = .object_property,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = new_key, .right = new_value, .flags = node.data.binary.flags } },
                });
            }

            // spread_element: unary
            if (node.tag == .spread_element) {
                const new_operand = try visitExprWithYieldExtraction(self, node.data.unary.operand, ops, next_label);
                return self.ast.addNode(.{
                    .tag = .spread_element,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
                });
            }

            // 그 외: visitNode fallback (yield가 남을 수 있음)
            if (std.debug.runtime_safety) {
                std.log.warn("visitExprWithYieldExtraction: unhandled tag {}", .{node.tag});
            }
            return self.visitNode(expr_idx);
        }

        // Expression-internal lazy branches need labels before their final `next_label`
        // values are allocated. Use reserved sentinel labels, then patch only the ops
        // emitted by the current expression once the real labels are known.
        const EXPR_LAZY_BRANCH_END_SENTINEL = LABEL_SENTINEL_BASE - 10_000;
        const EXPR_LAZY_COND_ELSE_SENTINEL = LABEL_SENTINEL_BASE - 10_001;
        const EXPR_LAZY_COND_END_SENTINEL = LABEL_SENTINEL_BASE - 10_002;

        fn appendAssignTempStmt(self: *Transformer, ops: *std.ArrayList(Operation), temp_span: Span, value_idx: NodeIndex, span: Span) Transformer.Error!void {
            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = value_idx, .flags = 0 } },
            });
            const stmt = try es_helpers.makeExprStmt(self, assign, span);
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = stmt } });
        }

        fn lowerLogicalExprWithYieldExtraction(self: *Transformer, node: Node, ops: *std.ArrayList(Operation), next_label: *u32, op_kind: token_mod.Kind) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            try self.generator_temp_var_spans.append(self.allocator, temp_span);
            const ops_start = ops.items.len;

            const left_value = try visitExprWithYieldExtraction(self, node.data.binary.left, ops, next_label);
            try appendAssignTempStmt(self, ops, temp_span, left_value, node.span);

            const temp_for_cond = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const cond = if (op_kind == .question2)
                try es_helpers.makeNeqNull(self, temp_for_cond, node.span)
            else
                temp_for_cond;
            const branch_code: OpCode = if (op_kind == .amp2) .break_when_false else .break_when_true;
            try ops.append(self.allocator, .{
                .code = branch_code,
                .arg = .{ .label_and_node = .{ .label = EXPR_LAZY_BRANCH_END_SENTINEL, .node = cond } },
            });

            const right_value = try visitExprWithYieldExtraction(self, node.data.binary.right, ops, next_label);
            try appendAssignTempStmt(self, ops, temp_span, right_value, node.span);

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
            fixupSentinel(ops.items[ops_start..], EXPR_LAZY_BRANCH_END_SENTINEL, end_label);

            return es_helpers.makeTempVarRef(self, temp_span, temp_span);
        }

        fn lowerConditionalExprWithYieldExtraction(self: *Transformer, node: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            try self.generator_temp_var_spans.append(self.allocator, temp_span);
            const ops_start = ops.items.len;

            const cond = try visitExprWithYieldExtraction(self, node.data.ternary.a, ops, next_label);
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = EXPR_LAZY_COND_ELSE_SENTINEL, .node = cond } },
            });

            const then_value = try visitExprWithYieldExtraction(self, node.data.ternary.b, ops, next_label);
            try appendAssignTempStmt(self, ops, temp_span, then_value, node.span);
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = EXPR_LAZY_COND_END_SENTINEL } });

            const else_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            const else_value = try visitExprWithYieldExtraction(self, node.data.ternary.c, ops, next_label);
            try appendAssignTempStmt(self, ops, temp_span, else_value, node.span);

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
            fixupSentinel(ops.items[ops_start..], EXPR_LAZY_COND_ELSE_SENTINEL, else_label);
            fixupSentinel(ops.items[ops_start..], EXPR_LAZY_COND_END_SENTINEL, end_label);

            return es_helpers.makeTempVarRef(self, temp_span, temp_span);
        }

        fn buildExpressionBodyStateMachine(self: *Transformer, body_idx: NodeIndex, body: Node, span: Span) Transformer.Error!StateMachineResult {
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);
            var next_label: u32 = 1;

            if (body.tag == .await_expression or body.tag == .yield_expression) {
                // return await/yield x → yield x + return _state.sent()
                const inner_value = body.data.unary.operand;
                const new_inner = if (!inner_value.isNone())
                    try visitExprWithYieldExtraction(self, inner_value, &ops, &next_label)
                else
                    NodeIndex.none;
                try ops.append(self.allocator, .{ .code = yieldOpCodeFor(body), .arg = .{ .node = new_inner } });
                next_label += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                const sent = try buildSentCall(self, span);
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = sent } });
            } else if (es2015_scan.containsYield(self, body_idx)) {
                // async arrow expression body: `async x => f(await x)` 는 implicit return 이므로,
                // block body 의 `return f(await x)` 와 동일하게 nested await를 먼저 추출한다.
                const new_value = try visitExprWithYieldExtraction(self, body_idx, &ops, &next_label);
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
            } else {
                // 일반 expression: return expr
                const new_value = try self.visitNode(body_idx);
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
            }

            const switch_node = try buildSwitchFromOps(self, ops.items, span);
            const var_decl_node = try buildHoistedVarDecl(self, &.{}, span);
            return .{ .body = switch_node, .var_decl = var_decl_node };
        }

        /// 연산 리스트를 switch case로 변환.
        /// `ops[from]` 이후 처음 나오는 실행 op 가 **재개 라벨에 민감한지**.
        ///
        /// `__generator` 의 op 4(`yield`)·5(`yield*`)는 실행 시 `_.label++` 로 재개 위치를
        /// 잡는다. 따라서 그 op 는 자기 case 의 라벨 + 1 에서 재개돼야 한다 — 빈 case 가
        /// 앞에 붙어 폴스루하면 그 관계가 깨져 같은 yield 가 두 번 실행된다. (#4718)
        fn nextOpIsResumeSensitive(ops: []const Operation, from: usize) bool {
            // 폴스루해 들어갈 case 의 **끝까지**(다음 nop 전까지) 본다. 문장 몇 개 뒤에 yield 가
            // 와도 같은 문제다 — 빈 라벨로 들어오면 yield 후 재개 라벨이 그 case 자신이라
            // 문장까지 **통째로 다시 실행**된다(#4722 에서 발견 — #4718 은 바로 다음만 봤다).
            var i = from + 1;
            while (i < ops.len) : (i += 1) {
                switch (ops[i].code) {
                    .nop => return false, // 다음 case 가 시작 — 빈 case 가 이어진다
                    .yield_op, .yield_star => return true,
                    else => {},
                }
            }
            return false;
        }

        fn buildSwitchFromOps(self: *Transformer, ops: []const Operation, span: Span) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var case_num: u32 = 0;
            // label = case number 직접 사용 (nop 순서대로 번호 매김)
            var current_case_stmts: std.ArrayList(NodeIndex) = .empty;
            defer current_case_stmts.deinit(self.allocator);

            for (ops, 0..) |op, op_i| {
                switch (op.code) {
                    .nop => {
                        // fall-through 방지: __generator는 label로 case를 추적하므로
                        // fall-through 시 label과 실행 위치가 불일치하여 무한루프.
                        // .return_statement 하나만 체크해도 충분: yield_op, return_op,
                        // break_op 모두 buildInstructionReturn을 거쳐 return_statement 생성.
                        if (current_case_stmts.items.len > 0) {
                            const next_case = case_num + 1;
                            const last_node = self.ast.getNode(current_case_stmts.items[current_case_stmts.items.len - 1]);
                            if (last_node.tag != .return_statement) {
                                const jump = try buildInstructionReturn(self, 3, try es_helpers.makeNumericLiteral(self, next_case), span);
                                try current_case_stmts.append(self.allocator, jump);
                            }
                        } else if (nextOpIsResumeSensitive(ops, op_i)) {
                            // **빈 case** 도 그냥 폴스루하면 안 된다 (#4718).
                            // 라벨이 겹치는 자리(예: try 영역 종료 라벨 + 라벨 스코프 종료
                            // 라벨)에 `yield` 가 오면 `case 14: case 15: return [4, v]` 가 되는데,
                            // `__generator` 의 op 4/5 는 재개 라벨을 **현재 라벨 + 1** 로 잡는다.
                            // 14 로 들어오면 재개가 15 = 같은 yield → **값이 두 번 방출된다**.
                            // 다음 op 가 재개 라벨에 민감할 때만 명시 점프를 넣어 크기 영향을 막는다.
                            const jump = try buildInstructionReturn(self, 3, try es_helpers.makeNumericLiteral(self, case_num + 1), span);
                            try current_case_stmts.append(self.allocator, jump);
                        }
                        const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                        try self.scratch.append(self.allocator, case_node);
                        current_case_stmts.clearRetainingCapacity();
                        case_num += 1;
                    },
                    .statement => {
                        if (op.arg == .node and !op.arg.node.isNone()) {
                            try current_case_stmts.append(self.allocator, op.arg.node);
                        }
                    },
                    .yield_op => {
                        // return [4, value]
                        const ret = try buildInstructionReturn(self, 4, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                        // case 마무리 (다음 nop에서 새 case가 시작됨)
                    },
                    .return_op => {
                        // return [2, value]
                        const ret = try buildInstructionReturn(self, 2, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_op => {
                        // return [3, label]
                        const label = if (op.arg == .label) op.arg.label else 0;
                        const label_node = try es_helpers.makeNumericLiteral(self, label);
                        const ret = try buildInstructionReturn(self, 3, label_node, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_when_false => {
                        if (op.arg == .label_and_node) {
                            const stmt = try buildConditionalBreak(self, op.arg.label_and_node.label, op.arg.label_and_node.node, true, span);
                            try current_case_stmts.append(self.allocator, stmt);
                        }
                    },
                    .break_when_true => {
                        if (op.arg == .label_and_node) {
                            const stmt = try buildConditionalBreak(self, op.arg.label_and_node.label, op.arg.label_and_node.node, false, span);
                            try current_case_stmts.append(self.allocator, stmt);
                        }
                    },
                    .yield_star => {
                        // return [5, __values(iter)] — (#1910) raw iterable 을 iterator 로 wrap.
                        // __generator 의 op[5] 가 .next 직접 호출해서 string/Map/Set 같이
                        // [Symbol.iterator] 만 가진 iterable 은 그대로 못 씀.
                        const inner_iter = if (op.arg == .node) op.arg.node else .none;
                        const wrapped_iter = if (!inner_iter.isNone()) blk: {
                            self.runtime_helpers.values = true;
                            const values_ref = try es_helpers.makeRuntimeHelperRef(self, "__values");
                            break :blk try es_helpers.makeCallExpr(self, values_ref, &.{inner_iter}, span);
                        } else inner_iter;
                        const ret = try buildInstructionReturn(self, 5, wrapped_iter, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                }
            }

            // 마지막 case
            if (current_case_stmts.items.len > 0) {
                const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                try self.scratch.append(self.allocator, case_node);
            }

            // switch(_state.label) { cases... }
            const state_ref = try makePendingStateRef(self);
            const label_prop = try es_helpers.makePropertyName(self, "label");
            const discriminant = try es_helpers.makeStaticMember(self, state_ref, label_prop, span);

            // switch_statement: extra = [discriminant, cases_start, cases_len]
            const cases_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const switch_extra = try self.ast.addExtras(&.{
                @intFromEnum(discriminant),
                cases_list.start,
                cases_list.len,
            });
            return self.ast.addNode(.{
                .tag = .switch_statement,
                .span = span,
                .data = .{ .extra = switch_extra },
            });
        }

        /// block_statement이면 내부 문들을 순회, 아니면 단일 문으로 collectOperations.
        /// 상태 기계가 직접 수집하는 문장 목록에 `using` 이 있으면 try/finally 구조로 먼저
        /// 바꾼다 — 이 경로는 목록 방문(visitListNode)을 거치지 않아 dispose 가 빠졌다 (#4730).
        fn rewriteUsingForStateMachine(self: *Transformer, list: ast_mod.NodeList) Transformer.Error!ast_mod.NodeList {
            if (!self.options.unsupported.using) return list;
            const Using = @import("es2025_using.zig").ES2025Using(Transformer);
            if (!Using.hasUsingDeclaration(self, list.start, list.len)) return list;
            return Using.rewriteUsingStatements(self, list.start, list.len, .body);
        }

        const ForOf = @import("es2015_for_of.zig").ES2015ForOf(Transformer);

        /// 블록 스코프 바인딩 리네임(#4712)이 동작하는지. 식별자 리네임은 block scoping 을
        /// 낮출 때만 적용되므로, 그렇지 않은 조합에서는 예전처럼 원래 이름을 끌어올린다.
        fn stateMachineRenamesBlockScope(self: *const Transformer) bool {
            return self.options.unsupported.block_scoping;
        }

        fn isLexicalDeclaration(self: *Transformer, idx: NodeIndex) bool {
            if (idx.isNone()) return false;
            const node = self.ast.getNode(idx);
            if (node.tag == .class_declaration) return true;
            return node.tag == .variable_declaration and self.ast.hasExtra(node.data.extra, 3) and
                self.ast.variableDeclarationKind(node).isLexical();
        }

        /// 목록 직계의 let/const/class 선언 이름.
        /// 목록 직계의 let/const/class 선언이 만드는 바인딩 노드. 이름이 아니라 노드를 모아
        /// 바꾼 이름의 `var` 선언에 원래 심볼을 물려줄 수 있게 한다 (#4760).
        fn collectLexicalBindingsInList(self: *Transformer, list: ast_mod.NodeList, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                if (!isLexicalDeclaration(self, idx)) continue;
                const node = self.ast.getNode(idx);
                if (node.tag == .class_declaration) {
                    const name = self.readNodeIdx(node.data.extra, ast_mod.ClassExtra.name);
                    if (!name.isNone()) try out.append(self.allocator, name);
                    continue;
                }
                const ds = self.readU32(node.data.extra, 1);
                const dl = self.readU32(node.data.extra, 2);
                var j: u32 = 0;
                while (j < dl) : (j += 1) {
                    const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[ds + j]));
                    if (d.tag != .variable_declarator) continue;
                    try collectBindingNodes(self, self.readNodeIdx(d.data.extra, 0), out);
                }
            }
        }

        /// 패턴 안의 바인딩 식별자 노드 (`collectBindingNames` 의 노드판).
        fn collectBindingNodes(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                if (self.ast.getNode(leaf_idx).tag != .binding_identifier) continue;
                try out.append(self.allocator, leaf_idx);
            }
        }

        /// 상태 기계가 수집하는 블록 스코프 바인딩을 wrapper 최상단 var 로 등록한다 (#4712).
        /// 사용자 바인딩(심볼 있음)은 **항상** `name$N` 으로 바꿔 심볼 표에 둔다 — 상태 기계는
        /// 블록마다 바인딩을 한 함수 스코프로 모으므로 같은 이름이 겹칠 수 있다(#4760 이전의 이름
        /// 스택 판정과 같은 보수적 선택). 심볼 표가 이미 정한 이름이 있으면 그 이름을 쓴다.
        /// 심볼 없는 바인딩은 변환기가 만든 임시 변수(`_d`, `_using`, `_` …)로, 만들 때 함수 안에서
        /// 고유하게 지어지므로 이름을 그대로 올린다.
        fn registerStateMachineBindings(self: *Transformer, bindings: []const NodeIndex) Transformer.Error!void {
            if (!stateMachineRenamesBlockScope(self)) return;
            for (bindings) |binding| {
                const bi = @intFromEnum(binding);
                const sym: ?u32 = if (bi < self.symbol_ids.items.len) self.symbol_ids.items[bi] else null;
                const sid = sym orelse {
                    try registerGeneratorVar(self, self.ast.getNode(binding).data.string_ref, binding);
                    continue;
                };
                const new_name = self.tableRenameOf(binding) orelse blk: {
                    const name = self.ast.getText(self.ast.getNode(binding).span);
                    self.block_rename_counter += 1;
                    if (self.name_arena == null) self.name_arena = std.heap.ArenaAllocator.init(self.allocator);
                    const n = try std.fmt.allocPrint(self.name_arena.?.allocator(), "{s}${d}", .{ name, self.block_rename_counter });
                    if (self.block_rename_map == null) self.block_rename_map = .empty;
                    try self.block_rename_map.?.put(self.allocator, sid, n);
                    break :blk n;
                };
                try registerGeneratorVar(self, try self.ast.addString(new_name), binding);
            }
        }

        fn isRegisteredGeneratorTemp(self: *Transformer, name: []const u8) bool {
            for (self.generator_temp_var_spans.items) |sp| {
                if (std.mem.eql(u8, self.ast.getText(sp), name)) return true;
            }
            return false;
        }

        fn registerLoopHeadBindings(self: *Transformer, head: NodeIndex) Transformer.Error!void {
            if (!isLexicalDeclaration(self, head)) return;
            var bindings: std.ArrayList(NodeIndex) = .empty;
            defer bindings.deinit(self.allocator);
            try collectLexicalBindingsInList(self, .{ .start = try self.ast.addExtras(&.{@intFromEnum(head)}), .len = 1 }, &bindings);
            try registerStateMachineBindings(self, bindings.items);
        }

        fn collectBodyOperations(self: *Transformer, body_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                // 이 블록의 let/const/class/using 은 블록 스코프 — 고유 이름으로 바꿔 wrapper 에
                // 등록한다(호이스팅은 중첩 블록의 lexical 선언을 건너뛴다) (#4712). using 재구성
                // 뒤에는 var 가 되므로 이름은 **원래 목록**에서 모은다.
                var lexical: std.ArrayList(NodeIndex) = .empty;
                defer lexical.deinit(self.allocator);
                try collectLexicalBindingsInList(self, body_node.data.list, &lexical);
                const list = try rewriteUsingForStateMachine(self, body_node.data.list);
                const stmts_start = list.start;
                const stmts_len = list.len;
                try registerStateMachineBindings(self, lexical.items);
                // collectOperations가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
                var i_stmt: u32 = 0;
                while (i_stmt < stmts_len) : (i_stmt += 1) {
                    const raw_idx = self.ast.extra_data.items[stmts_start + i_stmt];
                    try collectOperations(self, @enumFromInt(raw_idx), ops, next_label);
                }
            } else {
                try collectOperations(self, body_idx, ops, next_label);
            }
        }

        /// 조건부 break: if (cond) return [3, label] 또는 if (!cond) return [3, label].
        /// negate=true이면 조건을 !로 반전.
        fn buildConditionalBreak(self: *Transformer, label: u32, cond: NodeIndex, negate: bool, span: Span) Transformer.Error!NodeIndex {
            const final_cond = if (negate) blk: {
                // !cond 의 paren 은 precedence 재유도가 처리 (#4042 PR8)
                break :blk try self.ast.addNode(.{
                    .tag = .unary_expression,
                    .span = span,
                    .data = .{ .extra = try self.ast.addExtras(&.{
                        @intFromEnum(cond),
                        @intFromEnum(token_mod.Kind.bang),
                    }) },
                });
            } else cond;

            const label_node = try es_helpers.makeNumericLiteral(self, label);
            const break_ret = try buildInstructionReturn(self, 3, label_node, span);
            const if_body_list = try self.ast.addNodeList(&.{break_ret});
            const if_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = if_body_list },
            });
            return self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = final_cond, .b = if_body, .c = .none } },
            });
        }

        /// switch case 노드 생성: case N: stmts...
        /// switch_case: extra = [test_expr, stmts_start, stmts_len]
        fn buildSwitchCase(self: *Transformer, case_num: u32, stmts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const test_node = try es_helpers.makeNumericLiteral(self, case_num);

            const body_list = try self.ast.addNodeList(stmts);
            const case_extra = try self.ast.addExtras(&.{
                @intFromEnum(test_node),
                body_list.start,
                body_list.len,
            });

            return self.ast.addNode(.{
                .tag = .switch_case,
                .span = span,
                .data = .{ .extra = case_extra },
            });
        }

        /// return [instruction, value] 문 생성.
        pub fn buildInstructionReturn(self: *Transformer, instruction: u32, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const inst_node = try es_helpers.makeNumericLiteral(self, instruction);

            const arr_items = if (!value.isNone())
                try self.ast.addNodeList(&.{ inst_node, value })
            else
                try self.ast.addNodeList(&.{inst_node});

            const arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_items },
            });

            return self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = arr, .flags = 0 } },
            });
        }

        /// _state.sent() 호출 생성.
        fn buildSentCall(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try makePendingStateRef(self);
            const sent_prop = try es_helpers.makePropertyName(self, "sent");
            const sent_member = try es_helpers.makeStaticMember(self, state_ref, sent_prop, span);
            return es_helpers.makeCallExpr(self, sent_member, &.{}, span);
        }

        /// _state.sent(); expression_statement 생성.
        /// yield resume 시 throw된 에러를 발생시키기 위해 필요.
        fn buildSentExprStmt(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const sent = try buildSentCall(self, span);
            return es_helpers.makeExprStmt(self, sent, span);
        }

        /// _state identifier reference 생성.
        fn buildStateRef(self: *Transformer, _: Span) Transformer.Error!NodeIndex {
            return makePendingStateRef(self);
        }

        fn makePendingStateRef(self: *Transformer) Transformer.Error!NodeIndex {
            const ref = try es_helpers.makeSyntheticRef(self, "_state");
            try self.generator_state_refs.append(self.allocator, ref);
            return ref;
        }

        pub const GeneratorCall = struct {
            call: NodeIndex,
            callback: NodeIndex,
            state_param: NodeIndex,
            helper_ref: NodeIndex,
        };

        /// The async helper receives a real function wrapper. Its body contains
        /// the `__generator` call, and its child callback owns `_state`.
        pub fn bindWrappedStateMachine(self: *Transformer, source_owner: NodeIndex, wrapper: NodeIndex, gen: GeneratorCall, frame: *const StateMachineFrame, span: Span) Transformer.Error!void {
            const parent = self.originalFunctionScope(source_owner);
            if (parent.isNone()) {
                try self.bindGeneratedState(.none, .none, gen.callback, gen.state_param, frame.state_ref_start, frame.callback_temps.items, span);
                return;
            }
            const wrapper_scope = try self.addGeneratedFunctionScope(parent, wrapper);
            self.relocatePendingRuntimeHelperRef(gen.helper_ref, wrapper_scope);
            try self.bindGeneratedState(wrapper_scope, parent, gen.callback, gen.state_param, frame.state_ref_start, frame.callback_temps.items, span);
        }

        /// __generator(function(_state) { ... }) 호출 생성.
        /// es2017 결합 변환에서도 호출.
        /// __generator(body) 또는 __generator(body, genFn) 호출을 생성.
        /// genFn_idx가 .none이 아니면 프로토타입 체인 설정을 위해 두 번째 인자로 전달.
        pub fn buildGeneratorHelperCall(self: *Transformer, switch_body: NodeIndex, span: Span) Transformer.Error!GeneratorCall {
            return buildGeneratorHelperCallWithProto(self, switch_body, .none, span);
        }

        pub fn buildGeneratorHelperCallWithProto(self: *Transformer, switch_body: NodeIndex, genFn_idx: NodeIndex, span: Span) Transformer.Error!GeneratorCall {
            self.runtime_helpers.generator = true;

            // _state 파라미터
            const state_span = try self.ast.addString(try es_helpers.resolveSyntheticName(self, "_state"));
            const state_param = try es_helpers.makeSyntheticBinding(self, state_span);

            // function body: switch_body를 block으로 감싸기
            const body_list = try self.ast.addNodeList(&.{switch_body});
            const body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // function(_state) { ... }
            const params = try self.ast.addNodeList(&.{state_param});
            const none = @intFromEnum(NodeIndex.none);
            const params_node_g = try self.ast.addFormalParameters(params, .{ .start = 0, .end = 0 });
            const func_extra = try self.ast.addExtras(&.{
                none, // anonymous
                @intFromEnum(params_node_g),
                @intFromEnum(body),
                0, // flags
                none,
            });
            const func_expr = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // __generator(this, func) 또는 __generator(this, func, genFn) — (#1909)
            // body 안 `this` 가 enclosing function 의 this 가 되도록 thisArg 첫 인자 전달.
            const gen_ref = try es_helpers.makeRuntimeHelperRef(self, "__generator");
            const this_arg = try es_helpers.makeThisExpr(self, span);
            if (!genFn_idx.isNone()) {
                return .{ .call = try es_helpers.makeCallExpr(self, gen_ref, &.{ this_arg, func_expr, genFn_idx }, span), .callback = func_expr, .state_param = state_param, .helper_ref = gen_ref };
            }
            return .{ .call = try es_helpers.makeCallExpr(self, gen_ref, &.{ this_arg, func_expr }, span), .callback = func_expr, .state_param = state_param, .helper_ref = gen_ref };
        }
    };
}

test "ES2015 generator module compiles" {
    _ = ES2015Generator;
}
