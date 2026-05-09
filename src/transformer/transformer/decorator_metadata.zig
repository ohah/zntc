const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const token_mod = @import("../../lexer/token.zig");
const es_helpers = @import("../es_helpers.zig");

const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = token_mod.Span;
const Kind = token_mod.Kind;
const Error = std.mem.Allocator.Error;

/// TS 타입 어노테이션 AST 태그를 런타임 값으로 직렬화한다 (SWC 호환).
/// - 기본 타입: Number, String, Boolean
/// - void/null/undefined/never: void 0
/// - symbol/bigint: typeof 런타임 체크
/// - 클래스 참조: typeof X === "undefined" ? Object : X
pub fn serializeTypeAnnotation(self: anytype, type_ann_idx: NodeIndex) Error!NodeIndex {
    if (type_ann_idx.isNone()) return makeIdentifier(self, "Object");

    const type_node = self.ast.getNode(type_ann_idx);

    return switch (type_node.tag) {
        // 기본 타입 키워드 → 런타임 생성자 (런타임에 항상 존재)
        .ts_number_keyword => makeIdentifier(self, "Number"),
        .ts_string_keyword => makeIdentifier(self, "String"),
        .ts_boolean_keyword => makeIdentifier(self, "Boolean"),
        .ts_any_keyword, .ts_object_keyword, .ts_unknown_keyword => makeIdentifier(self, "Object"),

        // void/null/undefined/never → void 0 (SWC 호환)
        .ts_void_keyword, .ts_undefined_keyword, .ts_null_keyword, .ts_never_keyword => makeIdentifier(self, "void 0"),

        // symbol/bigint → typeof 런타임 체크 (ES5 환경에서 없을 수 있음, SWC 호환)
        .ts_symbol_keyword => makeTypeofGuard(self, "Symbol"),
        .ts_bigint_keyword => makeTypeofGuard(self, "BigInt"),

        // 타입 참조 (MyClass, Promise 등) → typeof 런타임 체크 (SWC 호환)
        .ts_type_reference => blk: {
            const src_text = self.ast.getText(type_node.span);
            const name_end = std.mem.indexOfScalar(u8, src_text, '<') orelse src_text.len;
            const name_only = src_text[0..name_end];
            break :blk makeTypeofGuard(self, name_only);
        },
        .identifier_reference, .binding_identifier => blk: {
            const name = self.ast.getText(type_node.data.string_ref);
            break :blk makeTypeofGuard(self, name);
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
pub fn extractTypeFromSource(self: anytype, param: Node) Error!NodeIndex {
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
    // SWC 호환 타입 직렬화 (텍스트 기반 폴백)
    if (std.mem.eql(u8, type_name, "number")) return makeIdentifier(self, "Number");
    if (std.mem.eql(u8, type_name, "string")) return makeIdentifier(self, "String");
    if (std.mem.eql(u8, type_name, "boolean")) return makeIdentifier(self, "Boolean");
    if (std.mem.eql(u8, type_name, "symbol")) return makeTypeofGuard(self, "Symbol");
    if (std.mem.eql(u8, type_name, "bigint")) return makeTypeofGuard(self, "BigInt");
    if (std.mem.eql(u8, type_name, "any") or std.mem.eql(u8, type_name, "object") or
        std.mem.eql(u8, type_name, "unknown")) return makeIdentifier(self, "Object");
    if (std.mem.eql(u8, type_name, "void") or std.mem.eql(u8, type_name, "undefined") or
        std.mem.eql(u8, type_name, "null") or std.mem.eql(u8, type_name, "never"))
        return makeIdentifier(self, "void 0");
    // 클래스/인터페이스 참조 → typeof 런타임 체크 (SWC 호환)
    return makeTypeofGuard(self, type_name);
}

/// 이름으로 identifier_reference 노드를 생성하는 헬퍼.
fn makeIdentifier(self: anytype, name: []const u8) Error!NodeIndex {
    return es_helpers.makeIdentifierRef(self, name);
}

/// typeof X === "undefined" ? Object : X 조건 표현식 생성 (SWC 호환).
/// 런타임에 타입이 없을 수 있는 참조(class/interface, Symbol, BigInt)에 사용.
fn makeTypeofGuard(self: anytype, name: []const u8) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // typeof X
    const name_ref = try makeIdentifier(self, name);
    const typeof_expr = try self.addExtraNode(.unary_expression, zero_span, &.{
        @intFromEnum(name_ref), @intFromEnum(Kind.kw_typeof),
    });

    // "undefined"
    const undef_span = try self.ast.addString("\"undefined\"");
    const undef_str = try self.ast.addNode(.{ .tag = .string_literal, .span = undef_span, .data = .{ .string_ref = undef_span } });

    // typeof X === "undefined"
    const eq_check = try self.ast.addNode(.{
        .tag = .binary_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = typeof_expr, .right = undef_str, .flags = @intFromEnum(Kind.eq3) } },
    });

    // Object
    const object_ref = try makeIdentifier(self, "Object");

    // X (consequent)
    const name_ref2 = try makeIdentifier(self, name);

    // typeof X === "undefined" ? Object : X
    return self.ast.addNode(.{
        .tag = .conditional_expression,
        .span = zero_span,
        .data = .{ .ternary = .{ .a = eq_check, .b = object_ref, .c = name_ref2 } },
    });
}

/// __metadata(key, value) 호출 노드를 생성한다.
pub fn buildMetadataCall(self: anytype, key: []const u8, value_idx: NodeIndex) Error!NodeIndex {
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
pub fn buildParamTypesArray(self: anytype, params: ast_mod.NodeList) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    var type_nodes: std.ArrayList(NodeIndex) = .empty;
    defer type_nodes.deinit(self.allocator);

    var j: u32 = 0;
    while (j < params.len) : (j += 1) {
        if (params.start + j >= self.ast.extra_data.items.len) break;
        const raw = self.ast.extra_data.items[params.start + j];
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
                const type_val = try serializeTypeAnnotation(self, type_ann_idx);
                try type_nodes.append(self.allocator, type_val);
            } else {
                try type_nodes.append(self.allocator, try makeIdentifier(self, "Object"));
            }
        } else if (param.tag == .binding_identifier or param.tag == .assignment_pattern) {
            // 일반 파라미터: 소스에서 타입 어노테이션 추출 (: Type 패턴)
            const type_val = try extractTypeFromSource(self, param);
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
    self: anytype,
    deco_list: *std.ArrayList(NodeIndex),
    params: ast_mod.NodeList,
) Error!void {
    if (!self.options.emit_decorator_metadata) return;

    // design:type → always Function for methods
    const func_ref = try makeIdentifier(self, "Function");
    const type_meta = try buildMetadataCall(self, "design:type", func_ref);
    try deco_list.append(self.allocator, type_meta);

    // design:paramtypes → 파라미터 타입 배열
    const param_types = try buildParamTypesArray(self, params);
    const paramtypes_meta = try buildMetadataCall(self, "design:paramtypes", param_types);
    try deco_list.append(self.allocator, paramtypes_meta);

    // design:returntype → Object (AST에 리턴 타입 추출 미지원)
    const return_type_val = try makeIdentifier(self, "Object");
    const return_meta = try buildMetadataCall(self, "design:returntype", return_type_val);
    try deco_list.append(self.allocator, return_meta);
}

/// class decorator 배열에 constructor paramtypes 메타데이터를 추가한다.
/// params_start/params_len은 원본 AST에서 미리 수집한 constructor 파라미터 위치.
pub fn appendClassMetadata(
    self: anytype,
    deco_list: *std.ArrayList(NodeIndex),
    params: ast_mod.NodeList,
) Error!void {
    if (!self.options.emit_decorator_metadata) return;
    if (params.len == 0) return;

    const param_types = try buildParamTypesArray(self, params);
    const meta = try buildMetadataCall(self, "design:paramtypes", param_types);
    try deco_list.append(self.allocator, meta);
}
