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
            if (node_idx.isNone()) return;
            const node = self.ast.getNode(node_idx);
            switch (node.tag) {
                .await_expression => {
                    // 자식 먼저 — nested await 도 변환.
                    try rewriteAwaitToYieldAwait(self, node.data.unary.operand);
                    // __await(operand) call 만들기.
                    self.runtime_helpers.await_helper = true;
                    const await_ref = try es_helpers.makeRuntimeHelperRef(self, "__await");
                    const await_call = try es_helpers.makeCallExpr(self, await_ref, &.{node.data.unary.operand}, node.span);
                    // span 보존하면서 await_expression → yield __await(value).
                    self.ast.replaceNode(node_idx, .{
                        .tag = .yield_expression,
                        .span = node.span,
                        .data = .{ .unary = .{ .operand = await_call, .flags = 0 } },
                    });
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
                    // 일반 노드 — child iterator 로 모든 자식 traversal.
                    const ast_walk = @import("../parser/ast_walk.zig");
                    var it = ast_walk.children(self.ast, node);
                    while (it.next()) |child| {
                        try rewriteAwaitToYieldAwait(self, child);
                    }
                },
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
            const flags = self.readU32(e, 3);

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
            // yield_expression: data.unary = { operand, flags } (flags bit 0 = yield*)
            const yield_node = try self.ast.addNode(.{
                .tag = .yield_expression,
                .span = node.span,
                .data = .{ .unary = .{ .operand = new_operand, .flags = 0 } },
            });
            return es_helpers.makeParenExpr(self, yield_node, node.span);
        }

        /// async function foo() { ... } → function foo() { return __async(function*() { ... }); }
        pub fn lowerAsyncFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const params_list = self.ast.functionParamsList(node);
            const params_start = params_list.start;
            const params_len = params_list.len;
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);
            const flags = self.readU32(e, 3);

            const new_name = try self.visitNode(name_idx);
            const new_body = try self.visitBodyWorkletAware(body_idx);

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
            const flags = self.readU32(e, 2);

            const new_params = try self.visitNode(params_idx);
            const new_body = try self.visitBodyWorkletAware(body_idx);

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
            const flags = self.readU32(e, 3);

            const new_name = try self.visitNode(name_idx);

            const new_params = try self.visitExtraList(.{ .start = params_start, .len = params_len });

            const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
            if (sm_result.body.isNone()) return .none;

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

            // arrow params → function params list로 변환
            const params_list = try es2015_arrow.ES2015Arrow(Transformer).arrowParamsToList(self, params_idx);

            const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
            if (sm_result.body.isNone()) return .none;

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
