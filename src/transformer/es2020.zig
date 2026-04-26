//! ES2020 다운레벨링: ?? (nullish coalescing) + ?. (optional chaining)
//!
//! --target < es2020 일 때 활성화.
//! ?? → a != null ? a : b
//! ?. → a == null ? void 0 : a.b
//!
//! 스펙:
//! - ?? : https://tc39.es/ecma262/#sec-nullish-coalescing-operator (ES2020, TC39 Stage 4: 2020-01)
//!         https://github.com/tc39/proposal-nullish-coalescing
//! - ?. : https://tc39.es/ecma262/#sec-optional-chains (ES2020, TC39 Stage 4: 2020-01)
//!         https://github.com/tc39/proposal-optional-chaining
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerNullishCoalescing, lowerOptionalChain)
//! - oxc: crates/oxc_transformer/src/es2020/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const helpers = @import("es_helpers.zig");
const es2015_class = @import("es2015_class.zig");

/// Transformer 타입 (순환 import 방지를 위해 generic)
pub fn ES2020(comptime Transformer: type) type {
    return struct {
        /// `a ?? b` → `a != null ? a : b`
        pub fn lowerNullishCoalescing(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const old_left_idx = node.data.binary.left;
            const simple = helpers.isSimpleIdentifier(self, old_left_idx);

            const new_left = try self.visitNode(old_left_idx);
            const new_right = try self.visitNode(node.data.binary.right);

            const null_span = try self.ast.addString("null");
            const null_node = try self.ast.addNode(.{
                .tag = .null_literal,
                .span = null_span,
                .data = .{ .none = 0 },
            });

            if (simple) {
                const left_copy = try self.ast.addNode(self.ast.getNode(new_left));
                self.copySymbolId(new_left, left_copy);
                const neq_null = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = new_left,
                        .right = null_node,
                        .flags = @intFromEnum(token_mod.Kind.neq),
                    } },
                });
                return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = neq_null, .b = left_copy, .c = new_right } },
                });
            } else {
                const temp_span = try helpers.makeTempVarSpan(self);
                const temp_ref1 = try helpers.makeTempVarRef(self, temp_span, node.span);
                const assign_node = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = temp_ref1,
                        .right = new_left,
                        .flags = @intFromEnum(token_mod.Kind.eq),
                    } },
                });
                const paren_assign = try helpers.makeParenExpr(self, assign_node, node.span);
                const neq_null = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = paren_assign,
                        .right = null_node,
                        .flags = @intFromEnum(token_mod.Kind.neq),
                    } },
                });
                const temp_ref2 = try helpers.makeTempVarRef(self, temp_span, node.span);
                return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = neq_null, .b = temp_ref2, .c = new_right } },
                });
            }
        }

        // ================================================================
        // Optional chaining
        // ================================================================

        pub fn findOptionalChainBase(self: *const Transformer, node: Node) ?NodeIndex {
            var current = node;
            while (true) {
                if (hasOptionalFlag(self, current)) return getChainObject(self, current);
                switch (current.tag) {
                    .static_member_expression, .computed_member_expression, .private_field_expression, .call_expression => {
                        const obj_idx = getChainObject(self, current);
                        if (obj_idx.isNone()) return null;
                        current = self.ast.getNode(obj_idx);
                    },
                    else => return null,
                }
            }
        }

        /// optional chain lowering 컨텍스트.
        /// `.normal`: short-circuit 시 `void 0` 반환.
        /// `.delete`: short-circuit 시 `true` 반환, 본 체인 마지막 access는 `delete` 로 감쌈.
        ///   `delete a?.b` 가 `delete (cond ? void 0 : a.b)` 로 변환되면 ConditionalExpression
        ///   결과에 delete 가 적용되어 Reference 가 아니므로 실제 삭제가 일어나지 않는 spec 함정 회피.
        pub const LowerCtx = enum { normal, delete };

        pub fn lowerOptionalChain(self: *Transformer, node: Node, base_idx: NodeIndex) Transformer.Error!NodeIndex {
            return lowerOptionalChainCtx(self, node, base_idx, .normal);
        }

        pub fn lowerOptionalChainCtx(
            self: *Transformer,
            node: Node,
            base_idx: NodeIndex,
            ctx: LowerCtx,
        ) Transformer.Error!NodeIndex {
            const optional_member_call = if (ctx == .normal)
                try prepareOptionalMemberCall(self, node, base_idx)
            else
                null;
            if (optional_member_call) |mc| {
                if (mc.full_result) |result| return result;
            }

            const simple = optional_member_call == null and helpers.isSimpleIdentifier(self, base_idx);
            const visited_base = if (optional_member_call) |mc| mc.null_check_base else try self.visitNode(base_idx);

            var null_check_base: NodeIndex = undefined;
            var chain_base: NodeIndex = undefined;

            if (optional_member_call) |mc| {
                null_check_base = mc.null_check_base;
                chain_base = mc.chain_base;
            } else if (simple) {
                null_check_base = visited_base;
                chain_base = try self.ast.addNode(self.ast.getNode(visited_base));
                // symbol_id 전파: 복제된 노드에도 rename이 적용되도록
                self.copySymbolId(visited_base, chain_base);
            } else {
                const temp_span = try helpers.makeTempVarSpan(self);
                const temp_ref1 = try helpers.makeTempVarRef(self, temp_span, node.span);
                const assign_node = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = temp_ref1,
                        .right = visited_base,
                        .flags = @intFromEnum(token_mod.Kind.eq),
                    } },
                });
                null_check_base = try helpers.makeParenExpr(self, assign_node, node.span);
                chain_base = try helpers.makeTempVarRef(self, temp_span, node.span);
            }

            const rebuilt_chain = if (optional_member_call) |mc|
                try rebuildChainNodeWithOptionalMemberCallThis(self, node, chain_base, base_idx, mc.receiver)
            else
                try rebuildChainNode(self, node, chain_base);
            const eq_null = try helpers.makeEqNull(self, null_check_base, node.span);

            const b_branch: NodeIndex, const c_branch: NodeIndex = switch (ctx) {
                .normal => .{ try helpers.makeVoidZero(self, node.span), rebuilt_chain },
                .delete => .{ try makeTrueLiteral(self, node.span), try makeDeleteOf(self, rebuilt_chain, node.span) },
            };

            const cond = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = node.span,
                .data = .{ .ternary = .{ .a = eq_null, .b = b_branch, .c = c_branch } },
            });
            // 괄호로 감싸서 binary expression 안에서 우선순위 보장
            // 예: a?.b !== c?.d → (a == null ? void 0 : a.b) !== (c == null ? void 0 : c.d)
            return helpers.makeParenExpr(self, cond, node.span);
        }

        const OptionalMemberCall = struct {
            null_check_base: NodeIndex,
            chain_base: NodeIndex,
            receiver: NodeIndex,
            full_result: ?NodeIndex = null,
        };

        fn prepareOptionalMemberCall(self: *Transformer, root: Node, base_idx: NodeIndex) Transformer.Error!?OptionalMemberCall {
            if (!isOptionalCallBase(self, root, base_idx)) return null;

            const base = self.ast.getNode(base_idx);
            switch (base.tag) {
                .static_member_expression, .computed_member_expression => {},
                else => return null,
            }

            const e = base.data.extra;
            const old_obj = self.readNodeIdx(e, 0);
            const old_prop = self.readNodeIdx(e, 1);
            const flags = self.readU32(e, 2);

            if ((flags & ast_mod.MemberFlags.optional_chain) != 0) {
                if (try lowerOptionalReceiverMethodCall(self, root, base_idx, old_obj, old_prop, flags)) |result| {
                    return .{
                        .null_check_base = result,
                        .chain_base = result,
                        .receiver = result,
                        .full_result = result,
                    };
                }
                return null;
            }

            const obj_simple = helpers.isSimpleIdentifier(self, old_obj);
            const visited_obj = try self.visitNode(old_obj);

            var member_obj: NodeIndex = undefined;
            var receiver: NodeIndex = undefined;
            if (obj_simple) {
                member_obj = visited_obj;
                receiver = try self.ast.addNode(self.ast.getNode(visited_obj));
                self.copySymbolId(visited_obj, receiver);
            } else {
                const obj_temp_span = try helpers.makeTempVarSpan(self);
                const obj_temp_lhs = try helpers.makeTempVarRef(self, obj_temp_span, root.span);
                const obj_assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = root.span,
                    .data = .{ .binary = .{
                        .left = obj_temp_lhs,
                        .right = visited_obj,
                        .flags = @intFromEnum(token_mod.Kind.eq),
                    } },
                });
                member_obj = try helpers.makeParenExpr(self, obj_assign, root.span);
                receiver = try helpers.makeTempVarRef(self, obj_temp_span, root.span);
            }

            const new_prop = try self.visitNode(old_prop);
            const member_flags = flags & ~ast_mod.MemberFlags.optional_chain;
            const member_extra = try self.ast.addExtras(&.{ @intFromEnum(member_obj), @intFromEnum(new_prop), member_flags });
            const member = try self.ast.addNode(.{ .tag = base.tag, .span = base.span, .data = .{ .extra = member_extra } });

            const fn_temp_span = try helpers.makeTempVarSpan(self);
            const fn_temp_lhs = try helpers.makeTempVarRef(self, fn_temp_span, root.span);
            const fn_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = root.span,
                .data = .{ .binary = .{
                    .left = fn_temp_lhs,
                    .right = member,
                    .flags = @intFromEnum(token_mod.Kind.eq),
                } },
            });

            return .{
                .null_check_base = try helpers.makeParenExpr(self, fn_assign, root.span),
                .chain_base = try helpers.makeTempVarRef(self, fn_temp_span, root.span),
                .receiver = receiver,
            };
        }

        fn lowerOptionalReceiverMethodCall(
            self: *Transformer,
            root: Node,
            base_idx: NodeIndex,
            old_obj: NodeIndex,
            old_prop: NodeIndex,
            member_flags: u32,
        ) Transformer.Error!?NodeIndex {
            if (root.tag != .call_expression) return null;
            const call_e = root.data.extra;
            const old_callee = self.readNodeIdx(call_e, 0);
            const call_flags = self.readU32(call_e, 3);
            if (!sameNodeIndex(old_callee, base_idx) or (call_flags & ast_mod.CallFlags.optional_chain) == 0) {
                return null;
            }

            const obj_simple = helpers.isSimpleIdentifier(self, old_obj);
            const visited_obj = try self.visitNode(old_obj);

            var receiver_check: NodeIndex = undefined;
            var member_obj: NodeIndex = undefined;
            var receiver: NodeIndex = undefined;
            if (obj_simple) {
                receiver_check = visited_obj;
                member_obj = try self.ast.addNode(self.ast.getNode(visited_obj));
                self.copySymbolId(visited_obj, member_obj);
                receiver = try self.ast.addNode(self.ast.getNode(visited_obj));
                self.copySymbolId(visited_obj, receiver);
            } else {
                const obj_temp_span = try helpers.makeTempVarSpan(self);
                const obj_temp_lhs = try helpers.makeTempVarRef(self, obj_temp_span, root.span);
                const obj_assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = root.span,
                    .data = .{ .binary = .{
                        .left = obj_temp_lhs,
                        .right = visited_obj,
                        .flags = @intFromEnum(token_mod.Kind.eq),
                    } },
                });
                receiver_check = try helpers.makeParenExpr(self, obj_assign, root.span);
                member_obj = try helpers.makeTempVarRef(self, obj_temp_span, root.span);
                receiver = try helpers.makeTempVarRef(self, obj_temp_span, root.span);
            }

            const new_prop = try self.visitNode(old_prop);
            const new_member_flags = member_flags & ~ast_mod.MemberFlags.optional_chain;
            const member_extra = try self.ast.addExtras(&.{ @intFromEnum(member_obj), @intFromEnum(new_prop), new_member_flags });
            const member = try self.ast.addNode(.{
                .tag = self.ast.getNode(base_idx).tag,
                .span = self.ast.getNode(base_idx).span,
                .data = .{ .extra = member_extra },
            });

            const fn_temp_span = try helpers.makeTempVarSpan(self);
            const fn_temp_lhs = try helpers.makeTempVarRef(self, fn_temp_span, root.span);
            const fn_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = root.span,
                .data = .{ .binary = .{
                    .left = fn_temp_lhs,
                    .right = member,
                    .flags = @intFromEnum(token_mod.Kind.eq),
                } },
            });
            const fn_check = try helpers.makeParenExpr(self, fn_assign, root.span);
            const inner_eq_null = try helpers.makeEqNull(self, fn_check, root.span);

            const call_prop = try helpers.makeIdentifierRef(self, "call");
            const fn_ref = try helpers.makeTempVarRef(self, fn_temp_span, root.span);
            const call_member = try helpers.makeStaticMember(self, fn_ref, call_prop, root.span);

            const args_start = self.readU32(call_e, 1);
            const args_len = self.readU32(call_e, 2);
            const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });
            var call_args = std.ArrayList(NodeIndex).empty;
            try call_args.ensureTotalCapacity(self.allocator, new_args.len + 1);
            call_args.appendAssumeCapacity(receiver);
            var i: u32 = 0;
            while (i < new_args.len) : (i += 1) {
                call_args.appendAssumeCapacity(@enumFromInt(self.ast.extra_data.items[new_args.start + i]));
            }
            const call = try helpers.makeCallExpr(self, call_member, call_args.items, root.span);

            const inner = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = root.span,
                .data = .{ .ternary = .{ .a = inner_eq_null, .b = try helpers.makeVoidZero(self, root.span), .c = call } },
            });
            const outer_eq_null = try helpers.makeEqNull(self, receiver_check, root.span);
            const outer = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = root.span,
                .data = .{ .ternary = .{ .a = outer_eq_null, .b = try helpers.makeVoidZero(self, root.span), .c = inner } },
            });
            return try helpers.makeParenExpr(self, outer, root.span);
        }

        fn isOptionalCallBase(self: *const Transformer, node: Node, base_idx: NodeIndex) bool {
            switch (node.tag) {
                .call_expression => {
                    const e = node.data.extra;
                    const old_callee = self.readNodeIdx(e, 0);
                    const flags = self.readU32(e, 3);
                    if ((flags & ast_mod.CallFlags.optional_chain) != 0 and sameNodeIndex(old_callee, base_idx)) {
                        return true;
                    }
                    if (old_callee.isNone()) return false;
                    return isOptionalCallBase(self, self.ast.getNode(old_callee), base_idx);
                },
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    const obj = getChainObject(self, node);
                    if (obj.isNone()) return false;
                    return isOptionalCallBase(self, self.ast.getNode(obj), base_idx);
                },
                else => return false,
            }
        }

        fn sameNodeIndex(a: NodeIndex, b: NodeIndex) bool {
            return @intFromEnum(a) == @intFromEnum(b);
        }

        fn makeTrueLiteral(self: *Transformer, _: Span) Transformer.Error!NodeIndex {
            const true_span = try self.ast.addString("true");
            return self.ast.addNode(.{
                .tag = .boolean_literal,
                .span = true_span,
                .data = .{ .none = 1 },
            });
        }

        fn makeDeleteOf(self: *Transformer, operand: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const op_flags: u32 = @intFromEnum(token_mod.Kind.kw_delete);
            const new_extra = try self.ast.addExtras(&.{ @intFromEnum(operand), op_flags });
            return self.ast.addNode(.{
                .tag = .unary_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        fn hasOptionalFlag(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            switch (node.tag) {
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    return (extras[e + 2] & ast_mod.MemberFlags.optional_chain) != 0;
                },
                .call_expression => {
                    const e = node.data.extra;
                    if (e + 3 >= extras.len) return false;
                    return (extras[e + 3] & ast_mod.CallFlags.optional_chain) != 0;
                },
                else => return false,
            }
        }

        fn getChainObject(self: *const Transformer, node: Node) NodeIndex {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            return @enumFromInt(extras[e]);
        }

        fn rebuildChainNode(self: *Transformer, old_node: Node, chain_base: NodeIndex) Transformer.Error!NodeIndex {
            switch (old_node.tag) {
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    const e = old_node.data.extra;
                    const old_obj: NodeIndex = self.readNodeIdx(e, 0);
                    const old_prop: NodeIndex = self.readNodeIdx(e, 1);
                    const flags = self.readU32(e, 2);
                    const is_optional = (flags & ast_mod.MemberFlags.optional_chain) != 0;
                    const new_obj = if (is_optional) chain_base else try rebuildChainNode(self, self.ast.getNode(old_obj), chain_base);
                    // private_field_expression: class body가 lowering 대상이면 여기서 get 호출로
                    // 직접 변환 — 재구성된 private_field_expression이 transformer visit을 거치지 않고
                    // 그대로 codegen되면 `o.#x` 가 class body 밖으로 새어나가 런타임 에러 (#1492).
                    if (old_node.tag == .private_field_expression and
                        (self.options.unsupported.class or self.options.unsupported.class_private_field) and
                        self.current_private_fields.len > 0)
                    {
                        if (try es2015_class.ES2015Class(Transformer).emitPrivateFieldGetWithNewObj(self, old_prop, new_obj, old_node.span)) |call| {
                            return call;
                        }
                    }
                    const new_prop = try self.visitNode(old_prop);
                    const new_flags = flags & ~ast_mod.MemberFlags.optional_chain;
                    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_obj), @intFromEnum(new_prop), new_flags });
                    return self.ast.addNode(.{ .tag = old_node.tag, .span = old_node.span, .data = .{ .extra = new_extra } });
                },
                .call_expression => {
                    const e = old_node.data.extra;
                    const old_callee: NodeIndex = self.readNodeIdx(e, 0);
                    const args_start = self.readU32(e, 1);
                    const args_len = self.readU32(e, 2);
                    const flags = self.readU32(e, 3);
                    const is_optional = (flags & ast_mod.CallFlags.optional_chain) != 0;
                    const new_callee = if (is_optional)
                        try makeOptionalCallCallee(self, old_callee, chain_base, old_node.span)
                    else
                        try rebuildChainNode(self, self.ast.getNode(old_callee), chain_base);
                    const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });
                    const new_flags = flags & ~ast_mod.CallFlags.optional_chain;
                    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_callee), new_args.start, new_args.len, new_flags });
                    return self.ast.addNode(.{ .tag = .call_expression, .span = old_node.span, .data = .{ .extra = new_extra } });
                },
                else => unreachable,
            }
        }

        fn rebuildChainNodeWithOptionalMemberCallThis(
            self: *Transformer,
            old_node: Node,
            chain_base: NodeIndex,
            optional_call_callee_idx: NodeIndex,
            receiver: NodeIndex,
        ) Transformer.Error!NodeIndex {
            switch (old_node.tag) {
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    const e = old_node.data.extra;
                    const old_obj: NodeIndex = self.readNodeIdx(e, 0);
                    const old_prop: NodeIndex = self.readNodeIdx(e, 1);
                    const flags = self.readU32(e, 2);
                    const is_optional = (flags & ast_mod.MemberFlags.optional_chain) != 0;
                    const new_obj = if (is_optional)
                        chain_base
                    else
                        try rebuildChainNodeWithOptionalMemberCallThis(self, self.ast.getNode(old_obj), chain_base, optional_call_callee_idx, receiver);
                    const new_prop = try self.visitNode(old_prop);
                    const new_flags = flags & ~ast_mod.MemberFlags.optional_chain;
                    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_obj), @intFromEnum(new_prop), new_flags });
                    return self.ast.addNode(.{ .tag = old_node.tag, .span = old_node.span, .data = .{ .extra = new_extra } });
                },
                .call_expression => {
                    const e = old_node.data.extra;
                    const old_callee: NodeIndex = self.readNodeIdx(e, 0);
                    const args_start = self.readU32(e, 1);
                    const args_len = self.readU32(e, 2);
                    const flags = self.readU32(e, 3);
                    const is_optional = (flags & ast_mod.CallFlags.optional_chain) != 0;
                    const new_args = try self.visitExtraList(.{ .start = args_start, .len = args_len });

                    if (is_optional and sameNodeIndex(old_callee, optional_call_callee_idx)) {
                        const call_prop = try helpers.makeIdentifierRef(self, "call");
                        const call_member = try helpers.makeStaticMember(self, chain_base, call_prop, old_node.span);
                        var args = std.ArrayList(NodeIndex).empty;
                        try args.ensureTotalCapacity(self.allocator, new_args.len + 1);
                        args.appendAssumeCapacity(receiver);
                        var i: u32 = 0;
                        while (i < new_args.len) : (i += 1) {
                            args.appendAssumeCapacity(@enumFromInt(self.ast.extra_data.items[new_args.start + i]));
                        }
                        return helpers.makeCallExpr(self, call_member, args.items, old_node.span);
                    }

                    const new_callee = if (is_optional)
                        try makeOptionalCallCallee(self, old_callee, chain_base, old_node.span)
                    else
                        try rebuildChainNodeWithOptionalMemberCallThis(self, self.ast.getNode(old_callee), chain_base, optional_call_callee_idx, receiver);
                    const new_flags = flags & ~ast_mod.CallFlags.optional_chain;
                    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_callee), new_args.start, new_args.len, new_flags });
                    return self.ast.addNode(.{ .tag = .call_expression, .span = old_node.span, .data = .{ .extra = new_extra } });
                },
                else => unreachable,
            }
        }

        fn makeOptionalCallCallee(
            self: *Transformer,
            old_callee: NodeIndex,
            chain_base: NodeIndex,
            span: Span,
        ) Transformer.Error!NodeIndex {
            if (!isEvalIdentifier(self, old_callee)) return chain_base;

            // `eval?.()`은 spec상 indirect eval이다. `eval()`로 재구성하면 direct eval이 되어
            // local scope를 건드리므로 Babel/OXC처럼 `(0, eval)()` 형태로 callee Reference를 끊는다.
            const zero = try helpers.makeNumericLiteral(self, 0);
            const seq_list = try self.ast.addNodeList(&.{ zero, chain_base });
            const seq = try self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
            return helpers.makeParenExpr(self, seq, span);
        }

        fn isEvalIdentifier(self: *Transformer, idx: NodeIndex) bool {
            if (idx.isNone()) return false;
            const node = self.ast.getNode(idx);
            if (node.tag != .identifier_reference) return false;
            return std.mem.eql(u8, self.ast.getText(node.data.string_ref), "eval");
        }
    };
}
