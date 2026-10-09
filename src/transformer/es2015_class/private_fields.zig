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
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const ReferenceFlags = @import("../../semantic/symbol.zig").ReferenceFlags;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;

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
            return buildWeakMapCall(self, mapping.var_name, mapping, "get", obj_idx, &.{}, node.span);
        }

        /// instance/static 분기해서 private field get 호출을 구성.
        fn buildPrivateFieldGetCall(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (mapping.class_name != null) return buildStaticPrivateFieldGet(self, mapping, obj_idx, span);
            return buildWeakMapCall(self, mapping.var_name, mapping, "get", obj_idx, &.{}, span);
        }

        /// this.#x = rhs (setter) → __classPrivateMethodGet(obj, _x, _x_set).call(obj, rhs) (#1523).
        fn lowerPrivateSetterCall(self: *Transformer, setter_mapping: Transformer.PrivateMethodMapping, obj_idx: NodeIndex, rhs_old: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.class_private_method_get = true;
            const new_obj = try self.visitNode(obj_idx);
            const new_rhs = try self.visitNode(rhs_old);
            const helper_ref = try es_helpers.makeRuntimeHelperRef(self, "__classPrivateMethodGet");
            const ws_ref = try es_helpers.makePrivateMethodWeakSetRef(self, setter_mapping);
            const fn_ref = try es_helpers.makeSyntheticRef(self, setter_mapping.func_name);
            const get_call = try es_helpers.makeCallExpr(self, helper_ref, &.{ new_obj, ws_ref, fn_ref }, span);
            const call_prop = try es_helpers.makePropertyName(self, "call");
            const callee = try es_helpers.makeStaticMember(self, get_call, call_prop, span);
            return es_helpers.makeCallExpr(self, callee, &.{ new_obj, new_rhs }, span);
        }

        fn buildStaticMethodGet(self: *Transformer, mapping: Transformer.PrivateMethodMapping, receiver: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.class_static_private_field = true;
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecGet");
            const class_ref = try self.makeUserRefNamed(mapping.class_name.?, mapping.class_name_node);
            const desc_ref = try es_helpers.makePrivateMethodWeakSetRef(self, mapping);
            return es_helpers.makeCallExpr(self, helper, &.{ receiver, class_ref, desc_ref }, span);
        }

        fn buildStaticMethodSet(self: *Transformer, mapping: Transformer.PrivateMethodMapping, receiver: NodeIndex, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.class_static_private_field = true;
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecSet");
            const class_ref = try self.makeUserRefNamed(mapping.class_name.?, mapping.class_name_node);
            const desc_ref = try es_helpers.makePrivateMethodWeakSetRef(self, mapping);
            return es_helpers.makeCallExpr(self, helper, &.{ receiver, class_ref, desc_ref, value }, span);
        }

        fn makeSequence(self: *Transformer, parts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const list = try self.ast.addNodeList(parts);
            return self.ast.addNode(.{ .tag = .sequence_expression, .span = span, .data = .{ .list = list } });
        }

        fn lowerStaticMethodAssign(self: *Transformer, mapping: Transformer.PrivateMethodMapping, obj_idx: NodeIndex, rhs_old: NodeIndex, op: token_mod.Kind, flags: u16, span: Span) Transformer.Error!NodeIndex {
            const receiver = try self.visitNode(obj_idx);
            const rhs = try self.visitNode(rhs_old);
            if (op == .eq) return buildStaticMethodSet(self, mapping, receiver, rhs, span);

            const recv_temp = try es_helpers.captureToTrackedTemp(self, receiver, span);
            const get_receiver = try es_helpers.makeTrackedTempRef(self, recv_temp.span, span, .{ .read = true });
            const old_value = try buildStaticMethodGet(self, mapping, get_receiver, span);
            const set_receiver = try es_helpers.makeTrackedTempRef(self, recv_temp.span, span, .{ .read = true });

            if (assign_ops.compoundAssignBaseOp(flags)) |base_op| {
                const computed = if (base_op == @intFromEnum(token_mod.Kind.star2) and self.options.unsupported.exponentiation)
                    try es_helpers.makeMathPowCall(self, old_value, rhs, span)
                else
                    try self.ast.addNode(.{ .tag = .binary_expression, .span = span, .data = .{ .binary = .{ .left = old_value, .right = rhs, .flags = base_op } } });
                const set_call = try buildStaticMethodSet(self, mapping, set_receiver, computed, span);
                return makeSequence(self, &.{ recv_temp.paren_assign, set_call }, span);
            }

            const set_call = try buildStaticMethodSet(self, mapping, set_receiver, rhs, span);
            const result = if (op == .pipe2_eq or op == .amp2_eq)
                try self.ast.addNode(.{ .tag = .logical_expression, .span = span, .data = .{ .binary = .{ .left = old_value, .right = set_call, .flags = @intFromEnum(if (op == .pipe2_eq) token_mod.Kind.pipe2 else token_mod.Kind.amp2) } } })
            else blk: {
                // The read must occur once: a getter may have side effects.
                const value_temp = try es_helpers.captureToTrackedTemp(self, old_value, span);
                const cond = try es_helpers.makeNeqNull(self, value_temp.paren_assign, span);
                const read = try es_helpers.makeTrackedTempRef(self, value_temp.span, span, .{ .read = true });
                break :blk try self.ast.addNode(.{ .tag = .conditional_expression, .span = span, .data = .{ .ternary = .{ .a = cond, .b = read, .c = set_call } } });
            };
            return makeSequence(self, &.{ recv_temp.paren_assign, result }, span);
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
            const get_ws = try es_helpers.makePrivateMethodWeakSetRef(self, getter_mapping);
            const get_fn = try es_helpers.makeSyntheticRef(self, getter_mapping.func_name);
            const get_outer = try es_helpers.makeCallExpr(self, get_helper, &.{ try self.visitNode(obj_idx), get_ws, get_fn }, span);
            const get_call_prop = try es_helpers.makePropertyName(self, "call");
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
            const set_ws = try es_helpers.makePrivateMethodWeakSetRef(self, setter_mapping);
            const set_fn = try es_helpers.makeSyntheticRef(self, setter_mapping.func_name);
            const set_outer = try es_helpers.makeCallExpr(self, set_helper, &.{ try self.visitNode(obj_idx), set_ws, set_fn }, span);
            const set_call_prop = try es_helpers.makePropertyName(self, "call");
            const set_callee = try es_helpers.makeStaticMember(self, set_outer, set_call_prop, span);
            return es_helpers.makeCallExpr(self, set_callee, &.{ try self.visitNode(obj_idx), computed }, span);
        }

        /// private_methods 리스트를 순회하며 WeakSet 선언 + standalone function 을 scratch 에 append.
        /// 같은 name 의 getter/setter 는 WeakSet 을 공유하므로 weakset_name 기준 첫 등장에만 선언.
        /// private_field_init 도 동일한 dedup 으로 instance_fields 에 append (#1523).
        pub fn emitPrivateMethodArtifacts(self: *Transformer, pms: []const Transformer.PrivateMethodMapping, fields_out: ?*std.ArrayList(NodeIndex), post_class_out: ?*std.ArrayList(NodeIndex), span: Span, class_name_span: Span) Transformer.Error!void {
            _ = class_name_span;
            const function_values = try self.allocator.alloc(NodeIndex, pms.len);
            defer self.allocator.free(function_values);
            const emit_standalone = try self.allocator.alloc(bool, pms.len);
            defer self.allocator.free(emit_standalone);

            for (pms, 0..) |pm, i| {
                const function_node = try es_helpers.buildStandaloneFunc(self, pm.func_name, pm.member_idx, pm.source_member_idx, pm.member_span);
                if (try es_helpers.capturePrivateClassSelf(self, pm, function_node, span)) |factory_call| {
                    function_values[i] = factory_call;
                    emit_standalone[i] = false;
                    continue;
                }
                function_values[i] = function_node;
                emit_standalone[i] = true;
            }

            for (pms, 0..) |pm, i| {
                const first_occurrence = blk: {
                    for (pms[0..i]) |prev| {
                        if (std.mem.eql(u8, prev.weakset_name, pm.weakset_name)) break :blk false;
                    }
                    break :blk true;
                };
                if (first_occurrence) {
                    if (pm.class_name != null) {
                        var method_fn: ?NodeIndex = null;
                        var getter_fn: ?NodeIndex = null;
                        var setter_fn: ?NodeIndex = null;
                        for (pms, 0..) |part, part_index| {
                            if (!std.mem.eql(u8, part.weakset_name, pm.weakset_name)) continue;
                            const value = if (emit_standalone[part_index])
                                try es_helpers.makeSyntheticRef(self, part.func_name)
                            else
                                function_values[part_index];
                            switch (part.kind) {
                                .method => method_fn = value,
                                .getter => getter_fn = value,
                                .setter => setter_fn = value,
                            }
                        }
                        try self.scratch.append(self.allocator, try es_helpers.buildStaticPrivateMethodDescriptor(self, pm.weakset_name, method_fn, getter_fn, setter_fn, span, pm.weakset_binding_node));
                        self.runtime_helpers.class_static_private_field = true;
                    } else {
                        try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakSet", pm.weakset_name, span, pm.weakset_binding_node));
                        if (fields_out) |fo| {
                            try fo.append(self.allocator, try es_helpers.buildPrivateMethodInit(self, pm.weakset_name, pm.weakset_symbol_id, span));
                        }
                    }
                }
                if (emit_standalone[i]) {
                    try self.scratch.append(self.allocator, function_values[i]);
                } else if (pm.class_name == null) {
                    const post_class = post_class_out orelse
                        std.debug.panic("captured instance private method has no post-class emission list", .{});
                    const assignment = try es_helpers.buildCapturedFunctionAssignment(self, pm.func_name, function_values[i], span);
                    try self.scratch.append(self.allocator, assignment.declaration);
                    try post_class.append(self.allocator, assignment.assignment);
                }
            }
        }

        /// Private method lowering creates declarations and references in several
        /// helpers before the enclosing class IIFE is complete. Once its owner
        /// scope is known, bind the exact generated names across that live tree.
        pub fn trackPrivateMethodSymbols(self: *Transformer, root: NodeIndex, pms: []const Transformer.PrivateMethodMapping, pfs: []const Transformer.PrivateFieldMapping, root_scope: ScopeId) Transformer.Error!void {
            if (!self.semantic_edit_enabled or (pms.len == 0 and pfs.len == 0)) return;
            const PrivateName = struct { kind: SymbolKind };
            const Binding = struct { name: []const u8, node: NodeIndex, kind: SymbolKind, scope: ScopeId, raw_id: u32 };
            const Ref = struct { node: NodeIndex, scope: ScopeId };
            var names: std.StringHashMapUnmanaged(PrivateName) = .empty;
            defer names.deinit(self.allocator);
            var function_names: std.StringHashMapUnmanaged(void) = .empty;
            defer function_names.deinit(self.allocator);
            var private_symbol_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer private_symbol_ids.deinit(self.allocator);
            for (pms) |pm| {
                const weakset_id = pm.weakset_symbol_id orelse
                    std.debug.panic("private method mapping has no direct WeakSet SymbolId", .{});
                try private_symbol_ids.put(self.allocator, weakset_id, {});
                const fn_entry = try names.getOrPut(self.allocator, pm.func_name);
                if (!fn_entry.found_existing) fn_entry.value_ptr.* = .{ .kind = .function_decl };
                try function_names.put(self.allocator, pm.func_name, {});
            }
            for (pfs) |pf| {
                const raw_id = pf.symbol_id orelse std.debug.panic("private field mapping has no direct SymbolId", .{});
                try private_symbol_ids.put(self.allocator, raw_id, {});
            }

            var pending_exact_refs: std.AutoHashMapUnmanaged(u32, u32) = .empty;
            defer pending_exact_refs.deinit(self.allocator);
            var finalized_exact_refs: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer finalized_exact_refs.deinit(self.allocator);
            for (self.pending_exact_symbol_refs.items) |pending| {
                if (!private_symbol_ids.contains(pending.symbol_id)) continue;
                const gop = try pending_exact_refs.getOrPut(self.allocator, @intFromEnum(pending.node));
                if (gop.found_existing)
                    std.debug.panic("private helper reference node is pending more than once", .{});
                gop.value_ptr.* = pending.symbol_id;
            }

            var bindings: std.ArrayList(Binding) = .empty;
            defer bindings.deinit(self.allocator);
            var refs: std.ArrayList(Ref) = .empty;
            defer refs.deinit(self.allocator);
            const Work = struct { node: NodeIndex, scope: ScopeId, parent: NodeIndex = .none };
            var stack: std.ArrayList(Work) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.allocator);
            while (stack.pop()) |work| {
                if (work.node.isNone() or @intFromEnum(work.node) >= self.ast.nodes.items.len) continue;
                const raw = @intFromEnum(work.node);
                if (seen.contains(raw)) continue;
                try seen.put(self.allocator, raw, {});
                const node = self.ast.getNode(work.node);
                const scope = self.outputOwnedScope(work.node) orelse work.scope;

                if (pending_exact_refs.get(raw)) |raw_id| {
                    const flags: ReferenceFlags = if (node.tag == .assignment_target_identifier)
                        .{ .write = true }
                    else if (node.tag == .identifier_reference)
                        .{ .read = true }
                    else
                        std.debug.panic("pending private helper identity points at a non-reference", .{});
                    try self.addSyntheticRefInScope(work.node, @enumFromInt(raw_id), scope, flags);
                    try finalized_exact_refs.put(self.allocator, raw, {});
                }

                if (node.tag == .function_declaration) {
                    const name_idx = self.readNodeIdx(node.data.extra, ast_mod.FunctionExtra.name);
                    if (!name_idx.isNone()) {
                        const name = self.ast.getText(self.ast.getNode(name_idx).data.string_ref);
                        if (names.getPtr(name)) |entry| {
                            try bindings.append(self.allocator, .{
                                .name = name,
                                .node = name_idx,
                                .kind = functionSymbolKind(self, node),
                                .scope = work.scope,
                                .raw_id = 0,
                            });
                            entry.kind = functionSymbolKind(self, node);
                        }
                    }
                }

                switch (node.tag) {
                    .binding_identifier => {
                        const name = self.ast.getText(node.data.string_ref);
                        if (names.getPtr(name)) |entry| {
                            const is_function_name = if (!work.parent.isNone()) blk: {
                                const parent = self.ast.getNode(work.parent);
                                if (parent.tag != .function_declaration) break :blk false;
                                break :blk self.readNodeIdx(parent.data.extra, ast_mod.FunctionExtra.name) == work.node;
                            } else false;
                            if (!is_function_name) {
                                const parent_is_declarator = !work.parent.isNone() and self.ast.getNode(work.parent).tag == .variable_declarator;
                                try bindings.append(self.allocator, .{
                                    .name = name,
                                    .node = work.node,
                                    .kind = if (parent_is_declarator and function_names.contains(name)) .variable_var else entry.kind,
                                    .scope = work.scope,
                                    .raw_id = 0,
                                });
                            }
                        }
                    },
                    .identifier_reference, .assignment_target_identifier => {
                        const name = self.ast.getText(node.data.string_ref);
                        if (names.contains(name)) try refs.append(self.allocator, .{ .node = work.node, .scope = scope });
                    },
                    else => {},
                }

                var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
                while (it.next()) |child| try stack.append(self.allocator, .{ .node = child, .scope = scope, .parent = work.node });
            }

            if (finalized_exact_refs.count() > 0) {
                var kept: usize = 0;
                for (self.pending_exact_symbol_refs.items) |pending| {
                    if (private_symbol_ids.contains(pending.symbol_id) and finalized_exact_refs.contains(@intFromEnum(pending.node))) continue;
                    self.pending_exact_symbol_refs.items[kept] = pending;
                    kept += 1;
                }
                self.pending_exact_symbol_refs.items.len = kept;
            }

            var entries = names.iterator();
            while (entries.next()) |entry| {
                const name = entry.key_ptr.*;
                var found = false;
                for (bindings.items) |*binding| {
                    if (!std.mem.eql(u8, binding.name, name)) continue;
                    found = true;
                    const binding_node = self.ast.getNode(binding.node);
                    const id = try self.declareSyntheticInScope(binding.node, binding_node.span, binding.kind, binding.scope) orelse
                        std.debug.panic("private helper {s} has no direct SymbolId", .{name});
                    binding.raw_id = @intFromEnum(id);
                }
                if (!found) std.debug.panic("private helper {s} has no emitted binding", .{name});
            }

            for (refs.items) |ref| {
                const name = self.ast.getText(self.ast.getNode(ref.node).data.string_ref);
                var selected: ?*const Binding = null;
                var selected_distance: usize = std.math.maxInt(usize);
                for (bindings.items) |*binding| {
                    if (!std.mem.eql(u8, binding.name, name)) continue;
                    const distance = privateBindingDistance(self, ref.scope, binding.scope) orelse continue;
                    if (distance < selected_distance) {
                        selected = binding;
                        selected_distance = distance;
                    }
                }
                const binding = selected orelse std.debug.panic("private helper reference {s} has no visible emitted binding", .{name});
                const flags: ReferenceFlags = if (self.ast.getNode(ref.node).tag == .assignment_target_identifier)
                    .{ .write = true }
                else
                    .{ .read = true };
                try self.addSyntheticRefInScope(ref.node, @enumFromInt(binding.raw_id), ref.scope, flags);
            }
        }

        fn privateBindingDistance(self: *Transformer, start: ScopeId, target: ScopeId) ?usize {
            var scope = start;
            var distance: usize = 0;
            while (!scope.isNone()) : (distance += 1) {
                if (scope == target) return distance;
                scope = self.outputScopeParent(scope);
            }
            return null;
        }

        fn functionSymbolKind(self: *Transformer, node: Node) SymbolKind {
            const flags = self.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
            const FnFlags = ast_mod.FunctionFlags;
            const is_async = (flags & FnFlags.is_async) != 0;
            const is_generator = (flags & FnFlags.is_generator) != 0;
            return if (is_async and is_generator)
                .async_generator_decl
            else if (is_async)
                .async_function_decl
            else if (is_generator)
                .generator_decl
            else
                .function_decl;
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
            const prop_idx = self.readNodeIdx(te, 1);
            if (!prop_idx.isNone() and self.ast.getNode(prop_idx).tag == .private_identifier) {
                const name = self.ast.getText(self.ast.getNode(prop_idx).span);
                const method = es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, name, .method) orelse
                    es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, name, .getter) orelse
                    es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, name, .setter);
                if (method) |pm| {
                    if (pm.class_name != null) return try buildStaticMethodSet(self, pm, try self.visitNode(obj_idx), value, span);
                }
            }
            const mapping = findPrivateFieldMapping(self, prop_idx) orelse return null;
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
                // `[...this.#x] = src` — rest 도 대입 좌변이다 (#4789).
                .assignment_target_rest => destructuringTargetHasPrivateField(self, node.data.unary.operand),
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
                const class_ref = try self.makeUserRefNamed(class_name, mapping.class_name_node);
                const desc_ref = try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id);
                self.runtime_helpers.class_static_private_field = true;
                return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref, new_value }, span);
            }
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classPrivateFieldSet");
            const wm_ref = try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id);
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
                const class_ref = try self.makeUserRefNamed(class_name, mapping.class_name_node);
                const desc_ref = try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id);
                self.runtime_helpers.class_static_private_field = true;
                const call = try es_helpers.makeCallExpr(self, helper, &.{ obj_new, class_ref, desc_ref }, span);
                return call;
            }
            const wm_ref = try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id);
            const get_prop = try es_helpers.makePropertyName(self, "get");
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
                    const static_mapping = es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, orig_name, .method) orelse
                        es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, orig_name, .getter) orelse
                        es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, orig_name, .setter);
                    if (static_mapping) |mapping| {
                        if (mapping.class_name != null) {
                            return lowerStaticMethodAssign(self, mapping, obj_idx, node.data.binary.right, op_kind_pre, node.data.binary.flags, node.span);
                        }
                    }
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
            const prop_idx = self.readNodeIdx(oe, 1);
            if (!prop_idx.isNone() and self.ast.getNode(prop_idx).tag == .private_identifier) {
                const name = self.ast.getText(self.ast.getNode(prop_idx).span);
                const method = es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, name, .method) orelse
                    es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, name, .getter) orelse
                    es2022.ES2022(Transformer).findPrivateMethodMappingOfKind(self, name, .setter);
                if (method) |mapping| {
                    if (mapping.class_name != null) return lowerStaticMethodUpdate(self, mapping, obj_idx, op_flags, span);
                }
            }
            const mapping = findPrivateFieldMapping(self, prop_idx) orelse return null;

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

        fn lowerStaticMethodUpdate(self: *Transformer, mapping: Transformer.PrivateMethodMapping, obj_idx: NodeIndex, op_flags: u32, span: Span) Transformer.Error!NodeIndex {
            const receiver = try self.visitNode(obj_idx);
            const recv_temp = try es_helpers.captureToTrackedTemp(self, receiver, span);
            const get_receiver = try es_helpers.makeTrackedTempRef(self, recv_temp.span, span, .{ .read = true });
            const get_value = try buildStaticMethodGet(self, mapping, get_receiver, span);
            const value_temp = try es_helpers.captureToTrackedTemp(self, get_value, span);
            const postfix = (op_flags & ast_mod.UnaryFlags.postfix) != 0;
            const set_receiver = try es_helpers.makeTrackedTempRef(self, recv_temp.span, span, .{ .read = true });
            const update_operand = try es_helpers.makeTrackedTempRef(self, value_temp.span, span, .{ .read = true, .write = true });
            const update_extra = try self.ast.addExtras(&.{ @intFromEnum(update_operand), op_flags });
            const update = try self.ast.addNode(.{ .tag = .update_expression, .span = span, .data = .{ .extra = update_extra } });

            if (postfix) {
                const old_temp = try es_helpers.captureToTrackedTemp(self, update, span);
                const new_value = try es_helpers.makeTrackedTempRef(self, value_temp.span, span, .{ .read = true });
                const set_call = try buildStaticMethodSet(self, mapping, set_receiver, new_value, span);
                const old_result = try es_helpers.makeTrackedTempRef(self, old_temp.span, span, .{ .read = true });
                return makeSequence(self, &.{ recv_temp.paren_assign, value_temp.paren_assign, old_temp.paren_assign, set_call, old_result }, span);
            }

            const set_call = try buildStaticMethodSet(self, mapping, set_receiver, update, span);
            return makeSequence(self, &.{ recv_temp.paren_assign, value_temp.paren_assign, set_call }, span);
        }

        /// _name.method(obj, extra_args...) 호출 생성.
        fn buildWeakMapCall(self: *Transformer, wm_name: []const u8, field_mapping: ?Transformer.PrivateFieldMapping, method: []const u8, obj_idx: NodeIndex, extra_arg_indices: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const wm_ref = if (field_mapping) |mapping|
                try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id)
            else
                try es_helpers.makeSyntheticRef(self, wm_name);
            return buildWeakCollectionCall(self, wm_ref, method, obj_idx, extra_arg_indices, span);
        }

        fn buildWeakCollectionCall(self: *Transformer, collection_ref: NodeIndex, method: []const u8, obj_idx: NodeIndex, extra_arg_indices: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const method_prop = try es_helpers.makePropertyName(self, method);
            const callee = try es_helpers.makeStaticMember(self, collection_ref, method_prop, span);
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
            const class_ref = try self.makeUserRefNamed(mapping.class_name.?, mapping.class_name_node);
            const desc_ref = try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id);
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
                    const class_ref = try self.makeUserRefNamed(class_name, pf.class_name_node);
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
                return buildWeakMapCall(self, pf.var_name, pf, "has", right_idx, &.{}, node.span);
            }

            // private method 매핑 조회
            for (self.current_private_methods) |pm| {
                if (!std.mem.eql(u8, pm.original_name, orig)) continue;
                if (pm.class_name) |class_name| {
                    const new_obj = try self.visitNode(right_idx);
                    const class_ref = try self.makeUserRefNamed(class_name, pm.class_name_node);
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
                return buildWeakCollectionCall(
                    self,
                    try es_helpers.makePrivateMethodWeakSetRef(self, pm),
                    "has",
                    right_idx,
                    &.{},
                    node.span,
                );
            }

            return null;
        }

        /// static private field set: __classStaticPrivateFieldSpecSet(receiver, ClassName, _descriptor, value)
        fn buildStaticPrivateFieldSet(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, value_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeRuntimeHelperRef(self, "__classStaticPrivateFieldSpecSet");
            const new_obj = try self.visitNode(obj_idx);
            const class_ref = try self.makeUserRefNamed(mapping.class_name.?, mapping.class_name_node);
            const desc_ref = try es_helpers.makeDeferredExactSyntheticRef(self, mapping.var_name, mapping.symbol_id);
            const new_value = try self.visitNode(value_idx);
            self.runtime_helpers.class_static_private_field = true;
            return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref, new_value }, span);
        }
    };
}
