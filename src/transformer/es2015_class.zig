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
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const class_constructors = @import("es2015_class/constructors.zig");
const class_methods = @import("es2015_class/methods.zig");
const class_members = @import("es2015_class/members.zig");
const class_private_fields = @import("es2015_class/private_fields.zig");
const class_super_props = @import("es2015_class/super_props.zig");
// #1752: 공용 helper 이름 모듈 (transformer → bundler 역의존 회피).
const rt = @import("../runtime_helper_names.zig");

const MethodExtra = ast_mod.MethodExtra;
const PropertyExtra = ast_mod.PropertyExtra;

pub fn ES2015Class(comptime Transformer: type) type {
    return struct {
        /// class_declaration을 function + prototype assignment로 변환.
        ///
        /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
        /// 반환: function_declaration. 나머지 prototype assignment는 pending_nodes에 추가.
        pub fn lowerClassDeclaration(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;

            // lowerClassExpression과 동일: class body는 독립 this 스코프이므로 arrow_this_depth 리셋.
            const saved_arrow_depth = self.arrow_this_depth;
            self.arrow_this_depth = 0;
            defer self.arrow_this_depth = saved_arrow_depth;

            const name_idx: NodeIndex = self.readNodeIdx(e, ast_mod.ClassExtra.name);
            const super_idx: NodeIndex = self.readNodeIdx(e, ast_mod.ClassExtra.super);
            const body_idx: NodeIndex = self.readNodeIdx(e, ast_mod.ClassExtra.body);

            // 클래스 이름 추출. `export default class {}` 는 class_declaration 이지만
            // 이름이 없으므로, ES5 lowering 의 outer `var` 선언에도 실제 binding 이 필요하다.
            var new_name = try self.visitNode(name_idx);
            const name_span = if (!new_name.isNone())
                self.ast.getNode(new_name).data.string_ref
            else blk: {
                const synthetic = try self.ast.addString("_Class");
                new_name = try es_helpers.makeBindingIdentifier(self, synthetic);
                break :blk synthetic;
            };

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
            const saved_super_static = self.current_super_is_static;
            const saved_super_static_receiver = self.current_super_static_receiver;
            // #3680: inner class body 안의 super 는 lexical 로 valid — outer standalone fn flag reset.
            const saved_super_in_extracted_fn = self.current_super_in_extracted_fn;
            self.current_super_class = super_span;
            self.current_super_class_old_idx = super_idx;
            self.current_super_is_static = false;
            self.current_super_static_receiver = null;
            self.current_super_in_extracted_fn = false;
            defer self.current_super_class = saved_super;
            defer self.current_super_class_old_idx = saved_super_old_idx;
            defer self.current_super_is_static = saved_super_static;
            defer self.current_super_static_receiver = saved_super_static_receiver;
            defer self.current_super_in_extracted_fn = saved_super_in_extracted_fn;

            // 클래스 바디 멤버 분류 (visitNode 호출 없이 metadata 만 수집).
            var cm = try classifyMembers(self, body_idx, span);
            defer cm.deinit(self.allocator);

            // 매핑은 모든 private field (regular + accessor backing) 가 모인 뒤 단일 지점에서 build.
            // 이후 deferred visit (static block / instance init) 가 이 매핑으로 lowering.
            const saved_private_fields = self.current_private_fields;
            const total_private = try setupPrivateFieldMappings(self, &cm, name_span);
            defer {
                if (total_private > 0) self.allocator.free(self.current_private_fields);
                self.current_private_fields = saved_private_fields;
            }
            try visitDeferredStaticBlocks(self, &cm, name_span);

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

            // IIFE 내부용 fresh binding (symbol 없음 — linker가 리네이밍 불가).
            // name_span은 stable Span이므로 재사용. getText slice는 이후 addString
            // realloc에 freed될 수 있어 쥐지 않는다 (#1481).
            const fresh_name_span = name_span;
            const fresh_name = try es_helpers.makeBindingIdentifier(self, fresh_name_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // computed accessor key memoization — var _acc_key_N = <expr>; 를 먼저 emit 해야 WeakMap/WeakSet
            // 선언 및 후속 Object.defineProperty 호출 시 참조 가능 (#1511).
            for (cm.accessor_key_memos.items) |memo| {
                try self.scratch.append(self.allocator, memo);
            }
            // instance private field → WeakMap 선언
            for (cm.private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakMap", pf.name, span));
            }
            // static private field → descriptor 객체 선언: var _x = { writable: true, value: initValue }
            for (cm.static_private_fields.items) |pf| {
                // V1 fix: class_name_span 전달 → static_receiver 보정
                try self.scratch.append(self.allocator, try es_helpers.buildStaticPrivateFieldDescriptor(self, pf.name, pf.init, span, name_span));
                self.runtime_helpers.class_static_private_field = true;
            }
            try emitInstanceInits(self, &cm, span);
            try emitPrivateMethodArtifacts(self, cm.private_methods.items, &cm.instance_fields, span);

            // IIFE 내부 function (fresh identifier — linker 무관)
            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, fresh_name, cm.instance_fields.items, has_super and super_span != null, span)
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
                const check_id = try es_helpers.makeRuntimeHelperRef(self, "__classCallCheck");
                const this_expr = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } });
                const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
                const call = try es_helpers.makeCallExpr(self, check_id, &.{ this_expr, class_ref }, span);
                func_node = try prependToFunctionBody(self, func_node, &.{try es_helpers.makeExprStmt(self, call, span)});
                self.runtime_helpers.class_call_check = true;
            }

            try self.scratch.append(self.allocator, func_node);

            // __extends(ClassName, _super) — parent는 IIFE 매개변수 _super
            const super_param_text = "_super";
            if (has_super and super_span != null) {
                const child_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
                const parent_ref = try es_helpers.makeIdentifierRef(self, super_param_text);
                const extends_ref = try es_helpers.makeRuntimeHelperRef(self, "__extends");
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

            // static fields/blocks 는 class evaluation 중 실행된다. extends class 의 경우 IIFE
            // 밖으로 내보내면 super lowering 이 참조하는 _super scope가 사라지므로 IIFE 내부에서
            // __extends 이후, return 이전에 실행한다.
            for (cm.static_elements.items) |element| {
                switch (element) {
                    .field => |field| {
                        const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, fresh_name_span);
                        const static_assign = try buildStaticFieldDefinePropertyWithCtx(self, class_ref, field.key, field.init, fresh_name_span, span);
                        try self.scratch.append(self.allocator, static_assign);
                    },
                    .stmt => |sb_stmt| try self.scratch.append(self.allocator, sb_stmt),
                    .raw_stmt => unreachable, // visitDeferredStaticBlocks 가 호출됐어야 함
                }
            }

            // return ClassName;
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try es_helpers.makeIdentifierRefFromSpan(self, name_span), .flags = 0 } },
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

            // Class body는 독립된 this 스코프. 외부 arrow의 arrow_this_depth가 leak되면
            // field initializer의 `this`가 `_this`로 잘못 치환된다 (Stage 3 decorator 재방문 케이스).
            const saved_arrow_depth = self.arrow_this_depth;
            self.arrow_this_depth = 0;
            defer self.arrow_this_depth = saved_arrow_depth;

            const name_idx: NodeIndex = self.readNodeIdx(e, ast_mod.ClassExtra.name);
            const super_idx: NodeIndex = self.readNodeIdx(e, ast_mod.ClassExtra.super);
            const body_idx: NodeIndex = self.readNodeIdx(e, ast_mod.ClassExtra.body);

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
            const saved_super_static = self.current_super_is_static;
            const saved_super_static_receiver = self.current_super_static_receiver;
            // #3680: inner class body 안의 super 는 lexical 로 valid — outer standalone fn flag reset.
            const saved_super_in_extracted_fn = self.current_super_in_extracted_fn;
            self.current_super_class = super_span;
            self.current_super_class_old_idx = super_idx;
            self.current_super_is_static = false;
            self.current_super_static_receiver = null;
            self.current_super_in_extracted_fn = false;
            defer self.current_super_class = saved_super;
            defer self.current_super_class_old_idx = saved_super_old_idx;
            defer self.current_super_is_static = saved_super_static;
            defer self.current_super_static_receiver = saved_super_static_receiver;
            defer self.current_super_in_extracted_fn = saved_super_in_extracted_fn;

            // 바디 멤버 분류 (visitNode 호출 없이 metadata 만 수집).
            var cm = try classifyMembers(self, body_idx, span);
            defer cm.deinit(self.allocator);

            // 매핑은 모든 private field 가 모인 뒤 단일 지점에서 build — 이후 deferred visit 들이 이 매핑으로 lowering.
            const saved_private_fields = self.current_private_fields;
            const total_private_ce = try setupPrivateFieldMappings(self, &cm, name_span);
            defer {
                if (total_private_ce > 0) self.allocator.free(self.current_private_fields);
                self.current_private_fields = saved_private_fields;
            }
            try visitDeferredStaticBlocks(self, &cm, name_span);

            // private method 매핑 설정
            const saved_private_methods = self.current_private_methods;
            if (cm.private_methods.items.len > 0) {
                self.current_private_methods = cm.private_methods.items;
            }
            defer self.current_private_methods = saved_private_methods;

            try emitInstanceInits(self, &cm, span);

            // private method 초기화 → constructor body에 삽입
            for (cm.private_methods.items) |pm| {
                const init_stmt = try es_helpers.buildPrivateMethodInit(self, pm.weakset_name, span);
                try cm.instance_fields.append(self.allocator, init_stmt);
            }

            // has_extra를 먼저 계산하여 func_node를 올바른 이름으로 한 번만 빌드
            const has_extra = cm.methods.items.len > 0 or cm.static_elements.items.len > 0 or
                cm.accessors.items.len > 0 or cm.private_fields.items.len > 0 or
                cm.static_private_fields.items.len > 0 or cm.private_methods.items.len > 0 or
                (has_super and super_span != null);

            // IIFE 경로면 fresh identifier (symbol 없음), 단순 경로면 원본 name_node.
            // `name_span`은 이미 addString/source에 저장된 stable Span이므로 그대로 재사용.
            // getText로 얻은 slice를 쥐고 있다가 이후 addString realloc에 freed 메모리 참조
            // → UTF-8 corrupted identifier 출력 (#1481).
            const func_name = if (has_extra) try es_helpers.makeBindingIdentifier(self, name_span) else name_node;

            var func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, func_name, cm.instance_fields.items, has_super and super_span != null, span)
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
                const check_id = try es_helpers.makeRuntimeHelperRef(self, "__classCallCheck");
                const this_expr = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } });
                const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
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

            // IIFE (lowerClassDeclaration과 동일 패턴) — name_span을 재사용.
            const expr_fresh_name = try es_helpers.makeBindingIdentifier(self, name_span);
            const expr_super_param = "_super";

            // func_node를 fresh name으로 재생성 (symbol 연결 없음)
            func_node = if (cm.constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, expr_fresh_name, cm.instance_fields.items, has_super and super_span != null, span)
            else if (has_super and super_span != null)
                try buildDefaultSuperConstructor(self, expr_fresh_name, super_span.?, cm.instance_fields.items, span)
            else
                try buildEmptyFunction(self, expr_fresh_name, span);

            if (cm.instance_fields.items.len > 0 and !(has_super and super_span != null)) {
                func_node = try prependToFunctionBody(self, func_node, cm.instance_fields.items);
            }
            // classCallCheck
            {
                const check_id = try es_helpers.makeRuntimeHelperRef(self, "__classCallCheck");
                const this_expr = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } });
                const class_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
                const call = try es_helpers.makeCallExpr(self, check_id, &.{ this_expr, class_ref }, span);
                func_node = try prependToFunctionBody(self, func_node, &.{try es_helpers.makeExprStmt(self, call, span)});
                self.runtime_helpers.class_call_check = true;
            }

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            for (cm.accessor_key_memos.items) |memo| {
                try self.scratch.append(self.allocator, memo);
            }
            for (cm.private_fields.items) |pf| {
                try self.scratch.append(self.allocator, try es_helpers.buildWeakCollectionDecl(self, "WeakMap", pf.name, span));
            }
            // static private field → descriptor 객체 선언
            for (cm.static_private_fields.items) |pf| {
                // V1 fix: class_name_span 전달
                try self.scratch.append(self.allocator, try es_helpers.buildStaticPrivateFieldDescriptor(self, pf.name, pf.init, span, name_span));
                self.runtime_helpers.class_static_private_field = true;
            }
            try emitPrivateMethodArtifacts(self, cm.private_methods.items, null, span);

            try self.scratch.append(self.allocator, func_node);

            // __extends(ClassName, _super) — parent는 IIFE 매개변수
            if (has_super and super_span != null) {
                const child_ref = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
                const parent_ref = try es_helpers.makeIdentifierRef(self, expr_super_param);
                const extends_ref = try es_helpers.makeRuntimeHelperRef(self, "__extends");
                try self.scratch.append(self.allocator, try es_helpers.makeExprStmt(self, try es_helpers.makeCallExpr(self, extends_ref, &.{ child_ref, parent_ref }, span), span));
                self.runtime_helpers.extends = true;
            }

            for (cm.methods.items) |info| {
                try self.scratch.append(self.allocator, try buildPrototypeAssignment(self, info, name_span, span));
            }

            const pending_top = self.pending_nodes.items.len;
            defer self.pending_nodes.shrinkRetainingCapacity(pending_top);
            if (cm.accessors.items.len > 0) {
                try emitAccessors(self, cm.accessors.items, name_span, span);
            }
            try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);

            for (cm.static_elements.items) |element| {
                switch (element) {
                    .field => |field| try self.scratch.append(self.allocator, try buildStaticFieldDefinePropertyWithCtx(self, try es_helpers.makeIdentifierRefFromSpan(self, name_span), field.key, field.init, name_span, span)),
                    .stmt => |sb_stmt| try self.scratch.append(self.allocator, sb_stmt),
                    .raw_stmt => unreachable, // visitDeferredStaticBlocks 가 호출됐어야 함
                }
            }

            // return ClassName;
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = try es_helpers.makeIdentifierRefFromSpan(self, name_span), .flags = 0 } },
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

        // super() / super.property lowering — es2015_class/super_props.zig로 위임
        const super_props_mod = class_super_props.SuperProps(Transformer);
        pub const isSuperCall = super_props_mod.isSuperCall;
        pub const lowerSuperCall = super_props_mod.lowerSuperCall;
        pub const buildSuperBaseRef = super_props_mod.buildSuperBaseRef;
        pub const isSuperMethodCall = super_props_mod.isSuperMethodCall;
        pub const lowerSuperMethodCall = super_props_mod.lowerSuperMethodCall;
        pub const isSuperMember = super_props_mod.isSuperMember;
        pub const lowerSuperMember = super_props_mod.lowerSuperMember;
        pub const isSuperComputedMember = super_props_mod.isSuperComputedMember;
        pub const lowerSuperComputedMember = super_props_mod.lowerSuperComputedMember;
        pub const lowerSuperPropertyAssignment = super_props_mod.lowerSuperPropertyAssignment;
        pub const lowerSuperPropertyUpdate = super_props_mod.lowerSuperPropertyUpdate;
        pub const isSuperComputedMethodCall = super_props_mod.isSuperComputedMethodCall;
        pub const lowerSuperComputedMethodCall = super_props_mod.lowerSuperComputedMethodCall;

        // Private field/accessor lowering — es2015_class/private_fields.zig로 위임
        const private_fields_mod = class_private_fields.PrivateFields(Transformer);
        pub const lowerPrivateFieldGet = private_fields_mod.lowerPrivateFieldGet;
        const emitPrivateMethodArtifacts = private_fields_mod.emitPrivateMethodArtifacts;
        pub const tryLowerPrivateFieldAssign = private_fields_mod.tryLowerPrivateFieldAssign;
        pub const destructuringTargetHasPrivateField = private_fields_mod.destructuringTargetHasPrivateField;
        pub const emitPrivateFieldGetWithNewObj = private_fields_mod.emitPrivateFieldGetWithNewObj;
        pub const lowerPrivateFieldSet = private_fields_mod.lowerPrivateFieldSet;
        pub const lowerPrivateFieldUpdate = private_fields_mod.lowerPrivateFieldUpdate;
        pub const lowerPrivateIn = private_fields_mod.lowerPrivateIn;

        // Method/prototype/accessor emission — es2015_class/methods.zig로 위임
        const methods_mod = class_methods.Methods(Transformer);
        const buildPrototypeAssignment = methods_mod.buildPrototypeAssignment;
        const emitAccessors = methods_mod.emitAccessors;

        // Class body member classification and field emission — es2015_class/members.zig로 위임
        const members_mod = class_members.Members(Transformer);
        const classifyMembers = members_mod.classifyMembers;
        const setupPrivateFieldMappings = members_mod.setupPrivateFieldMappings;
        const visitDeferredStaticBlocks = members_mod.visitDeferredStaticBlocks;
        const emitInstanceInits = members_mod.emitInstanceInits;
        const buildStaticFieldDefinePropertyWithCtx = members_mod.buildStaticFieldDefinePropertyWithCtx;

        // Constructor/default-constructor helpers are delegated to es2015_class/constructors.zig.
        const constructors_mod = class_constructors.Constructors(Transformer);
        const prependToFunctionBody = constructors_mod.prependToFunctionBody;
        const buildFunctionFromConstructor = constructors_mod.buildFunctionFromConstructor;
        const buildAssertThisInitialized = constructors_mod.buildAssertThisInitialized;
        const buildEmptyFunction = constructors_mod.buildEmptyFunction;
        const buildDefaultSuperConstructor = constructors_mod.buildDefaultSuperConstructor;
        const visitMethodBodyWithCtx = constructors_mod.visitMethodBodyWithCtx;

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
            const old_deco_start = self.readU32(e, ast_mod.ClassExtra.deco_start);
            const old_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);

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
                    const flags = self.readU32(me, MethodExtra.flags);
                    const is_static = (flags & ast_mod.MethodFlags.is_static) != 0;
                    const key: NodeIndex = self.readNodeIdx(me, MethodExtra.key);
                    const params_list_m = self.ast.functionParamsList(member);

                    if (!is_static and es_helpers.isConstructorKey(self, key)) {
                        // constructor param decorator
                        try self.collectParamDecorators(&ctor_param_decos, params_list_m);
                        continue;
                    }

                    // method decorator + param decorator
                    const deco_start = self.readU32(me, MethodExtra.deco_start);
                    const deco_len = self.readU32(me, MethodExtra.deco_len);
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
                    const pe = member.data.extra;
                    const flags = self.readU32(pe, PropertyExtra.flags);
                    const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;
                    const deco_start = self.readU32(pe, PropertyExtra.deco_start);
                    const deco_len = self.readU32(pe, PropertyExtra.deco_len);
                    if (deco_len > 0) {
                        const key_idx: NodeIndex = self.readNodeIdx(pe, PropertyExtra.key);
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

            const decorate_name = rt.helperName("__decorateClass", self.options.minify_whitespace);
            const decorate_span = try self.ast.addString(decorate_name);

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
