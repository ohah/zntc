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
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015Destructuring(comptime Transformer: type) type {
    return struct {
        /// variable_declaration에 destructuring pattern이 있는지 확인.
        pub fn hasDestructuring(self: *const Transformer, node: Node) bool {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return false;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];
            for (decls) |raw_idx| {
                const decl = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) continue;
                const name: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                if (name.isNone()) continue;
                const name_node = self.old_ast.getNode(name);
                if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) return true;
            }
            return false;
        }

        /// variable_declaration 안에 object rest (...rest)가 있는지 체크.
        /// ES2018 object rest는 target < es2018에서 __rest로 변환 필요.
        pub fn hasObjectRest(self: *const Transformer, node: Node) bool {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return false;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];
            for (decls) |raw_idx| {
                const decl = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) continue;
                const name: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                if (name.isNone()) continue;
                const name_node = self.old_ast.getNode(name);
                if (name_node.tag == .object_pattern) {
                    if (objectPatternHasRest(self, name_node)) return true;
                }
            }
            return false;
        }

        fn objectPatternHasRest(self: *const Transformer, pattern: Node) bool {
            const list = pattern.data.list;
            if (list.len == 0) return false;
            if (list.start + list.len > self.old_ast.extra_data.items.len) return false;
            const indices = self.old_ast.extra_data.items[list.start .. list.start + list.len];
            for (indices) |raw_idx| {
                const prop_idx: NodeIndex = @enumFromInt(raw_idx);
                if (prop_idx.isNone()) continue;
                const prop = self.old_ast.getNode(prop_idx);
                if (prop.tag == .rest_element) return true;
            }
            return false;
        }

        /// destructuring이 있는 variable_declaration을 분해한다.
        /// 각 destructuring declarator를 여러 개의 단순 declarator로 풀어서 반환.
        pub fn lowerDestructuringDeclaration(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const old_decls = extras[list_start .. list_start + list_len];

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            for (old_decls) |raw_idx| {
                const decl = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (decl.tag != .variable_declarator) continue;

                const name_idx: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                const init_idx: NodeIndex = @enumFromInt(extras[decl.data.extra + 2]);

                if (name_idx.isNone()) continue;
                const name_node = self.old_ast.getNode(name_idx);

                if (name_node.tag == .object_pattern or name_node.tag == .array_pattern) {
                    // destructuring → 분해
                    // 먼저 init을 임시 변수에 저장
                    const new_init = try self.visitNode(init_idx);
                    const temp_span = try es_helpers.makeTempVarSpan(self);
                    const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);

                    // var _ref = init
                    const ref_decl = try es_helpers.makeDeclarator(self, temp_binding, new_init, span);
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
            const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const var_extra = try self.new_ast.addExtras(&.{ 0, new_list.start, new_list.len }); // 0 = var
            return self.new_ast.addNode(.{
                .tag = .variable_declaration,
                .span = span,
                .data = .{ .extra = var_extra },
            });
        }

        /// assignment destructuring을 sequence expression으로 변환.
        /// ({a, b} = obj) → (_ref = obj, a = _ref.a, b = _ref.b, _ref)
        pub fn lowerDestructuringAssignment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left_idx = node.data.binary.left;
            const right_idx = node.data.binary.right;

            const left_node = self.old_ast.getNode(left_idx);
            const new_right = try self.visitNode(right_idx);
            const temp_span = try es_helpers.makeTempVarSpan(self);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // _ref = obj
            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const init_assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = new_right, .flags = 0 } },
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
            const seq_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.new_ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
        }

        /// object_assignment_target의 각 property를 assignment로 변환.
        fn emitObjectAssignments(self: *Transformer, target: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const members = self.old_ast.extra_data.items[target.data.list.start .. target.data.list.start + target.data.list.len];
            for (members) |raw_idx| {
                const prop = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (prop.tag == .assignment_target_rest) continue; // rest 미지원

                const key_idx = prop.data.binary.left;
                if (key_idx.isNone()) continue;

                const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
                const key_node = self.old_ast.getNode(key_idx);
                const new_key = try self.visitNode(key_idx);
                const access = try es_helpers.makeMemberFromKey(self, ref, new_key, key_node.tag, span);

                if (prop.tag == .assignment_target_property_identifier) {
                    const target_node = try self.new_ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = key_node.span,
                        .data = .{ .string_ref = key_node.data.string_ref },
                    });

                    // shorthand_with_default: {a = 1} → a = _ref.a === void 0 ? 1 : _ref.a
                    // flags bit 0 = shorthand_with_default, right = default value
                    const is_shorthand_default = (prop.data.binary.flags & 0x01) != 0;
                    const rhs = if (is_shorthand_default and !prop.data.binary.right.isNone()) blk: {
                        const default_val = try self.visitNode(prop.data.binary.right);
                        break :blk try buildDefaulted(self, access, default_val, ref_span, key_idx, key_node.tag, span);
                    } else access;

                    const assign = try self.new_ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = target_node, .right = rhs, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, assign);
                } else {
                    // long-form {a: b} 또는 {a: b = 1}
                    const right_idx = prop.data.binary.right;
                    const right_node = self.old_ast.getNode(right_idx);

                    if (right_node.tag == .assignment_target_with_default) {
                        const target_node = try self.visitNode(right_node.data.binary.left);
                        const default_val = try self.visitNode(right_node.data.binary.right);
                        const rhs = try buildDefaulted(self, access, default_val, ref_span, key_idx, key_node.tag, span);
                        const assign = try self.new_ast.addNode(.{
                            .tag = .assignment_expression,
                            .span = span,
                            .data = .{ .binary = .{ .left = target_node, .right = rhs, .flags = 0 } },
                        });
                        try self.scratch.append(self.allocator, assign);
                    } else {
                        const target_node = try self.visitNode(right_idx);
                        const assign = try self.new_ast.addNode(.{
                            .tag = .assignment_expression,
                            .span = span,
                            .data = .{ .binary = .{ .left = target_node, .right = access, .flags = 0 } },
                        });
                        try self.scratch.append(self.allocator, assign);
                    }
                }
            }
        }

        /// array_assignment_target의 각 element를 assignment로 변환.
        fn emitArrayAssignments(self: *Transformer, target: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const members = self.old_ast.extra_data.items[target.data.list.start .. target.data.list.start + target.data.list.len];
            for (members, 0..) |raw_idx, idx| {
                const elem = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (elem.tag == .elision) continue;
                if (elem.tag == .assignment_target_rest) continue;

                // _ref[idx]
                const access = try makeArrayAccess(self, ref_span, idx, span);

                if (elem.tag == .assignment_target_with_default) {
                    // [x = 1] → x = _ref[0] === void 0 ? 1 : _ref[0]
                    const target_node = try self.visitNode(elem.data.binary.left);
                    const default_val = try self.visitNode(elem.data.binary.right);
                    const void_zero = try es_helpers.makeVoidZero(self, span);
                    const eq_check = try self.new_ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                    });
                    // _ref[idx] 다시 생성 (access는 eq_check에서 소비)
                    const access2 = try makeArrayAccess(self, ref_span, idx, span);
                    const conditional = try self.new_ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = access2 } },
                    });
                    const assign = try self.new_ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = target_node, .right = conditional, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, assign);
                } else {
                    // target = _ref[idx]
                    const target_node = try self.visitNode(@enumFromInt(raw_idx));
                    const assign = try self.new_ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = target_node, .right = access, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, assign);
                }
            }
        }

        /// object_pattern 또는 array_pattern을 개별 declarator로 분해.
        /// ref_span은 임시 변수의 span (_ref).
        fn emitPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
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
            const members = self.old_ast.extra_data.items[pattern.data.list.start .. pattern.data.list.start + pattern.data.list.len];

            // 1단계: rest가 아닌 property key 이름을 수집 (__rest의 exclude 배열용)
            var exclude_keys: [64][]const u8 = undefined;
            var exclude_count: usize = 0;
            var rest_binding_idx: ?NodeIndex = null;

            for (members) |raw_idx| {
                const prop = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (prop.tag == .rest_element or prop.tag == .binding_rest_element) {
                    // rest element의 operand가 바인딩 이름
                    rest_binding_idx = prop.data.unary.operand;
                    continue;
                }
                if (prop.tag != .binding_property) continue;
                // key 이름 수집
                const key_idx_inner = prop.data.binary.left;
                if (!key_idx_inner.isNone()) {
                    const key_node_inner = self.old_ast.getNode(key_idx_inner);
                    if ((key_node_inner.tag == .identifier_reference or key_node_inner.tag == .binding_identifier) and
                        exclude_count < exclude_keys.len)
                    {
                        exclude_keys[exclude_count] = self.old_ast.source[key_node_inner.span.start..key_node_inner.span.end];
                        exclude_count += 1;
                    }
                }
            }

            // 2단계: 각 property를 declarator로 변환
            for (members) |raw_idx| {
                const prop = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (prop.tag == .rest_element or prop.tag == .binding_rest_element) {
                    // rest: var rest = __rest(_ref, ["a", "b"])
                    if (rest_binding_idx) |rest_idx| {
                        const rest_decl = try buildRestDeclarator(self, rest_idx, ref_span, exclude_keys[0..exclude_count], span);
                        try self.scratch.append(self.allocator, rest_decl);
                        self.runtime_helpers.rest = true;
                    }
                    continue;
                }

                if (prop.tag != .binding_property) continue;

                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;

                const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
                const key_node = self.old_ast.getNode(key_idx);

                const member_access = try es_helpers.makeMemberFromKeyIdx(self, ref, key_idx, span);

                // value 처리: shorthand vs long-form, default value
                if (value_idx.isNone() or @intFromEnum(value_idx) == @intFromEnum(key_idx)) {
                    // shorthand: { a } → var a = _ref.a
                    // symbol_id 전파: linker가 리네이밍한 경우 binding에도 반영되어야 함.
                    const binding = try self.new_ast.addNode(.{
                        .tag = .binding_identifier,
                        .span = key_node.span,
                        .data = .{ .string_ref = key_node.data.string_ref },
                    });
                    self.propagateSymbolId(key_idx, binding);
                    const decl = try es_helpers.makeDeclarator(self, binding, member_access, span);
                    try self.scratch.append(self.allocator, decl);
                } else {
                    const value_node = self.old_ast.getNode(value_idx);
                    if (value_node.tag == .assignment_pattern) {
                        // default: { a = 1 } → var a = _ref.a === void 0 ? 1 : _ref.a
                        const binding = try self.visitNode(value_node.data.binary.left);
                        const default_val = try self.visitNode(value_node.data.binary.right);
                        const defaulted = try buildDefaulted(self, member_access, default_val, ref_span, key_idx, key_node.tag, span);
                        const decl = try es_helpers.makeDeclarator(self, binding, defaulted, span);
                        try self.scratch.append(self.allocator, decl);
                    } else if (value_node.tag == .object_pattern or value_node.tag == .array_pattern) {
                        // nested: { a: { b } } → var _ref2 = _ref.a; var b = _ref2.b
                        const nested_span = try es_helpers.makeTempVarSpan(self);
                        const nested_binding = try es_helpers.makeBindingIdentifier(self, nested_span);
                        const nested_decl = try es_helpers.makeDeclarator(self, nested_binding, member_access, span);
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
        }

        /// array_pattern의 각 요소를 declarator로 변환.
        /// [x, y] → var x = _ref[0], y = _ref[1]
        fn emitArrayPatternDeclarators(self: *Transformer, pattern: Node, ref_span: Span, span: Span) Transformer.Error!void {
            const members = self.old_ast.extra_data.items[pattern.data.list.start .. pattern.data.list.start + pattern.data.list.len];

            for (members, 0..) |raw_idx, idx| {
                const elem = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (elem.tag == .elision) continue; // 빈 슬롯 스킵

                if (elem.tag == .rest_element or elem.tag == .spread_element or elem.tag == .binding_rest_element) {
                    // ...rest → var rest = _ref.slice(N)
                    const rest_binding = try self.visitNode(elem.data.unary.operand);
                    const rest_init = try buildArraySlice(self, ref_span, idx, span);
                    const rest_decl = try es_helpers.makeDeclarator(self, rest_binding, rest_init, span);
                    try self.scratch.append(self.allocator, rest_decl);
                    continue;
                }

                // _ref[idx]
                const elem_access = try makeArrayAccess(self, ref_span, idx, span);

                if (elem.tag == .assignment_pattern) {
                    // default: [x = 1] → var x = _ref[0] === void 0 ? 1 : _ref[0]
                    const binding = try self.visitNode(elem.data.binary.left);
                    const default_val = try self.visitNode(elem.data.binary.right);
                    const void_zero = try es_helpers.makeVoidZero(self, span);
                    const elem_access2 = try makeArrayAccess(self, ref_span, idx, span);
                    const eq_check = try self.new_ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = elem_access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                    });
                    const conditional = try self.new_ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = span,
                        .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = elem_access2 } },
                    });
                    const decl = try es_helpers.makeDeclarator(self, binding, conditional, span);
                    try self.scratch.append(self.allocator, decl);
                } else if (elem.tag == .object_pattern or elem.tag == .array_pattern) {
                    // nested: [[a, b]] → var _ref2 = _ref[0]; var a = _ref2[0]; ...
                    const nested_span = try es_helpers.makeTempVarSpan(self);
                    const nested_binding = try es_helpers.makeBindingIdentifier(self, nested_span);
                    const nested_decl = try es_helpers.makeDeclarator(self, nested_binding, elem_access, span);
                    try self.scratch.append(self.allocator, nested_decl);
                    try emitPatternDeclarators(self, elem, nested_span, span);
                } else {
                    // 단순: [x] → var x = _ref[0]
                    const binding = try self.visitNode(@enumFromInt(raw_idx));
                    const decl = try es_helpers.makeDeclarator(self, binding, elem_access, span);
                    try self.scratch.append(self.allocator, decl);
                }
            }
        }

        /// _ref.key === void 0 ? default : _ref.key (또는 _ref["key"])
        fn buildDefaulted(self: *Transformer, access: NodeIndex, default_val: NodeIndex, ref_span: Span, key_idx: NodeIndex, key_tag: Node.Tag, span: Span) Transformer.Error!NodeIndex {
            const void_zero = try es_helpers.makeVoidZero(self, span);
            const eq_check = try self.new_ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = access, .right = void_zero, .flags = @intFromEnum(token_mod.Kind.eq3) } },
            });
            // access는 이미 eq_check에서 소비되었으므로 다시 생성
            const ref2 = try es_helpers.makeTempVarRef(self, ref_span, ref_span);
            const new_key = try self.visitNode(key_idx);
            const access2 = try es_helpers.makeMemberFromKey(self, ref2, new_key, key_tag, span);
            return self.new_ast.addNode(.{
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

        /// rest = __rest(_ref, ["key1", "key2"]) declarator 생성.
        fn buildRestDeclarator(
            self: *Transformer,
            rest_idx: NodeIndex,
            ref_span: Span,
            exclude_keys: []const []const u8,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const binding = try self.visitNode(rest_idx);

            // __rest 호출: __rest(_ref, ["key1", "key2"])
            const rest_callee = try es_helpers.makeIdentifierRef(self, "__rest");

            // _ref 참조
            const ref = try es_helpers.makeTempVarRef(self, ref_span, ref_span);

            // exclude 배열: ["key1", "key2"]
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            for (exclude_keys) |key| {
                // 따옴표 포함 문자열 리터럴
                var buf: [256]u8 = undefined;
                buf[0] = '"';
                @memcpy(buf[1 .. 1 + key.len], key);
                buf[1 + key.len] = '"';
                const str_span = try self.new_ast.addString(buf[0 .. key.len + 2]);
                const str_node = try self.new_ast.addNode(.{
                    .tag = .string_literal,
                    .span = str_span,
                    .data = .{ .string_ref = str_span },
                });
                try self.scratch.append(self.allocator, str_node);
            }

            const arr_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const arr_node = try self.new_ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_list },
            });

            // __rest(_ref, [...])
            const call = try es_helpers.makeCallExpr(self, rest_callee, &.{ ref, arr_node }, span);

            return es_helpers.makeDeclarator(self, binding, call, span);
        }
    };
}

test "ES2015 destructuring module compiles" {
    _ = ES2015Destructuring;
}
