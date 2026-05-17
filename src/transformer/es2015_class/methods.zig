//! Method, prototype, and accessor emission helpers for ES2015 class lowering.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const constructors_mod = @import("constructors.zig");

const MethodExtra = ast_mod.MethodExtra;

pub fn Methods(comptime Transformer: type) type {
    return struct {
        const constructors = constructors_mod.Constructors(Transformer);
        const visitMethodBodyWithCtx = constructors.visitMethodBodyWithCtx;

        pub const MethodInfo = struct {
            member_idx: NodeIndex,
            is_static: bool,
            // prototype assignment statement 의 span 으로 사용 — leading comment 가
            // `X.prototype.foo` 토큰 사이가 아니라 statement 앞에서 flush 되도록 (#1508).
            member_span: Span,
        };

        pub const AccessorInfo = struct {
            member_idx: NodeIndex,
            is_static: bool,
            is_getter: bool,
            // `Object.defineProperty(...)` statement 및 get/set prop 의 span 으로 사용 —
            // leading comment 가 `function()` 뒤나 파라미터 안이 아니라 accessor 앞에서 flush 되도록 (#1516).
            member_span: Span,
        };

        /// accessor method_definition에서 function expression 생성.
        /// ES2015 params lowering 포함 (setter destructuring/default 등).
        fn buildAccessorFunc(self: *Transformer, member_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const member = self.ast.getNode(member_idx);
            const me = member.data.extra;
            const params_list_old = self.ast.functionParamsList(member);
            const params_start = params_list_old.start;
            const params_len = params_list_old.len;
            const body_idx: NodeIndex = self.readNodeIdx(me, MethodExtra.body);

            const new_params = try self.visitExtraList(.{ .start = params_start, .len = params_len });

            const nt_ctx: ?Transformer.NewTargetCtx = if (self.options.unsupported.new_target) .method else null;
            const new_body = try visitMethodBodyWithCtx(self, body_idx, span, nt_ctx);

            const none = @intFromEnum(NodeIndex.none);
            const new_params_node = try self.ast.addFormalParameters(new_params, span);
            const func_extra = try self.ast.addExtras(&.{
                none,                   @intFromEnum(new_params_node),
                @intFromEnum(new_body), 0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// 두 key 노드의 소스 텍스트가 같은지 확인.
        fn keysMatch(self: *const Transformer, a: NodeIndex, b: NodeIndex) bool {
            if (a.isNone() or b.isNone()) return false;
            const na = self.ast.getNode(a);
            const nb = self.ast.getNode(b);
            const ta = self.ast.getText(na.span);
            const tb = self.ast.getText(nb.span);
            return std.mem.eql(u8, ta, tb);
        }

        /// IIFE 내부용 ClassName.prototype — symbol 전파 없이 span 텍스트만 사용.
        /// fresh identifier를 받으므로 파서 영역 symbol_ids 조회 불가.
        fn buildFreshPrototypeRef(self: *Transformer, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
            const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, class_name_span);
            const proto_prop = try es_helpers.makeIdentifierRef(self, "prototype");
            return es_helpers.makeStaticMember(self, class_ref, proto_prop, span);
        }

        /// method → ClassName.prototype.method = function() {} (expression_statement)
        /// static method → ClassName.method = function() {}
        pub fn buildPrototypeAssignment(self: *Transformer, info: MethodInfo, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
            const saved_static = self.current_super_is_static;
            const saved_receiver = self.current_super_static_receiver;
            self.current_super_is_static = info.is_static;
            self.current_super_static_receiver = null;
            defer {
                self.current_super_is_static = saved_static;
                self.current_super_static_receiver = saved_receiver;
            }

            const member = self.ast.getNode(info.member_idx);
            const me = member.data.extra;
            // 모든 읽기가 mutation(visitExtraList) 이전이므로 캐시 안전.
            const extras = self.ast.extra_data.items;

            const key_idx: NodeIndex = @enumFromInt(extras[me]);
            const body_idx: NodeIndex = @enumFromInt(extras[me + 2]);
            const flags = extras[me + 3];

            // function expression 생성 — ES2015 params lowering은 Pass 2에서 일괄 처리
            const params_list_unwrap = self.ast.functionParamsList(member);
            const new_params = try self.visitExtraList(params_list_unwrap);

            const is_async = flags & ast_mod.MethodFlags.is_async != 0;
            const is_generator = flags & ast_mod.MethodFlags.is_generator != 0;

            // async method + generator 다운레벨링: class lowering이 먼저 실행되어
            // method_definition → function_expression으로 변환되므로,
            // 여기서 직접 async → state machine 변환을 수행해야 함.
            // (ast에 생성된 function_expression은 transformer가 재방문하지 않음)
            if (is_async and self.options.unsupported.async_await) {
                const GenMod = @import("../es2015_generator.zig").ES2015Generator(@TypeOf(self.*));

                if (self.options.unsupported.generator) {
                    const arrow_env = es_helpers.pushArrowEnv(self);
                    defer es_helpers.popArrowEnv(self, arrow_env);

                    const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
                    defer self.generator_temp_var_spans.clearRetainingCapacity();
                    if (!sm_result.body.isNone()) {
                        const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
                        const gen_wrapper = try es_helpers.wrapInFunction(self, gen_call, span);
                        const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper, span);
                        const func_expr = try buildWrappedFunc(
                            self,
                            async_call,
                            sm_result.var_decl,
                            new_params,
                            span,
                        );
                        return buildMethodAssignment(self, info, class_name_span, key_idx, func_expr, span);
                    }
                }
                const method_nt: ?Transformer.NewTargetCtx = if (self.options.unsupported.new_target) .method else null;
                const gen_wrapper = try es_helpers.buildGeneratorWrapper(self, try visitMethodBodyWithCtx(self, body_idx, span, method_nt), span);
                const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper, span);
                const func_expr = try buildWrappedFunc(self, async_call, .none, new_params, span);
                return buildMethodAssignment(self, info, class_name_span, key_idx, func_expr, span);
            }

            const method_nt: ?Transformer.NewTargetCtx = if (self.options.unsupported.new_target) .method else null;
            const new_body = try visitMethodBodyWithCtx(self, body_idx, span, method_nt);

            const func_flags: u32 = blk: {
                var f: u32 = 0;
                if (is_async) f |= 0x01;
                if (is_generator) f |= 0x02;
                break :blk f;
            };

            const none = @intFromEnum(NodeIndex.none);
            const new_params_node = try self.ast.addFormalParameters(new_params, span);
            const func_extra = try self.ast.addExtras(&.{
                none, // anonymous
                @intFromEnum(new_params_node),
                @intFromEnum(new_body),
                func_flags,
                none,
            });
            const func_expr = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            return buildMethodAssignment(self, info, class_name_span, key_idx, func_expr, span);
        }

        /// return call_expr 를 body로 하는 function expression 생성.
        /// var_decl이 있으면 body 앞에 추가 (hoisted vars).
        /// arrow lowering 결과 `_this`/`_arguments` 캡처가 필요하면 호출자가 미리
        /// arrow env 스코프 안에서 needs_this_var/needs_arguments_var 가 set 되도록 한다.
        fn buildWrappedFunc(
            self: *Transformer,
            call_expr: NodeIndex,
            var_decl: NodeIndex,
            params: ast_mod.NodeList,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call_expr, .flags = 0 } },
            });
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            if (self.options.unsupported.arrow) {
                var capture_stmts: [2]NodeIndex = undefined;
                const count = try es_helpers.fillThisArgumentsCaptures(self, &capture_stmts, span);
                try self.scratch.appendSlice(self.allocator, capture_stmts[0..count]);
            }
            if (!var_decl.isNone()) try self.scratch.append(self.allocator, var_decl);
            try self.scratch.append(self.allocator, return_stmt);

            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const wrapper_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });
            const none = @intFromEnum(NodeIndex.none);
            const params_node = try self.ast.addFormalParameters(params, span);
            const func_extra = try self.ast.addExtras(&.{
                none,
                @intFromEnum(params_node),
                @intFromEnum(wrapper_body),
                0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        pub fn buildBooleanProp(self: *Transformer, name: []const u8, value: bool, span: Span) Transformer.Error!NodeIndex {
            const key = try es_helpers.makeIdentifierRef(self, name);
            const value_span = try self.ast.addString(if (value) "true" else "false");
            const val = try self.ast.addNode(.{
                .tag = .boolean_literal,
                .span = value_span,
                .data = .{ .none = if (value) 0 else 1 },
            });
            return self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = key, .right = val, .flags = 0 } },
            });
        }

        pub fn buildValueProp(self: *Transformer, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const key = try es_helpers.makeIdentifierRef(self, "value");
            return self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
            });
        }

        /// method → Object.defineProperty(ClassName.prototype, "method", { configurable: true, writable: true, value: function() {} })
        /// static method → Object.defineProperty(ClassName, "method", { configurable: true, writable: true, value: function() {} })
        fn buildMethodAssignment(self: *Transformer, info: MethodInfo, class_name_span: Span, key_idx: NodeIndex, func_expr: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const target = if (info.is_static)
                try es_helpers.makeIdentifierRefFromSpan(self, class_name_span)
            else
                try buildFreshPrototypeRef(self, class_name_span, span);

            const config_prop = try buildBooleanProp(self, "configurable", true, span);
            const writable_prop = try buildBooleanProp(self, "writable", true, span);
            const value_prop = try buildValueProp(self, func_expr, span);
            const desc_list = try self.ast.addNodeList(&.{ config_prop, writable_prop, value_prop });
            const desc_obj = try self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = desc_list },
            });

            const obj_str_span = try self.ast.addString("Object");
            const dp_str_span = try self.ast.addString("defineProperty");
            const key_arg = try es_helpers.buildDefinePropertyKeyArg(self, key_idx);
            const call = try es_helpers.buildObjectDefinePropertyCall(self, obj_str_span, dp_str_span, target, key_arg, desc_obj, span);
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = info.member_span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// getter/setter → Object.defineProperty(target, "prop", { get/set: function() {} })
        pub fn emitAccessors(self: *Transformer, items: []const AccessorInfo, class_name_span: Span, span: Span) Transformer.Error!void {
            const obj_str_span = try self.ast.addString("Object");
            const dp_str_span = try self.ast.addString("defineProperty");

            // 처리 완료된 accessor 추적 (비인접 getter/setter 쌍 지원)
            var used = try self.allocator.alloc(bool, items.len);
            defer self.allocator.free(used);
            @memset(used, false);

            for (items, 0..) |info, i| {
                if (used[i]) continue;
                used[i] = true;

                const member = self.ast.getNode(info.member_idx);
                const me = member.data.extra;
                // mutation 이전 읽기 — 캐시 불필요, readNodeIdx 사용.
                const key_idx = self.readNodeIdx(me, MethodExtra.key);

                const func_expr = try buildAccessorFunc(self, info.member_idx, span);
                const accessor_key = try es_helpers.makeIdentifierRef(self, if (info.is_getter) "get" else "set");
                const prop1 = try self.ast.addNode(.{
                    .tag = .object_property,
                    .span = info.member_span,
                    .data = .{ .binary = .{ .left = accessor_key, .right = func_expr, .flags = 0 } },
                });

                // 전체 리스트에서 같은 key의 짝(getter↔setter) 찾기
                var paired_prop: ?NodeIndex = null;
                for (items[i + 1 ..], i + 1..) |next, j| {
                    if (used[j]) continue;
                    const next_member = self.ast.getNode(next.member_idx);
                    const next_me = next_member.data.extra;
                    // buildAccessorFunc 이후 extra_data가 재할당될 수 있으므로 캐시 금지 (#788).
                    const next_key = self.readNodeIdx(next_me, 0);
                    if (info.is_static == next.is_static and info.is_getter != next.is_getter and
                        keysMatch(self, key_idx, next_key))
                    {
                        used[j] = true;
                        const pair_func = try buildAccessorFunc(self, next.member_idx, span);
                        const pair_key = try es_helpers.makeIdentifierRef(self, if (next.is_getter) "get" else "set");
                        paired_prop = try self.ast.addNode(.{
                            .tag = .object_property,
                            .span = next.member_span,
                            .data = .{ .binary = .{ .left = pair_key, .right = pair_func, .flags = 0 } },
                        });
                        break;
                    }
                }

                // configurable: true — ES6 class getter/setter는 스펙상 configurable.
                // ES5 Object.defineProperty의 기본값은 false이므로 명시 필요.
                // 이를 누락하면 이후 Object.defineProperties로 재정의 시 TypeError 발생.
                const config_key = try es_helpers.makeIdentifierRef(self, "configurable");
                const true_span = try self.ast.addString("true");
                const config_val = try self.ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = true_span,
                    .data = .{ .none = 0 },
                });
                const config_prop = try self.ast.addNode(.{
                    .tag = .object_property,
                    .span = span,
                    .data = .{ .binary = .{ .left = config_key, .right = config_val, .flags = 0 } },
                });

                // descriptor object: { configurable: true, get: fn, set: fn } 또는 { configurable: true, get: fn }
                const obj_list = if (paired_prop) |pp|
                    try self.ast.addNodeList(&.{ config_prop, prop1, pp })
                else
                    try self.ast.addNodeList(&.{ config_prop, prop1 });
                const desc_obj = try self.ast.addNode(.{
                    .tag = .object_expression,
                    .span = span,
                    .data = .{ .list = obj_list },
                });

                // target (IIFE fresh identifier — symbol 전파 없음)
                const target = if (info.is_static)
                    try es_helpers.makeIdentifierRefFromSpan(self, class_name_span)
                else
                    try buildFreshPrototypeRef(self, class_name_span, span);

                const key_str = try es_helpers.buildDefinePropertyKeyArg(self, key_idx);
                const call = try es_helpers.buildObjectDefinePropertyCall(self, obj_str_span, dp_str_span, target, key_str, desc_obj, span);
                const stmt = try self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = info.member_span,
                    .data = .{ .unary = .{ .operand = call, .flags = 0 } },
                });
                try self.pending_nodes.append(self.allocator, stmt);
            }
        }
    };
}
