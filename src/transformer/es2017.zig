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
const es2015_generator = @import("es2015_generator.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2017(comptime Transformer: type) type {
    return struct {
        /// `await expr` → `(yield expr)`
        pub fn lowerAwaitExpression(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_operand = try self.visitNode(node.data.unary.operand);
            // yield_expression: data.unary = { operand, flags } (flags bit 0 = yield*)
            const yield_node = try self.new_ast.addNode(.{
                .tag = .yield_expression,
                .span = node.span,
                .data = .{ .unary = .{ .operand = new_operand, .flags = 0 } },
            });
            return self.new_ast.addNode(.{
                .tag = .parenthesized_expression,
                .span = node.span,
                .data = .{ .unary = .{ .operand = yield_node, .flags = 0 } },
            });
        }

        /// async function foo() { ... } → function foo() { return __async(function*() { ... }); }
        pub fn lowerAsyncFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const params_start = extras[e + 1];
            const params_len = extras[e + 2];
            const body_idx: NodeIndex = @enumFromInt(extras[e + 3]);
            const flags = extras[e + 4];

            const new_name = try self.visitNode(name_idx);
            const new_body = try self.visitNode(body_idx);
            const new_params = try self.visitExtraList(params_start, params_len);

            const gen_func = try buildGeneratorWrapper(self, new_body, node.span);
            const async_call = try buildAsyncHelperCall(self, gen_func, node.span);

            const return_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = node.span,
                .data = .{ .unary = .{ .operand = async_call, .flags = 0 } },
            });
            const body_list = try self.new_ast.addNodeList(&.{return_stmt});
            const wrapper_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = node.span,
                .data = .{ .list = body_list },
            });

            const new_flags = flags & ~ast_mod.FunctionFlags.is_async;
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(new_name),
                new_params.start,
                new_params.len,
                @intFromEnum(wrapper_body),
                new_flags,
                @intFromEnum(NodeIndex.none),
            });
            return self.new_ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });
        }

        /// async () => { ... } → () => __async(function*() { ... })
        pub fn lowerAsyncArrow(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const params_idx: NodeIndex = @enumFromInt(extras[e]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const flags = extras[e + 2];

            const new_params = try self.visitNode(params_idx);
            const new_body = try self.visitNode(body_idx);

            // expression body → { return expr; }
            const body_node = self.new_ast.getNode(new_body);
            const gen_body = if (body_node.tag != .block_statement) blk: {
                const ret = try self.new_ast.addNode(.{
                    .tag = .return_statement,
                    .span = node.span,
                    .data = .{ .unary = .{ .operand = new_body, .flags = 0 } },
                });
                const list = try self.new_ast.addNodeList(&.{ret});
                break :blk try self.new_ast.addNode(.{
                    .tag = .block_statement,
                    .span = node.span,
                    .data = .{ .list = list },
                });
            } else new_body;

            const gen_func = try buildGeneratorWrapper(self, gen_body, node.span);
            const async_call = try buildAsyncHelperCall(self, gen_func, node.span);

            const new_flags = flags & ~@as(u32, ast_mod.ArrowFlags.is_async);
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(new_params),
                @intFromEnum(async_call),
                new_flags,
            });
            return self.new_ast.addNode(.{
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
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const params_start = extras[e + 1];
            const params_len = extras[e + 2];
            const body_idx: NodeIndex = @enumFromInt(extras[e + 3]);
            const flags = extras[e + 4];

            const new_name = try self.visitNode(name_idx);
            const new_params = try self.visitExtraList(params_start, params_len);

            const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
            if (sm_result.body.isNone()) return .none;

            const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
            const async_call = try buildAsyncHelperCall(self, gen_call, span);

            const return_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = async_call, .flags = 0 } },
            });

            // hoisted var 선언을 __generator 밖에 배치
            const body_list = if (sm_result.var_decl.isNone())
                try self.new_ast.addNodeList(&.{return_stmt})
            else
                try self.new_ast.addNodeList(&.{ sm_result.var_decl, return_stmt });
            const wrapper_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // 일반 function으로 변환 (async + generator 플래그 모두 제거)
            const new_flags = flags & ~(ast_mod.FunctionFlags.is_async | @as(u32, ast_mod.FunctionFlags.is_generator));
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(new_name),
                new_params.start,
                new_params.len,
                @intFromEnum(wrapper_body),
                new_flags,
                @intFromEnum(NodeIndex.none),
            });
            return self.new_ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// async arrow → () => __async(__generator(function(_state) { switch... }).call(this))
        /// async_await + generator 둘 다 unsupported일 때 호출.
        pub fn lowerAsyncArrowToStateMachine(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const GenMod = es2015_generator.ES2015Generator(Transformer);
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const params_idx: NodeIndex = @enumFromInt(extras[e]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const flags = extras[e + 2];

            const new_params = try self.visitNode(params_idx);

            const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
            if (sm_result.body.isNone()) return .none;

            const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
            const async_call = try buildAsyncHelperCall(self, gen_call, span);

            // hoisted vars가 있으면 block body, 없으면 expression body
            const final_body = if (sm_result.var_decl.isNone()) async_call else blk: {
                const return_stmt = try self.new_ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = async_call, .flags = 0 } },
                });
                const body_list = try self.new_ast.addNodeList(&.{ sm_result.var_decl, return_stmt });
                break :blk try self.new_ast.addNode(.{
                    .tag = .block_statement,
                    .span = span,
                    .data = .{ .list = body_list },
                });
            };
            const new_flags = flags & ~@as(u32, ast_mod.ArrowFlags.is_async);
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(new_params),
                @intFromEnum(final_body),
                new_flags,
            });
            return self.new_ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        pub fn buildGeneratorWrapper(self: *Transformer, body: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const empty_params = try self.new_ast.addNodeList(&.{});
            const gen_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(NodeIndex.none), // name
                empty_params.start,
                empty_params.len,
                @intFromEnum(body),
                ast_mod.FunctionFlags.is_generator,
                @intFromEnum(NodeIndex.none), // return type
            });
            return self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = gen_extra },
            });
        }

        /// __async(gen).call(this) — this 바인딩 보존.
        pub fn buildAsyncHelperCall(self: *Transformer, gen_func: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.async_helper = true;
            const async_ref = try es_helpers.makeIdentifierRef(self, "__async");
            const inner_call = try es_helpers.makeCallExpr(self, async_ref, &.{gen_func}, span);
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const member = try es_helpers.makeStaticMember(self, inner_call, call_prop, span);
            const this_ref = try es_helpers.makeIdentifierRef(self, "this");
            return es_helpers.makeCallExpr(self, member, &.{this_ref}, span);
        }
    };
}
