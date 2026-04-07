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
    const e = node.data.extra;

    // Fast path: useDefineForClassFields=true AND !experimentalDecorators → 기존 동작
    // 멤버별 분류가 불필요하므로 body를 통째로 방문한다.
    if (self.options.use_define_for_class_fields and !self.options.experimental_decorators) {
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_super = try self.visitNode(self.readNodeIdx(e, 1));

        var current_body_idx = self.readNodeIdx(e, 2);

        // ES2022 다운레벨링: private method → WeakSet + standalone function
        var pm_pre_stmts: std.ArrayList(NodeIndex) = .empty;
        defer pm_pre_stmts.deinit(self.allocator);
        var pm_ctor_stmts: std.ArrayList(NodeIndex) = .empty;
        defer pm_ctor_stmts.deinit(self.allocator);
        var pm_mappings: std.ArrayList(PrivateMethodMapping) = .empty;
        defer {
            for (pm_mappings.items) |pm| {
                self.allocator.free(pm.weakset_name);
                self.allocator.free(pm.func_name);
            }
            pm_mappings.deinit(self.allocator);
        }

        var had_private_methods = false;
        if (self.options.unsupported.class_private_method) {
            var pm_body: NodeIndex = .none;

            // private method 변환 중 current_private_methods 설정
            // (body 내부의 this.#method() 호출이 변환되도록)
            const has_super = !self.readNodeIdx(e, 1).isNone();
            had_private_methods = try es2022.ES2022(Transformer).lowerPrivateMethods(
                self,
                current_body_idx,
                &pm_body,
                &pm_pre_stmts,
                &pm_ctor_stmts,
                &pm_mappings,
                has_super,
            );

            if (had_private_methods) {
                current_body_idx = pm_body;
                // lowerPrivateMethods가 내부적으로 current_private_methods를 설정/해제하므로
                // 여기서는 body가 이미 변환된 상태. 추가 설정 불필요.
            }
        }

        // ES2022 다운레벨링: static block → IIFE (target < es2022)
        // had_private_methods가 true이면 lowerPrivateMethods가 이미 body를
        // 이미 변환했으므로, lowerStaticBlocks(파서 노드 기반)를 건너뛴다.
        // lowerPrivateMethods 내의 visitNode가 static block도 이미 처리.
        if (self.options.unsupported.class_static_block and !had_private_methods) {
            var new_body: NodeIndex = .none;
            var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
            defer static_block_iifes.deinit(self.allocator);

            // 클래스 이름 추출 → static block 안의 this 치환에 사용.
            const class_name_span = self.getClassNameSpan(new_name);

            const had_static_blocks = try es2022.ES2022(Transformer).lowerStaticBlocks(
                self,
                current_body_idx,
                &new_body,
                &static_block_iifes,
                class_name_span,
            );

            if (had_static_blocks) {
                current_body_idx = new_body;

                const new_decos = try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7));
                const none = @intFromEnum(NodeIndex.none);
                const class_result = try self.addExtraNode(node.tag, node.span, &.{
                    @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(current_body_idx),
                    none,                   0,                       0,
                    new_decos.start,        new_decos.len,
                });

                // pre_stmts (WeakSet + function) → class → static block IIFE
                for (pm_pre_stmts.items) |stmt| {
                    try self.pending_nodes.append(self.allocator, stmt);
                }
                try self.pending_nodes.append(self.allocator, class_result);
                for (static_block_iifes.items) |iife| {
                    try self.pending_nodes.append(self.allocator, iife);
                }
                return .none;
            }
        }

        // private method만 있고 static block은 없는 경우
        if (had_private_methods) {
            const new_decos = try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7));
            const none = @intFromEnum(NodeIndex.none);
            const class_result = try self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(current_body_idx),
                none,                   0,                       0,
                new_decos.start,        new_decos.len,
            });

            for (pm_pre_stmts.items) |stmt| {
                try self.pending_nodes.append(self.allocator, stmt);
            }
            try self.pending_nodes.append(self.allocator, class_result);
            return .none;
        }

        const new_body = try self.visitNode(current_body_idx);
        const new_decos = try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7));
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

/// useDefineForClassFields=false / experimentalDecorators 처리.
/// 멤버를 개별 분류하여 instance field를 constructor로 이동하고,
/// experimental decorator를 __decorateClass 호출로 변환한다.
pub fn visitClassWithAssignSemantics(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const has_super = !self.readNodeIdx(e, 1).isNone();
    const new_name = try self.visitNode(self.readNodeIdx(e, 0));
    const new_super = try self.visitNode(self.readNodeIdx(e, 1));

    // 원본 class_body를 직접 순회
    const body_idx = self.readNodeIdx(e, 2);
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
    var ctor_params_start: u32 = 0;
    var ctor_params_len: u32 = 0;

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
        .ctor_params_start = &ctor_params_start,
        .ctor_params_len = &ctor_params_len,
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

    // experimentalDecorators — decorator를 class에서 제거하고 __decorateClass 호출 생성
    if (self.options.experimental_decorators) {
        const old_deco_start = self.readU32(e, 6);
        const old_deco_len = self.readU32(e, 7);

        if (old_deco_len > 0 or member_decorators.items.len > 0 or ctor_param_decos.items.len > 0) {
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
                ctor_params_start,
                ctor_params_len,
            );
        }
    }

    // decorator 리스트 복사 (experimental이 아닌 경우)
    const new_decos = if (!self.options.experimental_decorators)
        try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7))
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

/// ClassName.key = value; 할당문을 생성한다.
pub fn buildStaticFieldAssignment(self: *Transformer, class_name: NodeIndex, field: FieldAssignment) Error!NodeIndex {
    // ClassName
    const name_node = self.ast.getNode(class_name);
    const cls_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = name_node.span,
        .data = .{ .string_ref = name_node.span },
    });
    const member = if (field.is_computed) blk: {
        // computed: ClassName[key]
        const me_extra = try self.ast.addExtras(&.{
            @intFromEnum(cls_ref),
            @intFromEnum(field.key),
            0,
        });
        break :blk try self.ast.addNode(.{
            .tag = .computed_member_expression,
            .span = field.span,
            .data = .{ .extra = me_extra },
        });
    } else blk: {
        break :blk try es_helpers.makeStaticMember(self, cls_ref, field.key, field.span);
    };
    // ClassName.key = value
    const assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = field.span,
        .data = .{ .binary = .{ .left = member, .right = field.value, .flags = 0 } },
    });
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = field.span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
}

/// 단일 클래스 멤버를 분류하여 적절한 목록에 추가한다.
/// - property_definition: assign semantics 대상이면 field_assignments에, 아니면 class_members에
/// - method_definition: constructor면 기록, 일반 메서드면 class_members에
/// - 기타: class_members에 그대로 추가
/// visitClassWithAssignSemantics에서 멤버 분류에 사용되는 컨텍스트.
/// 6개 포인터 파라미터를 하나로 묶어 함수 시그니처를 단순화.
pub const ClassMemberContext = struct {
    class_members: *std.ArrayList(NodeIndex),
    field_assignments: *std.ArrayList(FieldAssignment),
    member_decorators: *std.ArrayList(MemberDecoratorInfo),
    existing_constructor: *?NodeIndex,
    existing_constructor_pos: *?usize,
    /// ES2022 다운레벨링: static block → IIFE (target < es2022 일 때 사용)
    static_block_iifes: ?*std.ArrayList(NodeIndex) = null,
    /// ES2022 static block 안의 this → 클래스 이름 치환에 사용
    class_name_span: ?Span = null,
    /// useDefineForClassFields=false: static field → class 밖 할당문
    static_field_assignments: ?*std.ArrayList(FieldAssignment) = null,
    /// constructor parameter decorator → class-level __decorateClass에 포함
    ctor_param_decos: *std.ArrayList(NodeIndex),
    /// super class가 있으면 field initializer visit 시 this → _this 치환
    has_super: bool = false,
    /// emitDecoratorMetadata: constructor 파라미터 위치 (원본 AST에서 수집)
    ctor_params_start: *u32 = undefined,
    ctor_params_len: *u32 = undefined,
};

pub fn classifyClassMember(
    self: *Transformer,
    raw_idx: u32,
    ctx: *ClassMemberContext,
) Error!void {
    const member_idx: NodeIndex = @enumFromInt(raw_idx);
    if (member_idx.isNone()) return;
    const member = self.ast.getNode(member_idx);

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    if (member.tag == .property_definition) {
        try self.classifyPropertyDefinition(raw_idx, member, ctx);
        return;
    }

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    if (member.tag == .method_definition) {
        try self.classifyMethodDefinition(member, ctx);
        return;
    }

    // ES2022 다운레벨링: static block → IIFE (target < es2022)
    if (member.tag == .static_block and ctx.static_block_iifes != null) {
        const iife = try es2022.ES2022(Transformer).buildStaticBlockIIFE(self, member, ctx.class_name_span);
        try ctx.static_block_iifes.?.append(self.allocator, iife);
        return;
    }

    // 기타 멤버 (static_block, accessor_property 등): 그대로 방문
    const new_member = try self.visitNode(@enumFromInt(raw_idx));
    if (!new_member.isNone()) {
        try ctx.class_members.append(self.allocator, new_member);
    }
}

/// property_definition 멤버를 분류한다.
/// - abstract/declare → 스트리핑 (스킵)
/// - experimental decorators → member_decorators에 수집
/// - assign semantics (non-static, non-abstract, non-declare, 초기화 있음) → field_assignments에
/// - 나머지 → class_members에 그대로 방문
pub fn classifyPropertyDefinition(
    self: *Transformer,
    raw_idx: u32,
    member: Node,
    ctx: *ClassMemberContext,
) Error!void {
    const class_members = ctx.class_members;
    const field_assignments = ctx.field_assignments;
    const member_decorators = ctx.member_decorators;
    const me = member.data.extra;
    const flags = self.readU32(me, 2);
    const is_static = (flags & 0x01) != 0;
    const is_abstract = (flags & 0x20) != 0;
    const is_declare = (flags & 0x40) != 0;

    // abstract(0x20), declare(0x40), Flow variance(0x80)는 타입 전용 → 스트리핑
    if (self.options.strip_types and (flags & 0xE0) != 0) {
        return;
    }

    // decorator 수집 (experimental decorators — 경로와 무관하게 한 번만)
    if (self.options.experimental_decorators) {
        const deco_start = self.readU32(me, 3);
        const deco_len = self.readU32(me, 4);
        if (deco_len > 0) {
            const new_key = try self.visitNode(self.readNodeIdx(me, 0));
            try self.collectMemberDecorators(member_decorators, deco_start, deco_len, 0, 0, new_key, is_static, 2, 0, 0);
        }
    }

    // useDefineForClassFields=false: non-static instance field를 constructor로 이동
    if (!self.options.use_define_for_class_fields and !is_static and !is_abstract and !is_declare) {
        const key_idx = self.readNodeIdx(me, 0);
        const init_idx = self.readNodeIdx(me, 1);
        if (!init_idx.isNone()) {
            const new_key = try self.visitNode(key_idx);
            // super class가 있으면 field value의 this → _this 치환
            const saved_super_alias = self.super_call_this_alias;
            if (ctx.has_super) self.super_call_this_alias = true;
            defer self.super_call_this_alias = saved_super_alias;
            const new_init = try self.visitNode(init_idx);
            const key_node = self.ast.getNode(key_idx);
            const is_computed = (key_node.tag == .computed_property_key);
            try field_assignments.append(self.allocator, .{
                .key = new_key,
                .value = new_init,
                .is_computed = is_computed,
                .span = member.span,
            });
        }
        return;
    }

    // useDefineForClassFields=false + static field
    if (!self.options.use_define_for_class_fields and is_static) {
        const key_idx = self.readNodeIdx(me, 0);
        const init_idx = self.readNodeIdx(me, 1);
        if (init_idx.isNone()) return; // 초기값 없음 → 타입 선언만, 제거
        // 초기값 있음 → class 밖 할당문으로 이동 (Foo.z = 2)
        if (ctx.static_field_assignments) |sfa| {
            const new_key = try self.visitNode(key_idx);
            const new_init = try self.visitNode(init_idx);
            const key_node = self.ast.getNode(key_idx);
            try sfa.append(self.allocator, .{
                .key = new_key,
                .value = new_init,
                .is_computed = (key_node.tag == .computed_property_key),
                .span = member.span,
            });
            return;
        }
        // static_field_assignments가 없으면 (use_define_for_class_fields=true) 그대로 유지
    }

    // 그 외: 그대로 방문
    const new_member = try self.visitNode(@enumFromInt(raw_idx));
    if (!new_member.isNone()) {
        try class_members.append(self.allocator, new_member);
    }
}

/// method_definition 멤버를 분류한다.
/// - constructor → existing_constructor/existing_constructor_pos에 기록
/// - experimental decorators가 있는 일반 메서드 → member_decorators에 수집
/// - 나머지 → class_members에 추가
pub fn classifyMethodDefinition(
    self: *Transformer,
    member: Node,
    ctx: *ClassMemberContext,
) Error!void {
    const class_members = ctx.class_members;
    const member_decorators = ctx.member_decorators;
    const me = member.data.extra;
    const flags = self.readU32(me, 4);
    const is_static = (flags & 0x01) != 0;

    // constructor 감지
    const is_ctor = if (!is_static) blk: {
        const key_idx = self.readNodeIdx(me, 0);
        const key_node = self.ast.getNode(key_idx);
        if (key_node.tag == .identifier_reference) {
            const name = self.ast.source[key_node.span.start..key_node.span.end];
            break :blk std.mem.eql(u8, name, "constructor");
        }
        break :blk false;
    } else false;

    if (is_ctor) {
        // constructor parameter decorator → class-level __decorateClass에 포함
        if (self.options.experimental_decorators) {
            const params_start = self.readU32(me, 1);
            const params_len = self.readU32(me, 2);
            try self.collectParamDecorators(ctx.ctor_param_decos, params_start, params_len);
            // emitDecoratorMetadata: 원본 AST에서 constructor 파라미터 위치 저장
            ctx.ctor_params_start.* = params_start;
            ctx.ctor_params_len.* = params_len;
        }

        const new_member = try self.visitMethodDefinition(member);
        if (!new_member.isNone()) {
            ctx.existing_constructor.* = new_member;
            ctx.existing_constructor_pos.* = class_members.items.len;
            try class_members.append(self.allocator, new_member);
        }
        return;
    }

    // 일반 메서드: member decorator + parameter decorator 수집 (single-pass)
    if (self.options.experimental_decorators) {
        const deco_start = self.readU32(me, 5);
        const deco_len = self.readU32(me, 6);
        const params_start = self.readU32(me, 1);
        const params_len = self.readU32(me, 2);
        if (deco_len > 0 or params_len > 0) {
            const new_key = try self.visitNode(self.readNodeIdx(me, 0));
            try self.collectMemberDecorators(
                member_decorators,
                deco_start,
                deco_len,
                params_start,
                params_len,
                new_key,
                is_static,
                1,
                params_start,
                params_len,
            );
        }
    }

    const new_member = try self.visitMethodDefinition(member);
    if (!new_member.isNone()) {
        try class_members.append(self.allocator, new_member);
    }
}

/// 수집된 field assignments를 constructor에 삽입한다.
/// 기존 constructor가 있으면 body에 삽입하고, 없으면 새로 생성한다.
pub fn applyFieldAssignments(
    self: *Transformer,
    class_members: *std.ArrayList(NodeIndex),
    fields: []const FieldAssignment,
    existing_constructor: ?NodeIndex,
    existing_constructor_pos: ?usize,
    has_super: bool,
) Error!void {
    if (existing_constructor) |ctor_idx| {
        // 기존 constructor의 body에 field assignments 삽입
        const updated_ctor = try self.insertFieldAssignmentsIntoConstructor(ctor_idx, fields, has_super);
        // position으로 직접 교체 (선형 검색 불필요)
        if (existing_constructor_pos) |pos| {
            class_members.items[pos] = updated_ctor;
        }
    } else {
        // constructor가 없으면 새로 생성
        const new_ctor = try self.buildConstructorWithFieldAssignments(fields, has_super);
        // class body 맨 앞에 삽입
        try class_members.insert(self.allocator, 0, new_ctor);
    }
}

/// useDefineForClassFields=false: instance field → constructor this.x = value 정보
pub const FieldAssignment = struct {
    key: NodeIndex,
    value: NodeIndex,
    is_computed: bool,
    span: Span,
};

/// experimentalDecorators: member decorator 정보
pub const MemberDecoratorInfo = struct {
    /// decorator expression들 (new AST)
    decorators: []NodeIndex,
    /// member key (new AST)
    key: NodeIndex,
    /// static 여부
    is_static: bool,
    /// descriptor 종류: 1=method, 2=property
    kind: u32,
    /// emitDecoratorMetadata: 원본 AST 파라미터 위치
    params_start: u32 = 0,
    params_len: u32 = 0,
};

/// decorator 노드에서 expression 부분을 visit하여 반환.
/// decorator 태그이면 operand(expression)를, 아니면 노드 자체를 visit.
pub fn visitDecoratorExpression(self: *Transformer, raw_idx: u32) Error!NodeIndex {
    const deco_idx: NodeIndex = @enumFromInt(raw_idx);
    if (deco_idx.isNone()) return .none;
    const deco_node = self.ast.getNode(deco_idx);
    return if (deco_node.tag == .decorator)
        self.visitNode(deco_node.data.unary.operand)
    else
        self.visitNode(@enumFromInt(raw_idx));
}

/// experimentalDecorators: member/parameter decorator를 수집하여 MemberDecoratorInfo에 저장.
/// parameter decorator는 __decorateParam(index, dec) 호출 노드로 래핑.
/// params_start/params_len이 0이면 parameter decorator 수집을 건너뜀.
pub fn collectMemberDecorators(
    self: *Transformer,
    list: *std.ArrayList(MemberDecoratorInfo),
    deco_start: u32,
    deco_len: u32,
    params_start: u32,
    params_len: u32,
    key: NodeIndex,
    is_static: bool,
    kind: u32,
    orig_params_start: u32,
    orig_params_len: u32,
) Error!void {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // 1) parameter decorator → __decorateParam(index, dec)
    if (params_len > 0) {
        try self.appendParamDecorators(&self.scratch, params_start, params_len);
    }

    // 2) member decorator (method/property 자체에 붙은 decorator)
    if (deco_len > 0) {
        var deco_i: u32 = 0;
        while (deco_i < deco_len) : (deco_i += 1) {
            const raw_idx = self.ast.extra_data.items[deco_start + deco_i];
            try self.scratch.append(self.allocator, try self.visitDecoratorExpression(raw_idx));
        }
    }

    const collected = self.scratch.items[scratch_top..];
    if (collected.len == 0) return;

    const deco_nodes = try self.allocator.alloc(NodeIndex, collected.len);
    @memcpy(deco_nodes, collected);

    try list.append(self.allocator, .{
        .decorators = deco_nodes,
        .key = key,
        .is_static = is_static,
        .kind = kind,
        .params_start = orig_params_start,
        .params_len = orig_params_len,
    });
}

/// __decorateParam(index, decorator) 호출 expression 노드 생성
/// constructor의 parameter decorator만 수집하여 __decorateParam 노드 리스트에 추가.
/// collectMemberDecorators의 param 수집 부분과 동일한 appendParamDecorators를 사용.
pub fn collectParamDecorators(
    self: *Transformer,
    list: *std.ArrayList(NodeIndex),
    params_start: u32,
    params_len: u32,
) Error!void {
    try self.appendParamDecorators(list, params_start, params_len);
}

/// parameter decorator를 __decorateParam(index, dec) 형태로 변환하여 list에 추가.
/// collectMemberDecorators와 collectParamDecorators 양쪽에서 사용.
pub fn appendParamDecorators(
    self: *Transformer,
    list: anytype,
    params_start: u32,
    params_len: u32,
) Error!void {
    const zero_span = Span{ .start = 0, .end = 0 };
    var param_i: u32 = 0;
    while (param_i < params_len) : (param_i += 1) {
        const raw_idx = self.ast.extra_data.items[params_start + param_i];
        const p_idx: NodeIndex = @enumFromInt(raw_idx);
        if (p_idx.isNone()) continue;
        const param = self.ast.getNode(p_idx);
        if (param.tag != .formal_parameter) continue;
        const pe = param.data.extra;
        const pdeco_start = self.ast.extra_data.items[pe + 4];
        const pdeco_len = self.ast.extra_data.items[pe + 5];
        if (pdeco_len == 0) continue;

        var pdeco_i: u32 = 0;
        while (pdeco_i < pdeco_len) : (pdeco_i += 1) {
            const deco_raw_idx = self.ast.extra_data.items[pdeco_start + pdeco_i];
            const dec_expr = try self.visitDecoratorExpression(deco_raw_idx);
            const param_deco = try self.buildDecorateParamCall(param_i, dec_expr, zero_span);
            try list.append(self.allocator, param_deco);
        }
    }
}

pub fn buildDecorateParamCall(
    self: *Transformer,
    param_index: usize,
    dec_expr: NodeIndex,
    span: Span,
) Error!NodeIndex {
    // callee: __decorateParam
    const callee_span = try self.ast.addString("__decorateParam");
    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = callee_span,
        .data = .{ .string_ref = callee_span },
    });

    // arg1: index (numeric literal)
    var index_buf: [10]u8 = undefined;
    const index_text = std.fmt.bufPrint(&index_buf, "{d}", .{param_index}) catch "0";
    const index_span = try self.ast.addString(index_text);
    const index_node = try self.ast.addNode(.{
        .tag = .numeric_literal,
        .span = index_span,
        .data = .{ .number_bytes = @bitCast(@as(f64, @floatFromInt(param_index))) },
    });

    // arg2: decorator expression
    const args = try self.ast.addNodeList(&.{ index_node, dec_expr });
    return self.addExtraNode(.call_expression, span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
}

/// useDefineForClassFields=false: 기존 constructor body에 field assignments 삽입.
/// super()가 있으면 그 뒤에, 없으면 body 맨 앞에 삽입.
pub fn insertFieldAssignmentsIntoConstructor(
    self: *Transformer,
    ctor_idx: NodeIndex,
    fields: []const FieldAssignment,
    has_super: bool,
) Error!NodeIndex {
    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    const ctor_node = self.ast.getNode(ctor_idx);
    const ce = ctor_node.data.extra;
    // extra_data에서 값만 미리 복사 (이후 AST 변형으로 슬라이스가 무효화될 수 있음)
    const ctor_e0 = self.ast.extra_data.items[ce];
    const ctor_e1 = self.ast.extra_data.items[ce + 1];
    const ctor_e2 = self.ast.extra_data.items[ce + 2];
    const ctor_e3 = self.ast.extra_data.items[ce + 3];
    const ctor_e4 = self.ast.extra_data.items[ce + 4];
    const ctor_e5 = self.ast.extra_data.items[ce + 5];
    const ctor_e6 = self.ast.extra_data.items[ce + 6];
    const body_idx: NodeIndex = @enumFromInt(ctor_e3);

    if (body_idx.isNone()) return ctor_idx;

    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) return ctor_idx;

    const old_list = body.data.list;
    const old_stmts_start = old_list.start;
    const old_stmts_len = old_list.len;

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // super() 호출을 찾아서 그 뒤에 삽입
    // isSuperCallStatement는 읽기만 하므로 슬라이스 안전
    var insert_pos: u32 = 0;
    if (has_super) {
        const old_stmts = self.ast.extra_data.items[old_stmts_start .. old_stmts_start + old_stmts_len];
        for (old_stmts, 0..) |raw_idx, idx| {
            if (self.isSuperCallStatement(@enumFromInt(raw_idx))) {
                insert_pos = @intCast(idx + 1);
                break;
            }
        }
    }

    // insert_pos 전의 문장들 (읽기만, AST 변형 없음)
    {
        var i_pre: u32 = 0;
        while (i_pre < insert_pos) : (i_pre += 1) {
            const raw_idx = self.ast.extra_data.items[old_stmts_start + i_pre];
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }
    }

    // field assignments 삽입 (buildThisAssignment가 AST를 변형)
    for (fields) |field| {
        const assign_stmt = try self.buildThisAssignment(field);
        try self.scratch.append(self.allocator, assign_stmt);
    }

    // insert_pos 후의 문장들 (buildThisAssignment 이후이므로 인덱스로 접근)
    {
        var i_post: u32 = insert_pos;
        while (i_post < old_stmts_len) : (i_post += 1) {
            const raw_idx = self.ast.extra_data.items[old_stmts_start + i_post];
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const new_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = body.span,
        .data = .{ .list = new_list },
    });

    // constructor method_definition을 새 body로 재생성
    return self.addExtraNode(.method_definition, ctor_node.span, &.{
        ctor_e0,                ctor_e1, ctor_e2,
        @intFromEnum(new_body), ctor_e4, ctor_e5,
        ctor_e6,
    });
}

/// super() 호출 expression_statement인지 판별
pub fn isSuperCallStatement(self: *const Transformer, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const stmt = self.ast.getNode(idx);
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone()) return false;
    const expr = self.ast.getNode(expr_idx);
    if (expr.tag != .call_expression) return false;
    // call_expression: extra = [callee, args_start, args_len, flags]
    const ce = expr.data.extra;
    if (ce >= self.ast.extra_data.items.len) return false;
    const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
    if (callee_idx.isNone()) return false;
    const callee = self.ast.getNode(callee_idx);
    return callee.tag == .super_expression;
}

/// useDefineForClassFields=false: constructor가 없을 때 새로 생성.
/// extends가 있으면 super(...args) 호출 포함.
pub fn buildConstructorWithFieldAssignments(
    self: *Transformer,
    fields: []const FieldAssignment,
    has_super: bool,
) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var params_list = NodeList{ .start = 0, .len = 0 };

    // extends가 있으면: constructor(...args) { super(...args); this.x = v; }
    if (has_super) {
        // ...args 파라미터
        const args_span = try self.ast.addString("args");
        const args_id = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = args_span,
            .data = .{ .string_ref = args_span },
        });
        const rest = try self.ast.addNode(.{
            .tag = .rest_element,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = args_id, .flags = 0 } },
        });
        params_list = try self.ast.addNodeList(&.{rest});

        // super(...args) 호출
        const super_expr = try self.ast.addNode(.{
            .tag = .super_expression,
            .span = zero_span,
            .data = .{ .none = 0 },
        });
        const args_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = args_span,
            .data = .{ .string_ref = args_span },
        });
        const spread_args = try self.ast.addNode(.{
            .tag = .spread_element,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = args_ref, .flags = 0 } },
        });
        const call_args = try self.ast.addNodeList(&.{spread_args});
        const super_call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(super_expr), call_args.start, call_args.len, 0,
        });
        const super_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = super_call, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, super_stmt);
    }

    // this.x = value 할당들
    for (fields) |field| {
        const stmt = try self.buildThisAssignment(field);
        try self.scratch.append(self.allocator, stmt);
    }

    const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = body_list },
    });

    // constructor key
    const ctor_span = try self.ast.addString("constructor");
    const ctor_key = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = ctor_span,
        .data = .{ .string_ref = ctor_span },
    });

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    const empty_decos = try self.ast.addNodeList(&.{});
    return self.addExtraNode(.method_definition, zero_span, &.{
        @intFromEnum(ctor_key), params_list.start, params_list.len,
        @intFromEnum(body), 0, // flags=0 (non-static, normal method)
        empty_decos.start,  empty_decos.len,
    });
}

/// this.key = value; expression statement 생성
pub fn buildThisAssignment(self: *Transformer, field: FieldAssignment) Error!NodeIndex {
    const this_node = try self.ast.addNode(.{
        .tag = .this_expression,
        .span = field.span,
        .data = .{ .none = 0 },
    });

    // computed key 또는 string/numeric literal key: this[key] = value
    // 일반 identifier key: this.key = value
    // string literal ("foo")이나 numeric literal (0)은 dot notation 불가 → bracket notation
    const key_node = self.ast.getNode(field.key);
    const needs_bracket = field.is_computed or key_node.tag == .string_literal or key_node.tag == .numeric_literal;
    const member = if (needs_bracket) blk: {
        // computed_property_key의 내부 expression을 꺼냄
        const actual_key = if (key_node.tag == .computed_property_key) key_node.data.unary.operand else field.key;
        const member_extra = try self.ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(actual_key), 0 });
        break :blk try self.ast.addNode(.{
            .tag = .computed_member_expression,
            .span = field.span,
            .data = .{ .extra = member_extra },
        });
    } else blk: {
        const member_extra = try self.ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(field.key), 0 });
        break :blk try self.ast.addNode(.{
            .tag = .static_member_expression,
            .span = field.span,
            .data = .{ .extra = member_extra },
        });
    };

    const assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = field.span,
        .data = .{ .binary = .{ .left = member, .right = field.value, .flags = 0 } },
    });
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = field.span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
}

/// experimentalDecorators: class/member decorator를 __decorateClass 호출로 변환.
///
/// 입력: @sealed class Foo { @log method() {} }
/// 출력:
///   let Foo = class Foo {};
///   __decorateClass([log], Foo.prototype, "method", 1);
///   Foo = __decorateClass([sealed], Foo);
pub fn transformExperimentalDecorators(
    self: *Transformer,
    node: Node,
    new_name: NodeIndex,
    name_old_idx: NodeIndex,
    new_super: NodeIndex,
    new_body: NodeIndex,
    old_deco_start: u32,
    old_deco_len: u32,
    member_decos: []const MemberDecoratorInfo,
    static_block_iifes: []const NodeIndex,
    static_field_assigns: []const FieldAssignment,
    ctor_param_decos: []const NodeIndex,
    ctor_params_start: u32,
    ctor_params_len: u32,
) Error!NodeIndex {
    const none = @intFromEnum(NodeIndex.none);
    const decorate_span = try self.ast.addString("__decorateClass");

    // class 이름 텍스트를 가져옴 (let Foo = class Foo {} 에 필요)
    const class_name_text = if (!new_name.isNone()) blk: {
        const name_node = self.ast.getNode(new_name);
        break :blk self.ast.getText(name_node.data.string_ref);
    } else null;

    // class node 생성 (decorator 없이)
    const empty_list = try self.ast.addNodeList(&.{});
    const class_node = try self.addExtraNode(.class_expression, node.span, &.{
        @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
        none,                   0,                       0,
        empty_list.start, empty_list.len, // decorator 제거
    });

    // class decorator 또는 constructor param decorator가 있으면 → let Foo = class Foo {}; 로 변환
    if ((old_deco_len > 0 or ctor_param_decos.len > 0) and class_name_text != null) {
        // let Foo = class Foo {};
        const name_span = self.ast.getNode(new_name).data.string_ref;
        const var_name = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
        // variable_declarator: extra = [name, type_ann, init_val]
        const declarator = try self.addExtraNode(.variable_declarator, node.span, &.{
            @intFromEnum(var_name),
            @intFromEnum(NodeIndex.none), // type_ann
            @intFromEnum(class_node), // init_val
        });
        const decl_list = try self.ast.addNodeList(&.{declarator});
        const var_decl = try self.addExtraNode(.variable_declaration, node.span, &.{
            1, decl_list.start, decl_list.len, // 1 = let
        });

        // pending_nodes에 let 선언 추가 (visitExtraList가 class 노드 앞에 삽입)
        try self.pending_nodes.append(self.allocator, var_decl);

        // member decorator 호출: __decorateClass([dec], Foo.prototype, "name", kind)
        for (member_decos) |md| {
            const call_stmt = try self.buildDecorateClassMemberCall(decorate_span, name_span, name_old_idx, md);
            try self.pending_nodes.append(self.allocator, call_stmt);
        }

        // class + constructor param decorator 호출: Foo = __decorateClass([...paramDecos, ...classDecos], Foo)
        const class_deco_stmt = try self.buildDecorateClassCall(
            decorate_span,
            name_span,
            name_old_idx,
            old_deco_start,
            old_deco_len,
            ctor_param_decos,
            ctor_params_start,
            ctor_params_len,
        );
        try self.pending_nodes.append(self.allocator, class_deco_stmt);

        // static field: Foo.x = value (decorator 호출 뒤에 배치)
        for (static_field_assigns) |field| {
            const stmt = try self.buildStaticFieldAssignment(new_name, field);
            try self.pending_nodes.append(self.allocator, stmt);
        }

        for (static_block_iifes) |iife| {
            try self.pending_nodes.append(self.allocator, iife);
        }

        return .none;
    }

    // class decorator가 없고 member decorator만 있는 경우
    // pending_nodes는 child 앞에 삽입되므로, class 노드도 pending에 넣고
    // decorator 호출을 그 뒤에 추가한 후 .none을 반환한다.
    if (member_decos.len > 0 and class_name_text != null) {
        const name_span = self.ast.getNode(new_name).data.string_ref;

        // class 노드를 pending에 추가
        const class_result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            empty_list.start, empty_list.len, // decorator 제거
        });
        try self.pending_nodes.append(self.allocator, class_result);

        for (member_decos) |md| {
            const call_stmt = try self.buildDecorateClassMemberCall(decorate_span, name_span, name_old_idx, md);
            try self.pending_nodes.append(self.allocator, call_stmt);
        }

        for (static_field_assigns) |field| {
            const stmt = try self.buildStaticFieldAssignment(new_name, field);
            try self.pending_nodes.append(self.allocator, stmt);
        }

        for (static_block_iifes) |iife| {
            try self.pending_nodes.append(self.allocator, iife);
        }

        return .none;
    }

    // decorator가 없는 경우
    // ES2022: static block이 있으면 class를 pending에 넣고 IIFE를 뒤에 추가
    if (static_block_iifes.len > 0) {
        const class_result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            empty_list.start,       empty_list.len,
        });
        try self.pending_nodes.append(self.allocator, class_result);
        for (static_block_iifes) |iife| {
            try self.pending_nodes.append(self.allocator, iife);
        }
        return .none;
    }

    return self.addExtraNode(node.tag, node.span, &.{
        @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
        none,                   0,                       0,
        empty_list.start,       empty_list.len,
    });
}

/// __decorateClass([dec1, dec2], Foo.prototype, "methodName", kind) 호출문 생성
pub fn buildDecorateClassMemberCall(
    self: *Transformer,
    decorate_span: Span,
    class_name_span: Span,
    class_name_old_idx: NodeIndex,
    md: MemberDecoratorInfo,
) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // callee: __decorateClass
    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = decorate_span,
        .data = .{ .string_ref = decorate_span },
    });

    // arg1: [dec1, dec2, ..., __metadata("design:type", Function), ...]
    var deco_items: std.ArrayList(NodeIndex) = .empty;
    defer deco_items.deinit(self.allocator);
    try deco_items.appendSlice(self.allocator, md.decorators);
    // emitDecoratorMetadata: __metadata 호출 추가
    try self.appendMemberMetadata(&deco_items, md.params_start, md.params_len);
    const deco_array_list = try self.ast.addNodeList(deco_items.items);
    const deco_array = try self.ast.addNode(.{
        .tag = .array_expression,
        .span = zero_span,
        .data = .{ .list = deco_array_list },
    });

    // arg2: Foo.prototype (instance) or Foo (static)
    const class_ref = try self.makeIdentifierRefWithSymbol(class_name_span, class_name_old_idx);
    const target = if (!md.is_static) blk: {
        const proto_span = try self.ast.addString("prototype");
        const proto_id = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = proto_span,
            .data = .{ .string_ref = proto_span },
        });
        const me = try self.ast.addExtras(&.{ @intFromEnum(class_ref), @intFromEnum(proto_id), 0 });
        break :blk try self.ast.addNode(.{
            .tag = .static_member_expression,
            .span = zero_span,
            .data = .{ .extra = me },
        });
    } else class_ref;

    // arg3: "methodName" 또는 computed key expression
    const key_node = self.ast.getNode(md.key);
    const key_string = if (key_node.tag == .computed_property_key)
        // computed key: [expr] → 그대로 expression 전달
        key_node.data.unary.operand
    else blk: {
        // 일반 key: identifier/string → 따옴표로 감싼 문자열 리터럴
        const key_text = self.ast.getText(key_node.data.string_ref);
        var quoted_buf: [256]u8 = undefined;
        quoted_buf[0] = '"';
        const copy_len = @min(key_text.len, quoted_buf.len - 2);
        @memcpy(quoted_buf[1 .. 1 + copy_len], key_text[0..copy_len]);
        quoted_buf[1 + copy_len] = '"';
        const quoted_span = try self.ast.addString(quoted_buf[0 .. 2 + copy_len]);
        break :blk try self.ast.addNode(.{
            .tag = .string_literal,
            .span = quoted_span,
            .data = .{ .string_ref = quoted_span },
        });
    };

    // arg4: kind (1=method, 2=property) — string_table에 숫자 텍스트 저장
    const kind_text = if (md.kind == 1) "1" else "2";
    const kind_span = try self.ast.addString(kind_text);
    const kind_node = try self.ast.addNode(.{
        .tag = .numeric_literal,
        .span = kind_span,
        .data = .{ .number_bytes = @bitCast(@as(f64, @floatFromInt(md.kind))) },
    });

    const args = try self.ast.addNodeList(&.{ deco_array, target, key_string, kind_node });
    const call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });
}

/// Foo = __decorateClass([...ctorParamDecos, ...classDecos], Foo) 호출문 생성 (class + constructor param decorator)
pub fn buildDecorateClassCall(
    self: *Transformer,
    decorate_span: Span,
    class_name_span: Span,
    class_name_old_idx: NodeIndex,
    old_deco_start: u32,
    old_deco_len: u32,
    ctor_param_decos: []const NodeIndex,
    ctor_params_start: u32,
    ctor_params_len: u32,
) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // callee: __decorateClass
    const callee = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = decorate_span,
        .data = .{ .string_ref = decorate_span },
    });

    // arg1: [...ctorParamDecos, ...classDecos]
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // constructor parameter decorators 먼저 (TypeScript 순서: __param → class decorator)
    for (ctor_param_decos) |param_deco| {
        try self.scratch.append(self.allocator, param_deco);
    }

    // class decorators
    if (old_deco_len > 0) {
        var deco_i: u32 = 0;
        while (deco_i < old_deco_len) : (deco_i += 1) {
            const raw_idx = self.ast.extra_data.items[old_deco_start + deco_i];
            try self.scratch.append(self.allocator, try self.visitDecoratorExpression(raw_idx));
        }
    }

    // emitDecoratorMetadata: constructor paramtypes 추가
    if (self.options.emit_decorator_metadata and ctor_params_len > 0) {
        var meta_list: std.ArrayList(NodeIndex) = .empty;
        defer meta_list.deinit(self.allocator);
        try self.appendClassMetadata(&meta_list, ctor_params_start, ctor_params_len);
        for (meta_list.items) |meta| {
            try self.scratch.append(self.allocator, meta);
        }
    }

    const deco_array_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const deco_array = try self.ast.addNode(.{
        .tag = .array_expression,
        .span = zero_span,
        .data = .{ .list = deco_array_list },
    });

    // arg2: Foo
    const class_ref = try self.makeIdentifierRefWithSymbol(class_name_span, class_name_old_idx);

    const args = try self.ast.addNodeList(&.{ deco_array, class_ref });
    const call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });

    // Foo = __decorateClass([dec], Foo)
    const lhs = try self.makeIdentifierRefWithSymbol(class_name_span, class_name_old_idx);
    const assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = lhs, .right = call, .flags = 0 } },
    });
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
}

// ================================================================
// emitDecoratorMetadata — __metadata("design:paramtypes", [...]) 생성
// ================================================================

/// TS 타입 어노테이션 AST 태그를 런타임 값 식별자로 직렬화한다.
/// 텍스트 비교 없이 AST 태그로 분기 — ts_number_keyword → Number 등.
pub fn serializeTypeAnnotation(self: *Transformer, type_ann_idx: NodeIndex) Error!NodeIndex {
    if (type_ann_idx.isNone()) return makeIdentifier(self, "Object");

    const type_node = self.ast.getNode(type_ann_idx);

    return switch (type_node.tag) {
        // 기본 타입 키워드 → 런타임 생성자
        .ts_number_keyword => makeIdentifier(self, "Number"),
        .ts_string_keyword => makeIdentifier(self, "String"),
        .ts_boolean_keyword => makeIdentifier(self, "Boolean"),
        .ts_symbol_keyword => makeIdentifier(self, "Symbol"),
        .ts_bigint_keyword => makeIdentifier(self, "BigInt"),
        .ts_any_keyword, .ts_object_keyword, .ts_unknown_keyword => makeIdentifier(self, "Object"),
        .ts_void_keyword, .ts_undefined_keyword, .ts_null_keyword, .ts_never_keyword => makeIdentifier(self, "Object"),

        // 타입 참조 (MyClass, Promise 등) → 소스 span에서 이름 추출
        .ts_type_reference => blk: {
            // ts_type_reference의 span은 소스 텍스트 범위 (제네릭 포함 가능)
            // 소스에서 이름만 추출 (< 이전까지)
            const src_text = self.ast.source[type_node.span.start..type_node.span.end];
            const name_end = std.mem.indexOfScalar(u8, src_text, '<') orelse src_text.len;
            const name_only = src_text[0..name_end];
            break :blk makeIdentifier(self, name_only);
        },
        .identifier_reference, .binding_identifier => blk: {
            break :blk self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = type_node.data.string_ref,
                .data = .{ .string_ref = type_node.data.string_ref },
            });
        },

        // 배열/튜플 → Array
        .ts_array_type, .ts_tuple_type => makeIdentifier(self, "Array"),
        // 함수 타입 → Function
        .ts_function_type, .ts_construct_signature => makeIdentifier(self, "Function"),
        // QualifiedName, union, intersection 등 → Object
        else => makeIdentifier(self, "Object"),
    };
}

/// 소스 텍스트에서 파라미터 뒤의 타입 어노테이션을 추출한다.
/// `name: Type` → "Type" 부분을 찾아 런타임 식별자로 직렬화.
pub fn extractTypeFromSource(self: *Transformer, param: Node) Error!NodeIndex {
    const span_end = param.span.end;
    const source = self.ast.source;
    if (span_end >= source.len) return makeIdentifier(self, "Object");

    // span 끝 이후에서 `: Type` 패턴 탐색
    var pos = span_end;
    // 공백 건너뜀
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\n' or source[pos] == '\r' or source[pos] == '?')) : (pos += 1) {}
    // `:` 확인
    if (pos >= source.len or source[pos] != ':') return makeIdentifier(self, "Object");
    pos += 1;
    // 공백 건너뜀
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) : (pos += 1) {}
    // 타입 이름 시작
    const type_start = pos;
    // 식별자 끝 찾기 (알파벳, 숫자, _, $, .)
    while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_' or source[pos] == '$' or source[pos] == '.')) : (pos += 1) {}
    if (pos == type_start) return makeIdentifier(self, "Object");

    const type_name = source[type_start..pos];
    // 기본 타입 매핑 (AST 태그 없이 텍스트 기반)
    if (std.mem.eql(u8, type_name, "number")) return makeIdentifier(self, "Number");
    if (std.mem.eql(u8, type_name, "string")) return makeIdentifier(self, "String");
    if (std.mem.eql(u8, type_name, "boolean")) return makeIdentifier(self, "Boolean");
    if (std.mem.eql(u8, type_name, "symbol")) return makeIdentifier(self, "Symbol");
    if (std.mem.eql(u8, type_name, "bigint")) return makeIdentifier(self, "BigInt");
    if (std.mem.eql(u8, type_name, "any") or std.mem.eql(u8, type_name, "object") or
        std.mem.eql(u8, type_name, "unknown") or std.mem.eql(u8, type_name, "void") or
        std.mem.eql(u8, type_name, "undefined") or std.mem.eql(u8, type_name, "null") or
        std.mem.eql(u8, type_name, "never")) return makeIdentifier(self, "Object");
    // 클래스/인터페이스 참조 → 그대로 식별자
    return makeIdentifier(self, type_name);
}

/// 이름으로 identifier_reference 노드를 생성하는 헬퍼
fn makeIdentifier(self: *Transformer, name: []const u8) Error!NodeIndex {
    const span = try self.ast.addString(name);
    return self.ast.addNode(.{ .tag = .identifier_reference, .span = span, .data = .{ .string_ref = span } });
}

/// __metadata(key, value) 호출 노드를 생성한다.
pub fn buildMetadataCall(self: *Transformer, key: []const u8, value_idx: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const callee = try makeIdentifier(self, "__metadata");

    // key 문자열 리터럴 — codegen의 writeStringLiteral은 따옴표 포함 텍스트를 기대
    var key_buf: [256]u8 = undefined;
    key_buf[0] = '"';
    const klen = @min(key.len, key_buf.len - 2);
    @memcpy(key_buf[1 .. 1 + klen], key[0..klen]);
    key_buf[1 + klen] = '"';
    const key_span = try self.ast.addString(key_buf[0 .. 2 + klen]);
    const key_node = try self.ast.addNode(.{ .tag = .string_literal, .span = key_span, .data = .{ .string_ref = key_span } });

    const args = try self.ast.addNodeList(&.{ key_node, value_idx });
    return self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
}

/// 함수의 파라미터 타입 배열을 생성한다: [Number, String, MyClass]
pub fn buildParamTypesArray(self: *Transformer, params_start: u32, params_len: u32) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    var type_nodes: std.ArrayList(NodeIndex) = .empty;
    defer type_nodes.deinit(self.allocator);

    var j: u32 = 0;
    while (j < params_len) : (j += 1) {
        if (params_start + j >= self.ast.extra_data.items.len) break;
        const raw = self.ast.extra_data.items[params_start + j];
        const p_idx: NodeIndex = @enumFromInt(raw);
        if (p_idx.isNone() or @intFromEnum(p_idx) >= self.ast.nodes.items.len) {
            try type_nodes.append(self.allocator, try makeIdentifier(self, "Object"));
            continue;
        }
        const param = self.ast.getNode(p_idx);
        if (param.tag == .formal_parameter) {
            // formal_parameter: extra = [pattern, type_ann, default, flags, deco_start, deco_len]
            const pe = param.data.extra;
            if (pe + 1 < self.ast.extra_data.items.len) {
                const type_ann_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[pe + 1]);
                const type_val = try self.serializeTypeAnnotation(type_ann_idx);
                try type_nodes.append(self.allocator, type_val);
            } else {
                try type_nodes.append(self.allocator, try makeIdentifier(self, "Object"));
            }
        } else if (param.tag == .binding_identifier or param.tag == .assignment_pattern) {
            // 일반 파라미터: 소스에서 타입 어노테이션 추출 (: Type 패턴)
            const type_val = try self.extractTypeFromSource(param);
            try type_nodes.append(self.allocator, type_val);
        } else {
            try type_nodes.append(self.allocator, try makeIdentifier(self, "Object"));
        }
    }

    const list = try self.ast.addNodeList(type_nodes.items);
    return self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = list } });
}

/// decorator 배열에 __metadata 호출을 추가한다 (emitDecoratorMetadata 활성 시).
/// member decorator용: design:type(Function) + design:paramtypes([...]) + design:returntype(...)
pub fn appendMemberMetadata(
    self: *Transformer,
    deco_list: *std.ArrayList(NodeIndex),
    params_start: u32,
    params_len: u32,
) Error!void {
    if (!self.options.emit_decorator_metadata) return;

    // design:type → always Function for methods
    const func_ref = try makeIdentifier(self, "Function");
    const type_meta = try self.buildMetadataCall("design:type", func_ref);
    try deco_list.append(self.allocator, type_meta);

    // design:paramtypes → 파라미터 타입 배열
    const param_types = try self.buildParamTypesArray(params_start, params_len);
    const paramtypes_meta = try self.buildMetadataCall("design:paramtypes", param_types);
    try deco_list.append(self.allocator, paramtypes_meta);

    // design:returntype → Object (AST에 리턴 타입 추출 미지원)
    const return_type_val = try makeIdentifier(self, "Object");
    const return_meta = try self.buildMetadataCall("design:returntype", return_type_val);
    try deco_list.append(self.allocator, return_meta);
}

/// class decorator 배열에 constructor paramtypes 메타데이터를 추가한다.
/// params_start/params_len은 원본 AST에서 미리 수집한 constructor 파라미터 위치.
pub fn appendClassMetadata(
    self: *Transformer,
    deco_list: *std.ArrayList(NodeIndex),
    params_start: u32,
    params_len: u32,
) Error!void {
    if (!self.options.emit_decorator_metadata) return;
    if (params_len == 0) return;

    const param_types = try self.buildParamTypesArray(params_start, params_len);
    const meta = try self.buildMetadataCall("design:paramtypes", param_types);
    try deco_list.append(self.allocator, meta);
}
