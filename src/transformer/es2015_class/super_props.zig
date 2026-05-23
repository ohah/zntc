//! Super call and super property helpers for ES2015 class lowering.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const assign_ops = @import("assign_ops.zig");
const constructors_mod = @import("constructors.zig");

const compoundAssignBaseOp = assign_ops.compoundAssignBaseOp;

pub fn SuperProps(comptime Transformer: type) type {
    return struct {
        const constructors = constructors_mod.Constructors(Transformer);
        const buildAssertThisInitialized = constructors.buildAssertThisInitialized;

        /// transparent wrapper(괄호, TS as 등) 안쪽이 super_expression 인지 검사 (#2030).
        /// wrapper-unwrap 자체는 `es_helpers.unwrapTransparentWrappers` 가 담당.
        fn isSuperUnwrapped(self: *Transformer, idx: NodeIndex) bool {
            const inner = es_helpers.unwrapTransparentWrappers(self, idx);
            if (inner.isNone()) return false;
            return self.ast.getNode(inner).tag == .super_expression;
        }

        /// call_expression의 callee가 super_expression인지 확인.
        pub fn isSuperCall(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            return isSuperUnwrapped(self, callee);
        }

        /// super(args) → __callSuper(_super, [args], _newTarget)
        /// Reflect.construct를 사용하여 네이티브 클래스 extends도 지원.
        /// _newTarget 은 derived constructor body 시작에 캡쳐된 `this.constructor` —
        /// arrow 안의 super() 도 closure 로 동일 값을 보존하고, multi-level chain
        /// 에서도 항상 top-level NewTarget 을 가리켜 prototype propagation 이 정확하다.
        /// super() 호출 후 this → _this 별칭을 활성화하여
        /// __callSuper가 반환하는 새 객체를 올바르게 참조.
        /// call_expression: extra = [callee, args_start, args_len, flags]
        pub fn lowerSuperCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const e = node.data.extra;
            const args_start = self.readU32(e, 1);
            const args_len = self.readU32(e, 2);
            const span = node.span;

            const callee = try es_helpers.makeRuntimeHelperRef(self, "__callSuper");

            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
            const new_target_ref = try es_helpers.makeIdentifierRef(self, "_newTarget");
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            {
                var i_loop: u32 = 0;
                while (i_loop < args_len) : (i_loop += 1) {
                    const raw_idx = self.ast.extra_data.items[args_start + i_loop];
                    const new_arg = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_arg.isNone()) {
                        try self.scratch.append(self.allocator, new_arg);
                    }
                }
            }

            const elems = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const args_array = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = elems },
            });

            const call = try es_helpers.makeCallExpr(self, callee, &.{ parent_ref, args_array, new_target_ref }, span);

            // _this = __callSuper(_super, [args], _newTarget)
            // 대입식으로 반환하여 super()가 if/else 등 어디에 있든 동작.
            // var _this / var _newTarget 선언과 return 검사는 postProcessDerivedConstructorBody에서 추가.
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            const raw_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = this_ref, .right = call, .flags = 0 } },
            });
            const assert_uninit = try es_helpers.makeRuntimeHelperRef(self, "__assertThisUninitialized");
            const current_this = try es_helpers.makeIdentifierRef(self, "_this");
            const assert_call = try es_helpers.makeCallExpr(self, assert_uninit, &.{current_this}, span);

            const seq_list = try self.ast.addNodeList(&.{ assert_call, raw_assign });
            const seq = try self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });

            self.super_call_this_alias = true;
            self.runtime_helpers.call_super = true;
            self.runtime_helpers.derived_constructor = true;

            return es_helpers.makeParenExpr(self, seq, span);
        }

        /// call_expression의 callee가 super.method (static_member_expression + super) 인지 확인.
        pub fn isSuperMethodCall(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            if (callee.isNone()) return false;
            const callee_node = self.ast.getNode(callee);
            if (callee_node.tag != .static_member_expression) return false;
            const me = callee_node.data.extra;
            if (me >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[me]);
            return isSuperUnwrapped(self, obj);
        }

        /// super.method(args) → Parent.prototype.method.call(this, args)
        /// static method 안에서는 Parent.method.call(this, args)
        /// V2/V5: non-derived class (current_super_class=null) 도 lowering — buildSuperBaseRef 가
        /// Object.prototype / Function.prototype 으로 fallback.
        pub fn lowerSuperMethodCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const callee_idx: NodeIndex = self.readNodeIdx(e, 0);
            const args_start = self.readU32(e, 1);
            const args_len = self.readU32(e, 2);
            const span = node.span;

            // callee = super.method → 메서드 이름 추출
            const callee_node = self.ast.getNode(callee_idx);
            const ce = callee_node.data.extra;
            const method_prop_idx: NodeIndex = self.readNodeIdx(ce, 1);

            // Parent.prototype.method 또는 static Parent.method
            const super_base = try buildSuperBaseRef(self, span);
            const new_method_prop = try self.visitNode(method_prop_idx);
            const method_member = try es_helpers.makeStaticMember(self, super_base, new_method_prop, span);

            // Parent.prototype.method.call
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const call_callee = try es_helpers.makeStaticMember(self, method_member, call_prop, span);

            // args: [this, ...original_args]
            const this_node = try buildSuperReceiver(self, span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, this_node);
            {
                var i_loop: u32 = 0;
                while (i_loop < args_len) : (i_loop += 1) {
                    const raw_idx = self.ast.extra_data.items[args_start + i_loop];
                    const new_arg = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_arg.isNone()) {
                        try self.scratch.append(self.allocator, new_arg);
                    }
                }
            }

            const new_args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(call_callee), new_args.start, new_args.len, 0,
            });
            return self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// static_member_expression의 object가 super_expression인지 확인.
        pub fn isSuperMember(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[e]);
            return isSuperUnwrapped(self, obj);
        }

        const SuperPropRef = struct {
            init: NodeIndex,
            read: NodeIndex,
            value: NodeIndex,
            write: NodeIndex,
        };

        fn cloneNewNode(self: *Transformer, idx: NodeIndex) Transformer.Error!NodeIndex {
            const cloned = try self.ast.addNode(self.ast.getNode(idx));
            self.copySymbolId(idx, cloned);
            return cloned;
        }

        fn makeStringLiteralFromText(self: *Transformer, text: []const u8) Transformer.Error!NodeIndex {
            var escaped = std.ArrayList(u8).empty;
            defer escaped.deinit(self.allocator);
            try escaped.append(self.allocator, '"');
            for (text) |c| {
                switch (c) {
                    '\\', '"' => {
                        try escaped.append(self.allocator, '\\');
                        try escaped.append(self.allocator, c);
                    },
                    else => try escaped.append(self.allocator, c),
                }
            }
            try escaped.append(self.allocator, '"');
            const lit_span = try self.ast.addString(escaped.items);
            return self.ast.addNode(.{
                .tag = .string_literal,
                .span = lit_span,
                .data = .{ .string_ref = lit_span },
            });
        }

        fn makeStaticSuperPropArg(self: *Transformer, prop_idx: NodeIndex) Transformer.Error!NodeIndex {
            const prop = self.ast.getNode(prop_idx);
            const text = if (prop.tag == .identifier_reference or prop.tag == .binding_identifier)
                self.ast.getText(prop.data.string_ref)
            else
                self.ast.getText(prop.span);
            return makeStringLiteralFromText(self, text);
        }

        fn makeSuperPropRefForAssignment(self: *Transformer, prop_idx: NodeIndex, is_computed: bool, span: Span) Transformer.Error!SuperPropRef {
            if (!is_computed) {
                const read = try makeStaticSuperPropArg(self, prop_idx);
                return .{
                    .init = .none,
                    .read = read,
                    .value = try cloneNewNode(self, read),
                    .write = try cloneNewNode(self, read),
                };
            }

            const visited = try self.visitNode(prop_idx);
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const temp_lhs = try es_helpers.makeTempVarRef(self, temp_span, span);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = temp_lhs,
                    .right = visited,
                    .flags = @intFromEnum(token_mod.Kind.eq),
                } },
            });
            return .{
                .init = assign,
                .read = try es_helpers.makeTempVarRef(self, temp_span, span),
                .value = try es_helpers.makeTempVarRef(self, temp_span, span),
                .write = try es_helpers.makeTempVarRef(self, temp_span, span),
            };
        }

        fn wrapSuperPropInit(self: *Transformer, prop_ref: SuperPropRef, expr: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (prop_ref.init.isNone()) return expr;
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            try self.scratch.append(self.allocator, prop_ref.init);
            try self.scratch.append(self.allocator, expr);
            const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const seq = try self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
            return es_helpers.makeParenExpr(self, seq, span);
        }

        /// ClassName.prototype static_member_expression 생성.
        /// class_name_old_idx는 OLD AST 노드 — symbol 기반 리네이밍 대상.
        fn buildPrototypeRef(self: *Transformer, class_name_span: Span, class_name_old_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const class_ref = try self.makeIdentifierRefWithSymbol(class_name_span, class_name_old_idx);
            const proto_prop = try es_helpers.makeIdentifierRef(self, "prototype");
            return es_helpers.makeStaticMember(self, class_ref, proto_prop, span);
        }

        /// V2/V5/V6 fix: non-derived class (current_super_class=null) 에서도 spec 상
        /// super 가 valid 하므로 home object [[Prototype]] 으로 fallback emit.
        /// - instance method: `globalThis.Object.prototype`
        /// - static method:   `globalThis.Function.prototype`
        ///   (class 자체가 함수이므로 D.[[Prototype]] = Function.prototype.)
        /// `globalThis` 사용으로 user 의 `const Object = ...` shadow 에 영향 안 받음
        /// (ES2017 표준). 우리 transpile 타깃이 ES2017 이하면 일반 `Object` 로 fallback 가능하나
        /// 현 시점 default target 은 ES2021+ 이라 globalThis 안전.
        fn buildNonDerivedSuperBase(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const root_name = if (self.current_super_is_static) "Function" else "Object";
            const global_ref = try es_helpers.makeIdentifierRef(self, "globalThis");
            const root_ref = try es_helpers.makeIdentifierRef(self, root_name);
            const proto_ref = try es_helpers.makeIdentifierRef(self, "prototype");
            const global_root = try es_helpers.makeStaticMember(self, global_ref, root_ref, span);
            return es_helpers.makeStaticMember(self, global_root, proto_ref, span);
        }

        fn buildSuperBaseRef(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse {
                // non-derived class — fallback to spec home object [[Prototype]]
                return buildNonDerivedSuperBase(self, span);
            };
            if (self.current_super_is_static) {
                return self.makeIdentifierRefWithSymbol(super_class_span, self.current_super_class_old_idx);
            }
            return buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);
        }

        fn buildSuperReceiver(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            if (self.current_super_static_receiver) |receiver_span| {
                return es_helpers.makeIdentifierRefFromSpan(self, receiver_span);
            }
            // derived constructor body 안에서는 super() lowering 이 인스턴스를 _this 에 저장하므로
            // super.x / super.x = v 의 receiver 도 외부 `this` 가 아닌 _this 여야 한다 (#2022).
            if (self.super_call_this_alias) {
                return buildAssertThisInitialized(self, span);
            }
            return makeThisOrAlias(self, span);
        }

        fn buildSuperPropGet(self: *Transformer, prop_arg: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // V2/V5: current_super_class=null 인 non-derived 케이스도 lowering — buildSuperBaseRef
            // 가 Object.prototype / Function.prototype 으로 fallback.
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__superGet");
            const base = try buildSuperBaseRef(self, span);
            const receiver = try buildSuperReceiver(self, span);
            self.runtime_helpers.super_get = true;
            return es_helpers.makeCallExpr(self, helper, &.{ base, prop_arg, receiver }, span);
        }

        fn buildSuperPropSet(self: *Transformer, prop_arg: NodeIndex, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__superSet");
            const base = try buildSuperBaseRef(self, span);
            const receiver = try buildSuperReceiver(self, span);
            self.runtime_helpers.super_set = true;
            return es_helpers.makeCallExpr(self, helper, &.{ base, prop_arg, value, receiver }, span);
        }

        /// super.method → __superGet(Parent.prototype, "method", this)
        /// static_member_expression: extra = [object, property, flags]
        pub fn lowerSuperMember(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const prop_idx: NodeIndex = self.readNodeIdx(e, 1);
            const span = node.span;
            return buildSuperPropGet(self, try makeStaticSuperPropArg(self, prop_idx), span);
        }

        /// computed_member_expression의 object가 super_expression인지 확인.
        /// super["prop"] 형태를 감지한다.
        pub fn isSuperComputedMember(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[e]);
            return isSuperUnwrapped(self, obj);
        }

        /// super["prop"] → __superGet(Parent.prototype, "prop", this)
        pub fn lowerSuperComputedMember(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const prop_idx: NodeIndex = self.readNodeIdx(e, 1);
            const span = node.span;
            return buildSuperPropGet(self, try self.visitNode(prop_idx), span);
        }

        /// super.x = v / super.x += v / super.x ||= v 를 receiver 보존 helper로 낮춘다.
        pub fn lowerSuperPropertyAssignment(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const left_idx = node.data.binary.left;
            if (left_idx.isNone()) return null;
            const left = self.ast.getNode(left_idx);
            const is_computed = switch (left.tag) {
                .static_member_expression => false,
                .computed_member_expression => true,
                else => return null,
            };
            const le = left.data.extra;
            if (le >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(le, 0);
            if (!isSuperUnwrapped(self, obj_idx)) return null;

            const prop_idx: NodeIndex = self.readNodeIdx(le, 1);
            const op_kind: token_mod.Kind = @enumFromInt(node.data.binary.flags);
            const span = node.span;

            if (op_kind == .eq) {
                const prop_arg = if (is_computed)
                    try self.visitNode(prop_idx)
                else
                    try makeStaticSuperPropArg(self, prop_idx);
                const new_rhs = try self.visitNode(node.data.binary.right);
                return buildSuperPropSet(self, prop_arg, new_rhs, span);
            }

            const prop_ref = try makeSuperPropRefForAssignment(self, prop_idx, is_computed, span);

            if (op_kind == .question2_eq or op_kind == .pipe2_eq or op_kind == .amp2_eq) {
                const get_read = try buildSuperPropGet(self, prop_ref.read, span);
                const new_rhs = try self.visitNode(node.data.binary.right);
                const set_call = try buildSuperPropSet(self, prop_ref.write, new_rhs, span);

                if (op_kind == .pipe2_eq or op_kind == .amp2_eq) {
                    const logical_op: token_mod.Kind = if (op_kind == .pipe2_eq) .pipe2 else .amp2;
                    const logical = try self.ast.addNode(.{
                        .tag = .logical_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = get_read, .right = set_call, .flags = @intFromEnum(logical_op) } },
                    });
                    return wrapSuperPropInit(self, prop_ref, logical, span);
                }

                if (self.options.unsupported.nullish_coalescing) {
                    const read_capture = try es_helpers.captureToTemp(self, get_read, span);
                    const neq_null = try es_helpers.makeNeqNull(self, read_capture.paren_assign, span);
                    const get_value = try es_helpers.makeTempVarRef(self, read_capture.span, span);
                    const cond = try self.ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = neq_null, .b = get_value, .c = set_call } },
                    });
                    return wrapSuperPropInit(self, prop_ref, cond, span);
                }
                const logical = try self.ast.addNode(.{
                    .tag = .logical_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = get_read, .right = set_call, .flags = @intFromEnum(token_mod.Kind.question2) } },
                });
                return wrapSuperPropInit(self, prop_ref, logical, span);
            }

            if (compoundAssignBaseOp(node.data.binary.flags)) |bin_op| {
                const get_call = try buildSuperPropGet(self, prop_ref.read, span);
                const new_rhs = try self.visitNode(node.data.binary.right);
                const computed = if (bin_op == @intFromEnum(token_mod.Kind.star2) and self.options.unsupported.exponentiation)
                    try es_helpers.makeMathPowCall(self, get_call, new_rhs, span)
                else
                    try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = get_call, .right = new_rhs, .flags = bin_op } },
                    });
                const set_call = try buildSuperPropSet(self, prop_ref.write, computed, span);
                return wrapSuperPropInit(self, prop_ref, set_call, span);
            }

            return null;
        }

        /// super.x++ / --super[x] 도 get/set helper로 낮춘다.
        pub fn lowerSuperPropertyUpdate(self: *Transformer, node: Node, op_flags: u32, span: Span) ?Transformer.Error!NodeIndex {
            const is_computed = switch (node.tag) {
                .static_member_expression => false,
                .computed_member_expression => true,
                else => return null,
            };
            const e = node.data.extra;
            if (e >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(e, 0);
            if (!isSuperUnwrapped(self, obj_idx)) return null;

            const op_kind = op_flags & 0xff;
            const is_increment = (op_kind == @intFromEnum(token_mod.Kind.plus2));
            const is_postfix = (op_flags & ast_mod.UnaryFlags.postfix) != 0;
            const bin_op: u16 = if (is_increment) @intFromEnum(token_mod.Kind.plus) else @intFromEnum(token_mod.Kind.minus);
            const prop_ref = try makeSuperPropRefForAssignment(self, self.readNodeIdx(e, 1), is_computed, span);

            if (is_postfix) {
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);

                const temp_span = try es_helpers.makeTempVarSpan(self);
                const get_call = try buildSuperPropGet(self, prop_ref.read, span);
                const tmp_lhs = try es_helpers.makeTempVarRef(self, temp_span, span);
                const init_old = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = tmp_lhs, .right = get_call, .flags = @intFromEnum(token_mod.Kind.eq) } },
                });
                try self.scratch.append(self.allocator, init_old);

                const computed = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{
                        .left = try es_helpers.makeTempVarRef(self, temp_span, span),
                        .right = try es_helpers.makeNumericLiteral(self, 1),
                        .flags = bin_op,
                    } },
                });
                try self.scratch.append(self.allocator, try buildSuperPropSet(self, prop_ref.write, computed, span));
                try self.scratch.append(self.allocator, try es_helpers.makeTempVarRef(self, temp_span, span));

                const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const seq = try self.ast.addNode(.{
                    .tag = .sequence_expression,
                    .span = span,
                    .data = .{ .list = seq_list },
                });
                const paren = try es_helpers.makeParenExpr(self, seq, span);
                return wrapSuperPropInit(self, prop_ref, paren, span);
            }

            const get_call = try buildSuperPropGet(self, prop_ref.read, span);
            const computed = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = get_call, .right = try es_helpers.makeNumericLiteral(self, 1), .flags = bin_op } },
            });
            const set_call = try buildSuperPropSet(self, prop_ref.write, computed, span);
            return wrapSuperPropInit(self, prop_ref, set_call, span);
        }

        /// call_expression의 callee가 super["method"] 인지 확인.
        pub fn isSuperComputedMethodCall(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            if (callee.isNone()) return false;
            const callee_node = self.ast.getNode(callee);
            if (callee_node.tag != .computed_member_expression) return false;
            const me = callee_node.data.extra;
            if (me >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[me]);
            return isSuperUnwrapped(self, obj);
        }

        /// super["method"](args) → Parent.prototype["method"].call(this, args)
        /// static method 안에서는 Parent["method"].call(this, args)
        /// V2/V5: non-derived class 도 lowering — buildSuperBaseRef fallback.
        pub fn lowerSuperComputedMethodCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const callee_idx: NodeIndex = self.readNodeIdx(e, 0);
            const args_start = self.readU32(e, 1);
            const args_len = self.readU32(e, 2);
            const span = node.span;

            const callee_node = self.ast.getNode(callee_idx);
            const ce = callee_node.data.extra;
            const method_prop_idx: NodeIndex = self.readNodeIdx(ce, 1);

            const super_base = try buildSuperBaseRef(self, span);
            const new_method_prop = try self.visitNode(method_prop_idx);
            const method_member = try es_helpers.makeComputedMember(self, super_base, new_method_prop, span);

            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const call_callee = try es_helpers.makeStaticMember(self, method_member, call_prop, span);

            const this_node = try buildSuperReceiver(self, span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            try self.scratch.append(self.allocator, this_node);
            {
                var i_loop: u32 = 0;
                while (i_loop < args_len) : (i_loop += 1) {
                    const raw_idx = self.ast.extra_data.items[args_start + i_loop];
                    const new_arg = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_arg.isNone()) {
                        try self.scratch.append(self.allocator, new_arg);
                    }
                }
            }

            const new_args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(call_callee), new_args.start, new_args.len, 0,
            });
            return self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        // ================================================================
        // 내부 헬퍼
        // ================================================================

        /// arrow function 내부이면 _this, 아니면 this 노드 생성.
        /// super() / super.method() 변환에서 공통 사용.
        fn makeThisOrAlias(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                self.needs_this_var = true;
                return es_helpers.makeIdentifierRef(self, "_this");
            }
            return self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
        }
    };
}
