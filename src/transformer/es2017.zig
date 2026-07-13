//! ES2017 다운레벨링: async/await → generator + Promise
//!
//! --target < es2017 일 때 활성화.
//! async function f() { await x; } → function f() { return __async(function*() { yield x; }); }
//!
//! 스펙:
//! - async functions: https://tc39.es/ecma262/#sec-async-function-definitions (ES2017, TC39 Stage 4: 2016-11)
//!                     https://github.com/tc39/ecmascript-asyncawait
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerAsync)
//! - oxc: crates/oxc_transformer/src/es2017/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const es_helpers = @import("es_helpers.zig");
const es2015_arrow = @import("es2015_arrow.zig");
const es2015_generator = @import("es2015_generator.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2017(comptime Transformer: type) type {
    return struct {
        /// async generator (`async function*`) body 안 await 표현을 `yield __await(value)` 로
        /// 변환. nested function/arrow scope 는 traversal 안 함 (own this/await context 가짐).
        /// (#1911)
        fn rewriteAwaitToYieldAwait(self: *Transformer, node_idx: NodeIndex) Transformer.Error!void {
            return rewriteRemainingAwait(self, node_idx, true);
        }

        /// async function body 안에 **남아 있는** await 표현을 `yield value` 로 변환 (#4488).
        ///
        /// 왜 필요한가 — visitor 는 자기가 *방문한* `await_expression` 만 yield 로 낮춘다
        /// (`lowerAwaitExpression`). 그런데 `for await` 다운레벨(es2018_for_await)은 body 를
        /// visit 하는 **도중에 새 await 노드를 만든다**. 그 노드는 이미 지나간 방문을 받지 못해
        /// generator 안에 raw `await` 로 남았다 → `'await' is not allowed in non-async function`.
        /// (es2015/es2016 타겟에서 산출물이 파싱조차 안 됐다.)
        /// body visit 이 **끝난 뒤** 한 번 훑어 남은 것을 정리한다.
        fn rewriteRemainingAwaitToYield(self: *Transformer, node_idx: NodeIndex) Transformer.Error!void {
            return rewriteRemainingAwait(self, node_idx, false);
        }

        /// `wrap_await_helper` = true → `yield __await(v)` (async generator: 사용자 yield 와 구분),
        /// false → `yield v` (plain async: __async 헬퍼의 generator 프로토콜).
        fn rewriteRemainingAwait(self: *Transformer, node_idx: NodeIndex, comptime wrap_await_helper: bool) Transformer.Error!void {
            // 반복 post-order worklist(#4123): 원본은 generic else 에서 자식을, await_expression
            // 에서 operand 를 재귀해, async-generator body 안 깊은 식(`await (a+b+c+…)`, 깊은
            // statement 중첩, `await await …`)에서 스택오버플로우였다. await_expression 만 operand
            // 를 **먼저** 변환한 뒤 자신을 yield 로 replace 해야 하므로(post-order + mutation),
            // await 노드에 한해 post 프레임을 둔다. generic/boundary 는 mutation 이 없어 자식
            // push(또는 skip)만 한다. operand subtree 의 in-place 변환은 NodeIndex 가 불변이라
            // 보존되고, post 프레임이 스택 더 깊은 곳에 있어 operand 처리 완료 후에만 replace 된다.
            const Frame = struct { idx: NodeIndex, post: bool };
            var stack: std.ArrayListUnmanaged(Frame) = .empty;
            defer stack.deinit(self.allocator);
            var child_buf: std.ArrayListUnmanaged(NodeIndex) = .empty;
            defer child_buf.deinit(self.allocator);

            try stack.append(self.allocator, .{ .idx = node_idx, .post = false });
            while (stack.pop()) |frame| {
                if (frame.post) {
                    // operand 는 이미 변환 완료. 이제 이 await 를 yield 로 replace.
                    const node = self.ast.getNode(frame.idx);
                    const yielded = if (wrap_await_helper) blk: {
                        self.runtime_helpers.await_helper = true;
                        const await_ref = try es_helpers.makeRuntimeHelperRef(self, "__await");
                        break :blk try es_helpers.makeCallExpr(self, await_ref, &.{node.data.unary.operand}, node.span);
                    } else node.data.unary.operand;
                    // span 보존하면서 await_expression → yield <value>.
                    self.ast.replaceNode(frame.idx, .{
                        .tag = .yield_expression,
                        .span = node.span,
                        .data = .{ .unary = .{ .operand = yielded, .flags = 0 } },
                    });
                    continue;
                }
                // pre 프레임: children() 는 extra_data 값을 그대로 yield 하므로(범위 검증 안 함)
                // none 외에 out-of-range 도 가능 → getNode 전 bounds 가드(post 프레임 idx 는 이미
                // 검증된 await 노드라 안전). walkPreorderIterative/scanChildren 동일.
                if (frame.idx.isNone() or @intFromEnum(frame.idx) >= self.ast.nodes.items.len) continue;
                const node = self.ast.getNode(frame.idx);
                switch (node.tag) {
                    .await_expression => {
                        // post-order: operand 를 먼저 변환(push post=false)한 뒤 자신을 replace.
                        // LIFO 라 post 를 먼저 push 해야 operand 처리 *후* 실행된다.
                        try stack.append(self.allocator, .{ .idx = frame.idx, .post = true });
                        try stack.append(self.allocator, .{ .idx = node.data.unary.operand, .post = false });
                    },
                    // 자체 async/await context 를 가진 nested scope — skip. `es2022_tla.hasTopLevelAwait`
                    // 의 boundary set 과 동일 (function/method/class 모두). class body 안 method
                    // 도 자체 컨텍스트라 await rewrite 에서 제외.
                    .function_declaration,
                    .function_expression,
                    .function,
                    .arrow_function_expression,
                    .method_definition,
                    .class_declaration,
                    .class_expression,
                    => {},
                    else => {
                        // 일반 노드 — 모든 자식을 push (소스 순서 보존 위해 역순).
                        try ast_walk.collectChildrenInto(self.ast, node, &child_buf, self.allocator);
                        var i = child_buf.items.len;
                        while (i > 0) {
                            i -= 1;
                            try stack.append(self.allocator, .{ .idx = child_buf.items[i], .post = false });
                        }
                    },
                }
            }
        }

        /// async generator (`async function*`) → `function() { return __asyncGenerator(this, arguments,
        /// function*() { /* await → yield __await */ }); }`. (#1911)
        /// generator 자체도 unsupported 면 inner function* 가 다시 ES5 generator state machine 으로 lower.
        pub fn lowerAsyncGeneratorToStateMachine(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const params_list = self.ast.functionParamsList(node);
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);

            const new_name = try self.visitNode(name_idx);
            const new_params = try self.visitExtraList(.{ .start = params_list.start, .len = params_list.len });

            try rewriteAwaitToYieldAwait(self, body_idx);

            // inner function*(): visitNode 거치면 ES5 target 시 자동으로 generator state machine 으로 lower.
            const inner_flags = (flags & ~@as(u32, ast_mod.FunctionFlags.is_async)) | @as(u32, ast_mod.FunctionFlags.is_generator);
            const inner_params_node = try self.ast.addFormalParameters(new_params, span);
            const none = @intFromEnum(NodeIndex.none);
            const inner_extra = try self.ast.addExtras(&.{
                none, // anonymous
                @intFromEnum(inner_params_node),
                @intFromEnum(body_idx),
                inner_flags,
                none,
            });
            const inner_func = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = inner_extra },
            });
            // inner function 자체도 visitNode 거쳐 generator/await downlevel 적용.
            const lowered_inner = try self.visitNode(inner_func);
            // 위 rewriteAwaitToYieldAwait 는 inner visit **전** 이라, 그 visit 중 for-await
            // 다운레벨이 새로 만든 await 를 놓친다 → 한 번 더 훑는다 (#4488).
            // 주의 — visit 은 body 를 **새 노드로 교체**하므로 원래 `body_idx` 가 아니라
            // 낮아진 결과의 body 를 봐야 한다. generator 가 state machine 으로 접힌 타겟
            // (es5)에선 함수 형태가 아니거나 남은 await 가 없어 no-op.
            if (!lowered_inner.isNone() and @intFromEnum(lowered_inner) < self.ast.nodes.items.len) {
                const li = self.ast.getNode(lowered_inner);
                switch (li.tag) {
                    .function_expression, .function, .function_declaration => {
                        try rewriteAwaitToYieldAwait(self, self.readNodeIdx(li.data.extra, 2));
                    },
                    else => {},
                }
            }

            // __asyncGenerator(this, arguments, function*() {...})
            self.runtime_helpers.async_generator = true;
            self.runtime_helpers.await_helper = true;
            const helper_ref = try es_helpers.makeRuntimeHelperRef(self, "__asyncGenerator");
            const this_arg = try es_helpers.makeThisExpr(self, span);
            const args_ref = try es_helpers.makeIdentifierRef(self, "arguments");
            const helper_call = try es_helpers.makeCallExpr(self, helper_ref, &.{ this_arg, args_ref, lowered_inner }, span);

            // outer wrapper: function name(<params>) { return __asyncGenerator(...); }
            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = helper_call, .flags = 0 } },
            });
            const outer_body_list = try self.ast.addNodeList(&.{return_stmt});
            const outer_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = outer_body_list },
            });
            const outer_params_node = try self.ast.addFormalParameters(new_params, span);
            const outer_flags = flags & ~(@as(u32, ast_mod.FunctionFlags.is_async) | @as(u32, ast_mod.FunctionFlags.is_generator));
            const outer_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_name),
                @intFromEnum(outer_params_node),
                @intFromEnum(outer_body),
                outer_flags,
                none,
            });
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = outer_extra },
            });
        }

        /// `await expr` → `(yield expr)`
        pub fn lowerAwaitExpression(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_operand = try self.visitNode(node.data.unary.operand);
            const yield_node = try es_helpers.makeYieldExpression(self, new_operand, node.span);
            return yield_node;
        }

        /// async function foo() { ... } → function foo() { return __async(function*() { ... }); }
        pub fn lowerAsyncFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const params_list = self.ast.functionParamsList(node);
            const params_start = params_list.start;
            const params_len = params_list.len;
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);

            const new_name = try self.visitNode(name_idx);
            const new_body = try self.visitBodyWorkletAware(body_idx);
            // body 를 visit 하는 도중 for-await 다운레벨이 **새로 만든** await 노드는 visitor 의
            // await→yield 변환을 못 받는다 → 여기서 정리 (#4488).
            try rewriteRemainingAwaitToYield(self, new_body);

            const new_params = try self.visitExtraList(.{ .start = params_start, .len = params_len });

            const gen_func = try es_helpers.buildGeneratorWrapper(self, new_body, node.span);
            const async_call = try es_helpers.buildAsyncHelperCall(self, gen_func, node.span);

            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = node.span,
                .data = .{ .unary = .{ .operand = async_call, .flags = 0 } },
            });

            const body_list = try self.ast.addNodeList(&.{return_stmt});

            const wrapper_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = node.span,
                .data = .{ .list = body_list },
            });

            const new_flags = flags & ~ast_mod.FunctionFlags.is_async;
            const new_params_node = try self.ast.addFormalParameters(new_params, node.span);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_name),
                @intFromEnum(new_params_node),
                @intFromEnum(wrapper_body),
                new_flags,
                @intFromEnum(NodeIndex.none),
            });
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });
        }

        /// async () => { ... } → () => __async(function*() { ... })
        pub fn lowerAsyncArrow(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const params_idx: NodeIndex = self.readNodeIdx(e, 0);
            const body_idx: NodeIndex = self.readNodeIdx(e, 1);
            const flags = self.readU32(e, ast_mod.ArrowExtra.flags);

            const new_params = try self.visitNode(params_idx);
            const new_body = try self.visitBodyWorkletAware(body_idx);
            // body visit 중 for-await 다운레벨이 새로 만든 await 정리 (#4488, lowerAsyncFunction 동일).
            try rewriteRemainingAwaitToYield(self, new_body);

            // expression body → { return expr; }
            const body_node = self.ast.getNode(new_body);
            const gen_body = if (body_node.tag != .block_statement) blk: {
                const ret = try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = new_body, .flags = 0 } },
                });
                const list = try self.ast.addNodeList(&.{ret});
                break :blk try self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = node.span,
                    .data = .{ .list = list },
                });
            } else new_body;

            const gen_func = try es_helpers.buildGeneratorWrapper(self, gen_body, node.span);
            const async_call = try es_helpers.buildAsyncHelperCall(self, gen_func, node.span);

            const new_flags = flags & ~@as(u32, ast_mod.ArrowFlags.is_async);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_params),
                @intFromEnum(async_call),
                new_flags,
            });
            return self.ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });
        }

        /// async function → __async(__generator(function(_state) { switch... })).call(this)
        /// async_await + generator 둘 다 unsupported일 때 호출.
        /// body를 pre-visit하지 않고 원본 body에서 직접 state machine 생성.
        /// await_expression은 es2015_generator의 collectOperations에서 yield처럼 처리됨.
        pub fn lowerAsyncToStateMachine(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const GenMod = es2015_generator.ES2015Generator(Transformer);
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const params_list = self.ast.functionParamsList(node);
            const params_start = params_list.start;
            const params_len = params_list.len;
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);

            const arrow_env = es_helpers.pushArrowEnv(self);
            defer es_helpers.popArrowEnv(self, arrow_env);

            const new_name = try self.visitNode(name_idx);

            const new_params = try self.visitExtraList(.{ .start = params_start, .len = params_len });

            // visitFunctionLike 를 거치지 않으므로 임시 변수 카운터를 직접 관리한다 (#1960).
            // state machine 안에서 optional chaining/nullish/destructuring lowering 이 만든
            // callback-local temp 는 __generator callback 안에 hoist 하고, for-await/yield
            // extraction 이 만든 state temp 는 sm_result.var_decl 로 wrapper top 에만 둔다.
            // 함수 스코프 종료 시 카운터를 복원해 outer scope 의 hoistTempVars 가 같은 이름을
            // 다시 hoist 하지 않도록 한다.
            const saved_temp_counter = self.temp_var_counter;

            var sm_result = try GenMod.buildStateMachine(self, body_idx, span);
            defer self.generator_temp_var_spans.clearRetainingCapacity();
            if (sm_result.body.isNone()) return .none;
            sm_result.body = try self.hoistStateMachineTempsAndRestore(sm_result.body, saved_temp_counter, span);

            const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
            // __async는 fn.apply()로 함수를 호출하므로 iterator를 직접 전달 불가.
            // function() { return __generator(cb); } 로 감싸야 함.
            const gen_wrapper_func = try es_helpers.wrapInFunction(self, gen_call, span);
            const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper_func, span);

            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = async_call, .flags = 0 } },
            });

            // hoisted var + return __async(...)
            const body_list = blk: {
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                if (self.options.unsupported.arrow) {
                    var capture_stmts: [2]NodeIndex = undefined;
                    const count = try es_helpers.fillThisArgumentsCaptures(self, &capture_stmts, span);
                    try self.scratch.appendSlice(self.allocator, capture_stmts[0..count]);
                }
                if (!sm_result.var_decl.isNone()) try self.scratch.append(self.allocator, sm_result.var_decl);
                try self.scratch.append(self.allocator, return_stmt);
                break :blk try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            };
            const wrapper_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // 일반 function으로 변환 (async + generator 플래그 모두 제거)
            const new_flags = flags & ~(ast_mod.FunctionFlags.is_async | @as(u32, ast_mod.FunctionFlags.is_generator));
            const new_params_node = try self.ast.addFormalParameters(new_params, span);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_name),
                @intFromEnum(new_params_node),
                @intFromEnum(wrapper_body),
                new_flags,
                @intFromEnum(NodeIndex.none),
            });
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// async arrow → function() { return __async(__generator(function(_state) { switch... }).call(this)) }
        /// async_await + generator 둘 다 unsupported일 때 호출.
        /// arrow도 unsupported이므로 function_expression으로 출력한다.
        /// params lowering은 Pass 2에서 자동 적용된다.
        pub fn lowerAsyncArrowToStateMachine(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const GenMod = es2015_generator.ES2015Generator(Transformer);
            const e = node.data.extra;
            const span = node.span;

            const params_idx: NodeIndex = self.readNodeIdx(e, 0);
            const body_idx: NodeIndex = self.readNodeIdx(e, 1);

            const saved_temp_counter = self.temp_var_counter;

            const lowered = blk: {
                // Async arrow skips ES2015Arrow.lowerArrowFunction(), so enter
                // the arrow lexical environment while visiting params/body.
                self.arrow_this_depth += 1;
                defer self.arrow_this_depth -= 1;

                const params_list = try es2015_arrow.ES2015Arrow(Transformer).arrowParamsToList(self, params_idx);
                const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
                break :blk .{ .params_list = params_list, .sm_result = sm_result };
            };
            const params_list = lowered.params_list;
            var sm_result = lowered.sm_result;
            defer self.generator_temp_var_spans.clearRetainingCapacity();
            if (sm_result.body.isNone()) return .none;
            sm_result.body = try self.hoistStateMachineTempsAndRestore(sm_result.body, saved_temp_counter, span);

            const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
            const gen_wrapper_func = try es_helpers.wrapInFunction(self, gen_call, span);
            const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper_func, span);

            // function body 구성: return __async(...)
            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = async_call, .flags = 0 } },
            });

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            if (!sm_result.var_decl.isNone()) try self.scratch.append(self.allocator, sm_result.var_decl);
            try self.scratch.append(self.allocator, return_stmt);
            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const func_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            const none = @intFromEnum(NodeIndex.none);
            const params_node = try self.ast.addFormalParameters(params_list, span);
            const func_extra = try self.ast.addExtras(&.{
                none, // anonymous
                @intFromEnum(params_node),
                @intFromEnum(func_body),
                0, // flags (not async, not generator)
                none, // return_type
            });
            return self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }
    };
}
