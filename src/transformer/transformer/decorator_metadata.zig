const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const token_mod = @import("../../lexer/token.zig");
const module_parser = @import("../../parser/module.zig");
const es_helpers = @import("../es_helpers.zig");
const qualified_type_name = @import("../qualified_type_name.zig");
const type_only = @import("type_only.zig");

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
    if (type_ann_idx.isNone()) return makeMetadataNameRef(self, "Object");

    const type_node = self.ast.getNode(type_ann_idx);

    return switch (type_node.tag) {
        // 기본 타입 키워드 → 런타임 생성자 (런타임에 항상 존재)
        .ts_number_keyword => makeMetadataNameRef(self, "Number"),
        .ts_string_keyword => makeMetadataNameRef(self, "String"),
        .ts_boolean_keyword => makeMetadataNameRef(self, "Boolean"),
        .ts_any_keyword, .ts_object_keyword, .ts_unknown_keyword => makeMetadataNameRef(self, "Object"),

        // void/null/undefined/never → void 0 (SWC 호환)
        .ts_void_keyword, .ts_undefined_keyword, .ts_null_keyword, .ts_never_keyword => es_helpers.makeVoidZero(self, .{ .start = 0, .end = 0 }),

        // symbol/bigint → typeof 런타임 체크 (ES5 환경에서 없을 수 있음, SWC 호환)
        .ts_symbol_keyword => makeTypeofGuard(self, "Symbol"),
        .ts_bigint_keyword => makeTypeofGuard(self, "BigInt"),

        // Unqualified type references use the existing typeof guard. Qualified
        // names retain a lexical base reference and explicit property nodes.
        .ts_type_reference => blk: {
            if (qualified_type_name.typeReferenceName(self.ast, type_node)) |name| {
                if (qualified_type_name.isSimpleQualifiedPath(name)) {
                    break :blk makeQualifiedMetadataTypeRef(self, name);
                }
            }
            const src_text = self.ast.getText(type_node.span);
            const name_end = std.mem.indexOfScalar(u8, src_text, '<') orelse src_text.len;
            break :blk makeTypeReferenceGuard(self, src_text[0..name_end]);
        },
        .identifier_reference, .binding_identifier => blk: {
            const name = self.ast.getText(type_node.data.string_ref);
            break :blk makeTypeReferenceGuard(self, name);
        },

        // 배열/튜플 → Array
        .ts_array_type, .ts_tuple_type => makeMetadataNameRef(self, "Array"),
        // 함수 타입 → Function
        .ts_function_type, .ts_construct_signature => makeMetadataNameRef(self, "Function"),
        // QualifiedName, union, intersection 등 → Object
        else => makeMetadataNameRef(self, "Object"),
    };
}

/// 소스 텍스트에서 파라미터 뒤의 타입 어노테이션을 추출한다.
/// `name: Type` → "Type" 부분을 찾아 런타임 식별자로 직렬화.
pub fn extractTypeFromSource(self: anytype, param: Node) Error!NodeIndex {
    return extractTypeFromSourceAtNode(self, param, NodeIndex.none);
}

fn extractTypeFromSourceAtNode(self: anytype, param: Node, param_idx: NodeIndex) Error!NodeIndex {
    const span_end = param.span.end;
    const source = self.ast.source;
    if (span_end >= source.len) return makeMetadataNameRef(self, "Object");

    // span 끝 이후에서 `: Type` 패턴 탐색
    var pos = span_end;
    // 공백 건너뜀
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\n' or source[pos] == '\r' or source[pos] == '?')) : (pos += 1) {}
    // `:` 확인
    if (pos >= source.len or source[pos] != ':') return makeMetadataNameRef(self, "Object");
    pos += 1;
    // 공백 건너뜀
    while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t')) : (pos += 1) {}
    // 타입 이름 시작
    const type_start = pos;
    if (!param_idx.isNone()) {
        if (findTypeAnnotationForParam(self, param_idx, @intCast(type_start))) |type_ann_idx| {
            return serializeTypeAnnotation(self, type_ann_idx);
        }
    }
    // 식별자 끝 찾기 (알파벳, 숫자, _, $, .)
    while (pos < source.len and (std.ascii.isAlphanumeric(source[pos]) or source[pos] == '_' or source[pos] == '$' or source[pos] == '.')) : (pos += 1) {}
    if (pos == type_start) return makeMetadataNameRef(self, "Object");

    const type_name = source[type_start..pos];
    // SWC 호환 타입 직렬화 (텍스트 기반 폴백)
    if (std.mem.eql(u8, type_name, "number")) return makeMetadataNameRef(self, "Number");
    if (std.mem.eql(u8, type_name, "string")) return makeMetadataNameRef(self, "String");
    if (std.mem.eql(u8, type_name, "boolean")) return makeMetadataNameRef(self, "Boolean");
    if (std.mem.eql(u8, type_name, "symbol")) return makeTypeofGuard(self, "Symbol");
    if (std.mem.eql(u8, type_name, "bigint")) return makeTypeofGuard(self, "BigInt");
    if (std.mem.eql(u8, type_name, "any") or std.mem.eql(u8, type_name, "object") or
        std.mem.eql(u8, type_name, "unknown")) return makeMetadataNameRef(self, "Object");
    if (std.mem.eql(u8, type_name, "void") or std.mem.eql(u8, type_name, "undefined") or
        std.mem.eql(u8, type_name, "null") or std.mem.eql(u8, type_name, "never"))
        return es_helpers.makeVoidZero(self, .{ .start = 0, .end = 0 });
    if (qualified_type_name.isSimpleQualifiedPath(type_name)) {
        return makeQualifiedMetadataTypeRef(self, type_name);
    }
    // 클래스/인터페이스 참조 → typeof 런타임 체크 (SWC 호환)
    return makeTypeReferenceGuard(self, type_name);
}

/// Simple parameter ASTs store the binding identifier in the parameter list,
/// while their type nodes are appended immediately after that binding. Select
/// the widest type-only node starting at the annotation's source position so
/// arrays and unions are serialized from their root shape instead of the first
/// identifier in the source text.
fn findTypeAnnotationForParam(self: anytype, param_idx: NodeIndex, type_start: u32) ?NodeIndex {
    var anchor = param_idx;
    var hops: usize = 0;
    while (!anchor.isNone() and hops < self.ast.nodes.items.len) : (hops += 1) {
        const node = self.ast.getNode(anchor);
        anchor = switch (node.tag) {
            .assignment_pattern => node.data.binary.left,
            .spread_element, .rest_element => node.data.unary.operand,
            .formal_parameter => @enumFromInt(self.ast.extra_data.items[node.data.extra]),
            else => break,
        };
    }
    if (anchor.isNone()) return null;
    const anchor_raw = @intFromEnum(anchor);
    if (anchor_raw >= self.ast.nodes.items.len) return null;

    var best: ?NodeIndex = null;
    var best_end = type_start;
    var raw = anchor_raw + 1;
    while (raw < self.ast.nodes.items.len) : (raw += 1) {
        const node = self.ast.nodes.items[raw];
        if (!type_only.isTypeOnlyNode(node.tag)) break;
        if (node.span.start == type_start and node.span.end >= best_end) {
            best = @enumFromInt(raw);
            best_end = node.span.end;
        }
    }
    return best;
}

/// Build `Namespace.Type` as a lexical base reference plus property names.
/// Only the base can be a variable symbol; qualified suffixes are properties.
fn makeQualifiedMetadataTypeRef(self: anytype, name: []const u8) Error!NodeIndex {
    var parts = std.mem.splitScalar(u8, name, '.');
    const base_name = parts.next() orelse return makeMetadataNameRef(self, name);
    var expression = try makeMetadataTypeNameRef(self, base_name) orelse
        return makeMetadataNameRef(self, "Object");
    const zero_span = Span{ .start = 0, .end = 0 };
    while (parts.next()) |property_name| {
        const property = try es_helpers.makePropertyName(self, property_name);
        expression = try es_helpers.makeStaticMember(self, expression, property, zero_span);
    }
    return expression;
}

/// typeof X === "undefined" ? Object : X 조건 표현식 생성 (SWC 호환).
/// 런타임에 타입이 없을 수 있는 참조(class/interface, Symbol, BigInt)에 사용.
fn makeTypeofGuard(self: anytype, name: []const u8) Error!NodeIndex {
    return makeTypeofGuardWithRef(self, name, try makeMetadataNameRef(self, name));
}

fn makeTypeReferenceGuard(self: anytype, name: []const u8) Error!NodeIndex {
    const ref = try makeMetadataTypeNameRef(self, name) orelse
        return makeMetadataNameRef(self, "Object");
    return makeTypeofGuardWithRef(self, name, ref);
}

fn makeTypeofGuardWithRef(self: anytype, name: []const u8, name_ref: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // typeof X
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
    const object_ref = try makeMetadataNameRef(self, "Object");

    // X (consequent)
    const name_ref2 = try makeMetadataNameRef(self, name);

    // typeof X === "undefined" ? Object : X
    return self.ast.addNode(.{
        .tag = .conditional_expression,
        .span = zero_span,
        .data = .{ .ternary = .{ .a = eq_check, .b = object_ref, .c = name_ref2 } },
    });
}

/// Metadata expressions execute where the decorated class executes. Resolve a
/// simple name through that lexical scope so minification can carry local class
/// and shadowed built-in identities into the generated references.
fn makeMetadataNameRef(self: anytype, name: []const u8) Error!NodeIndex {
    const ref = try self.makeLexicalScopeRef(name);
    const symbol_id = self.getSymbolIdAt(ref) orelse return ref;
    if (isTypeOnlyImportBinding(self, name, symbol_id)) {
        // A type-only import named Object/Number/etc. does not create a
        // runtime binding for the constructor used by generated metadata.
        try self.removeSemanticReference(ref);
        try self.markExplicitGlobalReference(ref);
    }
    return ref;
}

/// An explicitly type-only import cannot supply a runtime metadata value.
/// Erase the whole type reference (including any qualified suffix), rather
/// than reading an unrelated global with the same spelling through typeof.
fn makeMetadataTypeNameRef(self: anytype, name: []const u8) Error!?NodeIndex {
    const ref = try self.makeLexicalScopeRef(name);
    const symbol_id = self.getSymbolIdAt(ref) orelse return ref;
    if (!isTypeOnlyImportBinding(self, name, symbol_id)) return ref;
    try self.removeSemanticReference(ref);
    return null;
}

fn isTypeOnlyImportBinding(self: anytype, name: []const u8, symbol_id: u32) bool {
    if (symbol_id >= self.symbols.len or self.symbols[symbol_id].kind != .import_binding) return false;

    for (self.ast.nodes.items) |node| {
        if (node.tag != .import_declaration) continue;
        const start = node.data.extra;
        if (start > self.ast.extra_data.items.len or self.ast.extra_data.items.len - start < 6) continue;
        const import = module_parser.readImportDeclExtras(self.ast, start);
        if (import.specs_start > self.ast.extra_data.items.len or
            import.specs_len > self.ast.extra_data.items.len - import.specs_start) continue;
        var i: u32 = 0;
        while (i < import.specs_len) : (i += 1) {
            const spec_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[import.specs_start + i]);
            if (spec_idx.isNone() or @intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
            const spec = self.ast.getNode(spec_idx);
            const local_idx = switch (spec.tag) {
                .import_default_specifier, .import_namespace_specifier => spec_idx,
                .import_specifier => spec.data.binary.right,
                else => continue,
            };
            if (local_idx.isNone() or self.getSymbolIdAt(local_idx) != symbol_id) continue;
            if (!std.mem.eql(u8, name, self.ast.getText(self.ast.getNode(local_idx).span))) continue;
            const inline_type_only = spec.tag == .import_specifier and
                (spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0;
            if (import.is_type_only or inline_type_only) return true;
        }
    }
    return false;
}

/// __metadata(key, value) 호출 노드를 생성한다.
pub fn buildMetadataCall(self: anytype, key: []const u8, value_idx: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    self.runtime_helpers.metadata = true;
    const callee = try es_helpers.makeRuntimeHelperRef(self, "__metadata");

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
            try type_nodes.append(self.allocator, try makeMetadataNameRef(self, "Object"));
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
                try type_nodes.append(self.allocator, try makeMetadataNameRef(self, "Object"));
            }
        } else if (param.tag == .binding_identifier or param.tag == .assignment_pattern) {
            // 일반 파라미터: 소스에서 타입 어노테이션 추출 (: Type 패턴)
            const type_val = try extractTypeFromSourceAtNode(self, param, p_idx);
            try type_nodes.append(self.allocator, type_val);
        } else {
            try type_nodes.append(self.allocator, try makeMetadataNameRef(self, "Object"));
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
    const func_ref = try makeMetadataNameRef(self, "Function");
    const type_meta = try buildMetadataCall(self, "design:type", func_ref);
    try deco_list.append(self.allocator, type_meta);

    // design:paramtypes → 파라미터 타입 배열
    const param_types = try buildParamTypesArray(self, params);
    const paramtypes_meta = try buildMetadataCall(self, "design:paramtypes", param_types);
    try deco_list.append(self.allocator, paramtypes_meta);

    // design:returntype → Object (AST에 리턴 타입 추출 미지원)
    const return_type_val = try makeMetadataNameRef(self, "Object");
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
