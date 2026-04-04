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
            var super_expr_node: NodeIndex = .none; // 표현식 super class 저장용
            if (has_super) {
                const super_node = self.old_ast.getNode(super_idx);
                if (super_node.tag == .identifier_reference or super_node.tag == .binding_identifier) {
                    // 단순 식별자: IIFE 매개변수 _super로 전달.
                    // 원래 이름을 직접 사용하면 번들러에서 동일 이름의 다른 변수를 참조할 수 있으므로
                    // (예: EventEmitter가 eventemitter3과 react-native 양쪽에 존재),
                    // 항상 _super 매개변수를 통해 스코프를 격리한다.
                    super_expr_node = try self.makeIdentifierRefWithSymbol(super_node.data.string_ref, super_idx);
                    super_span = try self.new_ast.addString("_super");
                } else {
                    // 표현식 (e.g. React.Component, eventTargetShim.EventTarget):
                    // visit하여 new AST 노드로 변환, IIFE 매개변수 _super로 전달.
                    super_expr_node = try self.visitNode(super_idx);
                    super_span = try self.new_ast.addString("_super");
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
            // has_super를 전달하여 field initializer visit 시 this → _this 치환
            var cm = try classifyMembers(self, body_idx, span, has_super and super_span != null);
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

            // private method 매핑 설정 (method body 방문 시 this.#method() → _fn.call(this) 변환)
            const saved_private_methods = self.current_private_methods;
            if (cm.private_methods.items.len > 0) {
                self.current_private_methods = cm.private_methods.items;
            }
            defer self.current_private_methods = saved_private_methods;

            // --- IIFE 패턴 (SWC 호환) ---
            // class X extends P { ... }
            // → var X = (function(_super) { __extends(X, _super); function X() {...} return X; })(P)
            // IIFE 내부의 모든 참조는 symbol 연결 없는 fresh identifier (linker 리네이밍 영향 없음).
            // parent class는 IIFE 매개변수로 전달하여 스코프 격리.

            const orig_name_text = self.new_ast.getText(name_span);
            // IIFE 내부용 fresh binding (symbol 없음 — linker가 리네이밍 불가)
            const fresh_name_span = try self.new_ast.addString(orig_name_text);
            const fresh_name = try es_helpers.makeBindingIdentifier(self, fresh_name_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            for (cm.private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakMap", pf.name, span));
            }
            for (cm.private_methods.items) |pm| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakSet", pm.weakset_name, span));
                try self.scratch.append(self.allocator, try es_helpers.buildStandaloneFunc(self, pm.func_name, pm.member_idx, span));
            }

            for (cm.private_fields.items) |pf| {
                try cm.instance_fields.append(self.allocator, try buildPrivateFieldInit(self, pf.name, pf.init, span));
            }
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

            // instance fields: super가 있으면 __callSuper 이후에 _this로 초기화해야 하므로
            // postProcessSuperCallBody가 처리. super가 없으면 constructor body 앞에 prepend.
            if (cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }
            // __classCallCheck(this, ClassName) — constructor body 맨 앞
            {
                const check_id = try es_helpers.makeIdentifierRef(self, "__classCallCheck");
                const this_expr = try self.new_ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
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
            try self.scratch.append(self.allocator, try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try es_helpers.makeIdentifierRef(self, orig_name_text), .flags = 0 } },
            }));

            // IIFE body
            const body_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const iife_body = try self.new_ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = body_list } });

            // function(_super) { ... } 또는 function() { ... }
            const none = @intFromEnum(NodeIndex.none);
            const wrapper_params = if (has_super and super_span != null) blk: {
                const param_binding = try es_helpers.makeBindingIdentifier(self, try self.new_ast.addString(super_param_text));
                break :blk try self.new_ast.addNodeList(&.{param_binding});
            } else try self.new_ast.addNodeList(&.{});
            const wrapper_extra = try self.new_ast.addExtras(&.{
                none,                    wrapper_params.start, wrapper_params.len,
                @intFromEnum(iife_body), 0,                    none,
            });
            const wrapper_fn = try self.new_ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{ .extra = wrapper_extra } });
            const paren = try self.new_ast.addNode(.{ .tag = .parenthesized_expression, .span = span, .data = .{ .unary = .{ .operand = wrapper_fn, .flags = 0 } } });

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
            const var_decl = try es_helpers.makeVarDeclaration(self, &.{declarator}, 0, span);
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
            var expr_super_node: NodeIndex = .none;
            if (has_super) {
                const super_node = self.old_ast.getNode(super_idx);
                if (super_node.tag == .identifier_reference or super_node.tag == .binding_identifier) {
                    // 단순 식별자도 IIFE 매개변수 _super로 전달 (스코프 격리)
                    expr_super_node = try self.makeIdentifierRefWithSymbol(super_node.data.string_ref, super_idx);
                    super_span = try self.new_ast.addString("_super");
                } else {
                    expr_super_node = try self.visitNode(super_idx);
                    super_span = try self.new_ast.addString("_super");
                }
            }

            const saved_super = self.current_super_class;
            const saved_super_old_idx = self.current_super_class_old_idx;
            self.current_super_class = super_span;
            self.current_super_class_old_idx = super_idx;
            defer self.current_super_class = saved_super;
            defer self.current_super_class_old_idx = saved_super_old_idx;

            // 바디 멤버 분류
            var cm = try classifyMembers(self, body_idx, span, has_super and super_span != null);
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

            // private method 매핑 설정
            const saved_private_methods = self.current_private_methods;
            if (cm.private_methods.items.len > 0) {
                self.current_private_methods = cm.private_methods.items;
            }
            defer self.current_private_methods = saved_private_methods;

            // private field 초기화 → constructor body에 삽입
            for (cm.private_fields.items) |pf| {
                const init_stmt = try buildPrivateFieldInit(self, pf.name, pf.init, span);
                try cm.instance_fields.append(self.allocator, init_stmt);
            }

            // private method 초기화 → constructor body에 삽입
            for (cm.private_methods.items) |pm| {
                const init_stmt = try es_helpers.buildPrivateMethodInit(self, pm.weakset_name, span);
                try cm.instance_fields.append(self.allocator, init_stmt);
            }

            // has_extra를 먼저 계산하여 func_node를 올바른 이름으로 한 번만 빌드
            const has_extra = cm.methods.items.len > 0 or cm.static_fields.items.len > 0 or
                cm.accessors.items.len > 0 or cm.private_fields.items.len > 0 or
                cm.private_methods.items.len > 0 or
                cm.static_block_stmts.items.len > 0 or (has_super and super_span != null);

            // IIFE 경로면 fresh identifier (symbol 없음), 단순 경로면 원본 name_node
            const ce_name_text = self.new_ast.getText(name_span);
            const func_name = if (has_extra) try es_helpers.makeBindingIdentifier(self, try self.new_ast.addString(ce_name_text)) else name_node;

            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, func_name, cm.instance_fields.items, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, func_name, super_span.?, cm.instance_fields.items, span)
            else
                try buildEmptyFunction(self, func_name, span);

            if (cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }
            // __classCallCheck(this, ClassName) — constructor body 맨 앞
            {
                const check_id = try es_helpers.makeIdentifierRef(self, "__classCallCheck");
                const this_expr = try self.new_ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
                const class_ref = try es_helpers.makeIdentifierRef(self, ce_name_text);
                const call = try es_helpers.makeCallExpr(self, check_id, &.{ this_expr, class_ref }, span);
                func_node = try prependToFunctionBody(self, func_node, &.{try es_helpers.makeExprStmt(self, call, span)});
                self.runtime_helpers.class_call_check = true;
            }

            if (!has_extra) {
                const func = self.new_ast.getNode(func_node);
                return self.new_ast.addNode(.{
                    .tag = .function_expression,
                    .span = func.span,
                    .data = func.data,
                });
            }

            // SWC 호환 IIFE (lowerClassDeclaration과 동일 패턴)
            const expr_name_text = self.new_ast.getText(name_span);
            const expr_fresh_span = try self.new_ast.addString(expr_name_text);
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
                const this_expr = try self.new_ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
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
            try self.scratch.append(self.allocator, try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try es_helpers.makeIdentifierRef(self, expr_name_text), .flags = 0 } },
            }));

            // IIFE body
            const body_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const iife_body = try self.new_ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = body_list } });

            // function(_super) { ... } 또는 function() { ... }
            const none = @intFromEnum(NodeIndex.none);
            const wrapper_params = if (has_super and super_span != null) blk: {
                break :blk try self.new_ast.addNodeList(&.{try es_helpers.makeBindingIdentifier(self, try self.new_ast.addString(expr_super_param))});
            } else try self.new_ast.addNodeList(&.{});
            const wrapper_extra = try self.new_ast.addExtras(&.{ none, wrapper_params.start, wrapper_params.len, @intFromEnum(iife_body), 0, none });
            const wrapper_fn = try self.new_ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{ .extra = wrapper_extra } });
            const paren = try self.new_ast.addNode(.{ .tag = .parenthesized_expression, .span = span, .data = .{ .unary = .{ .operand = wrapper_fn, .flags = 0 } } });

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
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e >= extras.len) return false;
            const callee: NodeIndex = @enumFromInt(extras[e]);
            if (callee.isNone()) return false;
            return self.old_ast.getNode(callee).tag == .super_expression;
        }

        /// super(args) → __callSuper(this, _super, [args])
        /// Reflect.construct를 사용하여 네이티브 클래스 extends도 지원.
        /// super() 호출 후 this → _this 별칭을 활성화하여
        /// __callSuper가 반환하는 새 객체를 올바르게 참조.
        /// call_expression: extra = [callee, args_start, args_len, flags]
        pub fn lowerSuperCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const super_class_span = self.current_super_class orelse return self.visitCallExpression(node);
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const args_start = extras[e + 1];
            const args_len = extras[e + 2];
            const span = node.span;

            const callee = try es_helpers.makeIdentifierRef(self, "__callSuper");

            // super() 이전이므로 원래 this 사용 — 아직 alias 활성화 전
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });

            const parent_ref = try es_helpers.makeIdentifierRefFromSpan(self, super_class_span);
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            const old_args = self.old_ast.extra_data.items[args_start .. args_start + args_len];
            for (old_args) |raw_idx| {
                const new_arg = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_arg.isNone()) {
                    try self.scratch.append(self.allocator, new_arg);
                }
            }

            const elems = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const args_array = try self.new_ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = elems },
            });

            const call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, parent_ref, args_array }, span);

            // _this = __callSuper(this, _super, [args])
            // 대입식으로 반환하여 super()가 if/else 등 어디에 있든 동작.
            // var _this 선언과 return _this는 postProcessSuperCallBody에서 추가.
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            const assign = try self.new_ast.addNode(.{
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
            const proto_member = try buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);

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
            const proto_member = try buildPrototypeRef(self, super_class_span, self.current_super_class_old_idx, span);

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
        /// class_name_old_idx는 OLD AST 노드 — symbol 기반 리네이밍 대상.
        fn buildPrototypeRef(self: *Transformer, class_name_span: Span, class_name_old_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const class_ref = try self.makeIdentifierRefWithSymbol(class_name_span, class_name_old_idx);
            const proto_prop = try es_helpers.makeIdentifierRef(self, "prototype");
            return es_helpers.makeStaticMember(self, class_ref, proto_prop, span);
        }

        /// IIFE 내부용 ClassName.prototype — symbol 전파 없이 span 텍스트만 사용.
        /// fresh identifier(new AST)를 받으므로 old_symbol_ids 조회 불가.
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

        /// 클래스 바디 멤버를 분류: constructor, methods, instance_fields, static_fields, accessors, private_fields, private_methods.
        const ClassifiedMembers = struct {
            constructor_idx: ?NodeIndex,
            methods: std.ArrayList(MethodInfo),
            instance_fields: std.ArrayList(NodeIndex),
            static_fields: std.ArrayList(FieldInfo),
            accessors: std.ArrayList(AccessorInfo),
            private_fields: std.ArrayList(PrivateFieldInfo),
            private_methods: std.ArrayList(Transformer.PrivateMethodMapping),
            static_block_stmts: std.ArrayList(NodeIndex),

            fn deinit(cm: *ClassifiedMembers, allocator: std.mem.Allocator) void {
                for (cm.private_fields.items) |pf| {
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
                cm.private_methods.deinit(allocator);
                cm.static_block_stmts.deinit(allocator);
            }
        };

        fn classifyMembers(self: *Transformer, body_idx: NodeIndex, span: Span, has_super: bool) Transformer.Error!ClassifiedMembers {
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
                .private_methods = .empty,
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

                    // private method (#method) → WeakSet + standalone function 분류
                    if (!key.isNone()) {
                        const key_node = self.old_ast.getNode(key);
                        if (key_node.tag == .private_identifier) {
                            const orig_name = self.old_ast.source[key_node.span.start..key_node.span.end]; // "#bar"

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
                        // super class가 있으면 field value의 this → _this 치환
                        const saved_field_alias = self.super_call_this_alias;
                        if (has_super) self.super_call_this_alias = true;
                        defer self.super_call_this_alias = saved_field_alias;
                        const field_stmt = try buildFieldAssign(self, this_node, key, init_val, span);
                        try cm.instance_fields.append(self.allocator, field_stmt);
                    }
                } else if (member.tag == .static_block) {
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

        /// obj.key = init 또는 obj[computedKey] = init expression_statement 생성.
        /// instance field: obj = this, static field: obj = ClassName identifier.
        fn buildFieldAssign(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const member = try es_helpers.makeMemberFromKeyIdx(self, obj, key_idx, span);
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
        fn buildFunctionFromConstructor(self: *Transformer, ctor_idx: NodeIndex, name: NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const ctor = self.old_ast.getNode(ctor_idx);
            const ctor_extras = self.old_ast.extra_data.items;
            const me = ctor.data.extra;

            const params_start = ctor_extras[me + 1];
            const params_len = ctor_extras[me + 2];
            const body_idx: NodeIndex = @enumFromInt(ctor_extras[me + 3]);

            // super_call_this_alias save/restore (lowerSuperCall이 설정)
            const saved_super_alias = self.super_call_this_alias;
            self.super_call_this_alias = false;
            defer self.super_call_this_alias = saved_super_alias;

            const new_params = try self.visitExtraList(params_start, params_len);
            var new_body = try visitMethodBody(self, body_idx, span);

            // super() 호출이 있었으면 body 후처리:
            // 1. super() expression_statement → var _this = __callSuper(...)
            // 2. body 끝에 return _this 추가
            if (self.super_call_this_alias) {
                new_body = try postProcessSuperCallBody(self, new_body, instance_fields, span);
            }

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

        /// super() 호출이 있는 constructor body를 후처리:
        /// 1. body 앞에 var _this; 선언 추가
        /// 2. body 끝에 return _this; 추가
        /// lowerSuperCall이 _this = __callSuper(...) 대입식을 생성하므로,
        /// super()가 if/else 등 어디에 있든 정상 동작한다.
        fn postProcessSuperCallBody(self: *Transformer, body: NodeIndex, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const body_node = self.new_ast.getNode(body);
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

            // 기존 body statements — extra_data grow 후 다시 접근
            for (self.new_ast.extra_data.items[stmts_start .. stmts_start + stmts_len]) |raw_idx| {
                try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
            }

            // instance fields: _this에 할당 (super() 이후에 실행되어야 함)
            for (instance_fields) |field_stmt| {
                try self.scratch.append(self.allocator, try replaceThisWithThisAlias(self, field_stmt, span));
            }

            // return _this;
            const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
            try self.scratch.append(self.allocator, try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = this_ref, .flags = 0 } },
            }));

            const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = new_list },
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
        /// instance_fields가 없으면: function Child() { return __callSuper(this, _super, arguments); }
        /// instance_fields가 있으면: function Child() { var _this = __callSuper(this, _super, arguments); <fields on _this>; return _this; }
        fn buildDefaultSuperConstructor(self: *Transformer, name: NodeIndex, super_class_span: Span, instance_fields: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const call_super_ref = try es_helpers.makeIdentifierRef(self, "__callSuper");
            const this_node = try self.new_ast.addNode(.{
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
                try self.scratch.append(self.allocator, try self.new_ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = this_ref, .flags = 0 } },
                }));
            } else {
                // return __callSuper(this, _super, arguments);
                try self.scratch.append(self.allocator, try self.new_ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call_super, .flags = 0 } },
                }));
            }

            const body_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
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

        /// statement 안의 this_expression을 _this identifier로 교체한 복사본 생성.
        /// instance field init에서 사용: this.x = v → _this.x = v
        fn replaceThisWithThisAlias(self: *Transformer, stmt_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            _ = span;
            const stmt = self.new_ast.getNode(stmt_idx);
            if (stmt.tag != .expression_statement) return stmt_idx;

            const expr_idx = stmt.data.unary.operand;
            if (expr_idx.isNone()) return stmt_idx;
            const expr = self.new_ast.getNode(expr_idx);

            // assignment: this.x = v → _this.x = v (값에 this가 있으면 _this로 교체)
            if (expr.tag == .assignment_expression) {
                const left = expr.data.binary.left;
                const right = expr.data.binary.right;
                const new_left = try replaceThisInExpr(self, left);
                const new_right = try replaceThisInExpr(self, right);
                if (@intFromEnum(new_left) == @intFromEnum(left) and @intFromEnum(new_right) == @intFromEnum(right)) return stmt_idx;
                const new_assign = try self.new_ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = expr.span,
                    .data = .{ .binary = .{ .left = new_left, .right = new_right, .flags = expr.data.binary.flags } },
                });
                return self.new_ast.addNode(.{
                    .tag = .expression_statement,
                    .span = stmt.span,
                    .data = .{ .unary = .{ .operand = new_assign, .flags = 0 } },
                });
            }

            // call: __classPrivateMethodInit(this, ...) → __classPrivateMethodInit(_this, ...)
            if (expr.tag == .call_expression) {
                const new_call = try replaceThisInExpr(self, expr_idx);
                if (@intFromEnum(new_call) == @intFromEnum(expr_idx)) return stmt_idx;
                return self.new_ast.addNode(.{
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
            const node = self.new_ast.getNode(idx);

            if (node.tag == .this_expression) {
                return es_helpers.makeIdentifierRef(self, "_this");
            }

            // static_member_expression: extra = [object, property, flags]
            if (node.tag == .static_member_expression) {
                const e = node.data.extra;
                const obj_idx: NodeIndex = @enumFromInt(self.new_ast.extra_data.items[e]);
                const new_obj = try replaceThisInExpr(self, obj_idx);
                if (@intFromEnum(new_obj) == @intFromEnum(obj_idx)) return idx;
                const prop = self.new_ast.extra_data.items[e + 1];
                const flags = self.new_ast.extra_data.items[e + 2];
                const new_extra = try self.new_ast.addExtras(&.{
                    @intFromEnum(new_obj), prop, flags,
                });
                return self.new_ast.addNode(.{
                    .tag = .static_member_expression,
                    .span = node.span,
                    .data = .{ .extra = new_extra },
                });
            }

            // call_expression: extra = [callee, args_start, args_len, flags]
            // __classPrivateMethodInit(this, _bark) → __classPrivateMethodInit(_this, _bark)
            if (node.tag == .call_expression) {
                const e = node.data.extra;
                const callee: NodeIndex = @enumFromInt(self.new_ast.extra_data.items[e]);
                const args_start = self.new_ast.extra_data.items[e + 1];
                const args_len = self.new_ast.extra_data.items[e + 2];
                const flags = self.new_ast.extra_data.items[e + 3];

                // callee와 인자 중 this_expression을 _this로 교체
                const new_callee = try replaceThisInExpr(self, callee);
                const scratch_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top);
                var changed = @intFromEnum(new_callee) != @intFromEnum(callee);
                for (0..args_len) |i| {
                    const raw_arg = self.new_ast.extra_data.items[args_start + i];
                    const arg_idx: NodeIndex = @enumFromInt(raw_arg);
                    const new_arg = try replaceThisInExpr(self, arg_idx);
                    if (@intFromEnum(new_arg) != @intFromEnum(arg_idx)) changed = true;
                    try self.scratch.append(self.allocator, new_arg);
                }
                if (!changed) return idx;
                const new_args = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
                const new_extra = try self.new_ast.addExtras(&.{
                    @intFromEnum(new_callee), new_args.start, new_args.len, flags,
                });
                return self.new_ast.addNode(.{
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
            if (self.options.unsupported.arrow and !new_body.isNone() and
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

            const is_async = flags & 0x08 != 0;
            const is_generator = flags & 0x10 != 0;

            // async method + generator 다운레벨링: class lowering이 먼저 실행되어
            // method_definition → function_expression으로 변환되므로,
            // 여기서 직접 async → state machine 변환을 수행해야 함.
            // (new_ast에 생성된 function_expression은 transformer가 재방문하지 않음)
            if (is_async and self.options.unsupported.async_await) {
                const GenMod = @import("es2015_generator.zig").ES2015Generator(@TypeOf(self.*));

                if (self.options.unsupported.generator) {
                    // async + generator 둘 다 unsupported → __async(__generator(state machine))
                    // buildStateMachine이 old_ast에서 body를 읽고 내부에서 visitNode 수행
                    const sm_result = try GenMod.buildStateMachine(self, body_idx, span);
                    if (!sm_result.body.isNone()) {
                        const gen_call = try GenMod.buildGeneratorHelperCall(self, sm_result.body, span);
                        const gen_wrapper = try es_helpers.wrapInFunction(self, gen_call, span);
                        const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper, span);
                        const func_expr = try buildWrappedFunc(self, async_call, sm_result.var_decl, new_params, span);
                        return buildMethodAssignment(self, info, class_name_span, key_idx, func_expr, span);
                    }
                }
                // async만 unsupported → __async(function*() { ... })
                const gen_wrapper = try es_helpers.buildGeneratorWrapper(self, try visitMethodBody(self, body_idx, span), span);
                const async_call = try es_helpers.buildAsyncHelperCall(self, gen_wrapper, span);
                const func_expr = try buildWrappedFunc(self, async_call, .none, new_params, span);
                return buildMethodAssignment(self, info, class_name_span, key_idx, func_expr, span);
            }

            const new_body = try visitMethodBody(self, body_idx, span);
            const func_flags: u32 = blk: {
                var f: u32 = 0;
                if (is_async) f |= 0x01;
                if (is_generator) f |= 0x02;
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

            return buildMethodAssignment(self, info, class_name_span, key_idx, func_expr, span);
        }

        /// return call_expr 를 body로 하는 function expression 생성.
        /// var_decl이 있으면 body 앞에 추가 (hoisted vars).
        fn buildWrappedFunc(self: *Transformer, call_expr: NodeIndex, var_decl: NodeIndex, params: ast_mod.NodeList, span: Span) Transformer.Error!NodeIndex {
            const return_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call_expr, .flags = 0 } },
            });
            const body_list = if (var_decl.isNone())
                try self.new_ast.addNodeList(&.{return_stmt})
            else
                try self.new_ast.addNodeList(&.{ var_decl, return_stmt });
            const wrapper_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                none,
                params.start,
                params.len,
                @intFromEnum(wrapper_body),
                0,
                none,
            });
            return self.new_ast.addNode(.{
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
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member_access, .right = func_expr, .flags = 0 } },
            });
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

                // configurable: true — ES6 class getter/setter는 스펙상 configurable.
                // ES5 Object.defineProperty의 기본값은 false이므로 명시 필요.
                // 이를 누락하면 이후 Object.defineProperties로 재정의 시 TypeError 발생.
                const config_key = try es_helpers.makeIdentifierRef(self, "configurable");
                const true_span = try self.new_ast.addString("true");
                const config_val = try self.new_ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = true_span,
                    .data = .{ .none = 0 },
                });
                const config_prop = try self.new_ast.addNode(.{
                    .tag = .object_property,
                    .span = span,
                    .data = .{ .binary = .{ .left = config_key, .right = config_val, .flags = 0 } },
                });

                // descriptor object: { configurable: true, get: fn, set: fn } 또는 { configurable: true, get: fn }
                const obj_list = if (paired_prop) |pp|
                    try self.new_ast.addNodeList(&.{ config_prop, prop1, pp })
                else
                    try self.new_ast.addNodeList(&.{ config_prop, prop1 });
                const desc_obj = try self.new_ast.addNode(.{
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
            class_name_old_idx: NodeIndex,
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
                );
                try self.pending_nodes.append(self.allocator, class_deco_stmt);
            }
        }
    };
}

test "ES2015 class module compiles" {
    _ = ES2015Class;
}
