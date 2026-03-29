//! ES2015 다운레벨링: class → function + prototype
//!
//! --target < es2015 일 때 활성화.
//!
//! class Foo { constructor(x) { this.x = x; } method() {} }
//! → function Foo(x) { this.x = x; }
//!   Foo.prototype.method = function() {};
//!
//! static method() {} → Foo.method = function() {};
//!
//! extends/super:
//!   class Child extends Parent { constructor(x) { super(x); } }
//!   → function Child(x) { Parent.call(this, x); }
//!     __extends(Child, Parent);
//!
//!   super.method() → Parent.prototype.method.call(this)
//!
//! getter/setter:
//!   get prop() {} / set prop(v) {}
//!   → Object.defineProperty(Foo.prototype, "prop", { get: function() {}, ... })
//!
//! 제한사항:
//!   - private members (#field): 미지원
//!   - class expression: 미지원 (declaration만)
//!   - static blocks: 무시 (ES2022 변환이 먼저 처리)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-class-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/classes/ (~1620줄)
//! - esbuild: pkg/js_parser/js_parser_lower_class.go (~2578줄)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015Class(comptime Transformer: type) type {
    return struct {
        /// class_declaration을 function + prototype assignment로 변환.
        ///
        /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
        /// 반환: function_declaration. 나머지 prototype assignment는 pending_nodes에 추가.
        pub fn lowerClassDeclaration(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const super_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 2]);

            // 클래스 이름 추출
            const new_name = try self.visitNode(name_idx);
            const name_span = if (!new_name.isNone())
                self.new_ast.getNode(new_name).data.string_ref
            else
                try self.new_ast.addString("_Class");

            // super class 처리
            const has_super = !super_idx.isNone();
            var super_span: ?Span = null;
            if (has_super) {
                const super_node = self.old_ast.getNode(super_idx);
                if (super_node.tag == .identifier_reference or super_node.tag == .binding_identifier) {
                    // 단순 식별자: 이름을 직접 사용
                    super_span = super_node.data.string_ref;
                } else {
                    // 표현식: visit하고 임시 변수에 저장 (TODO: IIFE 패턴)
                    // 현재는 단순 식별자만 지원
                    super_span = null;
                }
            }

            // super class context 설정 (constructor/method body 방문 시 사용)
            const saved_super = self.current_super_class;
            self.current_super_class = super_span;
            defer self.current_super_class = saved_super;

            // 클래스 바디 멤버 분류
            var cm = try classifyMembers(self, body_idx, span);
            defer cm.deinit(self.allocator);

            // private field 매핑 설정 (method body 방문 시 this.#x → _x.get(this) 변환에 사용)
            const saved_private_fields = self.current_private_fields;
            if (cm.private_fields.items.len > 0) {
                var mappings = try self.allocator.alloc(Transformer.PrivateFieldMapping, cm.private_fields.items.len);
                for (cm.private_fields.items, 0..) |pf, i| {
                    mappings[i] = .{ .original_name = pf.original_name, .var_name = pf.name };
                }
                self.current_private_fields = mappings;
            }
            defer {
                if (cm.private_fields.items.len > 0) {
                    self.allocator.free(self.current_private_fields);
                }
                self.current_private_fields = saved_private_fields;
            }

            // --- private fields → WeakMap 선언 (function 앞에 배치) ---
            // var _x = new WeakMap();
            for (cm.private_fields.items) |pf| {
                const wm_decl = try buildWeakMapDecl(self, pf.name, span);
                try self.pending_nodes.append(self.allocator, wm_decl);
            }

            // --- private field 초기화 → _x.set(this, init) (constructor body에 삽입) ---
            for (cm.private_fields.items) |pf| {
                const init_stmt = try buildPrivateFieldInit(self, pf.name, pf.init, span);
                try cm.instance_fields.append(self.allocator, init_stmt);
            }

            // --- function declaration 생성 (pending_nodes에 추가) ---
            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, new_name, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, new_name, super_span.?, span)
            else
                try buildEmptyFunction(self, new_name, span);

            // instance fields → constructor body 앞에 삽입
            if (cm.instance_fields.items.len > 0) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }

            try self.pending_nodes.append(self.allocator, func_node);

            // --- __extends(Child, Parent) 호출 ---
            if (has_super and super_span != null) {
                const extends_call = try buildExtendsCall(self, name_span, super_span.?, span);
                try self.pending_nodes.append(self.allocator, extends_call);
                self.runtime_helpers.extends = true;
            }

            // --- prototype assignment 생성 (pending_nodes에 추가) ---
            for (cm.methods.items) |info| {
                const proto_assign = try buildPrototypeAssignment(self, info, name_span, span);
                try self.pending_nodes.append(self.allocator, proto_assign);
            }

            // --- getter/setter → Object.defineProperty ---
            if (cm.accessors.items.len > 0) {
                try emitAccessors(self, cm.accessors.items, name_span, span);
            }

            // --- static fields → ClassName.field = value ---
            for (cm.static_fields.items) |field| {
                const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
                const static_assign = try buildFieldAssign(self, class_ref, field.key, field.init, span);
                try self.pending_nodes.append(self.allocator, static_assign);
            }

            // --- static block body → class 뒤에 emit ---
            for (cm.static_block_stmts.items) |sb_stmt| {
                try self.pending_nodes.append(self.allocator, sb_stmt);
            }

            // --- experimentalDecorators: __decorateClass 호출 생성 ---
            if (self.options.experimental_decorators) {
                try emitDecoratorsForLoweredClass(self, node, body_idx, name_span);
            }

            return .none;
        }

        /// class_expression을 IIFE로 변환.
        ///
        /// const Foo = class Bar { method() {} }
        /// → const Foo = (function() { function Bar() {} Bar.prototype.method = ...; return Bar; })()
        ///
        /// 메서드/static이 없으면 단순 function expression으로 변환.
        pub fn lowerClassExpression(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const super_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 2]);

            // 클래스 이름
            const new_name = try self.visitNode(name_idx);
            const name_span = if (!new_name.isNone())
                self.new_ast.getNode(new_name).data.string_ref
            else
                try self.new_ast.addString("_Class");

            const name_node = if (!new_name.isNone())
                new_name
            else
                try es_helpers.makeBindingIdentifier(self, name_span);

            // super class
            const has_super = !super_idx.isNone();
            var super_span: ?Span = null;
            if (has_super) {
                const super_node = self.old_ast.getNode(super_idx);
                if (super_node.tag == .identifier_reference or super_node.tag == .binding_identifier) {
                    super_span = super_node.data.string_ref;
                }
            }

            const saved_super = self.current_super_class;
            self.current_super_class = super_span;
            defer self.current_super_class = saved_super;

            // 바디 멤버 분류
            var cm = try classifyMembers(self, body_idx, span);
            defer cm.deinit(self.allocator);

            // private field 매핑 설정
            const saved_private_fields = self.current_private_fields;
            if (cm.private_fields.items.len > 0) {
                var mappings = try self.allocator.alloc(Transformer.PrivateFieldMapping, cm.private_fields.items.len);
                for (cm.private_fields.items, 0..) |pf, i| {
                    mappings[i] = .{ .original_name = pf.original_name, .var_name = pf.name };
                }
                self.current_private_fields = mappings;
            }
            defer {
                if (cm.private_fields.items.len > 0) {
                    self.allocator.free(self.current_private_fields);
                }
                self.current_private_fields = saved_private_fields;
            }

            // private field 초기화 → constructor body에 삽입
            for (cm.private_fields.items) |pf| {
                const init_stmt = try buildPrivateFieldInit(self, pf.name, pf.init, span);
                try cm.instance_fields.append(self.allocator, init_stmt);
            }

            // constructor → function declaration
            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, name_node, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, name_node, super_span.?, span)
            else
                try buildEmptyFunction(self, name_node, span);

            if (cm.instance_fields.items.len > 0) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }

            // 메서드/static/extends/private가 없으면 단순 function expression으로 변환
            const has_extra = cm.methods.items.len > 0 or cm.static_fields.items.len > 0 or
                cm.accessors.items.len > 0 or cm.private_fields.items.len > 0 or
                cm.static_block_stmts.items.len > 0 or (has_super and super_span != null);

            if (!has_extra) {
                const func = self.new_ast.getNode(func_node);
                return self.new_ast.addNode(.{
                    .tag = .function_expression,
                    .span = func.span,
                    .data = func.data,
                });
            }

            // IIFE: (function() { var _x = new WeakMap(); function Foo() {} ...; return Foo; })()
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // WeakMap 선언 (IIFE 안에 배치)
            for (cm.private_fields.items) |pf| {
                const wm_decl = try buildWeakMapDecl(self, pf.name, span);
                try self.scratch.append(self.allocator, wm_decl);
            }

            try self.scratch.append(self.allocator, func_node);

            if (has_super and super_span != null) {
                const extends_call = try buildExtendsCall(self, name_span, super_span.?, span);
                try self.scratch.append(self.allocator, extends_call);
                self.runtime_helpers.extends = true;
            }

            for (cm.methods.items) |info| {
                const proto_assign = try buildPrototypeAssignment(self, info, name_span, span);
                try self.scratch.append(self.allocator, proto_assign);
            }

            const pending_top = self.pending_nodes.items.len;
            if (cm.accessors.items.len > 0) {
                try emitAccessors(self, cm.accessors.items, name_span, span);
            }
            // pending_nodes에서 scratch로 이동
            for (self.pending_nodes.items[pending_top..]) |p| {
                try self.scratch.append(self.allocator, p);
            }
            self.pending_nodes.shrinkRetainingCapacity(pending_top);

            // 5. static fields
            for (cm.static_fields.items) |field| {
                const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
                const static_assign = try buildFieldAssign(self, class_ref, field.key, field.init, span);
                try self.scratch.append(self.allocator, static_assign);
            }

            // 6. static block body
            for (cm.static_block_stmts.items) |sb_stmt| {
                try self.scratch.append(self.allocator, sb_stmt);
            }

            // 7. return ClassName;
            const return_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
            const return_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = return_ref, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, return_stmt);

            // IIFE body
            const body_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const iife_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // wrapper function expression: function() { ... }
            const none = @intFromEnum(NodeIndex.none);
            const empty_params = try self.new_ast.addNodeList(&.{});
            const wrapper_extra = try self.new_ast.addExtras(&.{
                none, // anonymous
                empty_params.start,
                empty_params.len,
                @intFromEnum(iife_body),
                0, // flags
                none, // return_type
            });
            const wrapper_fn = try self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = wrapper_extra },
            });

            // (function() { ... })() — call expression
            const paren = try self.new_ast.addNode(.{
                .tag = .parenthesized_expression,
                .span = span,
                .data = .{ .unary = .{ .operand = wrapper_fn, .flags = 0 } },
            });
            return es_helpers.makeCallExpr(self, paren, &.{}, span);
        }

        // ================================================================
        // super() / super.method() 변환
        // ================================================================

        /// call_expression의 callee가 super_expression인지 확인.
        pub fn isSuperCall(self: *Transformer, node: Node) bool {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            if (callee.isNone()) return false;
            return self.old_ast.getNode(callee).tag == .super_expression;
        }

        /// super(args) → Parent.call(this, args)
        /// call_expression: extra = [callee, args_start, args_len, flags]
        pub fn lowerSuperCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const args_start = extras[e + 1];
            const args_len = extras[e + 2];
            const span = node.span;

            // Parent.call
            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const callee = try es_helpers.makeStaticMember(self, parent_ref, call_prop, span);

            // args: [this, ...original_args]
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, this_node);

            // 원래 인자들을 visit하여 추가
            const old_args = self.old_ast.extra_data.items[args_start .. args_start + args_len];
            for (old_args) |raw_idx| {
                const new_arg = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_arg.isNone()) {
                    try self.scratch.append(self.allocator, new_arg);
                }
            }

            const new_args = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(callee), new_args.start, new_args.len, 0,
            });
            return self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// call_expression의 callee가 super.method (static_member_expression + super) 인지 확인.
        pub fn isSuperMethodCall(self: *Transformer, node: Node) bool {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            if (callee.isNone()) return false;
            const callee_node = self.old_ast.getNode(callee);
            if (callee_node.tag != .static_member_expression) return false;
            const me = callee_node.data.extra;
            if (me >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[me]);
            if (obj.isNone()) return false;
            return self.old_ast.getNode(obj).tag == .super_expression;
        }

        /// super.method(args) → Parent.prototype.method.call(this, args)
        pub fn lowerSuperMethodCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const callee_idx: NodeIndex = @enumFromInt(extras[e]);
            const args_start = extras[e + 1];
            const args_len = extras[e + 2];
            const span = node.span;

            // callee = super.method → 메서드 이름 추출
            const callee_node = self.old_ast.getNode(callee_idx);
            const callee_extras = self.old_ast.extra_data.items;
            const ce = callee_node.data.extra;
            const method_prop_idx: NodeIndex = @enumFromInt(callee_extras[ce + 1]);

            // Parent.prototype.method
            const proto_member = try buildPrototypeRef(self, super_class_span, span);

            const new_method_prop = try self.visitNode(method_prop_idx);
            const method_member = try es_helpers.makeStaticMember(self, proto_member, new_method_prop, span);

            // Parent.prototype.method.call
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const call_callee = try es_helpers.makeStaticMember(self, method_member, call_prop, span);

            // args: [this, ...original_args]
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            try self.scratch.append(self.allocator, this_node);
            const old_args = self.old_ast.extra_data.items[args_start .. args_start + args_len];
            for (old_args) |raw_idx| {
                const new_arg = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_arg.isNone()) {
                    try self.scratch.append(self.allocator, new_arg);
                }
            }

            const new_args = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(call_callee), new_args.start, new_args.len, 0,
            });
            return self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// static_member_expression의 object가 super_expression인지 확인.
        pub fn isSuperMember(self: *Transformer, node: Node) bool {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[e]);
            if (obj.isNone()) return false;
            return self.old_ast.getNode(obj).tag == .super_expression;
        }

        /// super.method → Parent.prototype.method
        /// static_member_expression: extra = [object, property, flags]
        pub fn lowerSuperMember(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitMemberExpression(node);
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const prop_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const span = node.span;

            // Parent.prototype
            const proto_member = try buildPrototypeRef(self, super_class_span, span);

            // Parent.prototype.method
            const new_prop = try self.visitNode(prop_idx);
            return es_helpers.makeStaticMember(self, proto_member, new_prop, span);
        }

        // ================================================================
        // 내부 헬퍼
        // ================================================================

        /// this.#x → _x.get(this).
        pub fn lowerPrivateFieldGet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const all_extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e >= all_extras.len) return null;
            const var_name = findPrivateFieldVarName(self, @enumFromInt(all_extras[e + 1])) orelse return null;
            return buildWeakMapCall(self, var_name, "get", @enumFromInt(all_extras[e]), &.{}, node.span);
        }

        /// this.#x = v → _x.set(this, v).
        pub fn lowerPrivateFieldSet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const left_node = self.old_ast.getNode(node.data.binary.left);
            const all_extras = self.old_ast.extra_data.items;
            const le = left_node.data.extra;
            if (le >= all_extras.len) return null;
            const var_name = findPrivateFieldVarName(self, @enumFromInt(all_extras[le + 1])) orelse return null;
            return buildWeakMapCall(self, var_name, "set", @enumFromInt(all_extras[le]), &.{node.data.binary.right}, node.span);
        }

        /// this.#x++ → _x.set(this, _x.get(this) + 1)
        /// this.#x-- → _x.set(this, _x.get(this) - 1)
        pub fn lowerPrivateFieldUpdate(self: *Transformer, operand: Node, op_flags: u32, span: Span) ?Transformer.Error!NodeIndex {
            const all_extras = self.old_ast.extra_data.items;
            const oe = operand.data.extra;
            if (oe + 1 >= all_extras.len) return null;
            const obj_idx: NodeIndex = @enumFromInt(all_extras[oe]);
            const var_name = findPrivateFieldVarName(self, @enumFromInt(all_extras[oe + 1])) orelse return null;

            // _x.get(this)
            const get_call = try buildWeakMapCall(self, var_name, "get", obj_idx, &.{}, span);

            const op_kind = op_flags & 0xFF;
            const is_increment = (op_kind == @intFromEnum(token_mod.Kind.plus2));
            const bin_op: u16 = if (is_increment) @intFromEnum(token_mod.Kind.plus) else @intFromEnum(token_mod.Kind.minus);

            // _x.get(this) + 1 or - 1
            const one = try es_helpers.makeNumericLiteral(self, 1);
            const add_node = try self.new_ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = get_call, .right = one, .flags = bin_op } },
            });

            // _x.set(this, add_node) — buildWeakMapCall 미사용: add_node가 이미 new_ast 노드라
            // visitNode를 거치면 안 됨. obj_idx는 this이므로 이중 visit 안전.
            const wm_ref = try es_helpers.makeIdentifierRef(self, var_name);
            const set_prop = try es_helpers.makeIdentifierRef(self, "set");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, set_prop, span);
            const new_obj = try self.visitNode(obj_idx);
            return es_helpers.makeCallExpr(self, callee, &.{ new_obj, add_node }, span);
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

        /// private field property에서 매핑된 WeakMap 변수 이름을 찾음.
        fn findPrivateFieldVarName(self: *const Transformer, prop_idx: NodeIndex) ?[]const u8 {
            if (prop_idx.isNone()) return null;
            const prop_node = self.old_ast.getNode(prop_idx);
            if (prop_node.tag != .private_identifier) return null;
            const orig = self.old_ast.source[prop_node.span.start..prop_node.span.end];
            for (self.current_private_fields) |pf| {
                if (std.mem.eql(u8, pf.original_name, orig)) return pf.var_name;
            }
            return null;
        }

        /// accessor method_definition에서 function expression 생성.
        fn buildAccessorFunc(self: *Transformer, member_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const member = self.old_ast.getNode(member_idx);
            const method_extras = self.old_ast.extra_data.items;
            const me = member.data.extra;
            const params_start = method_extras[me + 1];
            const params_len = method_extras[me + 2];
            const body_idx: NodeIndex = @enumFromInt(method_extras[me + 3]);

            const new_params = try self.visitExtraList(params_start, params_len);
            const new_body = try visitMethodBody(self, body_idx, span);

            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                none,                   new_params.start, new_params.len,
                @intFromEnum(new_body), 0,                none,
            });
            return self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// 두 key 노드의 소스 텍스트가 같은지 확인.
        fn keysMatch(self: *const Transformer, a: NodeIndex, b: NodeIndex) bool {
            if (a.isNone() or b.isNone()) return false;
            const na = self.old_ast.getNode(a);
            const nb = self.old_ast.getNode(b);
            const ta = self.old_ast.source[na.span.start..na.span.end];
            const tb = self.old_ast.source[nb.span.start..nb.span.end];
            return std.mem.eql(u8, ta, tb);
        }

        /// ClassName.prototype static_member_expression 생성.
        fn buildPrototypeRef(self: *Transformer, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
            const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, class_name_span);
            const proto_prop = try es_helpers.makeIdentifierRef(self, "prototype");
            return es_helpers.makeStaticMember(self, class_ref, proto_prop, span);
        }

        const MethodInfo = struct {
            member_idx: NodeIndex,
            is_static: bool,
        };

        const FieldInfo = struct {
            key: NodeIndex,
            init: NodeIndex,
        };

        const AccessorInfo = struct {
            member_idx: NodeIndex,
            is_static: bool,
            is_getter: bool,
        };

        const PrivateFieldInfo = struct {
            name: []const u8, // "#x" → "_x" 변환된 이름
            original_name: []const u8, // "#x" 원본 이름 (매칭용)
            init: NodeIndex, // 초기값 (none이면 undefined)
        };

        /// 클래스 바디 멤버를 분류: constructor, methods, instance_fields, static_fields, accessors, private_fields.
        const ClassifiedMembers = struct {
            constructor_idx: ?NodeIndex,
            methods: std.ArrayList(MethodInfo),
            instance_fields: std.ArrayList(NodeIndex),
            static_fields: std.ArrayList(FieldInfo),
            accessors: std.ArrayList(AccessorInfo),
            private_fields: std.ArrayList(PrivateFieldInfo),
            static_block_stmts: std.ArrayList(NodeIndex),

            fn deinit(cm: *ClassifiedMembers, allocator: std.mem.Allocator) void {
                for (cm.private_fields.items) |pf| {
                    allocator.free(pf.name);
                }
                cm.methods.deinit(allocator);
                cm.instance_fields.deinit(allocator);
                cm.static_fields.deinit(allocator);
                cm.accessors.deinit(allocator);
                cm.private_fields.deinit(allocator);
                cm.static_block_stmts.deinit(allocator);
            }
        };

        fn classifyMembers(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!ClassifiedMembers {
            const extras = self.old_ast.extra_data.items;
            const body_node = self.old_ast.getNode(body_idx);
            const members = extras[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];

            var cm = ClassifiedMembers{
                .constructor_idx = null,
                .methods = .empty,
                .instance_fields = .empty,
                .static_fields = .empty,
                .accessors = .empty,
                .private_fields = .empty,
                .static_block_stmts = .empty,
            };

            for (members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const key: NodeIndex = @enumFromInt(extras[me]);
                    const flags = extras[me + 4];
                    const is_static = (flags & 0x01) != 0;
                    const kind = (flags >> 1) & 0x03; // 0=method, 1=get, 2=set

                    if (!is_static and isConstructorKey(self, key)) {
                        cm.constructor_idx = @enumFromInt(raw_idx);
                        continue;
                    }

                    if (kind == 1 or kind == 2) {
                        try cm.accessors.append(self.allocator, .{
                            .member_idx = @enumFromInt(raw_idx),
                            .is_static = is_static,
                            .is_getter = kind == 1,
                        });
                    } else {
                        try cm.methods.append(self.allocator, .{
                            .member_idx = @enumFromInt(raw_idx),
                            .is_static = is_static,
                        });
                    }
                } else if (member.tag == .property_definition) {
                    const pe = member.data.extra;
                    const key: NodeIndex = @enumFromInt(extras[pe]);
                    const init_val: NodeIndex = @enumFromInt(extras[pe + 1]);
                    const flags = extras[pe + 2];
                    const is_static = (flags & 0x01) != 0;

                    // private field (#x) → WeakMap 기반 변환
                    const key_node = self.old_ast.getNode(key);
                    if (key_node.tag == .private_identifier) {
                        const orig_name = self.old_ast.source[key_node.span.start..key_node.span.end]; // "#x"
                        // "#x" → "_x"
                        var name_buf: [128]u8 = undefined;
                        name_buf[0] = '_';
                        const name_rest = orig_name[1..]; // "x" (# 제거)
                        @memcpy(name_buf[1 .. 1 + name_rest.len], name_rest);
                        const var_name = name_buf[0 .. 1 + name_rest.len];

                        try cm.private_fields.append(self.allocator, .{
                            .name = try self.allocator.dupe(u8, var_name),
                            .original_name = orig_name,
                            .init = init_val,
                        });
                        continue;
                    }

                    if (is_static and !init_val.isNone()) {
                        try cm.static_fields.append(self.allocator, .{ .key = key, .init = init_val });
                    } else if (!is_static and !init_val.isNone()) {
                        const this_node = try self.new_ast.addNode(.{
                            .tag = .this_expression,
                            .span = span,
                            .data = .{ .none = 0 },
                        });
                        const field_stmt = try buildFieldAssign(self, this_node, key, init_val, span);
                        try cm.instance_fields.append(self.allocator, field_stmt);
                    }
                } else if (member.tag == .static_block) {
                    // static block body의 문들을 class 뒤에 emit
                    const sb_body_idx = member.data.unary.operand;
                    if (!sb_body_idx.isNone()) {
                        const sb_body = self.old_ast.getNode(sb_body_idx);
                        if (sb_body.tag == .block_statement) {
                            const sb_stmts = self.old_ast.extra_data.items[sb_body.data.list.start .. sb_body.data.list.start + sb_body.data.list.len];
                            for (sb_stmts) |sb_raw| {
                                const new_stmt = try self.visitNode(@enumFromInt(sb_raw));
                                if (!new_stmt.isNone()) {
                                    try cm.static_block_stmts.append(self.allocator, new_stmt);
                                }
                            }
                        }
                    }
                }
            }

            return cm;
        }

        /// var _x = new WeakMap(); 선언 생성.
        fn buildWeakMapDecl(self: *Transformer, name: []const u8, span: Span) Transformer.Error!NodeIndex {
            // new WeakMap()
            const wm_ref = try es_helpers.makeIdentifierRef(self, "WeakMap");
            const empty_args = try self.new_ast.addNodeList(&.{});
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(wm_ref), empty_args.start, empty_args.len, 0,
            });
            const new_expr = try self.new_ast.addNode(.{
                .tag = .new_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });

            return self.buildVarDecl(name, new_expr, span);
        }

        /// _x.set(this, init) expression_statement 생성.
        fn buildPrivateFieldInit(self: *Transformer, name: []const u8, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const wm_ref = try es_helpers.makeIdentifierRef(self, name);
            const set_prop = try es_helpers.makeIdentifierRef(self, "set");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, set_prop, span);
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const new_init = if (!init_idx.isNone()) try self.visitNode(init_idx) else try es_helpers.makeVoidZero(self, span);
            const call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, new_init }, span);

            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// obj.key = init expression_statement 생성.
        /// instance field: obj = this, static field: obj = ClassName identifier.
        fn buildFieldAssign(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const new_key = try self.visitNode(key_idx);
            const member = try es_helpers.makeStaticMember(self, obj, new_key, span);
            const new_init = try self.visitNode(init_idx);
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member, .right = new_init, .flags = 0 } },
            });
            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// function_declaration의 body 앞에 문들을 삽입
        fn prependToFunctionBody(self: *Transformer, func_idx: NodeIndex, stmts: []const NodeIndex) Transformer.Error!NodeIndex {
            const func = self.new_ast.getNode(func_idx);
            const fe = func.data.extra;

            // extra_data 슬라이스는 prependStatementsToBody 호출 시 재할당될 수 있으므로
            // 필요한 값을 미리 로컬에 복사
            const saved_name = self.new_ast.extra_data.items[fe];
            const saved_params_start = self.new_ast.extra_data.items[fe + 1];
            const saved_params_len = self.new_ast.extra_data.items[fe + 2];
            const saved_flags = self.new_ast.extra_data.items[fe + 4];
            const body_idx: NodeIndex = @enumFromInt(self.new_ast.extra_data.items[fe + 3]);

            const new_body = try self.prependStatementsToBody(body_idx, stmts);

            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.new_ast.addExtras(&.{
                saved_name,
                saved_params_start,
                saved_params_len,
                @intFromEnum(new_body),
                saved_flags,
                none,
            });
            return self.new_ast.addNode(.{
                .tag = func.tag,
                .span = func.span,
                .data = .{ .extra = new_extra },
            });
        }

        /// constructor인지 확인 (key가 "constructor" identifier)
        fn isConstructorKey(self: *const Transformer, key_idx: NodeIndex) bool {
            if (key_idx.isNone()) return false;
            const key = self.old_ast.getNode(key_idx);
            if (key.tag != .identifier_reference and key.tag != .binding_identifier) return false;
            const text = self.old_ast.source[key.data.string_ref.start..key.data.string_ref.end];
            return std.mem.eql(u8, text, "constructor");
        }

        /// constructor method_definition에서 function_declaration 생성.
        /// method_definition: extra = [key, params_start, params_len, body, flags, ...]
        fn buildFunctionFromConstructor(self: *Transformer, ctor_idx: NodeIndex, name: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const ctor = self.old_ast.getNode(ctor_idx);
            const ctor_extras = self.old_ast.extra_data.items;
            const me = ctor.data.extra;

            const params_start = ctor_extras[me + 1];
            const params_len = ctor_extras[me + 2];
            const body_idx: NodeIndex = @enumFromInt(ctor_extras[me + 3]);

            const new_params = try self.visitExtraList(params_start, params_len);
            const new_body = try visitMethodBody(self, body_idx, span);

            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(name),
                new_params.start,
                new_params.len,
                @intFromEnum(new_body),
                0, // flags (no async/generator)
                none, // return_type
            });
            return self.new_ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// 빈 function declaration (constructor가 없는 경우)
        fn buildEmptyFunction(self: *Transformer, name: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // 빈 body
            const empty_list = try self.new_ast.addNodeList(&.{});
            const empty_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = empty_list },
            });

            const empty_params = try self.new_ast.addNodeList(&.{});
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(name),
                empty_params.start,
                empty_params.len,
                @intFromEnum(empty_body),
                0,
                none,
            });
            return self.new_ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// extends가 있고 constructor가 없을 때 기본 constructor 생성:
        /// function Child() { return Parent.apply(this, arguments) || this; }
        fn buildDefaultSuperConstructor(self: *Transformer, name: NodeIndex, super_class_span: Span, span: Span) Transformer.Error!NodeIndex {
            // Parent.apply(this, arguments)
            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
            const apply_prop = try es_helpers.makeIdentifierRef(self, "apply");
            const callee = try es_helpers.makeStaticMember(self, parent_ref, apply_prop, span);

            // args: [this, arguments]
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const args_ref = try es_helpers.makeIdentifierRef(self, "arguments");
            const apply_call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, args_ref }, span);

            // Parent.apply(this, arguments) || this
            const this2 = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const or_expr = try self.new_ast.addNode(.{
                .tag = .logical_expression,
                .span = span,
                .data = .{ .binary = .{ .left = apply_call, .right = this2, .flags = @intFromEnum(token_mod.Kind.pipe2) } },
            });

            // return Parent.apply(this, arguments) || this;
            const ret_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = or_expr, .flags = 0 } },
            });

            const body_list = try self.new_ast.addNodeList(&.{ret_stmt});
            const body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            const empty_params = try self.new_ast.addNodeList(&.{});
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(name),
                empty_params.start,
                empty_params.len,
                @intFromEnum(body),
                0,
                none,
            });
            return self.new_ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// __extends(Child, Parent) expression_statement 생성.
        fn buildExtendsCall(self: *Transformer, child_span: Span, parent_span: Span, span: Span) Transformer.Error!NodeIndex {
            const extends_ref = try es_helpers.makeIdentifierRef(self, "__extends");
            const child_ref = try es_helpers.makeIdentifierRefFromSpan(self, child_span);
            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, parent_span);
            const call = try es_helpers.makeCallExpr(self, extends_ref, &.{ child_ref, parent_ref }, span);

            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// 메서드 body를 방문하면서 arrow this/arguments 캡처를 관리.
        /// visitFunction과 동일한 save/restore/prepend 로직.
        fn visitMethodBody(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // arrow this state save/restore (일반 함수는 자체 this 바인딩)
            const saved_arrow_depth = self.arrow_this_depth;
            const saved_needs_this = self.needs_this_var;
            const saved_needs_args = self.needs_arguments_var;
            self.arrow_this_depth = 0;
            self.needs_this_var = false;
            self.needs_arguments_var = false;

            var new_body = try self.visitNode(body_idx);

            // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
            if (self.options.target.needsES2015() and !new_body.isNone() and
                (self.needs_this_var or self.needs_arguments_var))
            {
                var capture_stmts: [2]NodeIndex = undefined;
                var capture_count: usize = 0;

                if (self.needs_this_var) {
                    const this_init = try self.new_ast.addNode(.{
                        .tag = .this_expression,
                        .span = span,
                        .data = .{ .none = 0 },
                    });
                    capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, span);
                    capture_count += 1;
                }
                if (self.needs_arguments_var) {
                    const args_span = try self.new_ast.addString("arguments");
                    const args_init = try self.new_ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = args_span,
                        .data = .{ .string_ref = args_span },
                    });
                    capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, span);
                    capture_count += 1;
                }

                new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
            }

            self.arrow_this_depth = saved_arrow_depth;
            self.needs_this_var = saved_needs_this;
            self.needs_arguments_var = saved_needs_args;

            return new_body;
        }

        /// method → ClassName.prototype.method = function() {} (expression_statement)
        /// static method → ClassName.method = function() {}
        fn buildPrototypeAssignment(self: *Transformer, info: MethodInfo, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
            const member = self.old_ast.getNode(info.member_idx);
            const method_extras = self.old_ast.extra_data.items;
            const me = member.data.extra;

            const key_idx: NodeIndex = @enumFromInt(method_extras[me]);
            const params_start = method_extras[me + 1];
            const params_len = method_extras[me + 2];
            const body_idx: NodeIndex = @enumFromInt(method_extras[me + 3]);
            const flags = method_extras[me + 4];

            // function expression 생성
            const new_params = try self.visitExtraList(params_start, params_len);
            const new_body = try visitMethodBody(self, body_idx, span);

            const func_flags: u32 = blk: {
                var f: u32 = 0;
                if (flags & 0x08 != 0) f |= 0x01; // async
                if (flags & 0x10 != 0) f |= 0x02; // generator
                break :blk f;
            };

            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                none, // anonymous
                new_params.start,
                new_params.len,
                @intFromEnum(new_body),
                func_flags,
                none,
            });
            const func_expr = try self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // ClassName 또는 ClassName.prototype
            const target = if (info.is_static)
                try es_helpers.makeIdentifierRefFromSpan(self, class_name_span)
            else
                try buildPrototypeRef(self, class_name_span, span);

            // target.methodName
            const new_key = try self.visitNode(key_idx);
            const member_access = try es_helpers.makeStaticMember(self, target, new_key, span);

            // target.methodName = function() {}
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member_access, .right = func_expr, .flags = 0 } },
            });

            // expression_statement
            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// getter/setter → Object.defineProperty(target, "prop", { get/set: function() {} })
        fn emitAccessors(self: *Transformer, items: []const AccessorInfo, class_name_span: Span, span: Span) Transformer.Error!void {
            const obj_str_span = try self.new_ast.addString("Object");
            const dp_str_span = try self.new_ast.addString("defineProperty");

            // 처리 완료된 accessor 추적 (비인접 getter/setter 쌍 지원)
            var used = try self.allocator.alloc(bool, items.len);
            defer self.allocator.free(used);
            @memset(used, false);

            for (items, 0..) |info, i| {
                if (used[i]) continue;
                used[i] = true;

                const member = self.old_ast.getNode(info.member_idx);
                const method_extras = self.old_ast.extra_data.items;
                const me = member.data.extra;
                const key_idx: NodeIndex = @enumFromInt(method_extras[me]);

                const func_expr = try buildAccessorFunc(self, info.member_idx, span);
                const accessor_key = try es_helpers.makeIdentifierRef(self, if (info.is_getter) "get" else "set");
                const prop1 = try self.new_ast.addNode(.{
                    .tag = .object_property,
                    .span = span,
                    .data = .{ .binary = .{ .left = accessor_key, .right = func_expr, .flags = 0 } },
                });

                // 전체 리스트에서 같은 key의 짝(getter↔setter) 찾기
                var paired_prop: ?NodeIndex = null;
                for (items[i + 1 ..], i + 1..) |next, j| {
                    if (used[j]) continue;
                    const next_member = self.old_ast.getNode(next.member_idx);
                    const next_me = next_member.data.extra;
                    const next_key: NodeIndex = @enumFromInt(method_extras[next_me]);
                    if (info.is_static == next.is_static and info.is_getter != next.is_getter and
                        keysMatch(self, key_idx, next_key))
                    {
                        used[j] = true;
                        const pair_func = try buildAccessorFunc(self, next.member_idx, span);
                        const pair_key = try es_helpers.makeIdentifierRef(self, if (next.is_getter) "get" else "set");
                        paired_prop = try self.new_ast.addNode(.{
                            .tag = .object_property,
                            .span = span,
                            .data = .{ .binary = .{ .left = pair_key, .right = pair_func, .flags = 0 } },
                        });
                        break;
                    }
                }

                // descriptor object: { get: fn, set: fn } 또는 { get: fn }
                const obj_list = if (paired_prop) |pp|
                    try self.new_ast.addNodeList(&.{ prop1, pp })
                else
                    try self.new_ast.addNodeList(&.{prop1});
                const desc_obj = try self.new_ast.addNode(.{
                    .tag = .object_expression,
                    .span = span,
                    .data = .{ .list = obj_list },
                });

                // target
                const target = if (info.is_static)
                    try es_helpers.makeIdentifierRefFromSpan(self, class_name_span)
                else
                    try buildPrototypeRef(self, class_name_span, span);

                // key string literal
                const old_key_node = self.old_ast.getNode(key_idx);
                const key_text = self.old_ast.source[old_key_node.span.start..old_key_node.span.end];
                var quoted_buf: [256]u8 = undefined;
                quoted_buf[0] = '"';
                @memcpy(quoted_buf[1 .. 1 + key_text.len], key_text);
                quoted_buf[1 + key_text.len] = '"';
                const key_str_span = try self.new_ast.addString(quoted_buf[0 .. key_text.len + 2]);
                const key_str = try self.new_ast.addNode(.{
                    .tag = .string_literal,
                    .span = key_str_span,
                    .data = .{ .string_ref = key_str_span },
                });

                // Object.defineProperty(target, "key", descriptor)
                const obj_ref = try es_helpers.makeIdentifierRefFromSpan(self, obj_str_span);
                const dp_prop = try es_helpers.makeIdentifierRefFromSpan(self, dp_str_span);
                const dp_callee = try es_helpers.makeStaticMember(self, obj_ref, dp_prop, span);
                const call = try es_helpers.makeCallExpr(self, dp_callee, &.{ target, key_str, desc_obj }, span);
                const stmt = try self.new_ast.addNode(.{
                    .tag = .expression_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call, .flags = 0 } },
                });
                try self.pending_nodes.append(self.allocator, stmt);
            }
        }
        /// ES2015 lowering된 class에 experimentalDecorators 처리를 추가.
        /// class → function+prototype 변환 후, member/class/param decorator를 __decorateClass 호출로 emit.
        fn emitDecoratorsForLoweredClass(
            self: *Transformer,
            node: Node,
            body_idx: NodeIndex,
            name_span: Span,
        ) Transformer.Error!void {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;

            // class decorator: extra offset 6, 7
            const old_deco_start = extras[e + 6];
            const old_deco_len = extras[e + 7];

            // body 멤버를 순회하여 member decorator + constructor param decorator 수집
            const body_node = self.old_ast.getNode(body_idx);
            const members = extras[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];

            var member_decos: std.ArrayList(Transformer.MemberDecoratorInfo) = .empty;
            defer {
                for (member_decos.items) |md| self.allocator.free(md.decorators);
                member_decos.deinit(self.allocator);
            }

            var ctor_param_decos: std.ArrayList(NodeIndex) = .empty;
            defer ctor_param_decos.deinit(self.allocator);

            for (members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const flags = extras[me + 4];
                    const is_static = (flags & 0x01) != 0;
                    const key: NodeIndex = @enumFromInt(extras[me]);

                    if (!is_static and isConstructorKey(self, key)) {
                        // constructor param decorator
                        const params_start = extras[me + 1];
                        const params_len = extras[me + 2];
                        try self.collectParamDecorators(&ctor_param_decos, params_start, params_len);
                        continue;
                    }

                    // method decorator + param decorator
                    const deco_start = extras[me + 5];
                    const deco_len = extras[me + 6];
                    const params_start = extras[me + 1];
                    const params_len = extras[me + 2];
                    if (deco_len > 0 or params_len > 0) {
                        const new_key = try self.visitNode(key);
                        try self.collectMemberDecorators(
                            &member_decos,
                            deco_start,
                            deco_len,
                            params_start,
                            params_len,
                            new_key,
                            is_static,
                            1,
                        );
                    }
                } else if (member.tag == .property_definition) {
                    // property decorator
                    const me = member.data.extra;
                    const flags = extras[me + 2];
                    const is_static = (flags & 0x01) != 0;
                    const deco_start = extras[me + 3];
                    const deco_len = extras[me + 4];
                    if (deco_len > 0) {
                        const new_key = try self.visitNode(@enumFromInt(extras[me]));
                        try self.collectMemberDecorators(
                            &member_decos,
                            deco_start,
                            deco_len,
                            0,
                            0,
                            new_key,
                            is_static,
                            2,
                        );
                    }
                }
            }

            // decorator가 없으면 아무것도 안 함
            if (old_deco_len == 0 and member_decos.items.len == 0 and ctor_param_decos.items.len == 0) return;

            const decorate_span = try self.new_ast.addString("__decorateClass");

            // member decorator 호출: __decorateClass([dec], Foo.prototype, "name", kind)
            for (member_decos.items) |md| {
                const call_stmt = try self.buildDecorateClassMemberCall(decorate_span, name_span, md);
                try self.pending_nodes.append(self.allocator, call_stmt);
            }

            // class + constructor param decorator 호출: Foo = __decorateClass([...], Foo)
            if (old_deco_len > 0 or ctor_param_decos.items.len > 0) {
                const class_deco_stmt = try self.buildDecorateClassCall(
                    decorate_span,
                    name_span,
                    old_deco_start,
                    old_deco_len,
                    ctor_param_decos.items,
                );
                try self.pending_nodes.append(self.allocator, class_deco_stmt);
            }
        }
    };
}

test "ES2015 class module compiles" {
    _ = ES2015Class;
}
