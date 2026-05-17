//! Class/object member visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const es2015_shorthand = @import("../es2015_shorthand.zig");
const es_helpers = @import("../es_helpers.zig");
const styled_components_mod = @import("styled_components.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

fn expandBlockRenamedShorthand(self: *Transformer, node: Node) Error!?NodeIndex {
    if (!self.options.unsupported.block_scoping) return null;
    if (!node.data.binary.right.isNone()) return null;

    const key_idx = node.data.binary.left;
    if (key_idx.isNone()) return null;
    const key_node = self.ast.getNode(key_idx);
    if (key_node.tag != .identifier_reference) return null;

    const name = self.ast.getText(key_node.data.string_ref);
    const new_name = self.lookupBlockRename(name) orelse return null;

    // Object shorthand 의 key 는 property 이름이라 원본을 보존해야 하지만,
    // 암시된 value 참조는 block-scoping lowering 이 만든 renamed binding 을 읽어야 한다.
    const new_key = try self.copyNodeDirect(key_idx);
    self.propagateSymbolId(key_idx, new_key);

    const value_span = try self.ast.addString(new_name);
    const new_value = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = value_span,
        .data = .{ .string_ref = value_span },
    });
    self.propagateSymbolId(key_idx, new_value);

    return try self.ast.addNode(.{
        .tag = .object_property,
        .span = node.span,
        .data = .{ .binary = .{
            .left = new_key,
            .right = new_value,
            .flags = node.data.binary.flags,
        } },
    });
}

// method_definition: extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
// constructor의 parameter property (public x: number) 변환도 처리.
// abstract 메서드는 런타임에 존재하면 안 되므로 완전히 제거.
pub fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const flags = self.readU32(e, ast_mod.MethodExtra.flags);
    // abstract 메서드는 타입 전용이므로 완전히 스트리핑
    if (self.options.strip_types and (flags & ast_mod.MethodFlags.is_abstract) != 0) return NodeIndex.none;
    // TS method overload signature: body가 없으면 제거
    if (self.readNodeIdx(e, 2).isNone()) return NodeIndex.none;
    const new_key = try self.visitNode(self.readNodeIdx(e, 0));

    // 파라미터 방문 — parameter property 감지
    const params_idx_old = self.readNodeIdx(e, 1);
    var params_span = node.span;
    var params_list_old = NodeList{ .start = 0, .len = 0 };
    if (!params_idx_old.isNone()) {
        const pnode = self.ast.getNode(params_idx_old);
        if (pnode.tag == .formal_parameters) {
            params_list_old = pnode.data.list;
            params_span = pnode.span;
        }
    }
    // Method params/body are a function scope. Temps produced by transforms such
    // as `foo() ?? bar` must be declared inside the method body, not at the
    // class/module scope.
    const saved_temp_counter = self.temp_var_counter;

    var pp = try self.visitParamsCollectProperties(params_list_old);
    defer pp.prop_names.deinit(self.allocator);

    // arrow this/arguments 캡처: method도 자체 this 바인딩을 가짐 (visitFunction과 동일)
    const saved_arrow_depth = self.arrow_this_depth;
    const saved_needs_this = self.needs_this_var;
    const saved_needs_args = self.needs_arguments_var;
    const saved_super_alias = self.super_call_this_alias;
    self.arrow_this_depth = 0;
    self.needs_this_var = false;
    self.needs_arguments_var = false;
    self.super_call_this_alias = false;

    const is_ctor = (flags & ast_mod.MethodFlags.is_static) == 0 and
        es_helpers.isConstructorKey(self, self.readNodeIdx(e, ast_mod.MethodExtra.key));

    // ES2015 new.target: method → constructor 또는 void 0
    const saved_new_target_ctx = self.new_target_ctx;
    if (self.options.unsupported.new_target) {
        self.new_target_ctx = if (is_ctor) .constructor else .method;
    }
    defer self.new_target_ctx = saved_new_target_ctx;

    var new_body = try self.visitBodyWorkletAware(self.readNodeIdx(e, 2));

    // parameter property: derived class constructor 는 super() 후에, 그 외에는 body 앞에 prepend.
    // 전자에서 prepend 하면 `this` 가 super() 전 접근되어 ReferenceError.
    if (pp.prop_names.items.len > 0 and !new_body.isNone()) {
        if (is_ctor and self.current_super_class != null) {
            new_body = try self.insertParameterPropertyAssignmentsAfterSuper(new_body, pp.prop_names.items);
        } else {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names.items);
        }
    }

    // arrow가 this/arguments를 사용했으면 var _this = this; 등 삽입
    if (self.options.unsupported.arrow and !new_body.isNone() and
        (self.needs_this_var or self.needs_arguments_var))
    {
        var capture_stmts: [2]NodeIndex = undefined;
        var capture_count: usize = 0;

        if (self.needs_this_var) {
            const this_init = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = node.span,
                .data = .{ .none = 0 },
            });
            capture_stmts[capture_count] = try self.buildVarDecl("_this", this_init, node.span);
            capture_count += 1;
        }
        if (self.needs_arguments_var) {
            const args_span = try self.ast.addString("arguments");
            const args_init = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = args_span,
                .data = .{ .string_ref = args_span },
            });
            capture_stmts[capture_count] = try self.buildVarDecl("_arguments", args_init, node.span);
            capture_count += 1;
        }

        new_body = try self.prependStatementsToBody(new_body, capture_stmts[0..capture_count]);
    }

    if (self.temp_var_counter > saved_temp_counter and !new_body.isNone()) {
        new_body = try self.hoistTempVars(new_body, saved_temp_counter, node.span);
    }
    self.temp_var_counter = saved_temp_counter;

    self.arrow_this_depth = saved_arrow_depth;
    self.needs_this_var = saved_needs_this;
    self.needs_arguments_var = saved_needs_args;
    self.super_call_this_alias = saved_super_alias;

    // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
    // method_definition에서는 제거한다.
    const new_decos = if (self.options.experimental_decorators)
        NodeList{ .start = 0, .len = 0 }
    else
        try self.visitExtraList(.{ .start = self.readU32(e, 4), .len = self.readU32(e, 5) });
    const old_body_idx = self.readNodeIdx(e, 2);
    const new_params_node = try self.ast.addFormalParameters(pp.new_params, params_span);
    const result = try self.addExtraNode(.method_definition, node.span, &.{
        @intFromEnum(new_key), @intFromEnum(new_params_node), @intFromEnum(new_body),
        self.readU32(e, 3),    new_decos.start,               new_decos.len,
    });

    // Plugin dispatch: worklet 등 AST 플러그인 적용
    // method_definition은 object/class 내부에 있으므로 IIFE 교체는 불가.
    // 대신 워크릿 플러그인이 method body 기반으로 function_expression을 생성하여
    // object_property value로 교체할 수 있도록 정보를 전달한다.
    const is_auto_worklet = self.plugins.worklet.auto_next;
    // method 이름 추출 (key가 identifier인 경우)
    const method_name: ?[]const u8 = blk: {
        const key_idx = self.readNodeIdx(e, 0);
        if (key_idx.isNone()) break :blk null;
        const key_node = self.ast.getNode(key_idx);
        if (key_node.tag == .identifier_reference) {
            break :blk self.ast.getText(key_node.span);
        }
        break :blk null;
    };
    if (try self.dispatchFunctionPlugins(result, .{
        .node_idx = result,
        .node_tag = .method_definition,
        .name = method_name,
        .body_idx = new_body,
        .params = pp.new_params,
        .original_params = params_list_old,
        .original_body_idx = old_body_idx,
        .flags = flags,
        .source_path = self.options.jsx_filename,
        .is_auto_worklet = is_auto_worklet,
    })) |replacement| {
        return replacement;
    }

    return result;
}

// property_definition: extra = [key, init_val, flags, deco_start, deco_len]
// abstract 프로퍼티 (flags bit5=0x20) 및 declare 필드 (flags bit6=0x40)는
// 런타임에 존재하면 안 되므로 완전히 제거.
// declare 필드가 남으면 undefined로 초기화되어 의미가 바뀜.
pub fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const flags = self.readU32(e, 2);
    // abstract(0x20), declare(0x40), Flow variance(0x80)는 타입 전용이므로 완전히 스트리핑
    if (self.options.strip_types and (flags & 0xE0) != 0) return NodeIndex.none;
    const new_key = try self.visitNode(self.readNodeIdx(e, 0));
    var new_value = try self.visitNode(self.readNodeIdx(e, 1));
    // styled-components: `class { static Child = styled.div\`\` }` 의 value 가 styled
    // tagged template 이면 field key 를 displayName 으로 사용해 wrap. 인스턴스 필드도
    // 동일하게 처리 (드물지만 가능). objectProperty 패턴 재사용.
    if (!new_key.isNone() and styled_components_mod.shouldAttemptWrap(self, new_value)) {
        if (styled_components_mod.objectPropertyKeyName(self, new_key)) |key_name| {
            new_value = try styled_components_mod.wrapStyledTagInExpr(self, new_value, key_name);
        }
    }
    // experimentalDecorators 모드에서는 decorator를 class 수준에서 처리하므로
    // property_definition에서는 제거한다.
    const new_decos = if (self.options.experimental_decorators)
        NodeList{ .start = 0, .len = 0 }
    else
        try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = self.readU32(e, 4) });
    return self.addExtraNode(.property_definition, node.span, &.{
        @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
        new_decos.start,       new_decos.len,
    });
}

// accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
pub fn visitAccessorProperty(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const flags = self.readU32(e, 2);
    // declare accessor는 타입 전용이므로 완전히 스트리핑
    if (self.options.strip_types and (flags & ast_mod.PropertyFlags.is_declare) != 0) return NodeIndex.none;
    const new_key = try self.visitNode(self.readNodeIdx(e, 0));
    var new_value = try self.visitNode(self.readNodeIdx(e, 1));
    // styled-components: property_definition 와 동일 — accessor 필드도 init 이 styled
    // tagged template 이면 wrap. 드물지만 symmetry.
    if (!new_key.isNone() and styled_components_mod.shouldAttemptWrap(self, new_value)) {
        if (styled_components_mod.objectPropertyKeyName(self, new_key)) |key_name| {
            new_value = try styled_components_mod.wrapStyledTagInExpr(self, new_value, key_name);
        }
    }
    const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, 3), .len = self.readU32(e, 4) });
    return self.addExtraNode(.accessor_property, node.span, &.{
        @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
        new_decos.start,       new_decos.len,
    });
}

/// object_property: binary = { left=key, right=value, flags }
pub fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
    // ES2015: shorthand property 확장 ({ x } → { x: x })
    if (self.options.unsupported.object_extensions and node.data.binary.right.isNone()) {
        return es2015_shorthand.ES2015Shorthand(Transformer).expandShorthand(self, node);
    }
    if (try expandBlockRenamedShorthand(self, node)) |expanded| return expanded;
    // non-computed key(identifier, string, numeric)는 property 이름이므로
    // block scoping rename 등 변수 치환을 적용하면 안 됨. copyNodeDirect 사용.
    // symbol_id는 항상 전파: shorthand({ x })에서 codegen이 rename을
    // 감지하여 { x: x$1 }로 확장하는 데 필요. non-shorthand/literal key는
    // codegen이 writeSpan으로 출력하므로 symbol_id가 있어도 무시됨.
    const key_idx = node.data.binary.left;
    const new_key = if (!key_idx.isNone() and self.ast.getNode(key_idx).tag != .computed_property_key)
        try self.copyNodeDirect(key_idx)
    else
        try self.visitNode(key_idx);
    self.propagateSymbolId(key_idx, new_key);
    var new_value = try self.visitNode(node.data.binary.right);
    // styled-components: { One: styled.div`...` } 의 value 가 styled tagged template 이면
    // property key 이름을 displayName 으로 사용해 wrap. variable_declarator 와 동일 패턴.
    if (!new_key.isNone() and styled_components_mod.shouldAttemptWrap(self, new_value)) {
        if (styled_components_mod.objectPropertyKeyName(self, new_key)) |prop_name| {
            new_value = try styled_components_mod.wrapStyledTagInExpr(self, new_value, prop_name);
        }
    }
    return self.ast.addNode(.{
        .tag = .object_property,
        .span = node.span,
        .data = .{ .binary = .{
            .left = new_key,
            .right = new_value,
            .flags = node.data.binary.flags,
        } },
    });
}

/// formal_parameter:
///   extra = [pattern, type_ann, default, flags, deco_start, deco_len]
/// flags: parameter property modifier (public=0x01, private=0x02, protected=0x04, readonly=0x08, override=0x10)
/// parameter property (flags!=0)는 visitFunction/visitMethodDefinition에서 직접 처리하지만,
/// 다른 경로에서 도달할 수 있으므로 방어적으로 처리.
pub fn visitFormalParameter(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const flags = self.readU32(e, 3);
    // parameter property: modifier 제거하고 내부 패턴만 반환
    if (flags != 0) {
        return self.visitNode(self.readNodeIdx(e, 0));
    }
    const new_pattern = try self.visitNode(self.readNodeIdx(e, 0));
    const new_default = try self.visitNode(self.readNodeIdx(e, 2));
    const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, 4), .len = self.readU32(e, 5) });
    const none = @intFromEnum(NodeIndex.none);
    return self.addExtraNode(.formal_parameter, node.span, &.{
        @intFromEnum(new_pattern), none,            @intFromEnum(new_default), // type_ann 제거
        0,                         new_decos.start, new_decos.len,
    });
}
