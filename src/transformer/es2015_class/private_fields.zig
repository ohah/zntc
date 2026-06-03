//! Private field/accessor lowering for ES2015 class transforms.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const es2022 = @import("../es2022.zig");
const assign_ops = @import("assign_ops.zig");

pub fn PrivateFields(comptime Transformer: type) type {
    return struct {
        /// this.#x → instance: _x.get(this), static: __classStaticPrivateFieldSpecGet(receiver, ClassName, _x)
        /// optional flag가 설정된 노드는 null 반환 — optional chain lowering이 short-circuit과
        /// 함께 처리해야 함 (es2020.lowerOptionalChain 내부 rebuildChainNode에서 get 변환).
        pub fn lowerPrivateFieldGet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const e = node.data.extra;
            if (e >= self.ast.extra_data.items.len) return null;
            const flags = self.readU32(e, 2);
            if ((flags & ast_mod.MemberFlags.optional_chain) != 0) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(e, 0);
            const mapping = findPrivateFieldMapping(self, self.readNodeIdx(e, 1)) orelse return null;
            if (mapping.class_name != null) {
                return buildStaticPrivateFieldGet(self, mapping, obj_idx, node.span);
            }
            return buildWeakMapCall(self, mapping.var_name, "get", obj_idx, &.{}, node.span);
        }

        /// instance/static 분기해서 private field get 호출을 구성.
        fn buildPrivateFieldGetCall(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (mapping.class_name != null) return buildStaticPrivateFieldGet(self, mapping, obj_idx, span);
            return buildWeakMapCall(self, mapping.var_name, "get", obj_idx, &.{}, span);
        }

        /// this.#x = rhs (setter) → __classPrivateMethodGet(obj, _x, _x_set).call(obj, rhs) (#1523).
        fn lowerPrivateSetterCall(self: *Transformer, setter_mapping: Transformer.PrivateMethodMapping, obj_idx: NodeIndex, rhs_old: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.class_private_method_get = true;
            const new_obj = try self.visitNode(obj_idx);
            const new_rhs = try self.visitNode(rhs_old);
            const helper_ref = try es_helpers.makeRuntimeHelperRef(self, "__classPrivateMethodGet");
            const ws_ref = try es_helpers.makeIdentifierRef(self, setter_mapping.weakset_name);
            const fn_ref = try es_helpers.makeIdentifierRef(self, setter_mapping.func_name);
            const get_call = try es_helpers.makeCallExpr(self, helper_ref, &.{ new_obj, ws_ref, fn_ref }, span);
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const callee = try es_helpers.makeStaticMember(self, get_call, call_prop, span);
            return es_helpers.makeCallExpr(self, callee, &.{ new_obj, new_rhs }, span);
        }

        /// this.#x op= v → set(obj, get(obj) op v). obj 는 3회 visit — this/identifier 는 안전, 복잡 obj 는 정의역 밖 (#1511).
        fn lowerPrivateAccessorCompoundAssign(
            self: *Transformer,
            getter_mapping: Transformer.PrivateMethodMapping,
            setter_mapping: Transformer.PrivateMethodMapping,
            obj_idx: NodeIndex,
            bin_op: u16,
            rhs_old: NodeIndex,
            span: Span,
        ) Transformer.Error!NodeIndex {
            self.runtime_helpers.class_private_method_get = true;

            // getter side: __classPrivateMethodGet(obj, _x, _x_get).call(obj)
            const get_helper = try es_helpers.makeRuntimeHelperRef(self, "__classPrivateMethodGet");
            const get_ws = try es_helpers.makeIdentifierRef(self, getter_mapping.weakset_name);
            const get_fn = try es_helpers.makeIdentifierRef(self, getter_mapping.func_name);
            const get_outer = try es_helpers.makeCallExpr(self, get_helper, &.{ try self.visitNode(obj_idx), get_ws, get_fn }, span);
            const get_call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const get_callee = try es_helpers.makeStaticMember(self, get_outer, get_call_prop, span);
            const get_expr = try es_helpers.makeCallExpr(self, get_callee, &.{try self.visitNode(obj_idx)}, span);

            // 연산: get_expr op rhs
            const new_rhs = try self.visitNode(rhs_old);
            const computed = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = get_expr, .right = new_rhs, .flags = bin_op } },
            });

            // setter side: __classPrivateMethodGet(obj, _x, _x_set).call(obj, computed)
            const set_helper = try es_helpers.makeRuntimeHelperRef(self, "__classPrivateMethodGet");
            const set_ws = try es_helpers.makeIdentifierRef(self, setter_mapping.weakset_name);
            const set_fn = try es_helpers.makeIdentifierRef(self, setter_mapping.func_name);
            const set_outer = try es_helpers.makeCallExpr(self, set_helper, &.{ try self.visitNode(obj_idx), set_ws, set_fn }, span);
            const set_call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const set_callee = try es_helpers.makeStaticMember(self, set_outer, set_call_prop, span);
            return es_helpers.makeCallExpr(self, set_callee, &.{ try self.visitNode(obj_idx), computed }, span);
        }

        /// private_methods 리스트를 순회하며 WeakSet 선언 + standalone function 을 scratch 에 append.
        /// 같은 name 의 getter/setter 는 WeakSet 을 공유하므로 weakset_name 기준 첫 등장에만 선언.
        /// private_field_init 도 동일한 dedup 으로 instance_fields 에 append (#1523).
        pub fn emitPrivateMethodArtifacts(self: *Transformer, pms: []const Transformer.PrivateMethodMapping, fields_out: ?*std.ArrayList(NodeIndex), span: Span) Transformer.Error!void {
            for (pms, 0..) |pm, i| {
                const first_occurrence = blk: {
                    for (pms[0..i]) |prev| {
                        if (std.mem.eql(u8, prev.weakset_name, pm.weakset_name)) break :blk false;
                    }
                    break :blk true;
                };
                if (first_occurrence) {
                    try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakSet", pm.weakset_name, span));
                    if (fields_out) |fo| {
                        try fo.append(self.allocator, try es_helpers.buildPrivateMethodInit(self, pm.weakset_name, span));
                    }
                }
                try self.scratch.append(self.allocator, try es_helpers.buildStandaloneFunc(self, pm.func_name, pm.member_idx, pm.member_span));
            }
        }

        /// target이 private_field_expression이면 set 호출 생성(instance/static 자동 분기). 해당 없으면 null.
        /// destructuring assignment에서 `this.#x` 가 target일 때 `_x.get(this) = v` 같은 잘못된 target을
        /// 만들지 않도록 set 호출로 직접 변환 (#1485). value는 이미 변환된(new-AST) 노드여야 함.
        pub fn tryLowerPrivateFieldAssign(self: *Transformer, target_old_idx: NodeIndex, value: NodeIndex, span: Span) Transformer.Error!?NodeIndex {
            if (target_old_idx.isNone()) return null;
            const target_node = self.ast.getNode(target_old_idx);
            if (target_node.tag != .private_field_expression) return null;
            const te = target_node.data.extra;
            if (te >= self.ast.extra_data.items.len) return null;
            const obj_idx = self.readNodeIdx(te, 0);
            const mapping = findPrivateFieldMapping(self, self.readNodeIdx(te, 1)) orelse return null;
            return try buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, value, span);
        }

        /// destructuring assignment target 트리 안에 private_field_expression이 포함됐는지 검사.
        /// transformer 디스패처가 강제 destructuring lowering 여부 판정할 때 사용 (#1485).
        pub fn destructuringTargetHasPrivateField(self: *const Transformer, node_idx: NodeIndex) bool {
            if (node_idx.isNone()) return false;
            const node = self.ast.getNode(node_idx);
            return switch (node.tag) {
                .private_field_expression => true,
                .object_assignment_target, .array_assignment_target => blk: {
                    const start = node.data.list.start;
                    const len = node.data.list.len;
                    var i: u32 = 0;
                    while (i < len) : (i += 1) {
                        const child_raw = self.ast.extra_data.items[start + i];
                        const child_idx: NodeIndex = @enumFromInt(child_raw);
                        if (destructuringTargetHasPrivateField(self, child_idx)) break :blk true;
                    }
                    break :blk false;
                },
                // assignment_target_property_property: binary {left=key, right=target} — target에만 있음.
                // assignment_target_with_default: binary {left=target, right=default} — target에만 있음.
                .assignment_target_property_property => destructuringTargetHasPrivateField(self, node.data.binary.right),
                .assignment_target_with_default => destructuringTargetHasPrivateField(self, node.data.binary.left),
                else => false,
            };
        }

        /// private field용 set 호출 생성 — new_value는 이미 완성된(new-AST) 노드여야 함.
        /// obj_idx는 old AST 노드로, 내부에서 visit 수행.
        /// instance는 `__classPrivateFieldSet` helper, static은 수정된 spec helper 모두 value를 반환 (#1488).
        fn buildPrivateFieldSetWithComputedValue(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, new_value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (mapping.class_name) |class_name| {
                const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecSet");
                const new_obj = try self.visitNode(obj_idx);
                const class_ref = try es_helpers.makeIdentifierRef(self, class_name);
                const desc_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
                self.runtime_helpers.class_static_private_field = true;
                return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref, new_value }, span);
            }
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classPrivateFieldSet");
            const wm_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
            const new_obj = try self.visitNode(obj_idx);
            self.runtime_helpers.class_private_field_set = true;
            return es_helpers.makeCallExpr(self, helper, &.{ wm_ref, new_obj, new_value }, span);
        }

        /// private field get 호출을 생성 — obj_new는 이미 new-AST 노드(double-visit 방지).
        /// optional chain lowering 등 재구성된 private_field_expression 교체용 (#1492).
        pub fn emitPrivateFieldGetWithNewObj(self: *Transformer, prop_old_idx: NodeIndex, obj_new: NodeIndex, span: Span) Transformer.Error!?NodeIndex {
            const mapping = findPrivateFieldMapping(self, prop_old_idx) orelse return null;
            if (mapping.class_name) |class_name| {
                const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecGet");
                const class_ref = try es_helpers.makeIdentifierRef(self, class_name);
                const desc_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
                self.runtime_helpers.class_static_private_field = true;
                const call = try es_helpers.makeCallExpr(self, helper, &.{ obj_new, class_ref, desc_ref }, span);
                return call;
            }
            const wm_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
            const get_prop = try es_helpers.makeIdentifierRef(self, "get");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, get_prop, span);
            const call = try es_helpers.makeCallExpr(self, callee, &.{obj_new}, span);
            return call;
        }

        /// this.#x = v → instance: _x.set(this, v), static: __classStaticPrivateFieldSpecSet(receiver, ClassName, _x, v)
        /// this.#x += v (및 다른 compound) → set(receiver, get(receiver) <op> v)
        /// this.#x ??= v / ||= / &&= → get() <op> set(v) (Babel 스타일, short-circuit)
        pub fn lowerPrivateFieldSet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const left_node = self.ast.getNode(node.data.binary.left);
            const le = left_node.data.extra;
            if (le >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(le, 0);
            const prop_idx = self.readNodeIdx(le, 1);

            // private accessor 인터셉트 — simple `=` 는 setter 호출, compound (+=, -=, ...) 는 set(obj, get(obj) op rhs) 합성.
            // obj 는 2회 visit 되므로 side-effect 있는 복잡 obj 는 정의역 밖 (this / simple ident 는 안전).
            // Logical assignment (??=/||=/&&=) 는 현재 미지원 — getter 결과의 short-circuit 별도 복잡도.
            const op_kind_pre: token_mod.Kind = @enumFromInt(node.data.binary.flags);
            if (!prop_idx.isNone()) {
                const prop_node_pre = self.ast.getNode(prop_idx);
                if (prop_node_pre.tag == .private_identifier) {
                    const orig_name = self.ast.getText(prop_node_pre.span);
                    if (es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, orig_name, .setter)) |setter_mapping| {
                        if (op_kind_pre == .eq) {
                            return lowerPrivateSetterCall(self, setter_mapping, obj_idx, node.data.binary.right, node.span);
                        }
                        if (assign_ops.compoundAssignBaseOp(node.data.binary.flags)) |bin_op| {
                            if (es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, orig_name, .getter)) |getter_mapping| {
                                return lowerPrivateAccessorCompoundAssign(self, getter_mapping, setter_mapping, obj_idx, bin_op, node.data.binary.right, node.span);
                            }
                        }
                    }
                }
            }

            const mapping = findPrivateFieldMapping(self, prop_idx) orelse return null;

            const op_kind: token_mod.Kind = @enumFromInt(node.data.binary.flags);
            if (op_kind == .question2_eq or op_kind == .pipe2_eq or op_kind == .amp2_eq) {
                return lowerPrivateFieldLogicalAssign(self, mapping, obj_idx, op_kind, node.data.binary.right, node.span);
            }

            if (assign_ops.compoundAssignBaseOp(node.data.binary.flags)) |bin_op| {
                const get_call = try buildPrivateFieldGetCall(self, mapping, obj_idx, node.span);
                const new_rhs = try self.visitNode(node.data.binary.right);
                // `**=` + target<es2016: 내부 `**` 도 Math.pow로 lowering해야 함. 일반 binary
                // 경로를 거치지 않고 여기서 직접 생성 — 그렇지 않으면 `**` 가 그대로 남아
                // es2015 타겟에서 syntax error (#1486).
                const computed = if (bin_op == @intFromEnum(token_mod.Kind.star2) and self.options.unsupported.exponentiation)
                    try es_helpers.makeMathPowCall(self, get_call, new_rhs, node.span)
                else
                    try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = get_call, .right = new_rhs, .flags = bin_op } },
                    });
                return buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, computed, node.span);
            }

            // plain `=` : right를 visit한 뒤 buildPrivateFieldSetWithComputedValue 경유 —
            // instance(__classPrivateFieldSet) / static(__classStaticPrivateFieldSpecSet)
            // 모두 value를 반환해 expression semantic 일치 (#1488).
            const new_rhs = try self.visitNode(node.data.binary.right);
            return buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, new_rhs, node.span);
        }

        /// `this.#x ??=/||=/&&= v` lowering.
        /// private field get은 부작용 없으므로 ??= ternary 분기에서 get을 두 번 호출해도 안전.
        /// set helper 반환값이 spec상 expression 값과 다를 수 있으나, statement context에선 무관.
        fn lowerPrivateFieldLogicalAssign(
            self: *Transformer,
            mapping: Transformer.PrivateFieldMapping,
            obj_idx: NodeIndex,
            op_kind: token_mod.Kind,
            rhs_old: NodeIndex,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const get_read = try buildPrivateFieldGetCall(self, mapping, obj_idx, span);
            const new_rhs = try self.visitNode(rhs_old);
            const set_call = try buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, new_rhs, span);

            if (op_kind == .pipe2_eq or op_kind == .amp2_eq) {
                const logical_op: token_mod.Kind = if (op_kind == .pipe2_eq) .pipe2 else .amp2;
                return self.ast.addNode(.{
                    .tag = .logical_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = get_read, .right = set_call, .flags = @intFromEnum(logical_op) } },
                });
            }

            // ??= : nullish_coalescing 미지원 target이면 ternary, 아니면 `get ?? set`.
            if (self.options.unsupported.nullish_coalescing) {
                const neq_null = try es_helpers.makeNeqNull(self, get_read, span);
                const get_read2 = try buildPrivateFieldGetCall(self, mapping, obj_idx, span);
                return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = span,
                    .data = .{ .ternary = .{ .a = neq_null, .b = get_read2, .c = set_call } },
                });
            }
            return self.ast.addNode(.{
                .tag = .logical_expression,
                .span = span,
                .data = .{ .binary = .{ .left = get_read, .right = set_call, .flags = @intFromEnum(token_mod.Kind.question2) } },
            });
        }

        /// prefix  ++this.#x → set(get() + 1)   (expression 값 = 새 값)
        /// postfix this.#x++  → (_t = get(), set(_t + 1), _t)   (expression 값 = 이전 값)
        /// op_flags 의 0x100 비트가 postfix 표시 (parser/expression.zig 참고).
        pub fn lowerPrivateFieldUpdate(self: *Transformer, operand: Node, op_flags: u32, span: Span) ?Transformer.Error!NodeIndex {
            const oe = operand.data.extra;
            if (oe + 1 >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(oe, 0);
            const mapping = findPrivateFieldMapping(self, self.readNodeIdx(oe, 1)) orelse return null;

            const op_kind = op_flags & 0xFF;
            const is_increment = (op_kind == @intFromEnum(token_mod.Kind.plus2));
            const is_postfix = (op_flags & ast_mod.UnaryFlags.postfix) != 0;
            const bin_op: u16 = if (is_increment) @intFromEnum(token_mod.Kind.plus) else @intFromEnum(token_mod.Kind.minus);

            if (is_postfix) {
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);

                const temp_span = try es_helpers.makeTempVarSpan(self);
                // _t = get()
                const get_call = try buildPrivateFieldGetCall(self, mapping, obj_idx, span);
                const tmp_ref_lhs = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
                const init_assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = tmp_ref_lhs, .right = get_call, .flags = @intFromEnum(token_mod.Kind.eq) } },
                });
                try self.scratch.append(self.allocator, init_assign);
                // set(_t + 1)
                const tmp_ref_read = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
                const one = try es_helpers.makeNumericLiteral(self, 1);
                const computed = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = tmp_ref_read, .right = one, .flags = bin_op } },
                });
                const set_call = try buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, computed, span);
                try self.scratch.append(self.allocator, set_call);
                // _t (최종 expression 값)
                try self.scratch.append(self.allocator, try es_helpers.makeTempVarRef(self, temp_span, temp_span));

                const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const seq = try self.ast.addNode(.{
                    .tag = .sequence_expression,
                    .span = span,
                    .data = .{ .list = seq_list },
                });
                // sequence paren 은 precedence 재유도가 처리 (#4042 PR8)
                return seq;
            }

            // prefix: set(get() + 1) — expression 값이 새 값이라 세팅 결과 그대로 사용
            const get_call = try buildPrivateFieldGetCall(self, mapping, obj_idx, span);
            const one = try es_helpers.makeNumericLiteral(self, 1);
            const computed = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = get_call, .right = one, .flags = bin_op } },
            });
            return buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, computed, span);
        }

        /// _name.method(obj, extra_args...) 호출 생성.
        fn buildWeakMapCall(self: *Transformer, wm_name: []const u8, method: []const u8, obj_idx: NodeIndex, extra_arg_indices: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const wm_ref = try es_helpers.makeIdentifierRef(self, wm_name);
            const method_prop = try es_helpers.makeIdentifierRef(self, method);
            const callee = try es_helpers.makeStaticMember(self, wm_ref, method_prop, span);
            const new_obj = try self.visitNode(obj_idx);

            var args_buf: [3]NodeIndex = undefined;
            args_buf[0] = new_obj;
            var args_len: usize = 1;
            for (extra_arg_indices) |arg_idx| {
                args_buf[args_len] = try self.visitNode(arg_idx);
                args_len += 1;
            }

            return es_helpers.makeCallExpr(self, callee, args_buf[0..args_len], span);
        }

        /// private field property에서 전체 매핑 정보를 찾음 (static 여부 포함).
        fn findPrivateFieldMapping(self: *const Transformer, prop_idx: NodeIndex) ?Transformer.PrivateFieldMapping {
            if (prop_idx.isNone()) return null;
            const prop_node = self.ast.getNode(prop_idx);
            if (prop_node.tag != .private_identifier) return null;
            const orig = self.ast.getText(prop_node.span);
            for (self.current_private_fields) |pf| {
                if (std.mem.eql(u8, pf.original_name, orig)) return pf;
            }
            return null;
        }

        /// static private field get: __classStaticPrivateFieldSpecGet(receiver, ClassName, _descriptor)
        fn buildStaticPrivateFieldGet(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecGet");
            const new_obj = try self.visitNode(obj_idx);
            const class_ref = try es_helpers.makeIdentifierRef(self, mapping.class_name.?);
            const desc_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
            self.runtime_helpers.class_static_private_field = true;
            return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref }, span);
        }

        /// ES2022 Ergonomic Brand Checks: `#x in obj` → 내부 표현으로 다운레벨.
        ///
        /// node는 binary_expression(op=in, left=private_identifier "#x", right=obj).
        /// private mapping이 없으면 null 반환 (보존).
        ///
        /// - instance field  : `_x.has(obj)`   (WeakMap.has)
        /// - private method  : `_m.has(obj)`   (WeakSet.has)
        /// - static field    : `obj === ClassName` (class identity brand check)
        ///
        /// Spec: https://tc39.es/proposal-private-fields-in-in/
        /// Babel: @babel/plugin-transform-private-property-in-object
        pub fn lowerPrivateIn(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const left_idx = node.data.binary.left;
            const right_idx = node.data.binary.right;
            if (left_idx.isNone() or right_idx.isNone()) return null;
            const left_node = self.ast.getNode(left_idx);
            if (left_node.tag != .private_identifier) return null;

            const orig = self.ast.getText(left_node.span);

            // instance field / static field 매핑 우선 조회
            for (self.current_private_fields) |pf| {
                if (!std.mem.eql(u8, pf.original_name, orig)) continue;
                if (pf.class_name) |class_name| {
                    // static: obj === ClassName (class identity 비교)
                    const new_obj = try self.visitNode(right_idx);
                    const class_ref = try es_helpers.makeIdentifierRef(self, class_name);
                    return self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = node.span,
                        .data = .{ .binary = .{
                            .left = new_obj,
                            .right = class_ref,
                            .flags = @intFromEnum(token_mod.Kind.eq3),
                        } },
                    });
                }
                // instance: _x.has(obj)
                return buildWeakMapCall(self, pf.var_name, "has", right_idx, &.{}, node.span);
            }

            // private method 매핑 조회
            for (self.current_private_methods) |pm| {
                if (!std.mem.eql(u8, pm.original_name, orig)) continue;
                if (pm.class_name) |class_name| {
                    const new_obj = try self.visitNode(right_idx);
                    const class_ref = try es_helpers.makeIdentifierRef(self, class_name);
                    return self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = node.span,
                        .data = .{ .binary = .{
                            .left = new_obj,
                            .right = class_ref,
                            .flags = @intFromEnum(token_mod.Kind.eq3),
                        } },
                    });
                }
                return buildWeakMapCall(self, pm.weakset_name, "has", right_idx, &.{}, node.span);
            }

            return null;
        }

        /// static private field set: __classStaticPrivateFieldSpecSet(receiver, ClassName, _descriptor, value)
        fn buildStaticPrivateFieldSet(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, value_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecSet");
            const new_obj = try self.visitNode(obj_idx);
            const class_ref = try es_helpers.makeIdentifierRef(self, mapping.class_name.?);
            const desc_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
            const new_value = try self.visitNode(value_idx);
            self.runtime_helpers.class_static_private_field = true;
            return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref, new_value }, span);
        }
    };
}
