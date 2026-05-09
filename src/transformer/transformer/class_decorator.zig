//! Class + Decorator 변환
//!
//! visitClass, visitClassWithAssignSemantics, experimental decorators,
//! field assignments, constructor injection 등.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const Data = Node.Data;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const PrivateMethodMapping = Transformer.PrivateMethodMapping;
const es_helpers = @import("../es_helpers.zig");
const es2022 = @import("../es2022.zig");

pub fn visitClass(self: *Transformer, node: Node) Error!NodeIndex {
    // Stage 3 decorator dispatch는 transformer.zig `.class_declaration`/`.class_expression`의
    // `tryTransformStage3`가 선처리. 여기 들어온 시점엔 Stage 3 대상이 아니라고 가정.
    const e = node.data.extra;

    // Fast path: useDefineForClassFields=true AND !experimentalDecorators → 기존 동작
    // 멤버별 분류가 불필요하므로 body를 통째로 방문한다.
    if (self.options.use_define_for_class_fields and !self.options.experimental_decorators) {
        const raw_name_idx = self.readNodeIdx(e, ast_mod.ClassExtra.name);
        // #1587: class_expression의 name이 body 내부에서 참조되지 않으면 익명화.
        // #1592로 ClassExpression name이 body scope 심볼로 등록되어
        // reference_count == 0이 정확한 "미참조" 시그널. ClassDeclaration은 외부
        // scope 심볼이라 body 내부 ref만 count되지 않으므로 대상에서 제외.
        var new_name = if (shouldDropClassExprName(self, node.tag, raw_name_idx))
            ast_mod.NodeIndex.none
        else
            try self.visitNode(raw_name_idx);
        const super_idx = self.readNodeIdx(e, ast_mod.ClassExtra.super);
        const new_super = try self.visitNode(super_idx);

        // body visit 동안 derived class 여부를 method 변환부에 알린다 (parameter property
        // 가 super() 후로 가야 하는 경로 판별용).
        const saved_super_class = self.current_super_class;
        if (!super_idx.isNone()) {
            self.current_super_class = self.ast.getNode(super_idx).span;
        }
        defer self.current_super_class = saved_super_class;

        var current_body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);

        // ES2022 다운레벨링: private method (WeakSet + standalone fn) + private field (WeakMap + ctor init).
        // 두 변환은 단일 Pass로 통합 — body 순회 1회 + ctor_init 주입 1회.
        var pre_stmts: std.ArrayList(NodeIndex) = .empty;
        defer pre_stmts.deinit(self.allocator);
        var ctor_stmts: std.ArrayList(NodeIndex) = .empty;
        defer ctor_stmts.deinit(self.allocator);
        var pm_mappings: std.ArrayList(PrivateMethodMapping) = .empty;
        defer {
            for (pm_mappings.items) |pm| {
                self.allocator.free(pm.weakset_name);
                self.allocator.free(pm.func_name);
            }
            pm_mappings.deinit(self.allocator);
        }
        var pf_mappings: std.ArrayList(Transformer.PrivateFieldMapping) = .empty;
        defer {
            for (pf_mappings.items) |pf| {
                self.allocator.free(pf.var_name);
            }
            pf_mappings.deinit(self.allocator);
        }

        const lower_pm = self.options.unsupported.class_private_method;
        const lower_pf = self.options.unsupported.class_private_field;
        if ((lower_pm or lower_pf) and node.tag == .class_expression and new_name.isNone() and
            classBodyHasStaticPrivateMember(self, current_body_idx, lower_pm, lower_pf))
        {
            const tmp_span = try es_helpers.makeTempVarSpan(self);
            new_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
        }
        var had_private_methods = false;
        var had_private_fields = false;

        if (lower_pm or lower_pf) {
            const has_super = !self.readNodeIdx(e, 1).isNone();
            // static private field helper는 class 이름으로 receiver brand check를 한다.
            // 익명 class는 접근 helper가 `undefined`를 참조하게 되므로 static private field
            // 자체가 emit되지 않는 한 문제 없음.
            const class_name_text: ?[]const u8 = if (self.getClassNameSpan(new_name)) |s|
                self.ast.getText(s)
            else
                null;
            var new_body: NodeIndex = .none;
            const had_any = try es2022.ES2022(Transformer).lowerPrivateMembers(
                self,
                current_body_idx,
                &new_body,
                &pre_stmts,
                &ctor_stmts,
                &pm_mappings,
                &pf_mappings,
                lower_pm,
                lower_pf,
                has_super,
                class_name_text,
            );
            if (had_any) {
                current_body_idx = new_body;
                had_private_methods = pm_mappings.items.len > 0;
                had_private_fields = pf_mappings.items.len > 0;
            }
        }

        // ES2022 다운레벨링: static block → IIFE (target < es2022)
        // private member가 이미 body를 visit한 경우 `already_visited=true`로 재방문을 막는다.
        if (self.options.unsupported.class_static_block) {
            var new_body: NodeIndex = .none;
            var static_key_memos: std.ArrayList(NodeIndex) = .empty;
            defer static_key_memos.deinit(self.allocator);
            var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
            defer static_block_iifes.deinit(self.allocator);

            // 클래스 이름 추출 → static block 안의 this 치환에 사용.
            const class_name_span = self.getClassNameSpan(new_name);

            const already_visited = had_private_methods or had_private_fields;
            const had_static_blocks = try es2022.ES2022(Transformer).lowerStaticBlocks(
                self,
                current_body_idx,
                &new_body,
                &static_key_memos,
                &static_block_iifes,
                class_name_span,
                already_visited,
            );

            if (had_static_blocks) {
                current_body_idx = new_body;

                const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = self.readU32(e, ast_mod.ClassExtra.deco_len) });
                const none = @intFromEnum(NodeIndex.none);
                const class_result = try self.addExtraNode(node.tag, node.span, &.{
                    @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(current_body_idx),
                    none,                   0,                       0,
                    new_decos.start,        new_decos.len,
                });

                if (node.tag == .class_expression) {
                    return wrapClassExprInIIFE(
                        self,
                        static_key_memos.items,
                        pre_stmts.items,
                        class_result,
                        static_block_iifes.items,
                        new_name,
                        node.span,
                    );
                }

                // computed static keys → pre_stmts (WeakMap + WeakSet + function) → class → static block IIFE
                for (static_key_memos.items) |stmt| {
                    try self.pending_nodes.append(self.allocator, stmt);
                }
                for (pre_stmts.items) |stmt| {
                    try self.pending_nodes.append(self.allocator, stmt);
                }
                try self.pending_nodes.append(self.allocator, class_result);
                for (static_block_iifes.items) |iife| {
                    try self.pending_nodes.append(self.allocator, iife);
                }
                return .none;
            }
        }

        // private method/field 가 있고 static block은 없는 경우
        if (had_private_methods or had_private_fields) {
            const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = self.readU32(e, ast_mod.ClassExtra.deco_len) });
            const none = @intFromEnum(NodeIndex.none);
            const class_result = try self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(current_body_idx),
                none,                   0,                       0,
                new_decos.start,        new_decos.len,
            });

            if (node.tag == .class_expression) {
                return wrapClassExprInIIFE(
                    self,
                    &.{},
                    pre_stmts.items,
                    class_result,
                    &.{},
                    new_name,
                    node.span,
                );
            }

            for (pre_stmts.items) |stmt| {
                try self.pending_nodes.append(self.allocator, stmt);
            }
            try self.pending_nodes.append(self.allocator, class_result);
            return .none;
        }

        const new_body = try self.visitNode(current_body_idx);
        const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = self.readU32(e, ast_mod.ClassExtra.deco_len) });
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            new_decos.start,        new_decos.len,
        });
    }

    // Slow path: useDefineForClassFields=false 또는 experimentalDecorators
    // 클래스 바디의 멤버들을 개별로 분석해야 하므로, class_body를 직접 순회한다.
    return self.visitClassWithAssignSemantics(node);
}

fn classBodyHasStaticPrivateMember(self: *Transformer, body_idx: NodeIndex, lower_methods: bool, lower_fields: bool) bool {
    if (body_idx.isNone()) return false;
    const body_node = self.ast.getNode(body_idx);
    if (body_node.tag != .class_body) return false;

    const start = body_node.data.list.start;
    const len = body_node.data.list.len;
    if (start + len > self.ast.extra_data.items.len) return false;

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const member = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[start + i]));
        switch (member.tag) {
            .method_definition => {
                if (!lower_methods) continue;
                const e = member.data.extra;
                if (e + ast_mod.MethodExtra.flags >= self.ast.extra_data.items.len) continue;
                const flags = self.readU32(e, ast_mod.MethodExtra.flags);
                if ((flags & ast_mod.MethodFlags.is_static) == 0) continue;
                const key = self.readNodeIdx(e, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) return true;
            },
            .property_definition => {
                if (!lower_fields) continue;
                const e = member.data.extra;
                if (e + ast_mod.PropertyExtra.flags >= self.ast.extra_data.items.len) continue;
                const flags = self.readU32(e, ast_mod.PropertyExtra.flags);
                if ((flags & ast_mod.PropertyFlags.is_static) == 0) continue;
                const key = self.readNodeIdx(e, ast_mod.PropertyExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) return true;
            },
            else => {},
        }
    }

    return false;
}

/// class_expression의 private method / static block 다운레벨 결과를 IIFE로 래핑한다.
///
/// class_expression은 statement 컨텍스트가 아니므로 헬퍼 문장들을 pending_nodes로
/// 흘리면 부모 표현식에 쉼표-stitching되어 문법이 깨진다. declaration으로 태그만
/// 바꿔 IIFE body에 넣고 이름을 return한다 (extra 레이아웃은 declaration/expression
/// 동일하므로 재복사 불필요).
fn wrapClassExprInIIFE(
    self: *Transformer,
    pre_stmts_a: []const NodeIndex,
    pre_stmts_b: []const NodeIndex,
    class_expr_node: NodeIndex,
    post_stmts: []const NodeIndex,
    new_name: NodeIndex,
    span: Span,
) Error!NodeIndex {
    // 익명 class면 임시 이름을 부여해 return에서 참조할 수 있도록 한다.
    var decl_name = new_name;
    const ret_name_span: Span = if (decl_name.isNone()) blk: {
        const tmp_span = try es_helpers.makeTempVarSpan(self);
        decl_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
        break :blk tmp_span;
    } else self.ast.getNode(decl_name).data.string_ref;

    // tag만 declaration으로 교체 (extra 레이아웃 동일). name 슬롯은 익명 보정 위해 덮어씀.
    const ce = self.ast.getNode(class_expr_node).data.extra;
    const none = @intFromEnum(NodeIndex.none);
    const class_decl = try self.addExtraNode(.class_declaration, span, &.{
        @intFromEnum(decl_name), @intFromEnum(self.readNodeIdx(ce, 1)), @intFromEnum(self.readNodeIdx(ce, 2)),
        none,                    0,                                     0,
        self.readU32(ce, 6),     self.readU32(ce, 7),
    });

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    try self.scratch.appendSlice(self.allocator, pre_stmts_a);
    try self.scratch.appendSlice(self.allocator, pre_stmts_b);
    try self.scratch.append(self.allocator, class_decl);
    try self.scratch.appendSlice(self.allocator, post_stmts);

    const ret_ref = try es_helpers.makeIdentifierRefFromSpan(self, ret_name_span);
    try self.scratch.append(self.allocator, try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = ret_ref, .flags = 0 } },
    }));

    const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const body_block = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = body_list },
    });

    // (() => { ... })()  — params=.none 은 codegen이 "()"로 출력 (es2022.zig 패턴과 동일).
    const arrow = try self.addExtraNode(.arrow_function_expression, span, &.{
        none, @intFromEnum(body_block), 0,
    });
    const paren = try es_helpers.makeParenExpr(self, arrow, span);
    return es_helpers.makeCallExpr(self, paren, &.{}, span);
}

/// useDefineForClassFields=false / experimentalDecorators 처리.
/// 멤버를 개별 분류하여 instance field를 constructor로 이동하고,
/// experimental decorator를 __decorateClass 호출로 변환한다.
pub fn visitClassWithAssignSemantics(self: *Transformer, node: Node) Error!NodeIndex {
    // TODO(es2021): apply same IIFE wrapping for class_expression with private methods — see wrapClassExprInIIFE in fast path
    const e = node.data.extra;
    const has_super = !self.readNodeIdx(e, ast_mod.ClassExtra.super).isNone();
    const raw_name_idx = self.readNodeIdx(e, ast_mod.ClassExtra.name);
    var new_name = try self.visitNode(raw_name_idx);
    const new_super = try self.visitNode(self.readNodeIdx(e, ast_mod.ClassExtra.super));

    // 원본 class_body를 직접 순회
    const body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);
    const body_node = self.ast.getNode(body_idx);
    const body_members_start = body_node.data.list.start;
    const body_members_len = body_node.data.list.len;

    // 멤버 분류: class_members(새 body), field_assignments(constructor 이동 대상),
    // member_decorators(experimental decorator 대상)를 동시에 수집한다.
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var class_members: std.ArrayList(NodeIndex) = .empty;
    defer class_members.deinit(self.allocator);

    var field_assignments: std.ArrayList(FieldAssignment) = .empty;
    defer field_assignments.deinit(self.allocator);

    var member_decorators: std.ArrayList(MemberDecoratorInfo) = .empty;
    defer {
        for (member_decorators.items) |md| {
            self.allocator.free(md.decorators);
        }
        member_decorators.deinit(self.allocator);
    }

    var existing_constructor: ?NodeIndex = null;
    var existing_constructor_pos: ?usize = null;

    // ES2022 다운레벨링: static block → IIFE (target < es2022)
    var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
    defer static_block_iifes.deinit(self.allocator);

    var static_field_assignments: std.ArrayList(FieldAssignment) = .empty;
    defer static_field_assignments.deinit(self.allocator);

    var ctor_param_decos: std.ArrayList(NodeIndex) = .empty;
    defer ctor_param_decos.deinit(self.allocator);

    // emitDecoratorMetadata: constructor 파라미터 위치 (원본 AST에서 수집)
    var ctor_params: ast_mod.NodeList = .{ .start = 0, .len = 0 };

    var ctx = ClassMemberContext{
        .class_members = &class_members,
        .field_assignments = &field_assignments,
        .member_decorators = &member_decorators,
        .existing_constructor = &existing_constructor,
        .existing_constructor_pos = &existing_constructor_pos,
        .static_block_iifes = if (self.options.unsupported.class_static_block) &static_block_iifes else null,
        .static_field_assignments = if (!self.options.use_define_for_class_fields) &static_field_assignments else null,
        .ctor_param_decos = &ctor_param_decos,
        .has_super = has_super,
        .ctor_params = &ctor_params,
    };

    // ES2022 static block this 치환을 위한 클래스 이름 추출
    if (self.options.unsupported.class_static_block) {
        ctx.class_name_span = self.getClassNameSpan(new_name);
    }

    // classifyClassMember가 AST를 변형하므로 인덱스 루프 사용
    {
        var i_bm: u32 = 0;
        while (i_bm < body_members_len) : (i_bm += 1) {
            const raw_idx = self.ast.extra_data.items[body_members_start + i_bm];
            try self.classifyClassMember(raw_idx, &ctx);
        }
    }

    // computed key 호이스트: class 전에 var _a; _a = foo; 삽입 (esbuild 호환)
    // assign semantics에서 computed key는 class 평가 전에 한 번만 평가되어야 함
    if (!self.options.use_define_for_class_fields) {
        var computed_idx: u8 = 0;
        for (field_assignments.items) |*field| {
            if (field.is_computed) {
                const key_node = self.ast.getNode(field.key);
                const actual_key = if (key_node.tag == .computed_property_key)
                    key_node.data.unary.operand
                else
                    field.key;

                // var _a; / var _b; / ... (computed field별 고유 이름)
                var name_buf: [4]u8 = undefined;
                name_buf[0] = '_';
                name_buf[1] = 'a' + computed_idx;
                const temp_span = try self.ast.addString(name_buf[0..2]);
                computed_idx += 1;
                const temp_binding = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = temp_span,
                    .data = .{ .string_ref = temp_span },
                });
                const declarator_extra = try self.ast.addExtras(&.{
                    @intFromEnum(temp_binding),
                    @intFromEnum(NodeIndex.none),
                    @intFromEnum(NodeIndex.none),
                });
                const declarator = try self.ast.addNode(.{
                    .tag = .variable_declarator,
                    .span = field.span,
                    .data = .{ .extra = declarator_extra },
                });
                const decl_list = try self.ast.addNodeList(&.{declarator});
                const var_decl_extra = try self.ast.addExtras(&.{ 0, decl_list.start, decl_list.len });
                const var_decl = try self.ast.addNode(.{
                    .tag = .variable_declaration,
                    .span = field.span,
                    .data = .{ .extra = var_decl_extra },
                });
                try self.pending_nodes.append(self.allocator, var_decl);

                // _a = foo; 대입
                const temp_ref = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = temp_span,
                    .data = .{ .string_ref = temp_span },
                });
                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = field.span,
                    .data = .{ .binary = .{ .left = temp_ref, .right = actual_key, .flags = 0 } },
                });
                const assign_stmt = try self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = field.span,
                    .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
                });
                try self.pending_nodes.append(self.allocator, assign_stmt);

                // field의 key를 임시 변수로 교체
                const new_computed = try self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = field.span,
                    .data = .{ .unary = .{ .operand = temp_ref, .flags = 0 } },
                });
                field.key = new_computed;
            }
        }
    }

    // instance field를 constructor에 삽입 (useDefineForClassFields=false)
    if (field_assignments.items.len > 0) {
        try self.applyFieldAssignments(
            &class_members,
            field_assignments.items,
            existing_constructor,
            existing_constructor_pos,
            has_super,
        );
    }

    // class body 노드 생성
    const body_list = try self.ast.addNodeList(class_members.items);
    const new_body = try self.ast.addNode(.{
        .tag = .class_body,
        .span = body_node.span,
        .data = .{ .list = body_list },
    });

    const old_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);
    const has_any_decorator = old_deco_len > 0 or
        member_decorators.items.len > 0 or
        ctor_param_decos.items.len > 0;

    // #1596: fast path (#1587) 와 동일 최적화를 non-fast-path 에도 적용.
    // class name 이 runtime 에 참조되는 경우 — static field (`Foo.x=...`),
    // static block 다운레벨 (`this` 치환), decorator 중 하나라도 있으면 보존.
    if (shouldDropClassExprName(self, node.tag, raw_name_idx)) {
        const has_static_extras = static_field_assignments.items.len > 0 or
            static_block_iifes.items.len > 0;
        if (!has_any_decorator and !has_static_extras) {
            new_name = NodeIndex.none;
        }
    }

    // experimentalDecorators — decorator를 class에서 제거하고 __decorateClass 호출 생성
    if (self.options.experimental_decorators) {
        const old_deco_start = self.readU32(e, ast_mod.ClassExtra.deco_start);

        if (has_any_decorator) {
            return try self.transformExperimentalDecorators(
                node,
                new_name,
                self.readNodeIdx(e, 0),
                new_super,
                new_body,
                old_deco_start,
                old_deco_len,
                member_decorators.items,
                static_block_iifes.items,
                static_field_assignments.items,
                ctor_param_decos.items,
                ctor_params,
            );
        }
    }

    // decorator 리스트 복사 (experimental이 아닌 경우)
    const new_decos = if (!self.options.experimental_decorators)
        try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = old_deco_len })
    else
        NodeList{ .start = 0, .len = 0 };

    const none = @intFromEnum(NodeIndex.none);

    // static field / static block이 있으면 class 뒤에 할당문 추가
    const has_static_fields = static_field_assignments.items.len > 0;
    const has_static_blocks = static_block_iifes.items.len > 0;

    if (has_static_fields or has_static_blocks) {
        const class_result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            new_decos.start,        new_decos.len,
        });
        try self.pending_nodes.append(self.allocator, class_result);
        // static field: Foo.z = 2;
        for (static_field_assignments.items) |field| {
            const stmt = try self.buildStaticFieldAssignment(new_name, field);
            try self.pending_nodes.append(self.allocator, stmt);
        }
        for (static_block_iifes.items) |iife| {
            try self.pending_nodes.append(self.allocator, iife);
        }
        return .none;
    }

    return self.addExtraNode(node.tag, node.span, &.{
        @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
        none,                   0,                       0,
        new_decos.start,        new_decos.len,
    });
}

// ================================================================
// Class member / field assignment helpers — transformer/class_member_helpers.zig로 위임
// ================================================================
const class_member_helpers = @import("class_member_helpers.zig");

pub const ClassMemberContext = class_member_helpers.ClassMemberContext;
pub const FieldAssignment = class_member_helpers.FieldAssignment;
pub const MemberDecoratorInfo = class_member_helpers.MemberDecoratorInfo;
pub const buildStaticFieldAssignment = class_member_helpers.buildStaticFieldAssignment;
pub const classifyClassMember = class_member_helpers.classifyClassMember;
pub const classifyPropertyDefinition = class_member_helpers.classifyPropertyDefinition;
pub const classifyMethodDefinition = class_member_helpers.classifyMethodDefinition;
pub const applyFieldAssignments = class_member_helpers.applyFieldAssignments;
pub const insertFieldAssignmentsIntoConstructor = class_member_helpers.insertFieldAssignmentsIntoConstructor;
pub const isSuperCallStatement = class_member_helpers.isSuperCallStatement;
pub const buildConstructorWithFieldAssignments = class_member_helpers.buildConstructorWithFieldAssignments;
pub const buildThisAssignment = class_member_helpers.buildThisAssignment;
pub const visitDecoratorExpression = class_member_helpers.visitDecoratorExpression;
pub const collectMemberDecorators = class_member_helpers.collectMemberDecorators;
pub const collectParamDecorators = class_member_helpers.collectParamDecorators;
pub const appendParamDecorators = class_member_helpers.appendParamDecorators;
pub const buildDecorateParamCall = class_member_helpers.buildDecorateParamCall;
const makeThisPrivateField = class_member_helpers.makeThisPrivateField;
const insertAfterSuperCall = class_member_helpers.insertAfterSuperCall;
const buildSuperSpreadArgsShell = class_member_helpers.buildSuperSpreadArgsShell;

// ================================================================
// Legacy experimental decorators — transformer/legacy_decorator_helpers.zig로 위임
// ================================================================
const legacy_decorator_helpers = @import("legacy_decorator_helpers.zig");

pub const transformExperimentalDecorators = legacy_decorator_helpers.transformExperimentalDecorators;
pub const buildDecorateClassMemberCall = legacy_decorator_helpers.buildDecorateClassMemberCall;
pub const buildDecorateClassCall = legacy_decorator_helpers.buildDecorateClassCall;

// ================================================================
// emitDecoratorMetadata — transformer/decorator_metadata.zig로 위임
// ================================================================
const decorator_metadata = @import("decorator_metadata.zig");

pub const serializeTypeAnnotation = decorator_metadata.serializeTypeAnnotation;
pub const extractTypeFromSource = decorator_metadata.extractTypeFromSource;
pub const buildMetadataCall = decorator_metadata.buildMetadataCall;
pub const buildParamTypesArray = decorator_metadata.buildParamTypesArray;
pub const appendMemberMetadata = decorator_metadata.appendMemberMetadata;
pub const appendClassMetadata = decorator_metadata.appendClassMetadata;

/// 이름으로 identifier_reference 노드를 생성하는 헬퍼.
/// Stage 3 decorator helper들이 공유한다.
fn makeIdentifier(self: *Transformer, name: []const u8) Error!NodeIndex {
    return es_helpers.makeIdentifierRef(self, name);
}

// ============================================================
// TC39 Stage 3 Decorator Transform (TypeScript 5.0+ 호환)
// ============================================================
//
// TypeScript/Babel/SWC 공통 출력: __esDecorate + __runInitializers + IIFE 래핑.
// experimental_decorators=false일 때, class/member에 decorator가 있으면 이 경로를 탄다.

/// Stage 3 decorator가 있는 멤버(method/property/accessor)가 하나라도 있는지 확인.
/// class_body를 순회하여 decorator가 달린 멤버 존재 여부만 빠르게 판단한다.
/// 익명/export default class의 IIFE 내부 변수명
const ANON_CLASS_NAME = "_Class";

pub fn hasAnyMemberDecorators(self: *Transformer, class_extra: u32) bool {
    const body_idx = self.readNodeIdx(class_extra, 2);
    if (body_idx.isNone()) return false;
    const body_node = self.ast.getNode(body_idx);
    const start = body_node.data.list.start;
    const len = body_node.data.list.len;

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const member_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[start + i]);
        if (member_idx.isNone()) continue;
        const member = self.ast.getNode(member_idx);
        const me = member.data.extra;

        if (member.tag == .property_definition or member.tag == .accessor_property) {
            const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
            if (deco_len > 0) return true;
        } else if (member.tag == .method_definition) {
            const deco_len = self.readU32(me, ast_mod.MethodExtra.deco_len);
            if (deco_len > 0) return true;
        }
    }
    return false;
}

/// Stage 3 decorator 생성 헬퍼 위임.
const stage3_helpers = @import("stage3_decorator_helpers.zig");

pub const Stage3MemberInfo = stage3_helpers.Stage3MemberInfo;
pub const FieldInitNames = stage3_helpers.FieldInitNames;
pub const memberKeyToStringLiteral = stage3_helpers.memberKeyToStringLiteral;
pub const wrapInStringLiteral = stage3_helpers.wrapInStringLiteral;
pub const collectStage3Decorators = stage3_helpers.collectStage3Decorators;
pub const buildEsDecorateCall = stage3_helpers.buildEsDecorateCall;
pub const buildClassEsDecorateCall = stage3_helpers.buildClassEsDecorateCall;
pub const buildContextObject = stage3_helpers.buildContextObject;
pub const buildAccessObject = stage3_helpers.buildAccessObject;
pub const buildMetadataDecl = stage3_helpers.buildMetadataDecl;
pub const buildClassReassign = stage3_helpers.buildClassReassign;
pub const buildRunInitializersCall = stage3_helpers.buildRunInitializersCall;
pub const buildRunInitializersCall2 = stage3_helpers.buildRunInitializersCall2;
pub const buildStage3LetDeclarations = stage3_helpers.buildStage3LetDeclarations;
pub const makeObjProp = stage3_helpers.makeObjProp;
pub const makeLet = stage3_helpers.makeLet;
pub const buildFieldInitNames = stage3_helpers.buildFieldInitNames;
pub const buildMetadataDefineProperty = stage3_helpers.buildMetadataDefineProperty;
pub const buildGetterMethod = stage3_helpers.buildGetterMethod;
pub const buildSetterMethod = stage3_helpers.buildSetterMethod;
pub const extractCleanVarName = stage3_helpers.extractCleanVarName;
pub const appendEsDecorateStmt = stage3_helpers.appendEsDecorateStmt;

/// TC39 Stage 3 decorator 변환 메인 함수.
pub fn transformStage3Decorators(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);

    // 런타임 헬퍼 사용 표시
    self.runtime_helpers.es_decorator = true;

    // 클래스 이름, super, body, decorator 추출
    const name_idx = self.readNodeIdx(e, ast_mod.ClassExtra.name);
    const super_idx = self.readNodeIdx(e, ast_mod.ClassExtra.super);
    const body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);
    const class_deco_start = self.readU32(e, ast_mod.ClassExtra.deco_start);
    const class_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);

    // 클래스 이름 텍스트 (Foo). 익명/default class는 "_Class"를 사용.
    // "default"는 JS 예약어이므로 변수명으로 사용 불가.
    // 주의: getText 반환값은 string table 내부 포인터이므로 addString 후 무효화될 수 있음.
    // allocator로 복사하여 안전하게 보관한다.
    // makeTempVarSpan을 사용하지 않음 — hoistTempVars가 불필요한 var 선언을 추가하므로.
    const class_name_text = if (!name_idx.isNone()) blk: {
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.data.string_ref);
        if (std.mem.eql(u8, name_text, "default")) {
            break :blk try self.allocator.dupe(u8, ANON_CLASS_NAME);
        }
        break :blk try self.allocator.dupe(u8, name_text);
    } else blk: {
        break :blk try self.allocator.dupe(u8, ANON_CLASS_NAME);
    };
    defer self.allocator.free(class_name_text);

    // body 멤버 순회: member decorator 수집
    var member_infos: std.ArrayList(Stage3MemberInfo) = .empty;
    defer {
        for (member_infos.items) |info| {
            self.allocator.free(info.decorators);
            if (info.initializers_name) |name| self.allocator.free(name);
            if (info.extra_initializers_name) |name| self.allocator.free(name);
            if (info.descriptor_name) |name| self.allocator.free(name);
            if (info.deco_var_name) |name| self.allocator.free(name);
        }
        member_infos.deinit(self.allocator);
    }

    var has_instance_decorators = false;
    var has_static_decorators = false;

    const body_node = self.ast.getNode(body_idx);
    const body_start = body_node.data.list.start;
    const body_len = body_node.data.list.len;

    // 새 class body 멤버 (decorator 제거 + 필요 시 constructor 삽입)
    var new_members: std.ArrayList(NodeIndex) = .empty;
    defer new_members.deinit(self.allocator);

    var has_constructor = false;

    // instance field/accessor initializer 체이닝용: 마지막 field의 extra_initializers_name만 추적.
    // TypeScript 패턴: 첫 field에 _instanceExtraInitializers를 piggyback,
    // 이후 field에 이전 field의 _extraInitializers를 piggyback,
    // constructor에 마지막 field의 _extraInitializers를 삽입
    var last_instance_field_extra: ?[]const u8 = null;

    {
        var i: u32 = 0;
        while (i < body_len) : (i += 1) {
            const raw = self.ast.extra_data.items[body_start + i];
            const member_idx: NodeIndex = @enumFromInt(raw);
            if (member_idx.isNone()) continue;
            const member = self.ast.getNode(member_idx);
            const me = member.data.extra;

            if (member.tag == .method_definition) {
                const flags = self.readU32(me, ast_mod.MethodExtra.flags);
                const deco_start = self.readU32(me, ast_mod.MethodExtra.deco_start);
                const deco_len = self.readU32(me, ast_mod.MethodExtra.deco_len);
                const is_static = (flags & ast_mod.MethodFlags.is_static) != 0;
                const is_getter = (flags & ast_mod.MethodFlags.is_getter) != 0;
                const is_setter = (flags & ast_mod.MethodFlags.is_setter) != 0;

                // constructor 감지
                if (!is_getter and !is_setter and !is_static) {
                    const key_idx = self.readNodeIdx(me, ast_mod.MethodExtra.key);
                    if (!key_idx.isNone()) {
                        const key_node = self.ast.getNode(key_idx);
                        if (key_node.tag == .identifier_reference or key_node.tag == .binding_identifier) {
                            const key_text = self.ast.getText(key_node.data.string_ref);
                            if (std.mem.eql(u8, key_text, "constructor")) {
                                has_constructor = true;
                            }
                        }
                    }
                }

                // key를 한 번만 방문 (decorator info + stripped method 공용)
                const key_idx = self.readNodeIdx(me, ast_mod.MethodExtra.key);
                const new_key = try self.visitNode(key_idx);
                // private identifier 감지
                const is_private = blk: {
                    const orig_key = self.ast.getNode(key_idx);
                    break :blk orig_key.tag == .private_identifier;
                };

                const is_private_method = is_private and deco_len > 0 and !is_getter and !is_setter;

                if (deco_len > 0) {
                    const kind = if (is_getter) "getter" else if (is_setter) "setter" else "method";
                    const name_node_idx = try self.memberKeyToStringLiteral(new_key);
                    const decos = try self.collectStage3Decorators(deco_start, deco_len);
                    const var_n = extractCleanVarName(self, name_node_idx);
                    // getter/setter는 같은 이름에 다른 kind → kind prefix로 충돌 방지
                    const kind_prefix = if (is_getter) "get_" else if (is_setter) "set_" else "";
                    const deco_vname = try std.fmt.allocPrint(self.allocator, "_{s}{s}_decorators", .{ kind_prefix, var_n });

                    if (is_static) has_static_decorators = true else has_instance_decorators = true;

                    // private method: descriptor 변수명 + body 저장
                    var desc_name: ?[]const u8 = null;
                    var m_body: NodeIndex = .none;
                    var m_params: ast_mod.NodeList = .{ .start = 0, .len = 0 };
                    if (is_private_method) {
                        desc_name = try std.fmt.allocPrint(self.allocator, "_private_{s}_descriptor", .{var_n});
                        m_body = try self.visitNode(self.readNodeIdx(me, ast_mod.MethodExtra.body));
                        m_params = self.ast.functionParamsList(member);
                    }

                    try member_infos.append(self.allocator, .{
                        .kind = kind,
                        .name = name_node_idx,
                        .is_static = is_static,
                        .is_private = is_private,
                        .decorators = decos,
                        .descriptor_name = desc_name,
                        .method_body = m_body,
                        .method_params = m_params,
                        .deco_var_name = deco_vname,
                    });
                }

                if (is_private_method) {
                    // private decorated method → getter로 교체: get #method() { return _descriptor.value; }
                    const info = member_infos.items[member_infos.items.len - 1];
                    const desc_ref = try makeIdentifier(self, info.descriptor_name.?);
                    const val_key = try makeIdentifier(self, "value");
                    const return_expr = try es_helpers.makeStaticMember(self, desc_ref, val_key, zero_span);
                    const getter = try self.buildGetterMethod(new_key, return_expr, is_static, member.span);
                    try new_members.append(self.allocator, getter);
                } else {
                    // public method 또는 non-decorated → 그대로 추가
                    const new_body = try self.visitNode(self.readNodeIdx(me, ast_mod.MethodExtra.body));
                    const empty_list = try self.ast.addNodeList(&.{});
                    const new_method = try self.addExtraNode(.method_definition, member.span, &.{
                        @intFromEnum(new_key),
                        self.readU32(me, ast_mod.MethodExtra.params),
                        @intFromEnum(new_body),
                        flags,
                        empty_list.start,
                        empty_list.len,
                    });
                    try new_members.append(self.allocator, new_method);
                }
            } else if (member.tag == .property_definition) {
                const flags = self.readU32(me, ast_mod.PropertyExtra.flags);
                const deco_start = self.readU32(me, ast_mod.PropertyExtra.deco_start);
                const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
                const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;

                // key를 한 번만 방문
                const key_idx_prop = self.readNodeIdx(me, ast_mod.PropertyExtra.key);
                const new_key = try self.visitNode(key_idx_prop);
                const is_private_field = self.ast.getNode(key_idx_prop).tag == .private_identifier;

                var field_init_name: ?[]const u8 = null;
                if (deco_len > 0) {
                    const name_node_idx = try self.memberKeyToStringLiteral(new_key);
                    const decos = try self.collectStage3Decorators(deco_start, deco_len);
                    const var_n = extractCleanVarName(self, name_node_idx);
                    const deco_vname = try std.fmt.allocPrint(self.allocator, "_{s}_decorators", .{var_n});

                    if (is_static) has_static_decorators = true else has_instance_decorators = true;

                    const names = try self.buildFieldInitNames(name_node_idx);
                    field_init_name = names.init_name;

                    try member_infos.append(self.allocator, .{
                        .kind = "field",
                        .name = name_node_idx,
                        .is_static = is_static,
                        .is_private = is_private_field,
                        .decorators = decos,
                        .initializers_name = names.init_name,
                        .extra_initializers_name = names.extra_name,
                        .deco_var_name = deco_vname,
                    });
                }

                // property를 decorator 없이 추가 (decorated면 초기값을 __runInitializers로 래핑)
                const raw_init = try self.visitNode(self.readNodeIdx(me, ast_mod.PropertyExtra.init));
                const new_init = if (field_init_name) |init_name| blk: {
                    // TypeScript 패턴: (runInit(this, _prevExtra), runInit(this, _x_initializers, val))
                    // 첫 field: _prevExtra = _instanceExtraInitializers
                    // 이후 field: _prevExtra = 이전 field의 _extraInitializers
                    const this_node = try self.ast.addNode(.{
                        .tag = .this_expression,
                        .span = zero_span,
                        .data = .{ .none = 0 },
                    });
                    const callee = try makeIdentifier(self, "__runInitializers");
                    const init_arr = try makeIdentifier(self, init_name);
                    const init_call = if (!raw_init.isNone()) init_blk: {
                        const args = try self.ast.addNodeList(&.{ this_node, init_arr, raw_init });
                        break :init_blk try self.addExtraNode(.call_expression, zero_span, &.{
                            @intFromEnum(callee), args.start, args.len, 0,
                        });
                    } else init_blk: {
                        // 초기값 없어도 void 0을 명시적으로 전달 — __runInitializers가 arguments.length > 2를 체크
                        const void0 = try makeIdentifier(self, "void 0");
                        const args = try self.ast.addNodeList(&.{ this_node, init_arr, void0 });
                        break :init_blk try self.addExtraNode(.call_expression, zero_span, &.{
                            @intFromEnum(callee), args.start, args.len, 0,
                        });
                    };

                    // instance field만 initializer 체이닝 적용 (static은 static block에서 처리)
                    if (!is_static) {
                        const prev_extra = last_instance_field_extra orelse "_instanceExtraInitializers";
                        const result = try buildPiggybackedInitCall(self, prev_extra, init_call);
                        const info = member_infos.items[member_infos.items.len - 1];
                        if (info.extra_initializers_name) |extra_name| {
                            last_instance_field_extra = extra_name;
                        }
                        break :blk result;
                    } else {
                        break :blk init_call;
                    }
                } else raw_init;
                const empty_list = try self.ast.addNodeList(&.{});
                const new_prop = try self.addExtraNode(.property_definition, member.span, &.{
                    @intFromEnum(new_key),
                    @intFromEnum(new_init),
                    flags,
                    empty_list.start,
                    empty_list.len,
                });
                try new_members.append(self.allocator, new_prop);
            } else if (member.tag == .accessor_property) {
                const flags = self.readU32(me, ast_mod.PropertyExtra.flags);
                const deco_start = self.readU32(me, ast_mod.PropertyExtra.deco_start);
                const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
                const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;

                const key_idx = self.readNodeIdx(me, ast_mod.PropertyExtra.key);
                const new_key = try self.visitNode(key_idx);
                const new_init = try self.visitNode(self.readNodeIdx(me, ast_mod.PropertyExtra.init));

                if (deco_len > 0) {
                    const name_node_idx = try self.memberKeyToStringLiteral(new_key);
                    const decos = try self.collectStage3Decorators(deco_start, deco_len);
                    const var_n = extractCleanVarName(self, name_node_idx);
                    const deco_vname = try std.fmt.allocPrint(self.allocator, "_{s}_decorators", .{var_n});

                    if (is_static) has_static_decorators = true else has_instance_decorators = true;

                    const names = try self.buildFieldInitNames(name_node_idx);
                    const clean_name = names.clean_name;

                    try member_infos.append(self.allocator, .{
                        .kind = "accessor",
                        .name = name_node_idx,
                        .is_static = is_static,
                        .is_private = false,
                        .decorators = decos,
                        .initializers_name = names.init_name,
                        .extra_initializers_name = names.extra_name,
                        .deco_var_name = deco_vname,
                    });

                    // accessor → private backing field + getter + setter
                    const storage_name = try std.fmt.allocPrint(self.allocator, "#_{s}_accessor_storage", .{clean_name});
                    defer self.allocator.free(storage_name);
                    const storage_span = try self.ast.addString(storage_name);
                    const storage_key = try self.ast.addNode(.{
                        .tag = .private_identifier,
                        .span = storage_span,
                        .data = .{ .string_ref = storage_span },
                    });
                    // 초기값: TypeScript 패턴 — (runInit(this, _prevExtra), runInit(this, _x_initializers, val))
                    const init_val = blk: {
                        const init_call = if (!new_init.isNone()) init_blk: {
                            const this_node = try self.ast.addNode(.{
                                .tag = .this_expression,
                                .span = zero_span,
                                .data = .{ .none = 0 },
                            });
                            const callee = try makeIdentifier(self, "__runInitializers");
                            const init_arr_ref = try makeIdentifier(self, names.init_name);
                            const args = try self.ast.addNodeList(&.{ this_node, init_arr_ref, new_init });
                            break :init_blk try self.addExtraNode(.call_expression, zero_span, &.{
                                @intFromEnum(callee), args.start, args.len, 0,
                            });
                        } else NodeIndex.none;

                        // instance accessor만 initializer 체이닝 적용
                        if (!is_static) {
                            const prev_extra = last_instance_field_extra orelse "_instanceExtraInitializers";
                            last_instance_field_extra = names.extra_name;
                            break :blk try buildPiggybackedInitCall(self, prev_extra, init_call);
                        } else {
                            break :blk init_call;
                        }
                    };

                    const empty_decos = try self.ast.addNodeList(&.{});
                    const backing_field = try self.addExtraNode(.property_definition, member.span, &.{
                        @intFromEnum(storage_key),
                        @intFromEnum(init_val),
                        flags, // static 플래그 보존
                        empty_decos.start,
                        empty_decos.len,
                    });
                    try new_members.append(self.allocator, backing_field);

                    // get x() { return this.#_x_accessor_storage; }
                    // .private_field_expression 태그 필수 — .static_member_expression 으로 만들면
                    // transformer.zig:899 private field WeakMap dispatch 를 못 탐 (Stage 3 출력 재방문 경로에서만
                    // 우연히 동작하던 것을 안정화).
                    {
                        const return_expr = try makeThisPrivateField(self, storage_span);
                        const getter_key = try self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = self.ast.getNode(new_key).data.string_ref,
                            .data = .{ .string_ref = self.ast.getNode(new_key).data.string_ref },
                        });
                        const getter = try self.buildGetterMethod(getter_key, return_expr, is_static, zero_span);
                        try new_members.append(self.allocator, getter);
                    }

                    // set x(value) { this.#_x_accessor_storage = value; }
                    {
                        const setter_key = try self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = self.ast.getNode(new_key).data.string_ref,
                            .data = .{ .string_ref = self.ast.getNode(new_key).data.string_ref },
                        });
                        const assign_target = try makeThisPrivateField(self, storage_span);
                        const setter = try self.buildSetterMethod(setter_key, assign_target, is_static, zero_span);
                        try new_members.append(self.allocator, setter);
                    }
                } else {
                    // decorator 없는 accessor → 그대로 유지
                    const empty_list = try self.ast.addNodeList(&.{});
                    const new_acc = try self.addExtraNode(.accessor_property, member.span, &.{
                        @intFromEnum(new_key),
                        @intFromEnum(new_init),
                        flags,
                        empty_list.start,
                        empty_list.len,
                    });
                    try new_members.append(self.allocator, new_acc);
                }
            } else {
                // static_block 등 그대로 방문하여 추가
                const visited = try self.visitNode(member_idx);
                if (!visited.isNone()) {
                    try new_members.append(self.allocator, visited);
                }
            }
        }
    }

    // ---- IIFE 구조 생성 ----
    // 전체 출력:
    //   let Foo = (() => {
    //     let _classDecorators = [...]; ...
    //     var Foo = class [extends Super] { ... };
    //     return Foo = _classThis;
    //   })();

    // __esDecorate 호출 목록 (static {} 블록에 넣을 것)
    var static_block_stmts: std.ArrayList(NodeIndex) = .empty;
    defer static_block_stmts.deinit(self.allocator);

    // IIFE 내부 let 선언 목록
    var iife_stmts: std.ArrayList(NodeIndex) = .empty;
    defer iife_stmts.deinit(self.allocator);

    // _classThis 변수
    const classThis_span = try self.ast.addString("_classThis");

    // static { _classThis = this; }
    {
        const classThis_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = classThis_span,
            .data = .{ .string_ref = classThis_span },
        });
        const this_node = try self.ast.addNode(.{
            .tag = .this_expression,
            .span = zero_span,
            .data = .{ .none = 0 },
        });
        const assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = classThis_ref, .right = this_node, .flags = 0 } },
        });
        const assign_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
        const static_body_list = try self.ast.addNodeList(&.{assign_stmt});
        const static_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = zero_span,
            .data = .{ .list = static_body_list },
        });
        const static_block = try self.ast.addNode(.{
            .tag = .static_block,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = static_body, .flags = 0 } },
        });
        try new_members.insert(self.allocator, 0, static_block);
    }

    // _metadata 선언 + member __esDecorate 호출 + class __esDecorate 호출
    // → 2번째 static { } 블록에 모두 넣기

    // const _metadata = typeof Symbol === "function" && Symbol.metadata ? Object.create(null) : void 0;
    const metadata_decl = try self.buildMetadataDecl();
    try static_block_stmts.append(self.allocator, metadata_decl);

    // TC39 스펙 decorator 순서:
    // 1단계: 모든 member decorator 식을 **소스 순서**로 평가하여 변수에 저장
    // 2단계: __esDecorate를 **스펙 순서**로 호출
    //   (static non-field → instance non-field → static field → instance field)

    // 1단계: 소스 순서로 식 평가 → _name_decorators = [dec1, dec2];
    for (member_infos.items) |info| {
        if (info.deco_var_name) |vname| {
            const deco_list = try self.ast.addNodeList(info.decorators);
            const deco_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = zero_span,
                .data = .{ .list = deco_list },
            });
            const var_ref = try makeIdentifier(self, vname);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = zero_span,
                .data = .{ .binary = .{ .left = var_ref, .right = deco_arr, .flags = 0 } },
            });
            try static_block_stmts.append(self.allocator, try es_helpers.makeExprStmt(self, assign, zero_span));
        }
    }

    // 2단계: 스펙 순서로 __esDecorate 호출
    const is_non_field = struct {
        fn check(kind: []const u8) bool {
            return !std.mem.eql(u8, kind, "field");
        }
    }.check;
    // [is_static, is_non_field] — 4 pass: static non-field → instance non-field → static field → instance field
    const passes = [_][2]bool{ .{ true, true }, .{ false, true }, .{ true, false }, .{ false, false } };
    for (passes) |pass| {
        const want_static = pass[0];
        const want_non_field = pass[1];
        for (member_infos.items) |info| {
            if (info.is_static == want_static and is_non_field(info.kind) == want_non_field) {
                try self.appendEsDecorateStmt(&static_block_stmts, info);
            }
        }
    }

    // class decorator __esDecorate 호출 (식 평가는 이미 IIFE 최상단 let 선언에서 완료)
    if (class_deco_len > 0) {
        const class_call = try self.buildClassEsDecorateCall(classThis_span);
        const class_call_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = class_call, .flags = 0 } },
        });
        try static_block_stmts.append(self.allocator, class_call_stmt);

        // Foo = _classThis = _classDescriptor.value;
        const reassign = try self.buildClassReassign(class_name_text, classThis_span);
        try static_block_stmts.append(self.allocator, reassign);
    }

    // if (_metadata) Object.defineProperty(_classThis, Symbol.metadata, { enumerable: true, configurable: true, writable: true, value: _metadata });
    {
        const metadata_define = try self.buildMetadataDefineProperty(classThis_span);
        try static_block_stmts.append(self.allocator, metadata_define);
    }

    // __runInitializers(_classThis, _classExtraInitializers);
    if (class_deco_len > 0) {
        const run_init = try self.buildRunInitializersCall(classThis_span, "_classExtraInitializers");
        const run_init_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = run_init, .flags = 0 } },
        });
        try static_block_stmts.append(self.allocator, run_init_stmt);
    }

    // 2번째 static { } 블록 생성
    if (static_block_stmts.items.len > 0) {
        const sb_body_list = try self.ast.addNodeList(static_block_stmts.items);
        const sb_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = zero_span,
            .data = .{ .list = sb_body_list },
        });
        const sb = try self.ast.addNode(.{
            .tag = .static_block,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = sb_body, .flags = 0 } },
        });
        // 첫 static block 뒤에 삽입 (index 1)
        try new_members.insert(self.allocator, 1, sb);
    }

    // constructor에 __runInitializers 삽입
    // TypeScript 패턴:
    //   - field/accessor decorator 있을 때: constructor 앞에 마지막 field의 _extraInitializers 삽입
    //     (_instanceExtraInitializers는 첫 field 초기화에 piggyback됨)
    //   - field/accessor decorator 없을 때: constructor 앞에 _instanceExtraInitializers 삽입
    if (has_instance_decorators) {
        // constructor에 삽입할 initializer 이름 결정
        const ctor_init_name = last_instance_field_extra orelse "_instanceExtraInitializers";

        const this_node = try self.ast.addNode(.{
            .tag = .this_expression,
            .span = zero_span,
            .data = .{ .none = 0 },
        });
        const run_init = try self.buildRunInitializersCall2(this_node, ctor_init_name);
        const run_init_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = run_init, .flags = 0 } },
        });

        const has_super = !super_idx.isNone();

        if (has_constructor) {
            // new_members에서 constructor를 key 기반으로 탐색 (static block 삽입에 무관)
            for (new_members.items, 0..) |member_node_idx, mi| {
                const m = self.ast.getNode(member_node_idx);
                if (m.tag != .method_definition) continue;
                const m_flags = self.readU32(m.data.extra, ast_mod.MethodExtra.flags);
                // static/getter/setter 중 하나라도 있으면 skip (plain instance constructor 아님)
                const non_ctor_mask = ast_mod.MethodFlags.is_static | ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter;
                if ((m_flags & non_ctor_mask) != 0) continue;
                const m_key_idx = self.readNodeIdx(m.data.extra, 0);
                if (m_key_idx.isNone()) continue;
                const m_key = self.ast.getNode(m_key_idx);
                if (m_key.tag != .identifier_reference and m_key.tag != .binding_identifier) continue;
                if (!std.mem.eql(u8, self.ast.getText(m_key.data.string_ref), "constructor")) continue;

                const old_body_idx = self.readNodeIdx(m.data.extra, 2);
                const new_body_ctor = if (has_super)
                    try insertAfterSuperCall(self, old_body_idx, run_init_stmt)
                else
                    try self.prependStatementsToBody(old_body_idx, &.{run_init_stmt});
                const empty_decos = try self.ast.addNodeList(&.{});
                // method_definition: [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
                const new_ctor_method = try self.addExtraNode(.method_definition, m.span, &.{
                    self.readU32(m.data.extra, 0), // key
                    self.readU32(m.data.extra, 1), // params (formal_parameters idx)
                    @intFromEnum(new_body_ctor),
                    self.readU32(m.data.extra, 3), // flags
                    empty_decos.start,
                    empty_decos.len,
                });
                new_members.items[mi] = new_ctor_method;
                break;
            }
        } else {
            // 합성 constructor: derived면 `constructor(...args) { super(...args); __runInitializers(...); }`,
            // 아니면 `constructor() { __runInitializers(...); }`. super stmt는 scratch에 push, params는 반환.
            const stmts_scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(stmts_scratch_top);

            const ctor_params_node: NodeIndex = if (has_super) blk: {
                const shell = try buildSuperSpreadArgsShell(self);
                try self.scratch.append(self.allocator, shell.super_stmt);
                break :blk shell.params_node;
            } else blk: {
                const empty_params = try self.ast.addNodeList(&.{});
                break :blk try self.ast.addFormalParameters(empty_params, zero_span);
            };
            try self.scratch.append(self.allocator, run_init_stmt);

            const ctor_body_list = try self.ast.addNodeList(self.scratch.items[stmts_scratch_top..]);
            const ctor_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = zero_span,
                .data = .{ .list = ctor_body_list },
            });
            const ctor_key_span = try self.ast.addString("constructor");
            const ctor_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = ctor_key_span,
                .data = .{ .string_ref = ctor_key_span },
            });
            const empty_decos = try self.ast.addNodeList(&.{});
            const ctor_method = try self.addExtraNode(.method_definition, zero_span, &.{
                @intFromEnum(ctor_key),
                @intFromEnum(ctor_params_node),
                @intFromEnum(ctor_body),
                0, // flags (no static/getter/setter)
                empty_decos.start,
                empty_decos.len,
            });
            try new_members.append(self.allocator, ctor_method);
        }
    }

    // 새 class body 생성
    const new_body_list = try self.ast.addNodeList(new_members.items);
    const new_body = try self.ast.addNode(.{
        .tag = .class_body,
        .span = zero_span,
        .data = .{ .list = new_body_list },
    });

    // var Foo = class [extends Super] { ... } (decorator 없이, 이름 제거)
    // class body 내의 이름 바인딩은 const이므로, static { } 블록에서 Foo = ... 재대입이 불가.
    // TypeScript와 동일하게 class expression에 이름을 제거하여 외부 var Foo를 참조하게 한다.
    const new_super = try self.visitNode(super_idx);
    const empty_decos = try self.ast.addNodeList(&.{});
    const inner_class = try self.addExtraNode(.class_expression, node.span, &.{
        none,              @intFromEnum(new_super), @intFromEnum(new_body),
        none,              0,                       0,
        empty_decos.start, empty_decos.len,
    });

    // IIFE 내부: var Foo = class { ... };
    const inner_name_span = try self.ast.addString(class_name_text);
    const inner_binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = inner_name_span,
        .data = .{ .string_ref = inner_name_span },
    });
    const inner_declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(inner_binding), none, @intFromEnum(inner_class),
    });
    const inner_decl_list = try self.ast.addNodeList(&.{inner_declarator});
    const inner_var_decl = try self.addExtraNode(.variable_declaration, zero_span, &.{
        0, inner_decl_list.start, inner_decl_list.len, // 0 = var
    });
    try iife_stmts.append(self.allocator, inner_var_decl);

    // return Foo = _classThis;
    const return_name = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = inner_name_span,
        .data = .{ .string_ref = inner_name_span },
    });
    const classThis_ref2 = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = classThis_span,
        .data = .{ .string_ref = classThis_span },
    });
    const return_assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = return_name, .right = classThis_ref2, .flags = 0 } },
    });
    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = return_assign, .flags = 0 } },
    });
    try iife_stmts.append(self.allocator, return_stmt);

    // IIFE body: { let _classDecorators = ...; ... var Foo = class { ... }; return ...; }
    // let 선언들을 iife_stmts 앞에 삽입
    var all_iife_stmts: std.ArrayList(NodeIndex) = .empty;
    defer all_iife_stmts.deinit(self.allocator);

    // let 선언 생성
    const let_decls = try self.buildStage3LetDeclarations(
        class_deco_start,
        class_deco_len,
        member_infos.items,
        has_instance_decorators,
        has_static_decorators,
    );
    try all_iife_stmts.appendSlice(self.allocator, let_decls);
    self.allocator.free(let_decls);

    // var Foo = class { ... }; + return ...;
    try all_iife_stmts.appendSlice(self.allocator, iife_stmts.items);

    const iife_body_list = try self.ast.addNodeList(all_iife_stmts.items);
    const iife_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = iife_body_list },
    });

    // () => { ... }
    // arrow_function_expression: extra = [params(0), body(1), flags]
    // params = .none → codegen이 "()" 출력
    const arrow = try self.addExtraNode(.arrow_function_expression, zero_span, &.{
        none, // params = .none (빈 파라미터)
        @intFromEnum(iife_body),
        0, // flags (not async)
    });

    // (() => { ... })()
    const paren_arrow = try self.ast.addNode(.{
        .tag = .parenthesized_expression,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = arrow, .flags = 0 } },
    });
    const empty_args = try self.ast.addNodeList(&.{});
    const iife_call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(paren_arrow), empty_args.start, empty_args.len, 0,
    });

    // class expression / 익명 class / export default class → IIFE call 직접 반환
    // 이름 있는 class declaration만 `let Foo = (...)` 선언을 사용.
    // - class_expression: 표현식 위치에서 사용
    // - name_idx.isNone(): 익명 class (export default class {} 등)
    // - name == "default": export default class (JS 예약어)
    const has_named_binding = if (!name_idx.isNone()) blk: {
        break :blk !std.mem.eql(u8, self.ast.getText(self.ast.getNode(name_idx).data.string_ref), "default");
    } else false;

    if (node.tag == .class_expression or !has_named_binding) {
        return iife_call;
    }

    // class declaration → let Foo = (() => { ... })();
    // "default" 이름은 IIFE 내부 var에서 사용한 temp var name을 재사용
    const outer_name_span = try self.ast.addString(class_name_text);

    const outer_binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = outer_name_span,
        .data = .{ .string_ref = outer_name_span },
    });
    const outer_declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(outer_binding), none, @intFromEnum(iife_call),
    });
    const outer_decl_list = try self.ast.addNodeList(&.{outer_declarator});
    const outer_var_decl = try self.addExtraNode(.variable_declaration, zero_span, &.{
        1, outer_decl_list.start, outer_decl_list.len, // 1 = let
    });

    // pending_nodes로 hoist한 뒤 `.none` 반환 — export 컨텍스트에서
    // `export default Named;` / `export { Named };`로 분리되는 pattern을 유지한다.
    // ES5 target은 outer_var_decl 내부의 arrow/let/class/static block을 추가 다운레벨링하기
    // 위해 pending에 push하기 전에 visitNode로 재방문한다.
    const to_hoist = if (self.options.unsupported.class)
        try self.visitNode(outer_var_decl)
    else
        outer_var_decl;
    if (!to_hoist.isNone()) {
        try self.pending_nodes.append(self.allocator, to_hoist);
    }
    return .none;
}

/// field/accessor 초기화에 이전 extra initializers를 piggyback하는 sequence expression 생성.
/// TypeScript 패턴: `(__runInitializers(this, _prevExtra), __runInitializers(this, _x_initializers, val))`
/// init_call이 .none이면 prevCall만 반환 (초기값 없는 accessor).
fn buildPiggybackedInitCall(self: *Transformer, prev_extra_name: []const u8, init_call: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const prev_this = try self.ast.addNode(.{
        .tag = .this_expression,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const prev_callee = try makeIdentifier(self, "__runInitializers");
    const prev_arr = try makeIdentifier(self, prev_extra_name);
    const prev_args = try self.ast.addNodeList(&.{ prev_this, prev_arr });
    const prev_call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(prev_callee), prev_args.start, prev_args.len, 0,
    });
    if (!init_call.isNone()) {
        const seq_list = try self.ast.addNodeList(&.{ prev_call, init_call });
        const seq = try self.ast.addNode(.{
            .tag = .sequence_expression,
            .span = zero_span,
            .data = .{ .list = seq_list },
        });
        return es_helpers.makeParenExpr(self, seq, zero_span);
    } else {
        return prev_call;
    }
}

/// #1587: class_expression의 name이 body 내부 self-reference 없이 선언된 경우 true.
/// - `minify_syntax` + `!keep_names` + class_expression + name 존재 + reference_count == 0 필요.
/// - #1592로 ClassExpression name이 class body scope 심볼로 등록되므로 body 내부 참조만
///   reference_count에 누적됨. ClassDeclaration name은 외부 scope에 등록되어 내부 사용이
///   여전히 count되므로 본 predicate는 항상 false를 반환.
fn shouldDropClassExprName(self: *Transformer, tag: Tag, name_idx: NodeIndex) bool {
    if (!self.options.minify_syntax) return false;
    if (self.options.keep_names) return false;
    if (tag != .class_expression) return false;
    if (name_idx.isNone()) return false;
    const node_i = @intFromEnum(name_idx);
    if (node_i >= self.symbol_ids.items.len) return false;
    const sym_id = self.symbol_ids.items[node_i] orelse return false;
    if (sym_id >= self.symbols.len) return false;
    return self.symbols[sym_id].reference_count == 0;
}
