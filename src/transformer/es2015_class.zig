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
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const super_idx: NodeIndex = self.readNodeIdx(e, 1);
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);

            // 클래스 이름 추출
            const new_name = try self.visitNode(name_idx);
            const name_span = if (!new_name.isNone())
                self.ast.getNode(new_name).data.string_ref
            else
                try self.ast.addString("_Class");

            // super class 처리
            const has_super = !super_idx.isNone();
            var super_span: ?Span = null;
            var super_expr_node: NodeIndex = .none; // 표현식 super class 저장용
            if (has_super) {
                const super_node = self.ast.getNode(super_idx);
                if (super_node.tag == .identifier_reference or super_node.tag == .binding_identifier) {
                    // 단순 식별자: IIFE 매개변수 _super로 전달.
                    // 원래 이름을 직접 사용하면 번들러에서 동일 이름의 다른 변수를 참조할 수 있으므로
                    // (예: EventEmitter가 eventemitter3과 react-native 양쪽에 존재),
                    // 항상 _super 매개변수를 통해 스코프를 격리한다.
                    super_expr_node = try self.makeIdentifierRefWithSymbol(super_node.data.string_ref, super_idx);
                    super_span = try self.ast.addString("_super");
                } else {
                    // 표현식 (e.g. React.Component, eventTargetShim.EventTarget):
                    // visit하여 new AST 노드로 변환, IIFE 매개변수 _super로 전달.
                    super_expr_node = try self.visitNode(super_idx);
                    super_span = try self.ast.addString("_super");
                }
            }

            // super class context 설정 (constructor/method body 방문 시 사용)
            const saved_super = self.current_super_class;
            const saved_super_old_idx = self.current_super_class_old_idx;
            self.current_super_class = super_span;
            self.current_super_class_old_idx = super_idx;
            defer self.current_super_class = saved_super;
            defer self.current_super_class_old_idx = saved_super_old_idx;

            // 클래스 바디 멤버 분류
            var cm = try classifyMembers(self, body_idx, span);
            defer cm.deinit(self.allocator);

            const saved_private_fields = self.current_private_fields;
            const total_private = try setupPrivateFieldMappings(self, &cm, name_span);
            defer {
                if (total_private > 0) self.allocator.free(self.current_private_fields);
                self.current_private_fields = saved_private_fields;
            }

            const saved_private_methods = self.current_private_methods;
            if (cm.private_methods.items.len > 0) {
                self.current_private_methods = cm.private_methods.items;
            }
            defer self.current_private_methods = saved_private_methods;

            // --- IIFE 패턴 ---
            // class X extends P { ... }
            // → var X = (function(_super) { __extends(X, _super); function X() {...} return X; })(P)
            // IIFE 내부의 모든 참조는 symbol 연결 없는 fresh identifier (linker 리네이밍 영향 없음).
            // parent class는 IIFE 매개변수로 전달하여 스코프 격리.

            const orig_name_text = self.ast.getText(name_span);
            // IIFE 내부용 fresh binding (symbol 없음 — linker가 리네이밍 불가)
            const fresh_name_span = try self.ast.addString(orig_name_text);
            const fresh_name = try es_helpers.makeBindingIdentifier(self, fresh_name_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // instance private field → WeakMap 선언
            for (cm.private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakMap", pf.name, span));
            }
            // static private field → descriptor 객체 선언: var _x = { writable: true, value: initValue }
            for (cm.static_private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildStaticPrivateFieldDescriptor(self, pf.name, pf.init, span));
                self.runtime_helpers.class_static_private_field = true;
            }
            for (cm.private_methods.items) |pm| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakSet", pm.weakset_name, span));
                try self.scratch.append(self.allocator, try es_helpers.buildStandaloneFunc(self, pm.func_name, pm.member_idx, span));
            }

            try appendPrivateFieldInits(self, &cm, span);
            for (cm.private_methods.items) |pm| {
                try cm.instance_fields.append(self.allocator, try es_helpers.buildPrivateMethodInit(self, pm.weakset_name, span));
            }

            // IIFE 내부 function (fresh identifier — linker 무관)
            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, fresh_name, cm.instance_fields.items, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, fresh_name, super_span.?, cm.instance_fields.items, span)
            else
                try buildEmptyFunction(self, fresh_name, span);

            // 순서: __classCallCheck → var _this = this → fields → 원래 constructor body
            // prependToFunctionBody는 앞에 삽입하므로 역순으로 호출.

            // 3. instance fields prepend (가장 마지막에 호출 → classCallCheck/this_decl 뒤에 위치)
            if (cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }
            // 2. var _this = this; (field에 arrow this 캡처가 있는 경우)
            if (cm.fields_need_this_alias and cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                const this_decl = try self.buildVarDecl("_this", try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                }), span);
                func_node = try prependToFunctionBody(self, func_node, &.{this_decl});
            }
            // 1. __classCallCheck(this, ClassName) — constructor body 맨 앞
            {
                const check_id = try es_helpers.makeIdentifierRef(self, "__classCallCheck");
                const this_expr = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
                const class_ref = try es_helpers.makeIdentifierRef(self, orig_name_text);
                const call = try es_helpers.makeCallExpr(self, check_id, &.{ this_expr, class_ref }, span);
                func_node = try prependToFunctionBody(self, func_node, &.{try es_helpers.makeExprStmt(self, call, span)});
                self.runtime_helpers.class_call_check = true;
            }

            try self.scratch.append(self.allocator, func_node);

            // __extends(ClassName, _super) — parent는 IIFE 매개변수 _super
            const super_param_text = "_super";
            if (has_super and super_span != null) {
                const child_ref = try es_helpers.makeIdentifierRef(self, orig_name_text);
                const parent_ref = try es_helpers.makeIdentifierRef(self, super_param_text);
                const extends_ref = try es_helpers.makeIdentifierRef(self, "__extends");
                const extends_call_expr = try es_helpers.makeCallExpr(self, extends_ref, &.{ child_ref, parent_ref }, span);
                try self.scratch.append(self.allocator, try es_helpers.makeExprStmt(self, extends_call_expr, span));
                self.runtime_helpers.extends = true;
            }

            // prototype assignment — 문자열 기반 참조 (linker 무관)
            for (cm.methods.items) |info| {
                try self.scratch.append(self.allocator, try buildPrototypeAssignment(self, info, fresh_name_span, span));
            }

            const pending_top = self.pending_nodes.items.len;
            if (cm.accessors.items.len > 0) {
                try emitAccessors(self, cm.accessors.items, fresh_name_span, span);
            }
            for (self.pending_nodes.items[pending_top..]) |p| {
                try self.scratch.append(self.allocator, p);
            }
            self.pending_nodes.shrinkRetainingCapacity(pending_top);

            // return ClassName;
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try es_helpers.makeIdentifierRef(self, orig_name_text), .flags = 0 } },
            }));

            // IIFE body
            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const iife_body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = body_list } });

            // function(_super) { ... } 또는 function() { ... }
            const none = @intFromEnum(NodeIndex.none);
            const wrapper_params = if (has_super and super_span != null) blk: {
                const param_binding = try es_helpers.makeBindingIdentifier(self, try self.ast.addString(super_param_text));
                break :blk try self.ast.addNodeList(&.{param_binding});
            } else try self.ast.addNodeList(&.{});
            const wrapper_params_node = try self.ast.addFormalParameters(wrapper_params, span);
            // function_expression: [name(0), params(1), body(2), flags(3), ret_type(4)]
            const wrapper_extra = try self.ast.addExtras(&.{
                none,                    @intFromEnum(wrapper_params_node),
                @intFromEnum(iife_body), 0,
                none,
            });
            const wrapper_fn = try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{ .extra = wrapper_extra } });
            const paren = try es_helpers.makeParenExpr(self, wrapper_fn, span);

            // (function(_super) { ... })(ParentClass) 또는 (function() { ... })()
            const iife_call = if (has_super and super_span != null) blk: {
                const parent_arg = if (!super_expr_node.isNone())
                    super_expr_node // 표현식: 이미 visit된 AST 노드 (e.g. React.Component)
                else
                    try self.makeIdentifierRefWithSymbol(super_span.?, super_idx); // 식별자
                break :blk try es_helpers.makeCallExpr(self, paren, &.{parent_arg}, span);
            } else try es_helpers.makeCallExpr(self, paren, &.{}, span);

            // var ClassName = IIFE;
            const declarator = try es_helpers.makeDeclarator(self, new_name, iife_call, span);
            const var_decl = try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
            try self.pending_nodes.append(self.allocator, var_decl);

            // static fields → IIFE 밖 (init에서 ClassName 자기참조 시 이미 할당된 상태)
            for (cm.static_fields.items) |field| {
                const class_ref = try self.makeIdentifierRefWithSymbol(name_span, name_idx);
                const static_assign = try buildFieldAssign(self, class_ref, field.key, field.init, span);
                try self.pending_nodes.append(self.allocator, static_assign);
            }
            for (cm.static_block_stmts.items) |sb_stmt| {
                try self.pending_nodes.append(self.allocator, sb_stmt);
            }

            // experimentalDecorators
            if (self.options.experimental_decorators) {
                try emitDecoratorsForLoweredClass(self, node, body_idx, name_span, name_idx);
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
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = self.readNodeIdx(e, 0);
            const super_idx: NodeIndex = self.readNodeIdx(e, 1);
            const body_idx: NodeIndex = self.readNodeIdx(e, 2);

            // 클래스 이름
            const new_name = try self.visitNode(name_idx);
            const name_span = if (!new_name.isNone())
                self.ast.getNode(new_name).data.string_ref
            else
                try self.ast.addString("_Class");

            const name_node = if (!new_name.isNone())
                new_name
            else
                try es_helpers.makeBindingIdentifier(self, name_span);

            // super class
            const has_super = !super_idx.isNone();
            var super_span: ?Span = null;
            var expr_super_node: NodeIndex = .none;
            if (has_super) {
                const super_node = self.ast.getNode(super_idx);
                if (super_node.tag == .identifier_reference or super_node.tag == .binding_identifier) {
                    // 단순 식별자도 IIFE 매개변수 _super로 전달 (스코프 격리)
                    expr_super_node = try self.makeIdentifierRefWithSymbol(super_node.data.string_ref, super_idx);
                    super_span = try self.ast.addString("_super");
                } else {
                    expr_super_node = try self.visitNode(super_idx);
                    super_span = try self.ast.addString("_super");
                }
            }

            const saved_super = self.current_super_class;
            const saved_super_old_idx = self.current_super_class_old_idx;
            self.current_super_class = super_span;
            self.current_super_class_old_idx = super_idx;
            defer self.current_super_class = saved_super;
            defer self.current_super_class_old_idx = saved_super_old_idx;

            // 바디 멤버 분류
            var cm = try classifyMembers(self, body_idx, span);
            defer cm.deinit(self.allocator);

            const saved_private_fields = self.current_private_fields;
            const total_private_ce = try setupPrivateFieldMappings(self, &cm, name_span);
            defer {
                if (total_private_ce > 0) self.allocator.free(self.current_private_fields);
                self.current_private_fields = saved_private_fields;
            }

            // private method 매핑 설정
            const saved_private_methods = self.current_private_methods;
            if (cm.private_methods.items.len > 0) {
                self.current_private_methods = cm.private_methods.items;
            }
            defer self.current_private_methods = saved_private_methods;

            try appendPrivateFieldInits(self, &cm, span);

            // private method 초기화 → constructor body에 삽입
            for (cm.private_methods.items) |pm| {
                const init_stmt = try es_helpers.buildPrivateMethodInit(self, pm.weakset_name, span);
                try cm.instance_fields.append(self.allocator, init_stmt);
            }

            // has_extra를 먼저 계산하여 func_node를 올바른 이름으로 한 번만 빌드
            const has_extra = cm.methods.items.len > 0 or cm.static_fields.items.len > 0 or
                cm.accessors.items.len > 0 or cm.private_fields.items.len > 0 or
                cm.static_private_fields.items.len > 0 or cm.private_methods.items.len > 0 or
                cm.static_block_stmts.items.len > 0 or (has_super and super_span != null);

            // IIFE 경로면 fresh identifier (symbol 없음), 단순 경로면 원본 name_node
            const ce_name_text = self.ast.getText(name_span);
            const func_name = if (has_extra) try es_helpers.makeBindingIdentifier(self, try self.ast.addString(ce_name_text)) else name_node;

            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, func_name, cm.instance_fields.items, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, func_name, super_span.?, cm.instance_fields.items, span)
            else
                try buildEmptyFunction(self, func_name, span);

            // 순서: __classCallCheck → var _this = this → fields → body (역순 prepend)
            if (cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }
            if (cm.fields_need_this_alias and cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                const this_decl = try self.buildVarDecl("_this", try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                }), span);
                func_node = try prependToFunctionBody(self, func_node, &.{this_decl});
            }
            {
                const check_id = try es_helpers.makeIdentifierRef(self, "__classCallCheck");
                const this_expr = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
                const class_ref = try es_helpers.makeIdentifierRef(self, ce_name_text);
                const call = try es_helpers.makeCallExpr(self, check_id, &.{ this_expr, class_ref }, span);
                func_node = try prependToFunctionBody(self, func_node, &.{try es_helpers.makeExprStmt(self, call, span)});
                self.runtime_helpers.class_call_check = true;
            }

            if (!has_extra) {
                const func = self.ast.getNode(func_node);
                return self.ast.addNode(.{
                    .tag = .function_expression,
                    .span = func.span,
                    .data = func.data,
                });
            }

            // IIFE (lowerClassDeclaration과 동일 패턴)
            const expr_name_text = self.ast.getText(name_span);
            const expr_fresh_span = try self.ast.addString(expr_name_text);
            const expr_fresh_name = try es_helpers.makeBindingIdentifier(self, expr_fresh_span);
            const expr_super_param = "_super";

            // func_node를 fresh name으로 재생성 (symbol 연결 없음)
            func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, expr_fresh_name, cm.instance_fields.items, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, expr_fresh_name, super_span.?, cm.instance_fields.items, span)
            else
                try buildEmptyFunction(self, expr_fresh_name, span);

            if (cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }
            // classCallCheck
            {
                const check_id = try es_helpers.makeIdentifierRef(self, "__classCallCheck");
                const this_expr = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
                const class_ref = try es_helpers.makeIdentifierRef(self, expr_name_text);
                const call = try es_helpers.makeCallExpr(self, check_id, &.{ this_expr, class_ref }, span);
                func_node = try prependToFunctionBody(self, func_node, &.{try es_helpers.makeExprStmt(self, call, span)});
                self.runtime_helpers.class_call_check = true;
            }

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            for (cm.private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakMap", pf.name, span));
            }
            // static private field → descriptor 객체 선언
            for (cm.static_private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildStaticPrivateFieldDescriptor(self, pf.name, pf.init, span));
                self.runtime_helpers.class_static_private_field = true;
            }
            for (cm.private_methods.items) |pm| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakSet", pm.weakset_name, span));
                try self.scratch.append(self.allocator, try es_helpers.buildStandaloneFunc(self, pm.func_name, pm.member_idx, span));
            }

            try self.scratch.append(self.allocator, func_node);

            // __extends(ClassName, _super) — parent는 IIFE 매개변수
            if (has_super and super_span != null) {
                const child_ref = try es_helpers.makeIdentifierRef(self, expr_name_text);
                const parent_ref = try es_helpers.makeIdentifierRef(self, expr_super_param);
                const extends_ref = try es_helpers.makeIdentifierRef(self, "__extends");
                try self.scratch.append(self.allocator, try es_helpers.makeExprStmt(self, try es_helpers.makeCallExpr(self, extends_ref, &.{ child_ref, parent_ref }, span), span));
                self.runtime_helpers.extends = true;
            }

            for (cm.methods.items) |info| {
                try self.scratch.append(self.allocator, try buildPrototypeAssignment(self, info, expr_fresh_span, span));
            }

            const pending_top = self.pending_nodes.items.len;
            defer self.pending_nodes.shrinkRetainingCapacity(pending_top);
            if (cm.accessors.items.len > 0) {
                try emitAccessors(self, cm.accessors.items, expr_fresh_span, span);
            }
            try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);

            for (cm.static_fields.items) |field| {
                try self.scratch.append(self.allocator, try buildFieldAssign(self, try es_helpers.makeIdentifierRef(self, expr_name_text), field.key, field.init, span));
            }
            for (cm.static_block_stmts.items) |sb_stmt| {
                try self.scratch.append(self.allocator, sb_stmt);
            }

            // return ClassName;
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try es_helpers.makeIdentifierRef(self, expr_name_text), .flags = 0 } },
            }));

            // IIFE body
            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const iife_body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = body_list } });

            // function(_super) { ... } 또는 function() { ... }
            const none = @intFromEnum(NodeIndex.none);
            const wrapper_params = if (has_super and super_span != null) blk: {
                break :blk try self.ast.addNodeList(&.{try es_helpers.makeBindingIdentifier(self, try self.ast.addString(expr_super_param))});
            } else try self.ast.addNodeList(&.{});
            const wrapper_params_node2 = try self.ast.addFormalParameters(wrapper_params, span);
            const wrapper_extra = try self.ast.addExtras(&.{ none, @intFromEnum(wrapper_params_node2), @intFromEnum(iife_body), 0, none });
            const wrapper_fn = try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{ .extra = wrapper_extra } });
            const paren = try es_helpers.makeParenExpr(self, wrapper_fn, span);

            // (function(_super) { ... })(ParentClass) 또는 (function() { ... })()
            return if (has_super and super_span != null) blk: {
                const parent_arg = if (!expr_super_node.isNone())
                    expr_super_node
                else
                    try self.makeIdentifierRefWithSymbol(super_span.?, super_idx);
                break :blk try es_helpers.makeCallExpr(self, paren, &.{parent_arg}, span);
            } else es_helpers.makeCallExpr(self, paren, &.{}, span);
        }

        // ================================================================
        // super() / super.method() 변환
        // ================================================================

        /// call_expression의 callee가 super_expression인지 확인.
        pub fn isSuperCall(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            if (callee.isNone()) return false;
            return self.ast.getNode(callee).tag == .super_expression;
        }

        /// super(args) → __callSuper(this, _super, [args])
        /// Reflect.construct를 사용하여 네이티브 클래스 extends도 지원.
        /// super() 호출 후 this → _this 별칭을 활성화하여
        /// __callSuper가 반환하는 새 객체를 올바르게 참조.
        /// call_expression: extra = [callee, args_start, args_len, flags]
        pub fn lowerSuperCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const e = node.data.extra;
            const args_start = self.readU32(e, 1);
            const args_len = self.readU32(e, 2);
            const span = node.span;

            const callee = try es_helpers.makeIdentifierRef(self, "__callSuper");

            const this_node = try makeThisOrAlias(self, span);

            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
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

            const call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, parent_ref, args_array }, span);

            // _this = __callSuper(this, _super, [args])
            // 대입식으로 반환하여 super()가 if/else 등 어디에 있든 동작.
            // var _this 선언과 return _this는 postProcessSuperCallBody에서 추가.
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = this_ref, .right = call, .flags = 0 } },
            });

            self.super_call_this_alias = true;
            self.runtime_helpers.call_super = true;

            return assign;
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
            if (obj.isNone()) return false;
            return self.ast.getNode(obj).tag == .super_expression;
        }

        /// super.method(args) → Parent.prototype.method.call(this, args)
        pub fn lowerSuperMethodCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const e = node.data.extra;
            const callee_idx: NodeIndex = self.readNodeIdx(e, 0);
            const args_start = self.readU32(e, 1);
            const args_len = self.readU32(e, 2);
            const span = node.span;

            // callee = super.method → 메서드 이름 추출
            const callee_node = self.ast.getNode(callee_idx);
            const ce = callee_node.data.extra;
            const method_prop_idx: NodeIndex = self.readNodeIdx(ce, 1);

            // Parent.prototype.method
            const proto_member = try buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);

            const new_method_prop = try self.visitNode(method_prop_idx);
            const method_member = try es_helpers.makeStaticMember(self, proto_member, new_method_prop, span);

            // Parent.prototype.method.call
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const call_callee = try es_helpers.makeStaticMember(self, method_member, call_prop, span);

            // args: [this, ...original_args]
            const this_node = try makeThisOrAlias(self, span);

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
            if (obj.isNone()) return false;
            return self.ast.getNode(obj).tag == .super_expression;
        }

        /// super.method → Parent.prototype.method
        /// static_member_expression: extra = [object, property, flags]
        pub fn lowerSuperMember(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitMemberExpression(node);
            const e = node.data.extra;
            const prop_idx: NodeIndex = self.readNodeIdx(e, 1);
            const span = node.span;

            // Parent.prototype
            const proto_member = try buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);

            // Parent.prototype.method
            const new_prop = try self.visitNode(prop_idx);
            return es_helpers.makeStaticMember(self, proto_member, new_prop, span);
        }

        /// computed_member_expression의 object가 super_expression인지 확인.
        /// super["prop"] 형태를 감지한다.
        pub fn isSuperComputedMember(self: *Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const obj: NodeIndex = @enumFromInt(extras[e]);
            if (obj.isNone()) return false;
            return self.ast.getNode(obj).tag == .super_expression;
        }

        /// super["prop"] → Parent.prototype["prop"]
        pub fn lowerSuperComputedMember(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitMemberExpression(node);
            const e = node.data.extra;
            const prop_idx: NodeIndex = self.readNodeIdx(e, 1);
            const span = node.span;
            const proto_member = try buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);
            const new_prop = try self.visitNode(prop_idx);
            return es_helpers.makeComputedMember(self, proto_member, new_prop, span);
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
            if (obj.isNone()) return false;
            return self.ast.getNode(obj).tag == .super_expression;
        }

        /// super["method"](args) → Parent.prototype["method"].call(this, args)
        pub fn lowerSuperComputedMethodCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const e = node.data.extra;
            const callee_idx: NodeIndex = self.readNodeIdx(e, 0);
            const args_start = self.readU32(e, 1);
            const args_len = self.readU32(e, 2);
            const span = node.span;

            const callee_node = self.ast.getNode(callee_idx);
            const ce = callee_node.data.extra;
            const method_prop_idx: NodeIndex = self.readNodeIdx(ce, 1);

            const proto_member = try buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);
            const new_method_prop = try self.visitNode(method_prop_idx);
            const method_member = try es_helpers.makeComputedMember(self, proto_member, new_method_prop, span);

            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const call_callee = try es_helpers.makeStaticMember(self, method_member, call_prop, span);

            const this_node = try makeThisOrAlias(self, span);

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

        /// this.#x → instance: _x.get(this), static: __classStaticPrivateFieldSpecGet(receiver, ClassName, _x)
        pub fn lowerPrivateFieldGet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const e = node.data.extra;
            if (e >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(e, 0);
            const mapping = findPrivateFieldMapping(self, self.readNodeIdx(e, 1)) orelse return null;
            if (mapping.is_static) {
                return buildStaticPrivateFieldGet(self, mapping, obj_idx, node.span);
            }
            return buildWeakMapCall(self, mapping.var_name, "get", obj_idx, &.{}, node.span);
        }

        /// compound assignment(+=, -=, *=, ... >>>=)을 base binary op으로 매핑.
        /// 순수 대입(=) / 논리 대입(??=, ||=, &&=)은 null.
        /// 논리 대입은 es2021 lowering에서 먼저 처리되거나 별도 이슈로 남김.
        fn compoundAssignBaseOp(op_flags: u16) ?u16 {
            const op: token_mod.Kind = @enumFromInt(op_flags);
            return switch (op) {
                .plus_eq => @intFromEnum(token_mod.Kind.plus),
                .minus_eq => @intFromEnum(token_mod.Kind.minus),
                .star_eq => @intFromEnum(token_mod.Kind.star),
                .slash_eq => @intFromEnum(token_mod.Kind.slash),
                .percent_eq => @intFromEnum(token_mod.Kind.percent),
                .star2_eq => @intFromEnum(token_mod.Kind.star2),
                .amp_eq => @intFromEnum(token_mod.Kind.amp),
                .pipe_eq => @intFromEnum(token_mod.Kind.pipe),
                .caret_eq => @intFromEnum(token_mod.Kind.caret),
                .shift_left_eq => @intFromEnum(token_mod.Kind.shift_left),
                .shift_right_eq => @intFromEnum(token_mod.Kind.shift_right),
                .shift_right3_eq => @intFromEnum(token_mod.Kind.shift_right3),
                else => null,
            };
        }

        /// instance/static 분기해서 private field get 호출을 구성.
        fn buildPrivateFieldGetCall(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (mapping.is_static) return buildStaticPrivateFieldGet(self, mapping, obj_idx, span);
            return buildWeakMapCall(self, mapping.var_name, "get", obj_idx, &.{}, span);
        }

        /// private field용 set 호출 생성 — new_value는 이미 완성된(new-AST) 노드여야 함.
        /// obj_idx는 old AST 노드로, 내부에서 visit 수행.
        fn buildPrivateFieldSetWithComputedValue(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, new_value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (mapping.is_static) {
                const helper = try es_helpers.makeIdentifierRef(self, "__classStaticPrivateFieldSpecSet");
                const new_obj = try self.visitNode(obj_idx);
                const class_ref = try es_helpers.makeIdentifierRef(self, mapping.class_name orelse "undefined");
                const desc_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
                self.runtime_helpers.class_static_private_field = true;
                return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref, new_value }, span);
            }
            const wm_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
            const set_prop = try es_helpers.makeIdentifierRef(self, "set");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, set_prop, span);
            const new_obj = try self.visitNode(obj_idx);
            return es_helpers.makeCallExpr(self, callee, &.{ new_obj, new_value }, span);
        }

        /// this.#x = v → instance: _x.set(this, v), static: __classStaticPrivateFieldSpecSet(receiver, ClassName, _x, v)
        /// this.#x += v (및 다른 compound) → set(receiver, get(receiver) <op> v)
        pub fn lowerPrivateFieldSet(self: *Transformer, node: Node) ?Transformer.Error!NodeIndex {
            const left_node = self.ast.getNode(node.data.binary.left);
            const le = left_node.data.extra;
            if (le >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(le, 0);
            const mapping = findPrivateFieldMapping(self, self.readNodeIdx(le, 1)) orelse return null;

            if (compoundAssignBaseOp(node.data.binary.flags)) |bin_op| {
                const get_call = try buildPrivateFieldGetCall(self, mapping, obj_idx, node.span);
                const new_rhs = try self.visitNode(node.data.binary.right);
                const computed = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = node.span,
                    .data = .{ .binary = .{ .left = get_call, .right = new_rhs, .flags = bin_op } },
                });
                return buildPrivateFieldSetWithComputedValue(self, mapping, obj_idx, computed, node.span);
            }

            if (mapping.is_static) {
                return buildStaticPrivateFieldSet(self, mapping, obj_idx, node.data.binary.right, node.span);
            }
            return buildWeakMapCall(self, mapping.var_name, "set", obj_idx, &.{node.data.binary.right}, node.span);
        }

        /// this.#x++ / --  →  _x.set(this, _x.get(this) + 1)  / - 1
        /// static: ClassName.#x++ → __classStaticPrivateFieldSpecSet(ClassName, ClassName, _x, get(...) + 1)
        /// postfix/prefix 동일한 결과(새 값)로 lowering — expression 사용 시 postfix 원래 값 반환 못함.
        /// 현재 instance 경로도 같은 한계이며 #1468 범위 밖이라 동일하게 둠.
        pub fn lowerPrivateFieldUpdate(self: *Transformer, operand: Node, op_flags: u32, span: Span) ?Transformer.Error!NodeIndex {
            const oe = operand.data.extra;
            if (oe + 1 >= self.ast.extra_data.items.len) return null;
            const obj_idx: NodeIndex = self.readNodeIdx(oe, 0);
            const mapping = findPrivateFieldMapping(self, self.readNodeIdx(oe, 1)) orelse return null;

            const op_kind = op_flags & 0xFF;
            const is_increment = (op_kind == @intFromEnum(token_mod.Kind.plus2));
            const bin_op: u16 = if (is_increment) @intFromEnum(token_mod.Kind.plus) else @intFromEnum(token_mod.Kind.minus);

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
            const helper = try es_helpers.makeIdentifierRef(self, "__classStaticPrivateFieldSpecGet");
            const new_obj = try self.visitNode(obj_idx);
            const class_ref = try es_helpers.makeIdentifierRef(self, mapping.class_name orelse "undefined");
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
                if (pf.is_static) {
                    // static: obj === ClassName (class identity 비교)
                    const new_obj = try self.visitNode(right_idx);
                    const class_ref = try es_helpers.makeIdentifierRef(self, pf.class_name orelse "undefined");
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
                return buildWeakMapCall(self, pm.weakset_name, "has", right_idx, &.{}, node.span);
            }

            return null;
        }

        /// static private field set: __classStaticPrivateFieldSpecSet(receiver, ClassName, _descriptor, value)
        fn buildStaticPrivateFieldSet(self: *Transformer, mapping: Transformer.PrivateFieldMapping, obj_idx: NodeIndex, value_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const helper = try es_helpers.makeIdentifierRef(self, "__classStaticPrivateFieldSpecSet");
            const new_obj = try self.visitNode(obj_idx);
            const class_ref = try es_helpers.makeIdentifierRef(self, mapping.class_name orelse "undefined");
            const desc_ref = try es_helpers.makeIdentifierRef(self, mapping.var_name);
            const new_value = try self.visitNode(value_idx);
            self.runtime_helpers.class_static_private_field = true;
            return es_helpers.makeCallExpr(self, helper, &.{ new_obj, class_ref, desc_ref, new_value }, span);
        }

        /// accessor method_definition에서 function expression 생성.
        /// ES2015 params lowering 포함 (setter destructuring/default 등).
        fn buildAccessorFunc(self: *Transformer, member_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const member = self.ast.getNode(member_idx);
            const me = member.data.extra;
            const params_list_old = self.ast.functionParamsList(member);
            const params_start = params_list_old.start;
            const params_len = params_list_old.len;
            const body_idx: NodeIndex = self.readNodeIdx(me, 2);

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

        /// ClassName.prototype static_member_expression 생성.
        /// class_name_old_idx는 OLD AST 노드 — symbol 기반 리네이밍 대상.
        fn buildPrototypeRef(self: *Transformer, class_name_span: Span, class_name_old_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const class_ref = try self.makeIdentifierRefWithSymbol(class_name_span, class_name_old_idx);
            const proto_prop = try es_helpers.makeIdentifierRef(self, "prototype");
            return es_helpers.makeStaticMember(self, class_ref, proto_prop, span);
        }

        /// IIFE 내부용 ClassName.prototype — symbol 전파 없이 span 텍스트만 사용.
        /// fresh identifier를 받으므로 파서 영역 symbol_ids 조회 불가.
        fn buildFreshPrototypeRef(self: *Transformer, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
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

        /// 클래스 바디 멤버를 분류: constructor, methods, instance_fields, static_fields, accessors, private_fields, static_private_fields, private_methods.
        const ClassifiedMembers = struct {
            constructor_idx: ?NodeIndex,
            methods: std.ArrayList(MethodInfo),
            instance_fields: std.ArrayList(NodeIndex),
            static_fields: std.ArrayList(FieldInfo),
            accessors: std.ArrayList(AccessorInfo),
            private_fields: std.ArrayList(PrivateFieldInfo),
            /// static private fields: descriptor 객체 패턴.
            /// instance private fields와 달리 WeakMap이 아닌 { writable: true, value: init } 객체로 변환.
            static_private_fields: std.ArrayList(PrivateFieldInfo),
            private_methods: std.ArrayList(Transformer.PrivateMethodMapping),
            static_block_stmts: std.ArrayList(NodeIndex),
            /// instance field init에 arrow this 캡처가 필요한 경우 true.
            /// super class 없는 class에서 var _this = this; 삽입에 사용.
            fields_need_this_alias: bool = false,

            fn deinit(cm: *ClassifiedMembers, allocator: std.mem.Allocator) void {
                for (cm.private_fields.items) |pf| {
                    allocator.free(pf.name);
                }
                for (cm.static_private_fields.items) |pf| {
                    allocator.free(pf.name);
                }
                for (cm.private_methods.items) |pm| {
                    allocator.free(pm.weakset_name);
                    allocator.free(pm.func_name);
                }
                cm.methods.deinit(allocator);
                cm.instance_fields.deinit(allocator);
                cm.static_fields.deinit(allocator);
                cm.accessors.deinit(allocator);
                cm.private_fields.deinit(allocator);
                cm.static_private_fields.deinit(allocator);
                cm.private_methods.deinit(allocator);
                cm.static_block_stmts.deinit(allocator);
            }
        };

        /// private field init을 빌드하여 instance_fields에 추가.
        /// arrow function의 this 캡처를 감지하여 fields_need_this_alias 설정.
        fn appendPrivateFieldInits(self: *Transformer, cm: *ClassifiedMembers, span: Span) Transformer.Error!void {
            const saved_needs_this = self.needs_this_var;
            for (cm.private_fields.items) |pf| {
                const init_stmt = try buildPrivateFieldInit(self, pf.name, pf.init, span);
                if (self.needs_this_var and !saved_needs_this) {
                    cm.fields_need_this_alias = true;
                }
                self.needs_this_var = saved_needs_this;
                try cm.instance_fields.append(self.allocator, init_stmt);
            }
        }

        /// instance + static private field 매핑을 빌드하여 current_private_fields에 설정.
        /// 반환값: 매핑 총 개수 (defer에서 free 판단용).
        fn setupPrivateFieldMappings(self: *Transformer, cm: *ClassifiedMembers, name_span: Span) Transformer.Error!usize {
            const total = cm.private_fields.items.len + cm.static_private_fields.items.len;
            if (total == 0) return 0;

            var mappings = try self.allocator.alloc(Transformer.PrivateFieldMapping, total);
            for (cm.private_fields.items, 0..) |pf, i| {
                mappings[i] = .{ .original_name = pf.original_name, .var_name = pf.name };
            }
            const class_name = self.ast.getText(name_span);
            for (cm.static_private_fields.items, 0..) |pf, i| {
                mappings[cm.private_fields.items.len + i] = .{
                    .original_name = pf.original_name,
                    .var_name = pf.name,
                    .is_static = true,
                    .class_name = class_name,
                };
            }
            self.current_private_fields = mappings;
            return total;
        }

        fn classifyMembers(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!ClassifiedMembers {
            const body_node = self.ast.getNode(body_idx);
            const members_start = body_node.data.list.start;
            const members_len = body_node.data.list.len;

            var cm = ClassifiedMembers{
                .constructor_idx = null,
                .methods = .empty,
                .instance_fields = .empty,
                .static_fields = .empty,
                .accessors = .empty,
                .private_fields = .empty,
                .static_private_fields = .empty,
                .private_methods = .empty,
                .static_block_stmts = .empty,
            };

            // visitNode/addNode/buildFieldAssign이 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            var m_loop: u32 = 0;
            while (m_loop < members_len) : (m_loop += 1) {
                const raw_idx = self.ast.extra_data.items[members_start + m_loop];
                const member = self.ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const key: NodeIndex = self.readNodeIdx(me, 0);
                    const flags = self.readU32(me, 3);
                    const is_static = (flags & 0x01) != 0;
                    const is_abstract = (flags & 0x20) != 0;
                    const is_declare = (flags & 0x40) != 0;
                    const kind = (flags >> 1) & 0x03; // 0=method, 1=get, 2=set

                    // 본문 없는 메서드 스트리핑: abstract, declare, TS 오버로드 시그니처
                    const method_body: NodeIndex = @enumFromInt(self.readU32(me, 2));
                    if (is_abstract or is_declare or method_body.isNone()) continue;

                    if (!is_static and es_helpers.isConstructorKey(self, key)) {
                        cm.constructor_idx = @enumFromInt(raw_idx);
                        continue;
                    }

                    // private method (#method) → WeakSet + standalone function 분류
                    if (!key.isNone()) {
                        const key_node = self.ast.getNode(key);
                        if (key_node.tag == .private_identifier) {
                            const orig_name = self.ast.getText(key_node.span); // "#bar"

                            const names = try es_helpers.makePrivateMethodNames(self.allocator, orig_name);

                            try cm.private_methods.append(self.allocator, .{
                                .member_idx = @enumFromInt(raw_idx),
                                .original_name = orig_name,
                                .weakset_name = names.ws_name,
                                .func_name = names.fn_name,
                            });
                            continue;
                        }
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
                    const key: NodeIndex = self.readNodeIdx(pe, 0);
                    const init_val: NodeIndex = self.readNodeIdx(pe, 1);
                    const flags = self.readU32(pe, 2);
                    const is_static = (flags & 0x01) != 0;

                    // private field (#x) → instance: WeakMap, static: descriptor 객체
                    const key_node = self.ast.getNode(key);
                    if (key_node.tag == .private_identifier) {
                        const orig_name = self.ast.getText(key_node.span); // "#x"
                        const field_info = PrivateFieldInfo{
                            .name = try es_helpers.makePrivateVarName(self.allocator, orig_name),
                            .original_name = orig_name,
                            .init = init_val,
                        };
                        if (is_static) {
                            try cm.static_private_fields.append(self.allocator, field_info);
                        } else {
                            try cm.private_fields.append(self.allocator, field_info);
                        }
                        continue;
                    }

                    if (is_static and !init_val.isNone()) {
                        try cm.static_fields.append(self.allocator, .{ .key = key, .init = init_val });
                    } else if (!is_static and !init_val.isNone()) {
                        const this_node = try self.ast.addNode(.{
                            .tag = .this_expression,
                            .span = span,
                            .data = .{ .none = 0 },
                        });
                        // field init의 arrow function이 this를 캡처하려면 _this 필요.
                        // super class 있으면 _this = __callSuper(...)로 이미 존재하므로
                        // super_call_this_alias로 모든 this → _this 치환.
                        // super class 없는 경우 arrow body의 this 캡처는
                        // arrow_this_depth > 0 체크(transformer.zig)에서 별도 처리.
                        const saved_field_alias = self.super_call_this_alias;
                        const saved_needs_this = self.needs_this_var;
                        if (self.current_super_class != null) {
                            self.super_call_this_alias = true;
                        }
                        defer self.super_call_this_alias = saved_field_alias;
                        const field_stmt = try buildFieldAssign(self, this_node, key, init_val, span);
                        // arrow → function 변환이 needs_this_var를 설정했으면 기록
                        if (self.needs_this_var and !saved_needs_this) {
                            cm.fields_need_this_alias = true;
                        }
                        self.needs_this_var = saved_needs_this;
                        try cm.instance_fields.append(self.allocator, field_stmt);
                    }
                } else if (member.tag == .static_block) {
                    const sb_body_idx = member.data.unary.operand;
                    if (!sb_body_idx.isNone()) {
                        const sb_body = self.ast.getNode(sb_body_idx);
                        if (sb_body.tag == .block_statement) {
                            const sb_stmts_start = sb_body.data.list.start;
                            const sb_stmts_len = sb_body.data.list.len;
                            var i_loop: u32 = 0;
                            while (i_loop < sb_stmts_len) : (i_loop += 1) {
                                const sb_raw = self.ast.extra_data.items[sb_stmts_start + i_loop];
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

        /// _x.set(this, init) expression_statement 생성.
        fn buildPrivateFieldInit(self: *Transformer, name: []const u8, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const wm_ref = try es_helpers.makeIdentifierRef(self, name);
            const set_prop = try es_helpers.makeIdentifierRef(self, "set");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, set_prop, span);
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const new_init = if (!init_idx.isNone()) try self.visitNode(init_idx) else try es_helpers.makeVoidZero(self, span);
            const call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, new_init }, span);

            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// obj.key = init 또는 obj[computedKey] = init expression_statement 생성.
        /// instance field: obj = this, static field: obj = ClassName identifier.
        fn buildFieldAssign(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const member = try es_helpers.makeMemberFromKeyIdx(self, obj, key_idx, span);
            const new_init = try self.visitNode(init_idx);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member, .right = new_init, .flags = 0 } },
            });
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// function_declaration의 body 앞에 문들을 삽입
        fn prependToFunctionBody(self: *Transformer, func_idx: NodeIndex, stmts: []const NodeIndex) Transformer.Error!NodeIndex {
            const func = self.ast.getNode(func_idx);
            const fe = func.data.extra;

            // extra_data 슬라이스는 prependStatementsToBody 호출 시 재할당될 수 있으므로
            // 필요한 값을 미리 로컬에 복사
            const saved_name = self.ast.extra_data.items[fe];
            const saved_params_idx = self.ast.extra_data.items[fe + 1];
            const saved_flags = self.ast.extra_data.items[fe + 3];
            const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[fe + 2]);

            const new_body = try self.prependStatementsToBody(body_idx, stmts);

            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.ast.addExtras(&.{
                saved_name,
                saved_params_idx,
                @intFromEnum(new_body),
                saved_flags,
                none,
            });
            return self.ast.addNode(.{
                .tag = func.tag,
                .span = func.span,
                .data = .{ .extra = new_extra },
            });
        }

        /// constructor인지 확인 (key가 "constructor" identifier)
        /// constructor method_definition에서 function_declaration 생성.
        /// method_definition: extra = [key, params_start, params_len, body, flags, ...]
        fn buildFunctionFromConstructor(self: *Transformer, ctor_idx: NodeIndex, name: NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const ctor = self.ast.getNode(ctor_idx);
            const me = ctor.data.extra;

            const params_list_old = self.ast.functionParamsList(ctor);
            const body_idx: NodeIndex = self.readNodeIdx(me, 2);

            // super_call_this_alias save/restore (lowerSuperCall이 설정)
            const saved_super_alias = self.super_call_this_alias;
            self.super_call_this_alias = false;
            defer self.super_call_this_alias = saved_super_alias;

            // TS parameter property(`constructor(public x)`)는 modifier 만 strip 되어 일반 형태로 visit 되지만,
            // 이 경로는 visitMethodDefinition 을 거치지 않으므로 `this.x = x` 삽입을 직접 수행해야 함 (#1471).
            const pp = try self.visitParamsCollectProperties(params_list_old);

            // new.target: class constructor → function_named (ES5 class 변환 후 일반 함수)
            const saved_new_target_ctx = self.new_target_ctx;
            if (self.options.unsupported.new_target) {
                self.new_target_ctx = .{ .function_named = self.ast.getNode(name).data.string_ref };
            }
            defer self.new_target_ctx = saved_new_target_ctx;

            var new_body = try visitMethodBody(self, body_idx, span);

            // parameter property 가 있으면 visit된 body 앞에 `this.x = x` 삽입
            if (pp.prop_count > 0 and !new_body.isNone()) {
                new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
            }

            // super() 호출이 있었으면 body 후처리:
            // 1. super() expression_statement → var _this = __callSuper(...)
            // 2. body 끝에 return _this 추가
            if (self.super_call_this_alias) {
                new_body = try postProcessSuperCallBody(self, new_body, instance_fields, span);
            }

            const none = @intFromEnum(NodeIndex.none);
            const new_params_node = try self.ast.addFormalParameters(pp.new_params, span);
            const func_extra = try self.ast.addExtras(&.{
                @intFromEnum(name),
                @intFromEnum(new_params_node),
                @intFromEnum(new_body),
                0, // flags (no async/generator)
                none, // return_type
            });
            return self.ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// super() 호출이 있는 constructor body를 후처리:
        /// 1. body 앞에 var _this; 선언 추가
        /// 2. super() 직후에 instance fields 삽입
        /// 3. 나머지 constructor body
        /// 4. body 끝에 return _this; 추가
        ///
        /// ES6 스펙: class fields는 super() 직후, constructor body 이전에 초기화.
        /// lowerSuperCall이 _this = __callSuper(...) 대입식을 생성하므로,
        /// 해당 대입식을 포함하는 statement를 찾아 그 직후에 fields를 삽입한다.
        fn postProcessSuperCallBody(self: *Transformer, body: NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const body_node = self.ast.getNode(body);
            if (body_node.tag != .block_statement) return body;

            const stmts_list = body_node.data.list;
            // extra_data.items slice를 먼저 캡처하면, buildVarDecl 등이 extra_data를
            // grow시켜 재할당하면 dangling pointer가 됨.
            // 따라서 인덱스만 저장하고, 사용할 때 다시 접근한다.
            const stmts_start = stmts_list.start;
            const stmts_len = stmts_list.len;

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // var _this; (초기화 없는 선언) — extra_data grow 가능
            try self.scratch.append(self.allocator, try self.buildVarDecl("_this", .none, span));

            // super() 호출을 포함하는 statement를 찾는다.
            // lowerSuperCall이 _this = __callSuper(...)로 변환하므로,
            // expression_statement > assignment_expression(LHS=identifier) 패턴을 탐색.
            // if/else 안에 있을 수도 있으므로 재귀 탐색.
            var super_call_end: u32 = stmts_len; // fallback: fields를 body 끝에 배치
            {
                var i: u32 = 0;
                while (i < stmts_len) : (i += 1) {
                    const stmt_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[stmts_start + i]);
                    if (containsSuperCallAssignment(self, stmt_idx)) {
                        super_call_end = i + 1;
                        break;
                    }
                }
            }

            // body stmts: super() 호출까지 (포함)
            for (self.ast.extra_data.items[stmts_start .. stmts_start + super_call_end]) |raw_idx| {
                try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
            }

            // instance fields: super() 직후, constructor body 이전
            for (instance_fields) |field_stmt| {
                try self.scratch.append(self.allocator, try replaceThisWithThisAlias(self, field_stmt, span));
            }

            // body stmts: super() 이후 나머지 constructor body
            for (self.ast.extra_data.items[stmts_start + super_call_end .. stmts_start + stmts_len]) |raw_idx| {
                try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
            }

            // return _this;
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = this_ref, .flags = 0 } },
            }));

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = new_list },
            });
        }

        /// lowerSuperCall이 생성하는 `_this = __callSuper(...)` 대입을 포함하는지 재귀 탐색.
        /// LHS=bare identifier + RHS=call_expression 패턴으로 매칭.
        /// (member expression `_this.x = ...` 과 구분)
        fn containsSuperCallAssignment(self: *Transformer, node_idx: NodeIndex) bool {
            if (node_idx.isNone()) return false;
            const node = self.ast.getNode(node_idx);

            switch (node.tag) {
                .expression_statement => {
                    const expr_idx = node.data.unary.operand;
                    if (expr_idx.isNone()) return false;
                    const expr = self.ast.getNode(expr_idx);
                    if (expr.tag == .assignment_expression) {
                        const left = self.ast.getNode(expr.data.binary.left);
                        if (left.tag != .identifier_reference) return false;
                        const right = self.ast.getNode(expr.data.binary.right);
                        return right.tag == .call_expression;
                    }
                    return false;
                },
                .if_statement, .conditional_expression => {
                    if (containsSuperCallAssignment(self, node.data.ternary.b)) return true;
                    if (containsSuperCallAssignment(self, node.data.ternary.c)) return true;
                    return false;
                },
                .block_statement => {
                    const list = node.data.list;
                    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw_idx| {
                        if (containsSuperCallAssignment(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                else => return false,
            }
        }

        /// 빈 function declaration (constructor가 없는 경우)
        fn buildEmptyFunction(self: *Transformer, name: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // 빈 body
            const empty_list = try self.ast.addNodeList(&.{});
            const empty_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = empty_list },
            });

            const empty_params = try self.ast.addNodeList(&.{});
            const empty_params_node = try self.ast.addFormalParameters(empty_params, span);
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.ast.addExtras(&.{
                @intFromEnum(name),
                @intFromEnum(empty_params_node),
                @intFromEnum(empty_body),
                0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// extends가 있고 constructor가 없을 때 기본 constructor 생성:
        /// instance_fields가 없으면: function Child() { return __callSuper(this, _super, arguments); }
        /// instance_fields가 있으면: function Child() { var _this = __callSuper(this, _super, arguments); <fields on _this>; return _this; }
        fn buildDefaultSuperConstructor(self: *Transformer, name: NodeIndex, super_class_span: Span, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const call_super_ref = try es_helpers.makeIdentifierRef(self, "__callSuper");
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
            const args_ref = try es_helpers.makeIdentifierRef(self, "arguments");
            const call_super = try es_helpers.makeCallExpr(self, call_super_ref, &.{ this_node, parent_ref, args_ref }, span);

            self.runtime_helpers.call_super = true;

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            if (instance_fields.len > 0) {
                // var _this = __callSuper(this, _super, arguments);
                try self.scratch.append(self.allocator, try self.buildVarDecl("_this", call_super, span));

                // instance fields: this → _this 치환된 버전 사용
                // instance_fields는 이미 this.x = ... 형태로 생성되었으므로
                // this_expression을 _this로 교체해야 한다.
                // 현재는 transformer가 this_expression을 직접 생성하므로
                // _this 식별자로 새로 생성한다.
                for (instance_fields) |field_stmt| {
                    try self.scratch.append(self.allocator, try replaceThisWithThisAlias(self, field_stmt, span));
                }

                // return _this;
                const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
                try self.scratch.append(self.allocator, try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = this_ref, .flags = 0 } },
                }));
            } else {
                // return __callSuper(this, _super, arguments);
                try self.scratch.append(self.allocator, try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call_super, .flags = 0 } },
                }));
            }

            const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            const empty_params = try self.ast.addNodeList(&.{});
            const empty_params_node = try self.ast.addFormalParameters(empty_params, span);
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.ast.addExtras(&.{
                @intFromEnum(name),
                @intFromEnum(empty_params_node),
                @intFromEnum(body),
                0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// statement 안의 this_expression을 _this identifier로 교체한 복사본 생성.
        /// instance field init에서 사용: this.x = v → _this.x = v
        fn replaceThisWithThisAlias(self: *Transformer, stmt_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            _ = span;
            const stmt = self.ast.getNode(stmt_idx);
            if (stmt.tag != .expression_statement) return stmt_idx;

            const expr_idx = stmt.data.unary.operand;
            if (expr_idx.isNone()) return stmt_idx;
            const expr = self.ast.getNode(expr_idx);

            // assignment: this.x = v → _this.x = v (값에 this가 있으면 _this로 교체)
            if (expr.tag == .assignment_expression) {
                const left = expr.data.binary.left;
                const right = expr.data.binary.right;
                const new_left = try replaceThisInExpr(self, left);
                const new_right = try replaceThisInExpr(self, right);
                if (@intFromEnum(new_left) == @intFromEnum(left) and @intFromEnum(new_right) == @intFromEnum(right)) return stmt_idx;
                const new_assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = expr.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = expr.data.binary.flags } },
                });
                return self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = stmt.span,
                    .data = .{ .unary = .{ .operand = new_assign, .flags = 0 } },
                });
            }

            // call: __classPrivateMethodInit(this, ...) → __classPrivateMethodInit(_this, ...)
            if (expr.tag == .call_expression) {
                const new_call = try replaceThisInExpr(self, expr_idx);
                if (@intFromEnum(new_call) == @intFromEnum(expr_idx)) return stmt_idx;
                return self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = stmt.span,
                    .data = .{ .unary = .{ .operand = new_call, .flags = 0 } },
                });
            }

            return stmt_idx;
        }

        /// 식 안의 this_expression을 _this로 교체. call_expression(fn, [this, ...]) 패턴도 처리.
        fn replaceThisInExpr(self: *Transformer, idx: NodeIndex) Transformer.Error!NodeIndex {
            if (idx.isNone()) return idx;
            const node = self.ast.getNode(idx);

            if (node.tag == .this_expression) {
                return es_helpers.makeIdentifierRef(self, "_this");
            }

            // static_member_expression: extra = [object, property, flags]
            if (node.tag == .static_member_expression) {
                const e = node.data.extra;
                const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                const new_obj = try replaceThisInExpr(self, obj_idx);
                if (@intFromEnum(new_obj) == @intFromEnum(obj_idx)) return idx;
                const prop = self.ast.extra_data.items[e + 1];
                const flags = self.ast.extra_data.items[e + 2];
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_obj), prop, flags,
                });
                return self.ast.addNode(.{
                    .tag = .static_member_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // call_expression: extra = [callee, args_start, args_len, flags]
            // __classPrivateMethodInit(this, _bark) → __classPrivateMethodInit(_this, _bark)
            if (node.tag == .call_expression) {
                const e = node.data.extra;
                const callee: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                const args_start = self.ast.extra_data.items[e + 1];
                const args_len = self.ast.extra_data.items[e + 2];
                const flags = self.ast.extra_data.items[e + 3];

                // callee와 인자 중 this_expression을 _this로 교체
                const new_callee = try replaceThisInExpr(self, callee);
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                var changed = @intFromEnum(new_callee) != @intFromEnum(callee);
                for (0..args_len) |i| {
                    const raw_arg = self.ast.extra_data.items[args_start + i];
                    const arg_idx: NodeIndex = @enumFromInt(raw_arg);
                    const new_arg = try replaceThisInExpr(self, arg_idx);
                    if (@intFromEnum(new_arg) != @intFromEnum(arg_idx)) changed = true;
                    try self.scratch.append(self.allocator, new_arg);
                }
                if (!changed) return idx;
                const new_args = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_extra = try self.ast.addExtras(&.{
                    @intFromEnum(new_callee), new_args.start, new_args.len, flags,
                });
                return self.ast.addNode(.{
                    .tag = .call_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            return idx;
        }

        /// __extends(Child, Parent) expression_statement 생성.
        /// child_old_idx, parent_old_idx: 원본 AST 노드 인덱스 (symbol_id 전파용).
        fn buildExtendsCall(self: *Transformer, child_span: Span, parent_span: Span, child_old_idx: NodeIndex, parent_old_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const extends_ref = try es_helpers.makeIdentifierRef(self, "__extends");
            const child_ref = try self.makeIdentifierRefWithSymbol(child_span, child_old_idx);
            const parent_ref = try self.makeIdentifierRefWithSymbol(parent_span, parent_old_idx);
            const call = try es_helpers.makeCallExpr(self, extends_ref, &.{ child_ref, parent_ref }, span);

            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// 메서드 body를 방문하면서 arrow this/arguments 캡처를 관리.
        /// visitFunction과 동일한 save/restore/prepend 로직.
        fn visitMethodBody(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return visitMethodBodyWithCtx(self, body_idx, span, null);
        }

        /// visitMethodBody + new.target 컨텍스트 지정
        fn visitMethodBodyWithCtx(self: *Transformer, body_idx: NodeIndex, span: Span, nt_ctx: ?Transformer.NewTargetCtx) Transformer.Error!NodeIndex {
            // arrow this state save/restore (일반 함수는 자체 this 바인딩)
            const saved_arrow_depth = self.arrow_this_depth;
            const saved_needs_this = self.needs_this_var;
            const saved_needs_args = self.needs_arguments_var;
            self.arrow_this_depth = 0;
            self.needs_this_var = false;
            self.needs_arguments_var = false;

            // new.target context
            const saved_nt = self.new_target_ctx;
            if (nt_ctx) |ctx| self.new_target_ctx = ctx;
            defer self.new_target_ctx = saved_nt;

            var new_body = try self.visitNode(body_idx);

            // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
            if (self.options.unsupported.arrow and !new_body.isNone() and
                (self.needs_this_var or self.needs_arguments_var))
            {
                var capture_stmts: [2]NodeIndex = undefined;
                var capture_count: usize = 0;

                if (self.needs_this_var) {
                    const this_init = try self.ast.addNode(.{
                        .tag = .this_expression,
                        .span = span,
                        .data = .{ .none = 0 },
                    });
                    capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, span);
                    capture_count += 1;
                }
                if (self.needs_arguments_var) {
                    const args_span = try self.ast.addString("arguments");
                    const args_init = try self.ast.addNode(.{
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

            const is_async = flags & 0x08 != 0;
            const is_generator = flags & 0x10 != 0;

            // async method + generator 다운레벨링: class lowering이 먼저 실행되어
            // method_definition → function_expression으로 변환되므로,
            // 여기서 직접 async → state machine 변환을 수행해야 함.
            // (ast에 생성된 function_expression은 transformer가 재방문하지 않음)
            if (is_async and self.options.unsupported.async_await) {
                const GenMod = @import("es2015_generator.zig").ES2015Generator(@TypeOf(self.*));

                if (self.options.unsupported.generator) {
                    const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
                    if (!sm_result.body.isNone()) {
                        const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
                        const gen_wrapper = try es_helpers.wrapInFunction(self, gen_call, span);
                        const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper, span);
                        const func_expr = try buildWrappedFunc(self, async_call, sm_result.var_decl, new_params, span);
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
        fn buildWrappedFunc(self: *Transformer, call_expr: NodeIndex, var_decl: NodeIndex, params: ast_mod.NodeList, span: Span) Transformer.Error!NodeIndex {
            const return_stmt = try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call_expr, .flags = 0 } },
            });
            const body_list = if (var_decl.isNone())
                try self.ast.addNodeList(&.{return_stmt})
            else
                try self.ast.addNodeList(&.{ var_decl, return_stmt });
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

        /// target.methodName = func_expr (expression_statement)
        fn buildMethodAssignment(self: *Transformer, info: MethodInfo, class_name_span: Span, key_idx: NodeIndex, func_expr: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const target = if (info.is_static)
                try es_helpers.makeIdentifierRefFromSpan(self, class_name_span)
            else
                try buildFreshPrototypeRef(self, class_name_span, span);
            const member_access = try es_helpers.makeMemberFromKeyIdx(self, target, key_idx, span);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member_access, .right = func_expr, .flags = 0 } },
            });
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// getter/setter → Object.defineProperty(target, "prop", { get/set: function() {} })
        fn emitAccessors(self: *Transformer, items: []const AccessorInfo, class_name_span: Span, span: Span) Transformer.Error!void {
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
                const key_idx = self.readNodeIdx(me, 0);

                const func_expr = try buildAccessorFunc(self, info.member_idx, span);
                const accessor_key = try es_helpers.makeIdentifierRef(self, if (info.is_getter) "get" else "set");
                const prop1 = try self.ast.addNode(.{
                    .tag = .object_property,
                    .span = span,
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
                            .span = span,
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

                // key string literal
                const old_key_node = self.ast.getNode(key_idx);
                const key_text = self.ast.getText(old_key_node.span);
                var quoted_buf: [256]u8 = undefined;
                quoted_buf[0] = '"';
                @memcpy(quoted_buf[1 .. 1 + key_text.len], key_text);
                quoted_buf[1 + key_text.len] = '"';
                const key_str_span = try self.ast.addString(quoted_buf[0 .. key_text.len + 2]);
                const key_str = try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = key_str_span,
                    .data = .{ .string_ref = key_str_span },
                });

                // Object.defineProperty(target, "key", descriptor)
                const obj_ref = try es_helpers.makeIdentifierRefFromSpan(self, obj_str_span);
                const dp_prop = try es_helpers.makeIdentifierRefFromSpan(self, dp_str_span);
                const dp_callee = try es_helpers.makeStaticMember(self, obj_ref, dp_prop, span);
                const call = try es_helpers.makeCallExpr(self, dp_callee, &.{ target, key_str, desc_obj }, span);
                const stmt = try self.ast.addNode(.{
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
            class_name_old_idx: NodeIndex,
        ) Transformer.Error!void {
            const e = node.data.extra;

            // class decorator: extra offset 6, 7
            const old_deco_start = self.readU32(e, 6);
            const old_deco_len = self.readU32(e, 7);

            // body 멤버를 순회하여 member decorator + constructor param decorator 수집
            const body_node = self.ast.getNode(body_idx);
            const members_start = body_node.data.list.start;
            const members_len = body_node.data.list.len;

            var member_decos: std.ArrayList(Transformer.MemberDecoratorInfo) = .empty;
            defer {
                for (member_decos.items) |md| self.allocator.free(md.decorators);
                member_decos.deinit(self.allocator);
            }

            var ctor_param_decos: std.ArrayList(NodeIndex) = .empty;
            defer ctor_param_decos.deinit(self.allocator);

            // visitNode/collectMemberDecorators가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용
            var m_loop: u32 = 0;
            while (m_loop < members_len) : (m_loop += 1) {
                const raw_idx = self.ast.extra_data.items[members_start + m_loop];
                const member = self.ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const flags = self.readU32(me, 3);
                    const is_static = (flags & 0x01) != 0;
                    const key: NodeIndex = self.readNodeIdx(me, 0);
                    const params_list_m = self.ast.functionParamsList(member);

                    if (!is_static and es_helpers.isConstructorKey(self, key)) {
                        // constructor param decorator
                        try self.collectParamDecorators(&ctor_param_decos, params_list_m);
                        continue;
                    }

                    // method decorator + param decorator
                    const deco_start = self.readU32(me, 4);
                    const deco_len = self.readU32(me, 5);
                    if (deco_len > 0 or params_list_m.len > 0) {
                        const new_key = try self.visitNode(key);
                        const empty: NodeList = .{ .start = 0, .len = 0 };
                        try self.collectMemberDecorators(
                            &member_decos,
                            deco_start,
                            deco_len,
                            params_list_m,
                            new_key,
                            is_static,
                            1,
                            empty,
                        );
                    }
                } else if (member.tag == .property_definition) {
                    // property decorator
                    const me = member.data.extra;
                    const flags = self.readU32(me, 2);
                    const is_static = (flags & 0x01) != 0;
                    const deco_start = self.readU32(me, 3);
                    const deco_len = self.readU32(me, 4);
                    if (deco_len > 0) {
                        const key_idx: NodeIndex = self.readNodeIdx(me, 0);
                        const new_key = try self.visitNode(key_idx);
                        const empty: NodeList = .{ .start = 0, .len = 0 };
                        try self.collectMemberDecorators(
                            &member_decos,
                            deco_start,
                            deco_len,
                            empty,
                            new_key,
                            is_static,
                            2,
                            empty,
                        );
                    }
                }
            }

            // decorator가 없으면 아무것도 안 함
            if (old_deco_len == 0 and member_decos.items.len == 0 and ctor_param_decos.items.len == 0) return;

            const decorate_span = try self.ast.addString("__decorateClass");

            // member decorator 호출: __decorateClass([dec], Foo.prototype, "name", kind)
            for (member_decos.items) |md| {
                const call_stmt = try self.buildDecorateClassMemberCall(decorate_span, name_span, class_name_old_idx, md);
                try self.pending_nodes.append(self.allocator, call_stmt);
            }

            // class + constructor param decorator 호출: Foo = __decorateClass([...], Foo)
            if (old_deco_len > 0 or ctor_param_decos.items.len > 0) {
                const class_deco_stmt = try self.buildDecorateClassCall(
                    decorate_span,
                    name_span,
                    class_name_old_idx,
                    old_deco_start,
                    old_deco_len,
                    ctor_param_decos.items,
                    .{ .start = 0, .len = 0 },
                );
                try self.pending_nodes.append(self.allocator, class_deco_stmt);
            }
        }
    };
}

test "ES2015 class module compiles" {
    _ = ES2015Class;
}
