const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const token_mod = @import("../../lexer/token.zig");
const es_helpers = @import("../es_helpers.zig");
const es2022 = @import("../es2022.zig");
const rt = @import("../../runtime_helper_names.zig");

const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = token_mod.Span;
const Error = std.mem.Allocator.Error;

/// ClassName.key = value; 할당문을 생성한다.
pub fn buildStaticFieldAssignment(self: anytype, class_name: NodeIndex, field: FieldAssignment) Error!NodeIndex {
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
    ctor_params: *ast_mod.NodeList = undefined,
};

pub fn classifyClassMember(
    self: anytype,
    raw_idx: u32,
    ctx: *ClassMemberContext,
) Error!void {
    const member_idx: NodeIndex = @enumFromInt(raw_idx);
    if (member_idx.isNone()) return;
    const member = self.ast.getNode(member_idx);

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    if (member.tag == .property_definition) {
        try classifyPropertyDefinition(self, raw_idx, member, ctx);
        return;
    }

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    if (member.tag == .method_definition) {
        try classifyMethodDefinition(self, member, ctx);
        return;
    }

    // ES2022 다운레벨링: static block → IIFE (target < es2022)
    if (member.tag == .static_block and ctx.static_block_iifes != null) {
        const Self = @TypeOf(self.*);
        const iife = try es2022.ES2022(Self).buildStaticBlockIIFE(self, member, ctx.class_name_span);
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
    self: anytype,
    raw_idx: u32,
    member: Node,
    ctx: *ClassMemberContext,
) Error!void {
    const class_members = ctx.class_members;
    const field_assignments = ctx.field_assignments;
    const member_decorators = ctx.member_decorators;
    const me = member.data.extra;
    const flags = self.readU32(me, ast_mod.PropertyExtra.flags);
    const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;
    const is_abstract = (flags & ast_mod.PropertyFlags.is_abstract) != 0;
    const is_declare = (flags & ast_mod.PropertyFlags.is_declare) != 0;

    // abstract / declare / Flow variance는 타입 전용 → 스트리핑
    const type_only_mask = ast_mod.PropertyFlags.is_abstract | ast_mod.PropertyFlags.is_declare | ast_mod.PropertyFlags.flow_variance;
    if (self.options.strip_types and (flags & type_only_mask) != 0) {
        return;
    }

    // decorator 수집 (experimental decorators — 경로와 무관하게 한 번만)
    if (self.options.experimental_decorators) {
        const deco_start = self.readU32(me, ast_mod.PropertyExtra.deco_start);
        const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
        if (deco_len > 0) {
            const new_key = try self.visitNode(self.readNodeIdx(me, ast_mod.PropertyExtra.key));
            const empty: ast_mod.NodeList = .{ .start = 0, .len = 0 };
            try self.collectMemberDecorators(member_decorators, deco_start, deco_len, empty, new_key, is_static, 2, empty);
        }
    }

    // useDefineForClassFields=false: non-static instance field를 constructor로 이동
    if (!self.options.use_define_for_class_fields and !is_static and !is_abstract and !is_declare) {
        const key_idx = self.readNodeIdx(me, ast_mod.PropertyExtra.key);
        const init_idx = self.readNodeIdx(me, ast_mod.PropertyExtra.init);
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
        const key_idx = self.readNodeIdx(me, ast_mod.PropertyExtra.key);
        const init_idx = self.readNodeIdx(me, ast_mod.PropertyExtra.init);
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
    self: anytype,
    member: Node,
    ctx: *ClassMemberContext,
) Error!void {
    const class_members = ctx.class_members;
    const member_decorators = ctx.member_decorators;
    const me = member.data.extra;
    const flags = self.readU32(me, ast_mod.MethodExtra.flags);
    const is_static = (flags & ast_mod.MethodFlags.is_static) != 0;
    const params_list_m = self.ast.functionParamsList(member);

    // constructor 감지
    const is_ctor = if (!is_static) blk: {
        const key_idx = self.readNodeIdx(me, ast_mod.MethodExtra.key);
        const key_node = self.ast.getNode(key_idx);
        if (key_node.tag == .identifier_reference) {
            const name = self.ast.getText(key_node.span);
            break :blk std.mem.eql(u8, name, "constructor");
        }
        break :blk false;
    } else false;

    if (is_ctor) {
        // constructor parameter decorator → class-level __decorateClass에 포함
        if (self.options.experimental_decorators) {
            try self.collectParamDecorators(ctx.ctor_param_decos, params_list_m);
            // emitDecoratorMetadata: 원본 AST에서 constructor 파라미터 위치 저장
            ctx.ctor_params.* = params_list_m;
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
        const deco_start = self.readU32(me, ast_mod.MethodExtra.deco_start);
        const deco_len = self.readU32(me, ast_mod.MethodExtra.deco_len);
        if (deco_len > 0 or params_list_m.len > 0) {
            const new_key = try self.visitNode(self.readNodeIdx(me, ast_mod.MethodExtra.key));
            try self.collectMemberDecorators(
                member_decorators,
                deco_start,
                deco_len,
                params_list_m,
                new_key,
                is_static,
                1,
                params_list_m,
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
    self: anytype,
    class_members: *std.ArrayList(NodeIndex),
    fields: []const FieldAssignment,
    existing_constructor: ?NodeIndex,
    existing_constructor_pos: ?usize,
    has_super: bool,
) Error!void {
    if (existing_constructor) |ctor_idx| {
        // 기존 constructor의 body에 field assignments 삽입
        const updated_ctor = try insertFieldAssignmentsIntoConstructor(self, ctor_idx, fields, has_super);
        // position으로 직접 교체 (선형 검색 불필요)
        if (existing_constructor_pos) |pos| {
            class_members.items[pos] = updated_ctor;
        }
    } else {
        // constructor가 없으면 새로 생성
        const new_ctor = try buildConstructorWithFieldAssignments(self, fields, has_super);
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
    /// emitDecoratorMetadata: 원본 AST 파라미터 리스트
    params: ast_mod.NodeList = .{ .start = 0, .len = 0 },
};

/// decorator 노드에서 expression 부분을 visit하여 반환.
/// decorator 태그이면 operand(expression)를, 아니면 노드 자체를 visit.
pub fn visitDecoratorExpression(self: anytype, raw_idx: u32) Error!NodeIndex {
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
    self: anytype,
    list: *std.ArrayList(MemberDecoratorInfo),
    deco_start: u32,
    deco_len: u32,
    params: ast_mod.NodeList,
    key: NodeIndex,
    is_static: bool,
    kind: u32,
    orig_params: ast_mod.NodeList,
) Error!void {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // 1) parameter decorator → __decorateParam(index, dec)
    if (params.len > 0) {
        try self.appendParamDecorators(&self.scratch, params);
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
        .params = orig_params,
    });
}

/// __decorateParam(index, decorator) 호출 expression 노드 생성
/// constructor의 parameter decorator만 수집하여 __decorateParam 노드 리스트에 추가.
/// collectMemberDecorators의 param 수집 부분과 동일한 appendParamDecorators를 사용.
pub fn collectParamDecorators(
    self: anytype,
    list: *std.ArrayList(NodeIndex),
    params: ast_mod.NodeList,
) Error!void {
    try self.appendParamDecorators(list, params);
}

/// parameter decorator를 __decorateParam(index, dec) 형태로 변환하여 list에 추가.
/// collectMemberDecorators와 collectParamDecorators 양쪽에서 사용.
pub fn appendParamDecorators(
    self: anytype,
    list: anytype,
    params: ast_mod.NodeList,
) Error!void {
    const zero_span = Span{ .start = 0, .end = 0 };
    var param_i: u32 = 0;
    while (param_i < params.len) : (param_i += 1) {
        const raw_idx = self.ast.extra_data.items[params.start + param_i];
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
    self: anytype,
    param_index: usize,
    dec_expr: NodeIndex,
    span: Span,
) Error!NodeIndex {
    // callee: __decorateParam (#1621: minify 시 $dK 축약)
    const param_name = rt.helperName("__decorateParam", self.options.minify_whitespace);
    const callee_span = try self.ast.addString(param_name);
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
    self: anytype,
    ctor_idx: NodeIndex,
    fields: []const FieldAssignment,
    has_super: bool,
) Error!NodeIndex {
    // method_definition: extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
    const ctor_node = self.ast.getNode(ctor_idx);
    const ce = ctor_node.data.extra;
    // extra_data에서 값만 미리 복사 (이후 AST 변형으로 슬라이스가 무효화될 수 있음)
    const ctor_e0 = self.ast.extra_data.items[ce];
    const ctor_e1 = self.ast.extra_data.items[ce + 1];
    const ctor_e2 = self.ast.extra_data.items[ce + 2];
    const ctor_e3 = self.ast.extra_data.items[ce + 3];
    const ctor_e4 = self.ast.extra_data.items[ce + 4];
    const ctor_e5 = self.ast.extra_data.items[ce + 5];
    const body_idx: NodeIndex = @enumFromInt(ctor_e2);

    if (body_idx.isNone()) return ctor_idx;
    if (self.ast.getNode(body_idx).tag != .block_statement) return ctor_idx;

    const insert_pos: u32 = if (has_super) (findSuperCallInsertPos(self, body_idx) orelse 0) else 0;

    // field assignments 를 먼저 빌드 (buildThisAssignment 가 AST 변형 — splice 전에 완료).
    const field_stmts = try self.allocator.alloc(NodeIndex, fields.len);
    defer self.allocator.free(field_stmts);
    for (fields, 0..) |field, i| field_stmts[i] = try buildThisAssignment(self, field);

    const new_body = try spliceBlockStmtsAt(self, body_idx, insert_pos, field_stmts);

    // constructor method_definition을 새 body로 재생성
    // extra: [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
    return self.addExtraNode(.method_definition, ctor_node.span, &.{
        ctor_e0,                ctor_e1,
        @intFromEnum(new_body), ctor_e3,
        ctor_e4,                ctor_e5,
    });
}

/// `this.#storage_name` private field access 노드 생성. private_field_expression 태그 사용.
/// 일반 static_member_expression + private_identifier child 조합은 transformer 의 private field
/// WeakMap dispatch 를 못 타므로 이 helper 로 통일.
pub fn makeThisPrivateField(self: anytype, storage_span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const this_node = try self.ast.addNode(.{
        .tag = .this_expression,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const storage_ref = try self.ast.addNode(.{
        .tag = .private_identifier,
        .span = storage_span,
        .data = .{ .string_ref = storage_span },
    });
    return self.addExtraNode(.private_field_expression, zero_span, &.{
        @intFromEnum(this_node), @intFromEnum(storage_ref), 0,
    });
}

/// block_statement body에서 첫 super() 호출 뒤에 stmt를 삽입한 새 block_statement 반환.
/// super() 없으면 body 시작에 prepend. block_statement 가 아니면 prependStatementsToBody fallback.
pub fn insertAfterSuperCall(self: anytype, body_idx: NodeIndex, stmt: NodeIndex) Error!NodeIndex {
    if (body_idx.isNone()) return body_idx;
    if (self.ast.getNode(body_idx).tag != .block_statement) {
        return self.prependStatementsToBody(body_idx, &.{stmt});
    }
    const insert_pos = findSuperCallInsertPos(self, body_idx) orelse 0;
    return spliceBlockStmtsAt(self, body_idx, insert_pos, &.{stmt});
}

/// super() 호출 expression_statement인지 판별
pub fn isSuperCallStatement(self: anytype, idx: NodeIndex) bool {
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

/// block_statement body 에서 첫 super() 호출 stmt 직후 인덱스 반환. 없으면 null.
/// body_idx 가 block_statement 가 아니면 null.
fn findSuperCallInsertPos(self: anytype, body_idx: NodeIndex) ?u32 {
    if (body_idx.isNone()) return null;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) return null;
    const list = body.data.list;
    const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (stmts, 0..) |raw, idx| {
        if (isSuperCallStatement(self, @enumFromInt(raw))) return @intCast(idx + 1);
    }
    return null;
}

/// derived class 합성 constructor 의 기본 shell `(...args)` 과 `super(...args);` 를 생성.
/// has_super=true 경로에서만 호출. 두 노드는 독립 반환 — caller 가 scratch/body 조립에 배치.
pub fn buildSuperSpreadArgsShell(self: anytype) Error!struct {
    params_node: NodeIndex,
    super_stmt: NodeIndex,
} {
    const zero_span = Span{ .start = 0, .end = 0 };
    const args_span = try self.ast.addString("args");

    // ...args formal parameter
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
    const params_list = try self.ast.addNodeList(&.{rest});
    const params_node = try self.ast.addFormalParameters(params_list, zero_span);

    // super(...args) expression_statement
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

    return .{ .params_node = params_node, .super_stmt = super_stmt };
}

/// block_statement body 에 new_stmts 를 insert_pos 위치에 splice 한 새 block_statement 반환.
/// body 가 block_statement 가 아니면 body_idx 그대로 반환 (caller 가 fallback 처리).
/// 선행 조건: new_stmts 생성 시 발생하는 AST 변형은 이 함수 호출 전에 완료되어야 함 —
/// 본 함수는 old stmts 인덱스를 extra_data 재할당 후에도 `self.ast.extra_data.items` 로
/// 재접근하여 읽기만 수행.
fn spliceBlockStmtsAt(
    self: anytype,
    body_idx: NodeIndex,
    insert_pos: u32,
    new_stmts: []const NodeIndex,
) Error!NodeIndex {
    if (body_idx.isNone()) return body_idx;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) return body_idx;

    const old_list = body.data.list;
    const old_start = old_list.start;
    const old_len = old_list.len;
    const clamped: u32 = if (insert_pos > old_len) old_len else insert_pos;

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = 0;
    while (i < clamped) : (i += 1) {
        const raw = self.ast.extra_data.items[old_start + i];
        try self.scratch.append(self.allocator, @enumFromInt(raw));
    }
    for (new_stmts) |s| try self.scratch.append(self.allocator, s);
    while (i < old_len) : (i += 1) {
        const raw = self.ast.extra_data.items[old_start + i];
        try self.scratch.append(self.allocator, @enumFromInt(raw));
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .block_statement,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

/// useDefineForClassFields=false: constructor가 없을 때 새로 생성.
/// extends가 있으면 super(...args) 호출 포함.
pub fn buildConstructorWithFieldAssignments(
    self: anytype,
    fields: []const FieldAssignment,
    has_super: bool,
) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // extends가 있으면: constructor(...args) { super(...args); this.x = v; }
    const params_node: NodeIndex = if (has_super) blk: {
        const shell = try buildSuperSpreadArgsShell(self);
        try self.scratch.append(self.allocator, shell.super_stmt);
        break :blk shell.params_node;
    } else blk: {
        const empty_params = try self.ast.addNodeList(&.{});
        break :blk try self.ast.addFormalParameters(empty_params, zero_span);
    };

    // this.x = value 할당들
    for (fields) |field| {
        const stmt = try buildThisAssignment(self, field);
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

    const empty_decos = try self.ast.addNodeList(&.{});
    return self.addExtraNode(.method_definition, zero_span, &.{
        @intFromEnum(ctor_key), @intFromEnum(params_node),
        @intFromEnum(body), 0, // flags=0 (non-static, normal method)
        empty_decos.start,  empty_decos.len,
    });
}

/// this.key = value; expression statement 생성
pub fn buildThisAssignment(self: anytype, field: FieldAssignment) Error!NodeIndex {
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
