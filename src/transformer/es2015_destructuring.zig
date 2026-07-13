//! ES2015 다운레벨링: destructuring
//!
//! --target < es2015 일 때 활성화.
//!
//! variable_declarator에서 binding pattern을 감지하여 개별 선언으로 분해:
//!   const { a, b } = obj → var _ref = obj; var a = _ref.a; var b = _ref.b;
//!   const [x, y] = arr  → var _ref = arr; var x = _ref[0]; var y = _ref[1];
//!   const { a = 1 } = obj → var _ref = obj; var a = _ref.a === void 0 ? 1 : _ref.a;
//!
//! 구현: variable_declaration 레벨에서 처리.
//! destructuring이 있는 declarator를 여러 declarator로 풀어서 대체한다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-destructuring-assignment (ES2015)
//! - https://tc39.es/ecma262/#sec-destructuring-binding-patterns (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/destructuring.rs (~1388줄)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const es2015_class = @import("es2015_class.zig");

pub fn ES2015Destructuring(comptime Transformer: type) type {
    return struct {
        /// variable_declaration에 destructuring pattern이 있는지 확인.
        pub fn hasDestructuring(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return false;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];
            for (decls) |raw_idx| {
                const decl = self.ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) continue;
                const name: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                if (name.isNone()) continue;
                const name_node = self.ast.getNode(name);
                if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) return true;
            }
            return false;
        }

        /// variable_declaration 안에 object rest (...rest)가 있는지 체크.
        /// ES2018 object rest는 target < es2018에서 __rest로 변환 필요.
        pub fn hasObjectRest(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return false;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];
            for (decls) |raw_idx| {
                const decl = self.ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) continue;
                const name: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                if (name.isNone()) continue;
                const name_node = self.ast.getNode(name);
                if (name_node.tag == .object_pattern) {
                    if (objectPatternHasRest(self, name_node)) return true;
                }
            }
            return false;
        }

        fn objectPatternHasRest(self: *const Transformer, pattern: Node) bool {
            return self.ast.nodeListSplitRest(pattern.data.list).rest_operand != null;
        }

        /// assignment-target 트리(object/array_assignment_target)에 object rest 가
        /// 중첩 포함되어 있는지 재귀 검사 (#4261). for-of/for-in LHS 게이트용 —
        /// top-level `object_assignment_target` rest 뿐 아니라 `for ([b, {a,...r}] of)`
        /// 처럼 array-target 안에 중첩된 object rest 도 검출. array rest(`[a,...r]`,
        /// ES2015)는 제외(object rest=ES2018 만 lowering 필요).
        pub fn destructuringTargetHasObjectRest(self: *const Transformer, node_idx: NodeIndex) bool {
            if (node_idx.isNone()) return false;
            const node = self.ast.getNode(node_idx);
            return switch (node.tag) {
                .object_assignment_target => blk: {
                    if (self.ast.nodeListSplitRest(node.data.list).rest_operand != null) break :blk true;
                    break :blk targetListHasObjectRest(self, node.data.list);
                },
                .array_assignment_target => targetListHasObjectRest(self, node.data.list),
                .assignment_target_property_property => destructuringTargetHasObjectRest(self, node.data.binary.right),
                .assignment_target_with_default => destructuringTargetHasObjectRest(self, node.data.binary.left),
                else => false,
            };
        }

        fn targetListHasObjectRest(self: *const Transformer, list: NodeList) bool {
            const items = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (items) |raw| {
                if (destructuringTargetHasObjectRest(self, @enumFromInt(raw))) return true;
            }
            return false;
        }

        /// destructuring이 있는 variable_declaration을 분해한다.
        /// 각 destructuring declarator를 여러 개의 단순 declarator로 풀어서 반환.
        pub fn lowerDestructuringDeclaration(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;

            // extras를 visitNode 전에 읽기 (재할당 방지)
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < list_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[list_start + i_loop];
                const decl = self.ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) continue;

                // extras를 visitNode 전에 매번 직접 읽기 (재할당 방지)
                const name_idx: NodeIndex = self.readNodeIdx(decl.data.extra, 0);
                const init_idx: NodeIndex = self.readNodeIdx(decl.data.extra, 2);

                if (name_idx.isNone()) continue;
                const name_node = self.ast.getNode(name_idx);

                if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) {
                    // destructuring → 분해
                    // 먼저 init을 임시 변수에 저장
                    const new_init = try self.visitNode(init_idx);
                    const pattern_init = if (name_node.tag == .array_pattern)
                        try buildArrayRead(self, new_init, name_node, span)
                    else
                        new_init;
                    const temp_span = try es_helpers.makeTempVarSpan(self);
                    const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);

                    // var _ref = init
                    const ref_decl = try es_helpers.makeDeclarator(self, temp_binding, pattern_init, span);
                    try self.scratch.append(self.allocator, ref_decl);

                    // 패턴을 개별 declarator로 분해
                    try emitPatternDeclarators(self, name_node, temp_span, span);
                } else {
                    // 일반 declarator: 그대로 visit
                    const new_decl = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_decl.isNone()) {
                        try self.scratch.append(self.allocator, new_decl);
                    }
                }
            }

            // 새 variable_declaration
            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const var_extra = try self.ast.addExtras(&.{ 0, new_list.start, new_list.len }); // 0 = var
            return self.ast.addNode(.{
                .tag = .variable_declaration,
                .span = span,
                .data = .{ .extra = var_extra },
            });
        }

        /// binding pattern (object_pattern / array_pattern) 을 destructuring assignment sequence
        /// 로 분해. async/generator state machine 변환 (es2015_generator.collectVarDeclWithYield)
        /// 처럼 `var { x } = await ...` 가 `({ x: x } = _state.sent())` 같은 binding-pattern-as-LHS
        /// 형태로 떨어지는 경우에 사용 — ES5 환경에서는 invalid 라 lowering 필수 (#1960).
        ///
        /// 입력 `pattern` 은 binding pattern (이미 visit 끝났거나 raw), `rhs` 는 visit 끝난 노드.
        /// 결과는 `(_ref = rhs, x = _ref.x, ..., _ref)` sequence_expression. 호출자는 보통
        /// `makeExprStmt` 로 wrap 해서 statement 로 넣는다.
        pub fn lowerBindingPatternAssignment(
            self: *Transformer,
            pattern: Node,
            rhs: NodeIndex,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // _ref = rhs
            const init_lhs = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const init_assign = try es_helpers.makeAssignExpr(self, init_lhs, rhs, span, 0);
            try self.scratch.append(self.allocator, init_assign);

            if (pattern.tag == .object_pattern) {
                try emitObjectPatternAssignments(self, pattern, temp_span, span);
            } else if (pattern.tag == .array_pattern) {
                try emitArrayPatternAssignments(self, pattern, temp_span, span);
            }

            // 마지막에 _ref 노출 — destructuring assignment 의 평가 결과 (rhs) 와 일관
            try self.scratch.append(self.allocator, try es_helpers.makeTempVarRef(self, temp_span, temp_span));

            const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
        }

        /// object_pattern 의 각 binding_property 를 `target = _ref.key` assignment 로 emit.
        /// emitObjectPatternDeclarators 와 같은 traversal — declarator 대신 assignment 를 만든다.
        fn emitObjectPatternAssignments(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const opd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var i_loop: u32 = 0;
            while (i_loop < non_rest_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[opd_start + i_loop];
                const prop = self.ast.getNode(@enumFromInt(raw_idx));
                if (prop.tag != .binding_property) continue;

                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;
                if (key_idx.isNone()) continue;

                const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
                const key_node = self.ast.getNode(key_idx);
                const member_access = try es_helpers.makeMemberFromKeyIdx(self, ref, key_idx, span);

                if (value_idx.isNone() or @intFromEnum(value_idx) == @intFromEnum(key_idx)) {
                    // shorthand: { x } → x = _ref.x
                    const target_ref = try es_helpers.makeIdentifierRefFromSpan(self, key_node.data.string_ref);
                    self.propagateSymbolId(key_idx, target_ref);
                    const assign = try es_helpers.makeAssignExpr(self, target_ref, member_access, span, 0);
                    try self.scratch.append(self.allocator, assign);
                } else {
                    const value_node = self.ast.getNode(value_idx);
                    if (value_node.tag == .object_pattern or value_node.tag == .array_pattern) {
                        // nested: { a: { b } } → _inner = _ref.a, b = _inner.b
                        const inner_span = try es_helpers.makeTempVarSpan(self);
                        const inner_lhs = try es_helpers.makeTempVarRef(self, inner_span, inner_span);
                        const inner_init = try es_helpers.makeAssignExpr(self, inner_lhs, member_access, span, 0);
                        try self.scratch.append(self.allocator, inner_init);
                        if (value_node.tag == .object_pattern) {
                            try emitObjectPatternAssignments(self, value_node, inner_span, span);
                        } else {
                            try emitArrayPatternAssignments(self, value_node, inner_span, span);
                        }
                    } else if (value_node.tag == .assignment_pattern) {
                        // default: { a = 1 } 또는 { a: b = 1 } — _ref.key === void 0 ? default : _ref.key
                        const inner_target = value_node.data.binary.left;
                        const inner_target_node = self.ast.getNode(inner_target);
                        const default_val = try self.visitNode(value_node.data.binary.right);
                        const defaulted = try buildDefaulted(self, member_access, default_val, ref_span, key_idx, key_node.tag, span);
                        const target_ref = if (inner_target_node.tag == .binding_identifier)
                            try es_helpers.makeIdentifierRefFromSpan(self, inner_target_node.data.string_ref)
                        else
                            try self.visitNode(inner_target);
                        self.propagateSymbolId(inner_target, target_ref);
                        const assign = try es_helpers.makeAssignExpr(self, target_ref, defaulted, span, 0);
                        try self.scratch.append(self.allocator, assign);
                    } else {
                        // long-form: { a: b } → b = _ref.a
                        const target_ref = if (value_node.tag == .binding_identifier)
                            try es_helpers.makeIdentifierRefFromSpan(self, value_node.data.string_ref)
                        else
                            try self.visitNode(value_idx);
                        self.propagateSymbolId(value_idx, target_ref);
                        const assign = try es_helpers.makeAssignExpr(self, target_ref, member_access, span, 0);
                        try self.scratch.append(self.allocator, assign);
                    }
                }
            }
            // rest property — assignment 컨텍스트에서는 __rest 헬퍼 미지원, lowerDestructuringAssignment
            // 와 동일한 정책으로 일단 무시.
        }

        /// array_pattern 의 각 element 를 `target = _ref[idx]` assignment 로 emit.
        fn emitArrayPatternAssignments(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const apd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var idx: u32 = 0;
            while (idx < non_rest_len) : (idx += 1) {
                const raw_idx = self.ast.extra_data.items[apd_start + idx];
                const elem = self.ast.getNode(@enumFromInt(raw_idx));
                if (elem.tag == .elision) continue;

                const elem_access = try makeArrayAccess(self, ref_span, idx, span);

                if (elem.tag == .assignment_pattern) {
                    const inner_target = elem.data.binary.left;
                    const inner_target_node = self.ast.getNode(inner_target);
                    const default_val = try self.visitNode(elem.data.binary.right);
                    const void_zero = try es_helpers.makeVoidZero(self, span);
                    const elem_access2 = try makeArrayAccess(self, ref_span, idx, span);
                    const eq_check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                    });
                    const conditional = try self.ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                    });
                    const target_ref = if (inner_target_node.tag == .binding_identifier)
                        try es_helpers.makeIdentifierRefFromSpan(self, inner_target_node.data.string_ref)
                    else
                        try self.visitNode(inner_target);
                    self.propagateSymbolId(inner_target, target_ref);
                    const assign = try es_helpers.makeAssignExpr(self, target_ref, conditional, span, 0);
                    try self.scratch.append(self.allocator, assign);
                } else if (elem.tag == .object_pattern or elem.tag == .array_pattern) {
                    const inner_span = try es_helpers.makeTempVarSpan(self);
                    const inner_lhs = try es_helpers.makeTempVarRef(self, inner_span, inner_span);
                    const inner_init = try es_helpers.makeAssignExpr(self, inner_lhs, elem_access, span, 0);
                    try self.scratch.append(self.allocator, inner_init);
                    if (elem.tag == .object_pattern) {
                        try emitObjectPatternAssignments(self, elem, inner_span, span);
                    } else {
                        try emitArrayPatternAssignments(self, elem, inner_span, span);
                    }
                } else {
                    const target_ref = if (elem.tag == .binding_identifier)
                        try es_helpers.makeIdentifierRefFromSpan(self, elem.data.string_ref)
                    else
                        try self.visitNode(@enumFromInt(raw_idx));
                    self.propagateSymbolId(@enumFromInt(raw_idx), target_ref);
                    const assign = try es_helpers.makeAssignExpr(self, target_ref, elem_access, span, 0);
                    try self.scratch.append(self.allocator, assign);
                }
            }
            // rest element — declaration 컨텍스트의 _ref.slice(N) 와 달리 assignment 에서는 미지원.
        }

        /// assignment destructuring을 sequence expression으로 변환.
        /// ({a, b} = obj) → (_ref = obj, a = _ref.a, b = _ref.b, _ref)
        pub fn lowerDestructuringAssignment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left_idx = node.data.binary.left;
            const right_idx = node.data.binary.right;

            const left_node = self.ast.getNode(left_idx);
            const new_right = try self.visitNode(right_idx);
            const assignment_right = if (left_node.tag == .array_assignment_target or left_node.tag == .array_pattern)
                try buildArrayRead(self, new_right, left_node, span)
            else
                new_right;
            const temp_span = try es_helpers.makeTempVarSpan(self);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // _ref = obj
            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const init_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = assignment_right, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, init_assign);

            // 각 property/element를 assignment로 변환
            if (left_node.tag == .object_assignment_target) {
                try emitObjectAssignments(self, left_node, temp_span, span);
            } else if (left_node.tag == .array_assignment_target) {
                try emitArrayAssignments(self, left_node, temp_span, span);
            }

            // 마지막에 _ref 반환
            try self.scratch.append(self.allocator, try es_helpers.makeTempVarRef(self, temp_span, temp_span));

            // sequence expression
            const seq_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
        }

        /// object_assignment_target의 각 property를 assignment로 변환.
        fn emitObjectAssignments(self: *Transformer, target: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const oa_start = target.data.list.start;
            const split = self.ast.nodeListSplitRest(target.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var exclude_keys: std.ArrayList(NodeIndex) = .empty;
            defer exclude_keys.deinit(self.allocator);
            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < non_rest_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[oa_start + i_loop];
                const prop = self.ast.getNode(@enumFromInt(raw_idx));

                const key_idx = prop.data.binary.left;
                if (key_idx.isNone()) continue;

                const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
                const key_node = self.ast.getNode(key_idx);
                const access = try emitObjectMemberAccessForRest(self, ref, key_node, key_idx, &exclude_keys, .assign, span);

                if (prop.tag == .assignment_target_property_identifier) {
                    const target_node = try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = key_node.span,
                        .data = .{ .string_ref = key_node.data.string_ref },
                    });
                    // 새로 만든 노드는 symbol_ids 밖이라 그대로 두면 mangler rename 이
                    // 통째로 스킵된다 — `({o: {s, w = 1}} = box)` 가 es5 로 낮아질 때
                    // 원본 이름으로 대입돼 미선언 전역이 된다 (#4493 의 es5 표면).
                    // 이 파일의 다른 노드 생성 지점과 동일하게 심볼을 물려준다.
                    self.propagateSymbolId(key_idx, target_node);

                    // shorthand_with_default: {a = 1} → a = _ref.a === void 0 ? 1 : _ref.a
                    // flags bit 0 = shorthand_with_default, right = default value
                    const is_shorthand_default = (prop.data.binary.flags & 0x01) != 0;
                    const rhs = if (is_shorthand_default and !prop.data.binary.right.isNone()) blk: {
                        const default_val = try self.visitNode(prop.data.binary.right);
                        break :blk try buildDefaulted(self, access, default_val, ref_span, key_idx, key_node.tag, span);
                    } else access;

                    const assign = try self.ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = target_node, .right = rhs, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, assign);
                } else {
                    // long-form {a: b} 또는 {a: b = 1}
                    const right_idx = prop.data.binary.right;
                    const right_node = self.ast.getNode(right_idx);

                    if (right_node.tag == .assignment_target_with_default) {
                        const default_val = try self.visitNode(right_node.data.binary.right);
                        const rhs = try buildDefaulted(self, access, default_val, ref_span, key_idx, key_node.tag, span);
                        try emitTargetAssignOrRecurse(self, right_node.data.binary.left, rhs, span);
                    } else {
                        try emitTargetAssignOrRecurse(self, right_idx, access, span);
                    }
                }
            }

            if (split.rest_operand) |rest_inner| {
                const rest_assign = try buildRestAssignment(self, rest_inner, ref_span, exclude_keys.items, span);
                try self.scratch.append(self.allocator, rest_assign);
                self.runtime_helpers.rest = true;
            }
        }

        /// array_assignment_target의 각 element를 assignment로 변환.
        fn emitArrayAssignments(self: *Transformer, target: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const aa_start = target.data.list.start;
            // assignment 컨텍스트의 rest는 declaration 컨텍스트의 __rest 같은 런타임 헬퍼가
            // 없어 현재 미지원 — split으로 elements만 처리하고 rest는 무시.
            const split = self.ast.nodeListSplitRest(target.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var idx: u32 = 0;
            while (idx < non_rest_len) : (idx += 1) {
                const raw_idx = self.ast.extra_data.items[aa_start + idx];
                const elem = self.ast.getNode(@enumFromInt(raw_idx));
                if (elem.tag == .elision) continue;

                // _ref[idx]
                const access = try makeArrayAccess(self, ref_span, idx, span);

                if (elem.tag == .assignment_target_with_default) {
                    // [x = 1] → x = _ref[0] === void 0 ? 1 : _ref[0]
                    const default_val = try self.visitNode(elem.data.binary.right);
                    const void_zero = try es_helpers.makeVoidZero(self, span);
                    const eq_check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                    });
                    // _ref[idx] 다시 생성 (access는 eq_check에서 소비)
                    const access2 = try makeArrayAccess(self, ref_span, idx, span);
                    const conditional = try self.ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = access2 } },
                    });
                    try emitTargetAssignOrRecurse(self, elem.data.binary.left, conditional, span);
                } else {
                    // target = _ref[idx]. nested destructuring, private field, 일반 assignment 분기.
                    try emitTargetAssignOrRecurse(self, @enumFromInt(raw_idx), access, span);
                }
            }
        }

        /// target(old AST)에 value(new AST)를 배정. target 종류에 따라 분기:
        ///   - private_field_expression → `__classPrivateFieldSet(...)` (#1485).
        ///   - object/array_assignment_target → 임시 변수 + 재귀 emit (nested destructuring).
        ///   - 나머지 (identifier, member expr 등) → 일반 `target = value` assignment.
        /// 생성된 표현식은 self.scratch 에 push된다 (lowerDestructuringAssignment 패턴 유지).
        fn emitTargetAssignOrRecurse(self: *Transformer, target_old_idx: NodeIndex, value: NodeIndex, span: Span) Transformer.Error!void {
            if (try es2015_class.ES2015Class(Transformer).tryLowerPrivateFieldAssign(self, target_old_idx, value, span)) |call| {
                try self.scratch.append(self.allocator, call);
                return;
            }
            // #4244: super member target (`[super.x] = …`, `({a: super.x} = o)`) →
            // __superSet write helper. generic `visitNode(target)=value` 는 super.x 를
            // READ(`__superGet`)로 내려 `__superGet(...)=v` (Invalid LHS) 를 만든다.
            if (try es2015_class.ES2015Class(Transformer).trySuperAssignTarget(self, target_old_idx, value, span)) |super_set| {
                try self.scratch.append(self.allocator, super_set);
                return;
            }
            const target_node = self.ast.getNode(target_old_idx);
            if (target_node.tag == .object_assignment_target or target_node.tag == .array_assignment_target or target_node.tag == .object_pattern or target_node.tag == .array_pattern) {
                // nested: _inner = value; 각 element 재귀 emit.
                const inner_span = try es_helpers.makeTempVarSpan(self);
                const inner_lhs = try es_helpers.makeTempVarRef(self, inner_span, inner_span);
                const inner_value = if (target_node.tag == .array_assignment_target or target_node.tag == .array_pattern)
                    try buildArrayRead(self, value, target_node, span)
                else
                    value;
                const init = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = inner_lhs, .right = inner_value, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, init);
                if (target_node.tag == .object_assignment_target or target_node.tag == .object_pattern) {
                    try emitObjectAssignments(self, target_node, inner_span, span);
                } else {
                    try emitArrayAssignments(self, target_node, inner_span, span);
                }
                return;
            }
            const visited_target = try self.visitNode(target_old_idx);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = visited_target, .right = value, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, assign);
        }

        /// object_pattern 또는 array_pattern을 개별 declarator로 분해.
        /// ref_span은 임시 변수의 span (_ref).
        pub fn emitPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
            if (pattern.tag == .object_pattern) {
                try emitObjectPatternDeclarators(self, pattern, ref_span, span);
            } else if (pattern.tag == .array_pattern) {
                try emitArrayPatternDeclarators(self, pattern, ref_span, span);
            }
        }

        /// object_pattern의 각 property를 declarator로 변환.
        /// { a, b: c, d = 1 } → var a = _ref.a, c = _ref.b, d = _ref.d === void 0 ? 1 : _ref.d
        /// { a, ...rest } → var a = _ref.a, rest = __rest(_ref, ["a"])
        fn emitObjectPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const opd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);

            var exclude_keys: std.ArrayList(NodeIndex) = .empty;
            defer exclude_keys.deinit(self.allocator);

            // 각 property를 declarator로 변환하면서 rest exclude key도 같은 평가 결과로 수집한다.
            // visitNode가 AST를 변형하므로 인덱스 루프 사용 (split.elements 슬라이스는 stale 가능)
            const non_rest_len: u32 = @intCast(split.elements.len);
            var i_loop: u32 = 0;
            while (i_loop < non_rest_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[opd_start + i_loop];
                const prop = self.ast.getNode(@enumFromInt(raw_idx));

                if (prop.tag != .binding_property) continue;

                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;

                const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
                const key_node = self.ast.getNode(key_idx);

                const member_access = try emitObjectMemberAccessForRest(self, ref, key_node, key_idx, &exclude_keys, .decl, span);

                // value 처리: shorthand vs long-form, default value
                if (value_idx.isNone() or @intFromEnum(value_idx) == @intFromEnum(key_idx)) {
                    // shorthand: { a } → var a = _ref.a
                    // block scoping rename이 필요한 경우 이름 교체.
                    var binding_span = key_node.span;
                    var binding_data = key_node.data.string_ref;
                    if (self.options.unsupported.block_scoping and self.block_rename_stack.items.len > 0) {
                        const text = self.ast.getText(key_node.data.string_ref);
                        if (self.lookupBlockRename(text)) |new_name| {
                            const new_span = try self.ast.addString(new_name);
                            binding_span = new_span;
                            binding_data = new_span;
                        }
                    }
                    const binding = try self.ast.addNode(.{
                        .tag = .binding_identifier,
                        .span = binding_span,
                        .data = .{ .string_ref = binding_data },
                    });
                    self.propagateSymbolId(key_idx, binding);
                    const decl = try es_helpers.makeDeclarator(self, binding, member_access, span);
                    try self.scratch.append(self.allocator, decl);
                } else {
                    const value_node = self.ast.getNode(value_idx);
                    if (value_node.tag == .assignment_pattern) {
                        const left_node = self.ast.getNode(value_node.data.binary.left);
                        if (left_node.tag == .object_pattern or left_node.tag == .array_pattern) {
                            // (#3979) default 가 있는 *중첩* 패턴: { a: { c = 2 } = {} }
                            //   → var _ref2 = _ref.a === void 0 ? {} : _ref.a; var c = _ref2.c ...
                            // left 가 패턴이면 visitNode 로 verbatim 방출(invalid ES5)하지 말고
                            // defaulted 값을 임시변수에 담아 재귀(non-default 중첩 분기와 동일 lowering).
                            const default_val = try self.visitNode(value_node.data.binary.right);
                            try rewritePatternDefaultTDZ(self, default_val, pattern, i_loop);
                            const defaulted = try buildDefaulted(self, member_access, default_val, ref_span, key_idx, key_node.tag, span);
                            const nested_span = try es_helpers.makeTempVarSpan(self);
                            const nested_binding = try es_helpers.makeBindingIdentifier(self, nested_span);
                            const nested_init = if (left_node.tag == .array_pattern)
                                try buildArrayRead(self, defaulted, left_node, span)
                            else
                                defaulted;
                            const nested_decl = try es_helpers.makeDeclarator(self, nested_binding, nested_init, span);
                            try self.scratch.append(self.allocator, nested_decl);
                            try emitPatternDeclarators(self, left_node, nested_span, span);
                        } else {
                            // default: { a = 1 } → var a = _ref.a === void 0 ? 1 : _ref.a
                            const binding = try self.visitNode(value_node.data.binary.left);
                            const default_val = try self.visitNode(value_node.data.binary.right);
                            try rewritePatternDefaultTDZ(self, default_val, pattern, i_loop);
                            const defaulted = try buildDefaulted(self, member_access, default_val, ref_span, key_idx, key_node.tag, span);
                            const decl = try es_helpers.makeDeclarator(self, binding, defaulted, span);
                            try self.scratch.append(self.allocator, decl);
                        }
                    } else if (value_node.tag == .object_pattern or value_node.tag == .array_pattern) {
                        // nested: { a: { b } } → var _ref2 = _ref.a; var b = _ref2.b
                        const nested_span = try es_helpers.makeTempVarSpan(self);
                        const nested_binding = try es_helpers.makeBindingIdentifier(self, nested_span);
                        const nested_init = if (value_node.tag == .array_pattern)
                            try buildArrayRead(self, member_access, value_node, span)
                        else
                            member_access;
                        const nested_decl = try es_helpers.makeDeclarator(self, nested_binding, nested_init, span);
                        try self.scratch.append(self.allocator, nested_decl);
                        try emitPatternDeclarators(self, value_node, nested_span, span);
                    } else {
                        // long-form: { a: b } → var b = _ref.a
                        const binding = try self.visitNode(value_idx);
                        const decl = try es_helpers.makeDeclarator(self, binding, member_access, span);
                        try self.scratch.append(self.allocator, decl);
                    }
                }
            }

            // rest: var rest = __rest(_ref, ["a", "b"])
            if (split.rest_operand) |rest_inner| {
                const rest_decl = try buildRestDeclarator(self, rest_inner, ref_span, exclude_keys.items, span);
                try self.scratch.append(self.allocator, rest_decl);
                self.runtime_helpers.rest = true;
            }
        }

        /// array_pattern의 각 요소를 declarator로 변환.
        /// [x, y] → var x = _ref[0], y = _ref[1]
        fn emitArrayPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const apd_start = pattern.data.list.start;
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);

            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var idx: u32 = 0;
            while (idx < non_rest_len) : (idx += 1) {
                const raw_idx = self.ast.extra_data.items[apd_start + idx];
                const elem = self.ast.getNode(@enumFromInt(raw_idx));

                if (elem.tag == .elision) continue; // 빈 슬롯 스킵

                // _ref[idx]
                const elem_access = try makeArrayAccess(self, ref_span, idx, span);

                if (elem.tag == .assignment_pattern) {
                    const left_node = self.ast.getNode(elem.data.binary.left);
                    if (left_node.tag == .object_pattern or left_node.tag == .array_pattern) {
                        // (#3979) default 가 있는 *중첩* 패턴: [ { a = 1 } = {} ] / [ [c=2] = [] ]
                        // left 가 패턴이면 verbatim 방출(invalid ES5)하지 말고 defaulted 값을
                        // 임시변수에 담아 재귀(non-default 중첩 분기와 동일 lowering).
                        const default_val = try self.visitNode(elem.data.binary.right);
                        try rewritePatternDefaultTDZ(self, default_val, pattern, idx);
                        const void_zero = try es_helpers.makeVoidZero(self, span);
                        const elem_access2 = try makeArrayAccess(self, ref_span, idx, span);
                        const eq_check = try self.ast.addNode(.{
                            .tag = .binary_expression,
                            .span = span,
                            .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                        });
                        const conditional = try self.ast.addNode(.{
                            .tag = .conditional_expression,
                            .span = span,
                            .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                        });
                        const nested_span = try es_helpers.makeTempVarSpan(self);
                        const nested_binding = try es_helpers.makeBindingIdentifier(self, nested_span);
                        const nested_init = if (left_node.tag == .array_pattern)
                            try buildArrayRead(self, conditional, left_node, span)
                        else
                            conditional;
                        const nested_decl = try es_helpers.makeDeclarator(self, nested_binding, nested_init, span);
                        try self.scratch.append(self.allocator, nested_decl);
                        try emitPatternDeclarators(self, left_node, nested_span, span);
                    } else {
                        // default: [x = 1] → var x = _ref[0] === void 0 ? 1 : _ref[0]
                        const binding = try self.visitNode(elem.data.binary.left);
                        const default_val = try self.visitNode(elem.data.binary.right);
                        try rewritePatternDefaultTDZ(self, default_val, pattern, idx);
                        const void_zero = try es_helpers.makeVoidZero(self, span);
                        const elem_access2 = try makeArrayAccess(self, ref_span, idx, span);
                        const eq_check = try self.ast.addNode(.{
                            .tag = .binary_expression,
                            .span = span,
                            .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                        });
                        const conditional = try self.ast.addNode(.{
                            .tag = .conditional_expression,
                            .span = span,
                            .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                        });
                        const decl = try es_helpers.makeDeclarator(self, binding, conditional, span);
                        try self.scratch.append(self.allocator, decl);
                    }
                } else if (elem.tag == .object_pattern or elem.tag == .array_pattern) {
                    // nested: [[a, b]] → var _ref2 = _ref[0]; var a = _ref2[0]; ...
                    const nested_span = try es_helpers.makeTempVarSpan(self);
                    const nested_binding = try es_helpers.makeBindingIdentifier(self, nested_span);
                    const nested_init = if (elem.tag == .array_pattern)
                        try buildArrayRead(self, elem_access, elem, span)
                    else
                        elem_access;
                    const nested_decl = try es_helpers.makeDeclarator(self, nested_binding, nested_init, span);
                    try self.scratch.append(self.allocator, nested_decl);
                    try emitPatternDeclarators(self, elem, nested_span, span);
                } else {
                    // 단순: [x] → var x = _ref[0]
                    const binding = try self.visitNode(@enumFromInt(raw_idx));
                    const decl = try es_helpers.makeDeclarator(self, binding, elem_access, span);
                    try self.scratch.append(self.allocator, decl);
                }
            }

            // ...rest → var rest = _ref.slice(N)
            if (split.rest_operand) |rest_inner| {
                const rest_binding = try self.visitNode(rest_inner);
                const rest_init = try buildArraySlice(self, ref_span, non_rest_len, span);
                const rest_decl = try es_helpers.makeDeclarator(self, rest_binding, rest_init, span);
                try self.scratch.append(self.allocator, rest_decl);
            }
        }

        /// _ref.key === void 0 ? default : _ref.key (또는 _ref["key"])
        fn buildDefaulted(self: *Transformer, access: NodeIndex, default_val: NodeIndex, ref_span: Span, key_idx: NodeIndex, key_tag: Node.Tag, span: Span) Transformer.Error!NodeIndex {
            const void_zero = try es_helpers.makeVoidZero(self, span);
            const eq_check = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
            });
            // access는 이미 eq_check에서 소비되었으므로 다시 생성
            const ref2 = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
            const new_key = try self.visitNode(key_idx);
            const access2 = try es_helpers.makeMemberFromKey(self, ref2, new_key, key_tag, span);
            return self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = access2 } },
            });
        }

        /// _ref[idx] computed member expression 생성 (배열 인덱스 접근).
        fn makeArrayAccess(self: *Transformer, ref_span: Span, idx: usize, span: Span) Transformer.Error!NodeIndex {
            const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(idx));
            return es_helpers.makeComputedMember(self, ref, idx_node, span);
        }

        /// _ref.slice(N) 호출 생성 (array rest 변환용).
        fn buildArraySlice(self: *Transformer, ref_span: Span, start_idx: usize, span: Span) Transformer.Error!NodeIndex {
            // _ref.slice
            const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
            const slice_prop = try es_helpers.makeIdentifierRef(self, "slice");
            const callee = try es_helpers.makeStaticMember(self, ref, slice_prop, span);

            // slice(N)
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(start_idx));
            return es_helpers.makeCallExpr(self, callee, &.{idx_node}, span);
        }

        pub fn buildArrayRead(self: *Transformer, value: NodeIndex, pattern: Node, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.read = true;
            const callee = try es_helpers.makeRuntimeHelperRef(self, "__read");
            const read_len = arrayPatternReadLimit(self, pattern);
            if (read_len) |len| {
                const len_node = try es_helpers.makeNumericLiteral(self, len);
                return es_helpers.makeCallExpr(self, callee, &.{ value, len_node }, span);
            }
            return es_helpers.makeCallExpr(self, callee, &.{value}, span);
        }

        fn arrayPatternReadLimit(self: *Transformer, pattern: Node) ?u32 {
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            if (split.rest_operand != null) return null;
            return @intCast(split.elements.len);
        }

        fn rewritePatternDefaultTDZ(self: *Transformer, default_val: NodeIndex, pattern: Node, start_idx: u32) Transformer.Error!void {
            var names: std.ArrayList(Span) = .empty;
            defer names.deinit(self.allocator);
            try collectPatternBindingNamesFrom(self, pattern, start_idx, &names);
            try es_helpers.rewriteTDZReferences(self, default_val, names.items);
        }

        fn collectPatternBindingNamesFrom(self: *Transformer, pattern: Node, start_idx: u32, out: *std.ArrayList(Span)) Transformer.Error!void {
            const split = self.ast.nodeListSplitRest(pattern.data.list);
            const non_rest_len: u32 = @intCast(split.elements.len);
            var i: u32 = start_idx;
            while (i < non_rest_len) : (i += 1) {
                const raw = self.ast.extra_data.items[pattern.data.list.start + i];
                try collectBindingNames(self, @enumFromInt(raw), out);
            }
            if (split.rest_operand) |rest| try collectBindingNames(self, rest, out);
        }

        fn collectBindingNames(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(Span)) Transformer.Error!void {
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                try out.append(self.allocator, self.ast.getNode(leaf_idx).data.string_ref);
            }
        }

        const ComputedKeyMode = enum { decl, assign };

        /// object pattern 의 한 property 에 대해 `_ref[key]` member access 를 만들고, rest 가 있으면
        /// exclude key 도 같은 capture 결과로 모아둔다.
        ///
        /// computed key (`{[k()]: a}`) 는 평가 순서 보존을 위해 한 번 임시 변수로 캡쳐 — destructuring
        /// declarator 컨텍스트에서는 `_key=expr` declarator, assignment-target 컨텍스트에서는
        /// `(_key=expr)` assignment_expression 형태로 `self.scratch` 에 push 한다.
        ///
        /// non-computed key (identifier/string/number) 는 캡쳐 없이 곧장 member access 를 만들고,
        /// rest exclude 는 raw key 를 따옴표로 감싼 string literal 로 등록한다.
        fn emitObjectMemberAccessForRest(
            self: *Transformer,
            ref: NodeIndex,
            key_node: Node,
            key_idx: NodeIndex,
            exclude_keys: *std.ArrayList(NodeIndex),
            mode: ComputedKeyMode,
            span: Span,
        ) Transformer.Error!NodeIndex {
            if (key_node.tag == .computed_property_key) {
                const key_span = try es_helpers.makeTempVarSpan(self);
                const capture: NodeIndex = switch (mode) {
                    .decl => blk: {
                        const key_binding = try es_helpers.makeBindingIdentifier(self, key_span);
                        const key_value = try self.visitNode(key_node.data.unary.operand);
                        break :blk try es_helpers.makeDeclarator(self, key_binding, key_value, span);
                    },
                    .assign => try self.ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = span,
                        .data = .{ .binary = .{
                            .left = try es_helpers.makeTempVarRef(self, key_span, span),
                            .right = try self.visitNode(key_node.data.unary.operand),
                            .flags = @intFromEnum(token_mod.Kind.eq),
                        } },
                    }),
                };
                try self.scratch.append(self.allocator, capture);
                try exclude_keys.append(self.allocator, try es_helpers.makeTempVarRef(self, key_span, span));
                return es_helpers.makeComputedMember(self, ref, try es_helpers.makeTempVarRef(self, key_span, span), span);
            }
            try exclude_keys.append(self.allocator, try makeRestExcludeKey(self, key_node));
            return es_helpers.makeMemberFromKeyIdx(self, ref, key_idx, span);
        }

        fn makeRestExcludeKey(self: *Transformer, key_node: Node) Transformer.Error!NodeIndex {
            // __rest 헬퍼는 `e[i] = String(e[i])` 로 exclusion 원소를 런타임 정규화
            // (runtime_helpers.zig REST_RUNTIME). 따라서 #4242:
            switch (key_node.tag) {
                .identifier_reference, .binding_identifier => {
                    // 이름 표기 — \u escape 는 디코드해야 es5 에서 잔존(SyntaxError)
                    // /이중escape 안 됨. escape 없으면 byte-identical.
                    const raw = self.ast.getText(key_node.span);
                    if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
                        return self.wrapInStringLiteral(raw);
                    }
                    const group_name = @import("../regexp/group_name.zig");
                    var decoded: std.ArrayList(u8) = .empty;
                    defer decoded.deinit(self.allocator);
                    try group_name.appendCanonical(self.allocator, &decoded, raw);
                    return self.wrapInStringLiteral(decoded.items);
                },
                // string/numeric/bigint key 는 노드 그대로 — 헬퍼 String() 이
                // 정규화. 이전: string 은 strip+requote 로 `'q"z'`→`"q"z"`
                // SyntaxError, numeric/bigint 는 `else=>""` 빈 exclusion(누락).
                .string_literal, .numeric_literal, .bigint_literal => {
                    return self.ast.addNode(.{
                        .tag = key_node.tag,
                        .span = key_node.span,
                        .data = key_node.data,
                    });
                },
                else => return self.wrapInStringLiteral(""),
            }
        }

        /// `__rest(_ref, [exclude_keys...])` 호출과 visit 된 binding 을 한 쌍으로 빌드.
        /// declarator 컨텍스트와 assignment 컨텍스트가 같은 11-step 보일러플레이트를 공유 (#1287).
        fn buildRestCall(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
        ) Transformer.Error!struct { binding: NodeIndex, call: NodeIndex } {
            const binding = try self.visitNode(rest_idx);
            const rest_callee = try es_helpers.makeRuntimeHelperRef(self, "__rest");
            const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            for (exclude_keys) |key| {
                try self.scratch.append(self.allocator, key);
            }
            const arr_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const arr_node = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_list },
            });
            const call = try es_helpers.makeCallExpr(self, rest_callee, &.{ ref, arr_node }, span);
            return .{ .binding = binding, .call = call };
        }

        /// rest = __rest(_ref, [...]) declarator (declaration 컨텍스트).
        fn buildRestDeclarator(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const parts = try buildRestCall(self, rest_idx, ref_span, exclude_keys, span);
            return es_helpers.makeDeclarator(self, parts.binding, parts.call, span);
        }

        /// rest = __rest(_ref, [...]) assignment (assignment-target 컨텍스트).
        fn buildRestAssignment(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const NodeIndex,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const parts = try buildRestCall(self, rest_idx, ref_span, exclude_keys, span);
            return self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = parts.binding, .right = parts.call, .flags = 0 } },
            });
        }
        /// for_in_statement를 기본적으로 visit (ternary 자식 3개 재귀 방문).
        fn visitForInDefault(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_a = try self.visitNode(node.data.ternary.a);
            const new_b = try self.visitNode(node.data.ternary.b);
            const new_c = try self.visitNode(node.data.ternary.c);
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
            });
        }

        /// for-in/for-of 루프의 binding destructuring을 분해한다 (node.tag 보존).
        /// for (var [i,j,k] in obj) { body }
        /// → for (var _ref in obj) { var i = _ref[0], j = _ref[1], k = _ref[2]; body }
        /// for (const { a, ...r } of arr) { body }  (#4254: object rest at es2015~17)
        /// → for (var _ref of arr) { var a = _ref.a, r = __rest(_ref, ["a"]); body }
        ///
        /// for-in/for-of 는 left 에 단일 binding 만 허용하므로 destructuring pattern 을
        /// 임시 변수로 교체하고 body 앞에 분해 선언문을 삽입한다. LHS 슬롯에 multi-
        /// declarator 를 직접 넣으면(`for(var _a,a=_a.a,... of)`) invalid 문법이 된다.
        pub fn lowerForInOfDestructuring(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a; // variable_declaration
            const right = node.data.ternary.b; // right-hand side expression
            const body = node.data.ternary.c; // body

            const left_node = self.ast.getNode(left);

            // assignment-target LHS (`for ({a, ...r} of arr)`) 는 binding 이 아니므로
            // 별도 처리: body 에 `({a,...r} = _ref)` assignment 를 prepend (#4254 후속).
            if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                return lowerForInOfAssignTargetDestructuring(self, node);
            }

            // variable_declaration에서 첫 번째 declarator의 패턴을 추출
            const le = left_node.data.extra;
            const list_start = self.readU32(le, 1);
            const list_len = self.readU32(le, 2);
            if (list_len == 0) return visitForInDefault(self, node);

            const first_decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start]);
            const first_decl = self.ast.getNode(first_decl_idx);
            if (first_decl.tag != .variable_declarator) return visitForInDefault(self, node);

            const binding_idx: NodeIndex = self.readNodeIdx(first_decl.data.extra, 0);
            if (binding_idx.isNone()) return visitForInDefault(self, node);
            const binding_node = self.ast.getNode(binding_idx);

            // destructuring pattern이 아니면 일반 처리
            if (binding_node.tag != .array_pattern and binding_node.tag != .object_pattern) {
                return visitForInDefault(self, node);
            }

            // 1) 임시 변수 _ref 생성
            const temp_span = try es_helpers.makeTempVarSpan(self);

            // 2) for-in의 left를 var _ref 로 교체
            // #4254: per-iteration 바인딩 보존 — block_scoping native(es2015+)면
            // 원본 let/const 유지. var 로 강등하면 loop temp/destructure 가 함수
            // 스코프 단일 바인딩으로 붕괴해 closure capture 가 깨진다(마지막 iter
            // 값만 캡처). block_scoping 미지원(es5)이면 var (for-of 는 es5 에서 이
            // 경로 미도달=lowerForOfStatement; for-in 만, 기존 var 동작 유지).
            const orig_kind = self.ast.variableDeclarationKind(left_node);
            const out_kind: ast_mod.VariableDeclarationKind = if (self.options.unsupported.block_scoping) .@"var" else orig_kind;

            const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);
            const temp_decl = try es_helpers.makeDeclarator(self, temp_binding, NodeIndex.none, span);
            const new_left = try es_helpers.makeVarDeclaration(self, &.{temp_decl}, out_kind, span);

            // 3) right를 visit
            const new_right = try self.visitNode(right);

            // 4) body를 visit
            const new_body = try self.visitNode(body);

            // 5) body 앞에 삽입할 destructuring 선언문들을 생성
            //    var i = _ref[0], j = _ref[1], k = _ref[2]
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try emitPatternDeclarators(self, binding_node, temp_span, span);

            // scratch에 쌓인 declarator들로 variable_declaration 생성
            const decl_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const var_extra = try self.ast.addExtras(&.{ @intFromEnum(out_kind), decl_list.start, decl_list.len });
            const destr_decl = try self.ast.addNode(.{
                .tag = .variable_declaration,
                .span = span,
                .data = .{ .extra = var_extra },
            });

            // 6) body 앞에 destructuring 선언문 삽입
            const final_body = if (!new_body.isNone())
                try self.prependStatementsToBody(new_body, &.{destr_decl})
            else
                new_body;

            // 7) 새 for_in/for_of_statement 생성 (입력 tag 보존)
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .ternary = .{ .a = new_left, .b = new_right, .c = final_body } },
            });
        }

        /// for-of/for-in 의 LHS 가 assignment-target object/array rest 일 때
        /// (`for ({a, ...r} of arr)`), body 에 `({a,...r} = _ref)` 를 prepend (#4254 후속).
        /// `for (kind _ref of arr) { ({a,...r} = _ref); body }`. 그 assignment 는
        /// visit 시 lowerDestructuringAssignment(#4251 object_spread 게이트)가 __rest
        /// 로 lowering. assignment target(a/r)은 outer 변수라 _ref 만 per-iteration
        /// 바인딩(closure 는 outer 캡처).
        fn lowerForInOfAssignTargetDestructuring(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a; // object/array_assignment_target
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;

            const temp_span = try es_helpers.makeTempVarSpan(self);
            const out_kind: ast_mod.VariableDeclarationKind = if (self.options.unsupported.block_scoping) .@"var" else .@"const";
            const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);
            const temp_decl = try es_helpers.makeDeclarator(self, temp_binding, NodeIndex.none, span);
            const new_left = try es_helpers.makeVarDeclaration(self, &.{temp_decl}, out_kind, span);

            const new_right = try self.visitNode(right);
            const new_body = try self.visitNode(body);

            // ({a,...r} = _ref) — visit 시 lowerDestructuringAssignment 로 __rest lowering.
            const ref_for_assign = try es_helpers.makeTempVarRef(self, temp_span, span);
            const assign = try es_helpers.makeAssignExpr(self, left, ref_for_assign, span, 0);
            const visited_assign = try self.visitNode(assign);
            const assign_stmt = try es_helpers.makeExprStmt(self, visited_assign, span);

            const final_body = if (!new_body.isNone())
                try self.prependStatementsToBody(new_body, &.{assign_stmt})
            else
                new_body;

            return self.ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .ternary = .{ .a = new_left, .b = new_right, .c = final_body } },
            });
        }
    };
}

test "ES2015 destructuring module compiles" {
    _ = ES2015Destructuring;
}
