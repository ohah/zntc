const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const token_mod = @import("../../lexer/token.zig");
const es_helpers = @import("../es_helpers.zig");
const rt = @import("../../runtime_helper_names.zig");

const Tag = ast_mod.Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Span = token_mod.Span;
const Kind = token_mod.Kind;
const Error = std.mem.Allocator.Error;

fn makeIdentifier(self: anytype, name: []const u8) Error!NodeIndex {
    return es_helpers.makeIdentifierRef(self, name);
}

pub const Stage3MemberInfo = struct {
    /// "method", "getter", "setter", "field", "accessor"
    kind: []const u8,
    /// 멤버 이름 (문자열 리터럴 또는 computed)
    name: NodeIndex,
    /// static 여부
    is_static: bool,
    /// private 여부
    is_private: bool,
    /// decorator 식 배열 (방문 완료)
    decorators: []const NodeIndex,
    /// field 초기값 (field/accessor만)
    init_value: NodeIndex = .none,
    /// field/accessor용 initializers 변수명 (예: "_x_initializers")
    initializers_name: ?[]const u8 = null,
    /// field/accessor용 extraInitializers 변수명 (예: "_x_extraInitializers")
    extra_initializers_name: ?[]const u8 = null,
    /// private method용: descriptor 변수명 (예: "_private_secret_descriptor")
    descriptor_name: ?[]const u8 = null,
    /// private method용: 원본 method body (function expression으로 변환에 사용)
    method_body: NodeIndex = .none,
    /// private method용: 원본 params NodeList
    method_params: ast_mod.NodeList = .{ .start = 0, .len = 0 },
    /// decorator 변수명 (예: "_greet_decorators") — 식 평가/적용 분리용
    deco_var_name: ?[]const u8 = null,
    /// 원본 AST 멤버 인덱스 (class body 내 위치)
    raw_idx: u32 = 0,
};

/// member key를 문자열 리터럴 노드로 변환.
/// identifier "foo" → string literal "\"foo\"", computed → 그대로.
pub fn memberKeyToStringLiteral(self: anytype, key: NodeIndex) Error!NodeIndex {
    if (key.isNone()) return key;
    const key_node = self.ast.getNode(key);

    // identifier/private → "name" 형태의 string literal로 변환
    if (key_node.tag == .identifier_reference or key_node.tag == .binding_identifier or key_node.tag == .private_identifier) {
        const name = self.ast.getText(key_node.data.string_ref);
        return wrapInStringLiteral(self, name);
    }

    // string_literal → 이미 따옴표 포함 (codegen이 그대로 출력)
    if (key_node.tag == .string_literal) {
        // 소스 텍스트가 "b" 형태 → context.name은 따옴표 없는 "b"
        // 하지만 우리 string_literal은 이미 따옴표 포함이므로 그대로 반환
        return key;
    }

    // numeric_literal → "0" 형태의 string literal로 변환
    if (key_node.tag == .numeric_literal) {
        const src = self.ast.getText(key_node.span);
        return wrapInStringLiteral(self, src);
    }

    // bigint_literal → "2" 형태로 변환 (끝의 n 제거)
    if (key_node.tag == .bigint_literal) {
        const src = self.ast.getText(key_node.span);
        const without_n = if (src.len > 0 and src[src.len - 1] == 'n') src[0 .. src.len - 1] else src;
        return wrapInStringLiteral(self, without_n);
    }

    return key;
}

/// 텍스트를 따옴표로 감싸서 string_literal 노드 생성.
/// `addString` 이 string_table 로 복사하므로 임시 버퍼는 함수 종료시 free 된다.
/// 길이 제한 없음 — 이전의 `[256]u8` 스택 버퍼는 긴 키(base64 / 합성 식별자)를 silent
/// truncate 하던 latent bug 였다.
pub fn wrapInStringLiteral(self: anytype, text: []const u8) Error!NodeIndex {
    const quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{text});
    defer self.allocator.free(quoted);
    const span = try self.ast.addString(quoted);
    return self.ast.addNode(.{ .tag = .string_literal, .span = span, .data = .{ .string_ref = span } });
}

/// decorator 식들을 방문하여 슬라이스로 반환. caller가 free.
pub fn collectStage3Decorators(self: anytype, deco_start: u32, deco_len: u32) Error![]const NodeIndex {
    var result: std.ArrayList(NodeIndex) = .empty;
    defer result.deinit(self.allocator);
    var i: u32 = 0;
    while (i < deco_len) : (i += 1) {
        const raw = self.ast.extra_data.items[deco_start + i];
        const deco_idx: NodeIndex = @enumFromInt(raw);
        if (deco_idx.isNone()) continue;
        const deco_node = self.ast.getNode(deco_idx);
        // decorator 노드의 operand가 실제 식
        if (deco_node.tag == .decorator) {
            const visited = try self.visitNode(deco_node.data.unary.operand);
            try result.append(self.allocator, visited);
        } else {
            const visited = try self.visitNode(deco_idx);
            try result.append(self.allocator, visited);
        }
    }
    return result.toOwnedSlice(self.allocator);
}

/// __esDecorate(this, null, _decorators, { kind: "method", name: "...", static: bool, private: bool, access: { ... }, metadata: _metadata }, null, _extraInitializers) 호출 생성.
pub fn buildEsDecorateCall(self: anytype, info: Stage3MemberInfo) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const callee = try makeIdentifier(self, "__esDecorate");

    // arg1: this (ctor — method/getter/setter) 또는 null (field)
    const arg1 = if (std.mem.eql(u8, info.kind, "field"))
        try makeIdentifier(self, "null")
    else
        try self.ast.addNode(.{ .tag = .this_expression, .span = zero_span, .data = .{ .none = 0 } });

    // arg2: null (public) 또는 _descriptor = { value: __setFunctionName(fn, "#name") } (private method)
    const arg2 = if (info.descriptor_name) |dname| blk: {
        // _private_method_descriptor = { value: __setFunctionName(function() { ... }, "#name") }
        const desc_ref = try makeIdentifier(self, dname);

        // __setFunctionName(function() { ... }, "#name")
        const setfn_callee = try makeIdentifier(self, "__setFunctionName");
        // function expression with original body
        const fn_params_node = try self.ast.addFormalParameters(info.method_params, zero_span);
        const fn_expr = try self.addExtraNode(.function_expression, zero_span, &.{
            @intFromEnum(NodeIndex.none), // name (anonymous)
            @intFromEnum(fn_params_node),
            @intFromEnum(info.method_body),
            0, // flags
            @intFromEnum(NodeIndex.none), // ret_type
        });
        const name_str = info.name; // "#method" as string_literal
        const setfn_args = try self.ast.addNodeList(&.{ fn_expr, name_str });
        const setfn_call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(setfn_callee), setfn_args.start, setfn_args.len, 0,
        });

        // { value: __setFunctionName(...) }
        const value_key = try makeIdentifier(self, "value");
        const value_prop = try makeObjProp(self, value_key, setfn_call);
        const desc_list = try self.ast.addNodeList(&.{value_prop});
        const desc_obj = try self.ast.addNode(.{ .tag = .object_expression, .span = zero_span, .data = .{ .list = desc_list } });

        // _descriptor = { value: ... }
        break :blk try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = desc_ref, .right = desc_obj, .flags = 0 } },
        });
    } else try makeIdentifier(self, "null");

    // arg3: decorator 배열 (변수 참조 — 식 평가는 이미 소스 순서로 완료)
    const arg3 = if (info.deco_var_name) |vname|
        try makeIdentifier(self, vname)
    else blk: {
        const deco_list = try self.ast.addNodeList(info.decorators);
        break :blk try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = deco_list } });
    };

    // arg4: context object { kind: "method", name: "greet", static: false, private: false, access: { ... }, metadata: _metadata }
    const arg4 = try buildContextObject(self, info);

    // arg5: initializers (null for method/getter/setter, per-field var for field/accessor)
    const arg5 = if (info.initializers_name) |name|
        try makeIdentifier(self, name)
    else
        try makeIdentifier(self, "null");

    // arg6: extraInitializers (per-field var for field/accessor, shared var for method/getter/setter)
    const arg6 = if (info.extra_initializers_name) |name|
        try makeIdentifier(self, name)
    else blk: {
        const extra_init_name = if (info.is_static) "_staticExtraInitializers" else "_instanceExtraInitializers";
        break :blk try makeIdentifier(self, extra_init_name);
    };

    const args = try self.ast.addNodeList(&.{ arg1, arg2, arg3, arg4, arg5, arg6 });
    return self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
}

/// class decorator용 __esDecorate 호출:
/// __esDecorate(null, _classDescriptor = { value: _classThis }, _classDecorators, { kind: "class", name: _classThis.name, metadata: _metadata }, null, _classExtraInitializers)
pub fn buildClassEsDecorateCall(self: anytype, classThis_span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    const callee = try makeIdentifier(self, "__esDecorate");

    // arg1: null
    const arg1 = try makeIdentifier(self, "null");

    // arg2: _classDescriptor = { value: _classThis }
    const classThis_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = classThis_span,
        .data = .{ .string_ref = classThis_span },
    });
    const value_key_span = try self.ast.addString("value");
    const value_key = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = value_key_span,
        .data = .{ .string_ref = value_key_span },
    });
    const value_prop = try makeObjProp(self, value_key, classThis_ref);
    const obj_list = try self.ast.addNodeList(&.{value_prop});
    const obj = try self.ast.addNode(.{ .tag = .object_expression, .span = zero_span, .data = .{ .list = obj_list } });

    const desc_span = try self.ast.addString("_classDescriptor");
    const desc_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = desc_span,
        .data = .{ .string_ref = desc_span },
    });
    const arg2 = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = desc_ref, .right = obj, .flags = 0 } },
    });

    // arg3: _classDecorators (이미 static block에서 할당됨)
    const arg3 = try makeIdentifier(self, "_classDecorators");

    // arg4: { kind: "class", name: _classThis.name, metadata: _metadata }
    const kind_key = try makeIdentifier(self, "kind");
    const kind_val_span = try self.ast.addString("\"class\"");
    const kind_val = try self.ast.addNode(.{ .tag = .string_literal, .span = kind_val_span, .data = .{ .string_ref = kind_val_span } });
    const kind_prop = try makeObjProp(self, kind_key, kind_val);

    const name_key = try makeIdentifier(self, "name");
    // _classThis.name
    const classThis_ref2 = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = classThis_span,
        .data = .{ .string_ref = classThis_span },
    });
    const name_prop_key = try makeIdentifier(self, "name");
    const classThis_name = try self.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(classThis_ref2), @intFromEnum(name_prop_key), 0,
    });
    const name_prop = try makeObjProp(self, name_key, classThis_name);

    const metadata_key = try makeIdentifier(self, "metadata");
    const metadata_val = try makeIdentifier(self, "_metadata");
    const metadata_prop = try makeObjProp(self, metadata_key, metadata_val);

    const ctx_list = try self.ast.addNodeList(&.{ kind_prop, name_prop, metadata_prop });
    const arg4 = try self.ast.addNode(.{ .tag = .object_expression, .span = zero_span, .data = .{ .list = ctx_list } });

    // arg5: null
    const arg5 = try makeIdentifier(self, "null");

    // arg6: _classExtraInitializers
    const arg6 = try makeIdentifier(self, "_classExtraInitializers");

    const args = try self.ast.addNodeList(&.{ arg1, arg2, arg3, arg4, arg5, arg6 });
    return self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
}

/// context object 생성: { kind: "method", name: "greet", static: false, private: false, access: { has: ..., get: ... }, metadata: _metadata }
pub fn buildContextObject(self: anytype, info: Stage3MemberInfo) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    var props: std.ArrayList(NodeIndex) = .empty;
    defer props.deinit(self.allocator);

    // kind
    var kind_buf: [16]u8 = undefined;
    kind_buf[0] = '"';
    const klen = info.kind.len;
    @memcpy(kind_buf[1 .. 1 + klen], info.kind);
    kind_buf[1 + klen] = '"';
    const kind_key = try makeIdentifier(self, "kind");
    const kind_val_span = try self.ast.addString(kind_buf[0 .. 2 + klen]);
    const kind_val = try self.ast.addNode(.{ .tag = .string_literal, .span = kind_val_span, .data = .{ .string_ref = kind_val_span } });
    try props.append(self.allocator, try makeObjProp(self, kind_key, kind_val));

    // name
    const name_key = try makeIdentifier(self, "name");
    try props.append(self.allocator, try makeObjProp(self, name_key, info.name));

    // static
    const static_key = try makeIdentifier(self, "static");
    const static_val = try makeIdentifier(self, if (info.is_static) "true" else "false");
    try props.append(self.allocator, try makeObjProp(self, static_key, static_val));

    // private
    const private_key = try makeIdentifier(self, "private");
    const private_val = try makeIdentifier(self, if (info.is_private) "true" else "false");
    try props.append(self.allocator, try makeObjProp(self, private_key, private_val));

    // access: { has: obj => "name" in obj, get: obj => obj.name, ... }
    const access_key = try makeIdentifier(self, "access");
    const access_obj = try buildAccessObject(self, info);
    try props.append(self.allocator, try makeObjProp(self, access_key, access_obj));

    // metadata
    const metadata_key = try makeIdentifier(self, "metadata");
    const metadata_val = try makeIdentifier(self, "_metadata");
    try props.append(self.allocator, try makeObjProp(self, metadata_key, metadata_val));

    const list = try self.ast.addNodeList(props.items);
    return self.ast.addNode(.{ .tag = .object_expression, .span = zero_span, .data = .{ .list = list } });
}

/// access 객체 생성: { has: obj => "name" in obj, get: obj => obj.name, set: (obj, value) => { obj.name = value; } }
/// kind에 따라 has/get/set 조합이 다르다:
/// - method/getter: has + get
/// - setter: has + set
/// - field/accessor: has + get + set
pub fn buildAccessObject(self: anytype, info: Stage3MemberInfo) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);
    var access_props: std.ArrayList(NodeIndex) = .empty;
    defer access_props.deinit(self.allocator);

    // 멤버 이름 텍스트 추출 (string_literal "\"name\"" → "name")
    const name_node = self.ast.getNode(info.name);
    const raw_name = self.ast.getText(name_node.data.string_ref);
    // 따옴표 제거: "\"foo\"" → "foo"
    const member_name = if (raw_name.len >= 2 and raw_name[0] == '"')
        raw_name[1 .. raw_name.len - 1]
    else
        raw_name;

    // identifier-safe 판정: 숫자로 시작하거나 유효하지 않은 식별자면 computed access 사용
    // obj.name (static) vs obj["name"] or obj[0] (computed)
    const needs_computed = blk: {
        if (info.is_private) break :blk false; // private은 항상 obj.#name
        if (member_name.len == 0) break :blk true;
        const first = member_name[0];
        if (first >= '0' and first <= '9') break :blk true; // 숫자로 시작
        // JS 식별자가 아닌 문자가 있으면 computed
        for (member_name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') break :blk true;
        }
        break :blk false;
    };

    // has: obj => "name" in obj (public) 또는 obj => #name in obj (private)
    {
        const has_key = try makeIdentifier(self, "has");
        const obj_param_span = try self.ast.addString("obj");
        const obj_param = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = obj_param_span,
            .data = .{ .string_ref = obj_param_span },
        });

        const obj_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = obj_param_span,
            .data = .{ .string_ref = obj_param_span },
        });

        const in_left = if (info.is_private) blk: {
            // #name (private_identifier)
            const priv_span = try self.ast.addString(member_name);
            break :blk try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = priv_span,
                .data = .{ .string_ref = priv_span },
            });
        } else blk: {
            // "name" (string_literal)
            break :blk try self.ast.addNode(.{
                .tag = .string_literal,
                .span = name_node.data.string_ref,
                .data = .{ .string_ref = name_node.data.string_ref },
            });
        };
        const in_expr = try self.ast.addNode(.{
            .tag = .binary_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = in_left, .right = obj_ref, .flags = @intFromEnum(Kind.kw_in) } },
        });

        const has_arrow = try self.addExtraNode(.arrow_function_expression, zero_span, &.{
            @intFromEnum(obj_param), @intFromEnum(in_expr), 0,
        });
        try access_props.append(self.allocator, try makeObjProp(self, has_key, has_arrow));
    }

    // get: obj => obj.name (method, getter, field, accessor — not setter)
    const is_setter_only = std.mem.eql(u8, info.kind, "setter");
    if (!is_setter_only) {
        const get_key = try makeIdentifier(self, "get");
        const obj_param_span = try self.ast.addString("obj");
        const obj_param = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = obj_param_span,
            .data = .{ .string_ref = obj_param_span },
        });

        // obj.name (public) / obj.#name (private) / obj["name"] or obj[0] (computed key)
        const obj_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = obj_param_span,
            .data = .{ .string_ref = obj_param_span },
        });
        const obj_member = if (needs_computed) blk: {
            // obj["name"] 또는 obj[0]
            const key_node = info.name; // 이미 string_literal "\"name\"" 형태
            break :blk try es_helpers.makeComputedMember(self, obj_ref, key_node, zero_span);
        } else blk: {
            const member_key_tag: Tag = if (info.is_private) .private_identifier else .identifier_reference;
            const member_key_span = try self.ast.addString(member_name);
            const member_key_node = try self.ast.addNode(.{
                .tag = member_key_tag,
                .span = member_key_span,
                .data = .{ .string_ref = member_key_span },
            });
            break :blk try es_helpers.makeStaticMember(self, obj_ref, member_key_node, zero_span);
        };

        const get_arrow = try self.addExtraNode(.arrow_function_expression, zero_span, &.{
            @intFromEnum(obj_param), @intFromEnum(obj_member), 0,
        });
        try access_props.append(self.allocator, try makeObjProp(self, get_key, get_arrow));
    }

    // set: (obj, value) => { obj.name = value; } (setter, field, accessor — not method/getter)
    const needs_set = std.mem.eql(u8, info.kind, "setter") or
        std.mem.eql(u8, info.kind, "field") or
        std.mem.eql(u8, info.kind, "accessor");
    if (needs_set) {
        const set_key = try makeIdentifier(self, "set");

        // function(obj, value) { obj.name = value; }
        // function_expression: extra = [name(0), params_start, params_len, body(3), flags, ret_type(5)]
        const obj_param_span = try self.ast.addString("obj");
        const obj_param = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = obj_param_span,
            .data = .{ .string_ref = obj_param_span },
        });
        const val_param_span = try self.ast.addString("value");
        const val_param = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = val_param_span,
            .data = .{ .string_ref = val_param_span },
        });
        const fn_params = try self.ast.addNodeList(&.{ obj_param, val_param });

        // body: { obj.name = value; } / { obj.#name = value; } / { obj["name"] = value; }
        const obj_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = obj_param_span,
            .data = .{ .string_ref = obj_param_span },
        });
        const obj_member = if (needs_computed) blk: {
            break :blk try es_helpers.makeComputedMember(self, obj_ref, info.name, zero_span);
        } else blk: {
            const set_key_tag: Tag = if (info.is_private) .private_identifier else .identifier_reference;
            const set_key_span = try self.ast.addString(member_name);
            const set_key_node = try self.ast.addNode(.{
                .tag = set_key_tag,
                .span = set_key_span,
                .data = .{ .string_ref = set_key_span },
            });
            break :blk try es_helpers.makeStaticMember(self, obj_ref, set_key_node, zero_span);
        };
        const val_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = val_param_span,
            .data = .{ .string_ref = val_param_span },
        });
        const assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = obj_member, .right = val_ref, .flags = 0 } },
        });
        const assign_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
        const body_list = try self.ast.addNodeList(&.{assign_stmt});
        const fn_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = zero_span,
            .data = .{ .list = body_list },
        });

        const set_fn_params_node = try self.ast.addFormalParameters(fn_params, zero_span);
        const set_fn = try self.addExtraNode(.function_expression, zero_span, &.{
            none, // name (anonymous)
            @intFromEnum(set_fn_params_node),
            @intFromEnum(fn_body),
            0, // flags
            none, // ret_type
        });
        try access_props.append(self.allocator, try makeObjProp(self, set_key, set_fn));
    }

    const list = try self.ast.addNodeList(access_props.items);
    return self.ast.addNode(.{ .tag = .object_expression, .span = zero_span, .data = .{ .list = list } });
}

/// const _metadata = typeof Symbol === "function" && Symbol.metadata ? Object.create(null) : void 0;
pub fn buildMetadataDecl(self: anytype) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);

    // typeof Symbol === "function"
    const symbol_ref = try makeIdentifier(self, "Symbol");
    const typeof_expr = try self.addExtraNode(.unary_expression, zero_span, &.{
        @intFromEnum(symbol_ref), @intFromEnum(Kind.kw_typeof),
    });
    const func_str_span = try self.ast.addString("\"function\"");
    const func_str = try self.ast.addNode(.{ .tag = .string_literal, .span = func_str_span, .data = .{ .string_ref = func_str_span } });
    const typeof_check = try self.ast.addNode(.{
        .tag = .binary_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = typeof_expr, .right = func_str, .flags = @intFromEnum(Kind.eq3) } },
    });

    // Symbol.metadata
    const symbol_ref2 = try makeIdentifier(self, "Symbol");
    const metadata_prop = try makeIdentifier(self, "metadata");
    const symbol_metadata = try self.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(symbol_ref2), @intFromEnum(metadata_prop), 0,
    });

    // typeof Symbol === "function" && Symbol.metadata
    const and_expr = try self.ast.addNode(.{
        .tag = .binary_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = typeof_check, .right = symbol_metadata, .flags = @intFromEnum(Kind.amp2) } },
    });

    // Object.create(null)
    const object_ref = try makeIdentifier(self, "Object");
    const create_key = try makeIdentifier(self, "create");
    const obj_create = try self.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(object_ref), @intFromEnum(create_key), 0,
    });
    const null_arg = try makeIdentifier(self, "null");
    const null_args = try self.ast.addNodeList(&.{null_arg});
    const obj_create_call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(obj_create), null_args.start, null_args.len, 0,
    });

    // void 0
    const void0 = try makeIdentifier(self, "void 0");

    // ... ? Object.create(null) : void 0
    const ternary = try self.ast.addNode(.{
        .tag = .conditional_expression,
        .span = zero_span,
        .data = .{ .ternary = .{ .a = and_expr, .b = obj_create_call, .c = void0 } },
    });

    // const _metadata = ...;
    const metadata_span = try self.ast.addString("_metadata");
    const metadata_binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = metadata_span,
        .data = .{ .string_ref = metadata_span },
    });
    const declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(metadata_binding), none, @intFromEnum(ternary),
    });
    const decl_list = try self.ast.addNodeList(&.{declarator});
    return self.addExtraNode(.variable_declaration, zero_span, &.{
        2, decl_list.start, decl_list.len, // 2 = const
    });
}

/// Foo = _classThis = _classDescriptor.value; 문 생성
pub fn buildClassReassign(self: anytype, class_name: []const u8, classThis_span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // _classDescriptor.value
    const desc_ref = try makeIdentifier(self, "_classDescriptor");
    const value_key = try makeIdentifier(self, "value");
    const desc_value = try self.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(desc_ref), @intFromEnum(value_key), 0,
    });

    // _classThis = _classDescriptor.value
    const classThis_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = classThis_span,
        .data = .{ .string_ref = classThis_span },
    });
    const inner_assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = classThis_ref, .right = desc_value, .flags = 0 } },
    });

    // Foo = _classThis = ...
    const foo_ref = try makeIdentifier(self, class_name);
    const outer_assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = foo_ref, .right = inner_assign, .flags = 0 } },
    });

    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = outer_assign, .flags = 0 } },
    });
}

/// __runInitializers(target_span_ref, name) 호출 생성.
/// target은 Span(identifier_reference로 변환)
pub fn buildRunInitializersCall(self: anytype, target_span: Span, init_name: []const u8) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const callee = try makeIdentifier(self, "__runInitializers");
    const target = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = target_span,
        .data = .{ .string_ref = target_span },
    });
    const init_ref = try makeIdentifier(self, init_name);
    const args = try self.ast.addNodeList(&.{ target, init_ref });
    return self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
}

/// __runInitializers(target_node, name) 호출 생성.
/// target은 이미 생성된 NodeIndex (예: this)
pub fn buildRunInitializersCall2(self: anytype, target_node: NodeIndex, init_name: []const u8) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const callee = try makeIdentifier(self, "__runInitializers");
    const init_ref = try makeIdentifier(self, init_name);
    const args = try self.ast.addNodeList(&.{ target_node, init_ref });
    return self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(callee), args.start, args.len, 0,
    });
}

/// IIFE 내부 let 선언들 생성.
/// let _classDecorators = [...]; let _classDescriptor; let _classExtraInitializers = []; let _classThis;
/// let _instanceExtraInitializers = []; (instance decorator 있을 때)
pub fn buildStage3LetDeclarations(
    self: anytype,
    class_deco_start: u32,
    class_deco_len: u32,
    member_infos: []const Stage3MemberInfo,
    has_instance: bool,
    has_static: bool,
) Error![]NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);
    var stmts: std.ArrayList(NodeIndex) = .empty;
    defer stmts.deinit(self.allocator);

    // let _classThis; — static { _classThis = this; } 에서 항상 사용
    try stmts.append(self.allocator, try makeLet(self, zero_span, "_classThis", .none));

    // class decorator가 있으면 추가 변수 (식 평가는 소스 순서 — class body보다 먼저)
    if (class_deco_len > 0) {
        // let _classDecorators = [dec1, dec2]; (IIFE 최상단에서 평가 — TC39 소스 순서)
        const decos = try collectStage3Decorators(self, class_deco_start, class_deco_len);
        defer self.allocator.free(decos);
        const deco_list = try self.ast.addNodeList(decos);
        const deco_arr = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = deco_list } });
        try stmts.append(self.allocator, try makeLet(self, zero_span, "_classDecorators", deco_arr));

        // let _classDescriptor;
        try stmts.append(self.allocator, try makeLet(self, zero_span, "_classDescriptor", .none));

        // let _classExtraInitializers = [];
        const empty_arr_list = try self.ast.addNodeList(&.{});
        const empty_arr = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = empty_arr_list } });
        try stmts.append(self.allocator, try makeLet(self, zero_span, "_classExtraInitializers", empty_arr));
    }

    // instance/static extra initializers
    if (has_instance) {
        const empty_arr_list = try self.ast.addNodeList(&.{});
        const empty_arr = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = empty_arr_list } });
        try stmts.append(self.allocator, try makeLet(self, zero_span, "_instanceExtraInitializers", empty_arr));
    }
    if (has_static) {
        const empty_arr_list = try self.ast.addNodeList(&.{});
        const empty_arr = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = empty_arr_list } });
        try stmts.append(self.allocator, try makeLet(self, zero_span, "_staticExtraInitializers", empty_arr));
    }

    // member decorator 변수 + initializers + descriptor 변수
    for (member_infos) |info| {
        if (info.deco_var_name) |vname| {
            try stmts.append(self.allocator, try makeLet(self, zero_span, vname, .none));
        }
        if (info.descriptor_name) |dname| {
            // let _private_method_descriptor;
            try stmts.append(self.allocator, try makeLet(self, zero_span, dname, .none));
        }
        if (info.initializers_name) |init_name| {
            const empty_arr_list = try self.ast.addNodeList(&.{});
            const empty_arr = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = empty_arr_list } });
            try stmts.append(self.allocator, try makeLet(self, zero_span, init_name, empty_arr));
        }
        if (info.extra_initializers_name) |extra_name| {
            const empty_arr_list2 = try self.ast.addNodeList(&.{});
            const empty_arr2 = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = empty_arr_list2 } });
            try stmts.append(self.allocator, try makeLet(self, zero_span, extra_name, empty_arr2));
        }
    }

    _ = none;
    return stmts.toOwnedSlice(self.allocator);
}

/// object property { key: value } 노드 생성
pub fn makeObjProp(self: anytype, key: NodeIndex, value: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    return self.ast.addNode(.{
        .tag = .object_property,
        .span = zero_span,
        .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
    });
}

/// let name = init; 또는 let name; 선언 생성
pub fn makeLet(self: anytype, span: Span, name: []const u8, init: NodeIndex) Error!NodeIndex {
    const name_span = try self.ast.addString(name);
    const binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
    const declarator = try self.addExtraNode(.variable_declarator, span, &.{
        @intFromEnum(binding), @intFromEnum(NodeIndex.none), @intFromEnum(init),
    });
    const decl_list = try self.ast.addNodeList(&.{declarator});
    return self.addExtraNode(.variable_declaration, span, &.{
        1, decl_list.start, decl_list.len, // 1 = let
    });
}

/// field/accessor decorator용 initializers 변수명 생성 헬퍼.
/// 따옴표 포함된 string_literal 노드에서 clean name을 추출하고
/// _name_initializers / _name_extraInitializers 문자열을 할당한다.
pub const FieldInitNames = struct {
    init_name: []const u8,
    extra_name: []const u8,
    clean_name: []const u8,
};

pub fn buildFieldInitNames(self: anytype, name_node_idx: NodeIndex) Error!FieldInitNames {
    const var_name = extractCleanVarName(self, name_node_idx);
    // clean_name은 #을 포함 (private field identity), var_name은 # 제거 (JS 변수명)
    const name_node = self.ast.getNode(name_node_idx);
    const raw_name = self.ast.getText(name_node.data.string_ref);
    const clean_name = if (raw_name.len >= 2 and raw_name[0] == '"')
        raw_name[1 .. raw_name.len - 1]
    else
        raw_name;
    const init_name = try std.fmt.allocPrint(self.allocator, "_{s}_initializers", .{var_name});
    const extra_name = try std.fmt.allocPrint(self.allocator, "_{s}_extraInitializers", .{var_name});
    return .{ .init_name = init_name, .extra_name = extra_name, .clean_name = clean_name };
}

/// if (_metadata) Object.defineProperty(_classThis, Symbol.metadata, { enumerable: true, configurable: true, writable: true, value: _metadata });
pub fn buildMetadataDefineProperty(self: anytype, classThis_span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // _metadata (condition)
    const metadata_cond = try makeIdentifier(self, "_metadata");

    // Object.defineProperty(_classThis, Symbol.metadata, { enumerable: true, configurable: true, writable: true, value: _metadata })
    const object_ref = try makeIdentifier(self, "Object");
    const defprop_key = try makeIdentifier(self, "defineProperty");
    const obj_defprop = try es_helpers.makeStaticMember(self, object_ref, defprop_key, zero_span);

    // arg1: _classThis
    const ct_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = classThis_span,
        .data = .{ .string_ref = classThis_span },
    });

    // arg2: Symbol.metadata
    const sym_ref = try makeIdentifier(self, "Symbol");
    const meta_key = try makeIdentifier(self, "metadata");
    const sym_meta = try es_helpers.makeStaticMember(self, sym_ref, meta_key, zero_span);

    // arg3: { enumerable: true, configurable: true, writable: true, value: _metadata }
    const enum_k = try makeIdentifier(self, "enumerable");
    const enum_v = try makeIdentifier(self, "true");
    const conf_k = try makeIdentifier(self, "configurable");
    const conf_v = try makeIdentifier(self, "true");
    const writ_k = try makeIdentifier(self, "writable");
    const writ_v = try makeIdentifier(self, "true");
    const val_k = try makeIdentifier(self, "value");
    const val_v = try makeIdentifier(self, "_metadata");

    const p1 = try makeObjProp(self, enum_k, enum_v);
    const p2 = try makeObjProp(self, conf_k, conf_v);
    const p3 = try makeObjProp(self, writ_k, writ_v);
    const p4 = try makeObjProp(self, val_k, val_v);
    const props_list = try self.ast.addNodeList(&.{ p1, p2, p3, p4 });
    const desc_obj = try self.ast.addNode(.{ .tag = .object_expression, .span = zero_span, .data = .{ .list = props_list } });

    const call_args = try self.ast.addNodeList(&.{ ct_ref, sym_meta, desc_obj });
    const call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(obj_defprop), call_args.start, call_args.len, 0,
    });

    // if (_metadata) call;
    const call_stmt = try self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = call, .flags = 0 } },
    });
    const body_list = try self.ast.addNodeList(&.{call_stmt});
    const body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = body_list },
    });

    return self.ast.addNode(.{
        .tag = .if_statement,
        .span = zero_span,
        .data = .{ .ternary = .{ .a = metadata_cond, .b = body, .c = .none } },
    });
}

/// getter method_definition 생성 헬퍼: get key() { return return_expr; }
/// private method → getter 변환, accessor → getter 생성 양쪽에서 공용.
pub fn buildGetterMethod(self: anytype, key: NodeIndex, return_expr: NodeIndex, is_static: bool, span: Span) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = return_expr, .flags = 0 } },
    });
    const body_list = try self.ast.addNodeList(&.{return_stmt});
    const getter_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = body_list },
    });
    const empty_params = try self.ast.addNodeList(&.{});
    const empty_params_node = try self.ast.addFormalParameters(empty_params, span);
    const empty_decos = try self.ast.addNodeList(&.{});
    const getter_flags: u32 = 0x02 | (if (is_static) @as(u32, 0x01) else 0);
    return self.addExtraNode(.method_definition, span, &.{
        @intFromEnum(key),
        @intFromEnum(empty_params_node),
        @intFromEnum(getter_body),
        getter_flags,
        empty_decos.start,
        empty_decos.len,
    });
}

/// setter method_definition 생성 헬퍼: set key(value) { assign_target = value; }
/// param name 은 Babel/SWC 관례대로 "value" 고정. assign_target 은 caller 가 pre-build
/// (예: this.#storage 노드). buildGetterMethod 와 대칭.
pub fn buildSetterMethod(self: anytype, key: NodeIndex, assign_target: NodeIndex, is_static: bool, span: Span) Error!NodeIndex {
    const val_span = try self.ast.addString("value");
    const val_param = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = val_span,
        .data = .{ .string_ref = val_span },
    });
    const params_list = try self.ast.addNodeList(&.{val_param});
    const params_node = try self.ast.addFormalParameters(params_list, span);

    const val_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = val_span,
        .data = .{ .string_ref = val_span },
    });
    const assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = span,
        .data = .{ .binary = .{ .left = assign_target, .right = val_ref, .flags = 0 } },
    });
    const assign_stmt = try self.ast.addNode(.{
        .tag = .expression_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
    const body_list = try self.ast.addNodeList(&.{assign_stmt});
    const body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = body_list },
    });
    const empty_decos = try self.ast.addNodeList(&.{});
    const setter_flags: u32 = 0x04 | (if (is_static) @as(u32, 0x01) else 0);
    return self.addExtraNode(.method_definition, span, &.{
        @intFromEnum(key),
        @intFromEnum(params_node),
        @intFromEnum(body),
        setter_flags,
        empty_decos.start,
        empty_decos.len,
    });
}

/// 문자열 리터럴 노드에서 JS 변수명으로 사용 가능한 이름 추출.
/// 따옴표 제거 ("\"foo\"" → "foo") + # 제거 ("#foo" → "foo").
pub fn extractCleanVarName(self: anytype, name_node_idx: NodeIndex) []const u8 {
    const name_node = self.ast.getNode(name_node_idx);
    const raw_name = self.ast.getText(name_node.data.string_ref);
    const clean = if (raw_name.len >= 2 and raw_name[0] == '"')
        raw_name[1 .. raw_name.len - 1]
    else
        raw_name;
    return if (clean.len > 0 and clean[0] == '#') clean[1..] else clean;
}

/// __esDecorate 호출문을 static_block_stmts에 추가하는 헬퍼
pub fn appendEsDecorateStmt(self: anytype, stmts: *std.ArrayList(NodeIndex), info: Stage3MemberInfo) Error!void {
    const zero_span = Span{ .start = 0, .end = 0 };
    const call = try buildEsDecorateCall(self, info);
    try stmts.append(self.allocator, try es_helpers.makeExprStmt(self, call, zero_span));
}
