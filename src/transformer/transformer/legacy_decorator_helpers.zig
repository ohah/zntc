const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const rt = @import("../../runtime_helper_names.zig");
const class_member_helpers = @import("class_member_helpers.zig");

const FieldAssignment = class_member_helpers.FieldAssignment;
const MemberDecoratorInfo = class_member_helpers.MemberDecoratorInfo;

/// experimentalDecorators: class/member decorator를 __decorateClass 호출로 변환.
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
    ctor_params: NodeList,
) Error!NodeIndex {
    const none = @intFromEnum(NodeIndex.none);
    // #1621: minify 시 $dC 축약.
    const decorate_name = rt.helperName("__decorateClass", self.options.minify_whitespace);
    const decorate_span = try self.ast.addString(decorate_name);
    // 헬퍼 정의가 transpile-only 모드에서도 inline 되도록 표식 (#2194).
    self.runtime_helpers.legacy_decorator = true;

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
            const call_stmt = try buildDecorateClassMemberCall(self, decorate_span, name_span, name_old_idx, md);
            try self.pending_nodes.append(self.allocator, call_stmt);
        }

        // class + constructor param decorator 호출: Foo = __decorateClass([...paramDecos, ...classDecos], Foo)
        const class_deco_stmt = try buildDecorateClassCall(
            self,
            decorate_span,
            name_span,
            name_old_idx,
            old_deco_start,
            old_deco_len,
            ctor_param_decos,
            ctor_params,
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
            const call_stmt = try buildDecorateClassMemberCall(self, decorate_span, name_span, name_old_idx, md);
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
    try self.appendMemberMetadata(&deco_items, md.params);
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
    ctor_params: NodeList,
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
    if (self.options.emit_decorator_metadata and ctor_params.len > 0) {
        var meta_list: std.ArrayList(NodeIndex) = .empty;
        defer meta_list.deinit(self.allocator);
        try self.appendClassMetadata(&meta_list, ctor_params);
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
