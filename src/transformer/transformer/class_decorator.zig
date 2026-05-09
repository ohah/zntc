//! Class + Decorator 변환
//!
//! visitClass, visitClassWithAssignSemantics, experimental decorators,
//! field assignments, constructor injection 등.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const class_visit_mod = @import("class_visit.zig");
pub const visitClass = class_visit_mod.visitClass;
const shouldDropClassExprName = class_visit_mod.shouldDropClassExprName;

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

// ============================================================
// TC39 Stage 3 Decorator Transform (TypeScript 5.0+ 호환)
// ============================================================
//
// TypeScript/Babel/SWC 공통 출력: __esDecorate + __runInitializers + IIFE 래핑.
// experimental_decorators=false일 때, class/member에 decorator가 있으면 이 경로를 탄다.

/// Stage 3 decorator가 있는 멤버(method/property/accessor)가 하나라도 있는지 확인.
/// class_body를 순회하여 decorator가 달린 멤버 존재 여부만 빠르게 판단한다.
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

const stage3_transform = @import("stage3_decorator_transform.zig");
pub const transformStage3Decorators = stage3_transform.transformStage3Decorators;
