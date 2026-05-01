//! Schema 빌더 — type alias / interface body → `ComponentShape`.
//!
//! 입력: NativeProps type alias (또는 interface) 의 declaration NodeIndex.
//! 출력: `schema.ComponentShape` (props, events, commands).
//!
//! 사용 시점: codegen plugin (#2348 PR #6) 이 `codegenNativeComponent<NativeProps>('Name')`
//! 을 인식하면 `type_index.get("NativeProps")` 로 declaration 을 찾아 본 빌더에 전달.
//! 빌더가 ComponentShape 를 반환하면 view_config_emitter (PR #4) 가 JS 문자열로 직렬화.
//!
//! 처리 패턴:
//!
//!   - Wrapper 풀기: `Readonly<{...}>`, `$ReadOnly<{...}>` → 안의 object body
//!   - Intersection: `{...} & ViewProps` → ViewProps 부분 무시 (RN 런타임이 등록)
//!   - Property → PropTypeAnnotation 매핑 (`GenerateViewConfigJs.js:43-108` 참고)
//!   - Function-typed prop (`(event: T) => void`) → EventTypeShape
//!   - Identity / default wrapper: `WithDefault<T, D>`, `UnsafeMixed<T>` → inner T
//!   - Generic array: `Array<T>` / `ReadonlyArray<T>` → ComponentArrayTypeAnnotation
//!   - Flow nullable: `?T` → inner T (RN runtime 이 nullable semantics 처리)
//!   - Union: 모든 element 가 string literal 이면 `string_enum`, 아니면 `mixed`
//!   - Explicit event wrapper: `DirectEventHandler<T>` / `BubblingEventHandler<T>`
//!     → EventTypeShape (wrapper 이름이 bubble vs direct 결정)
//!
//! Cross-file type reference (`import type { ViewProps }`) 는 fail-fast —
//! `error.UnresolvedTypeReference` 반환. caller 가 JS fallback (`@react-native/codegen`)
//! 으로 처리 (#2348 § 5).
//!
//! 메모리: caller arena. 모든 슬라이스 / 문자열은 build() 호출 시 alloc 으로 할당.

const std = @import("std");
const ast_mod = @import("../../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = ast_mod.Node.Tag;

const schema = @import("schema.zig");
const TypeIndex = @import("type_index.zig").TypeIndex;
const PropertySignatureFlags = @import("../../../parser/ts.zig").PropertySignatureFlags;

pub const Error = error{
    /// 이름 type reference 가 type_index 에 없음 (cross-file 또는 정의 누락).
    UnresolvedTypeReference,
    /// 인식 못 하는 prop type 형태.
    UnsupportedPropType,
    /// NativeProps 가 object literal 도 wrapper 도 아님.
    InvalidNativePropsBody,
    OutOfMemory,
};

/// codegen plugin 진입점. type alias / interface declaration 으로부터 ComponentShape 빌드.
///
/// `component_name` 은 `codegenNativeComponent('Name')` 의 `'Name'` 인자 — 빌더가
/// 외부에서 받음 (declaration 자체엔 이름 없음).
pub fn build(
    ast: *const Ast,
    type_index: *const TypeIndex,
    component_name: []const u8,
    native_props_idx: NodeIndex,
    alloc: std.mem.Allocator,
) Error!schema.ComponentShape {
    const body_idx = try resolveDeclarationBody(ast, type_index, native_props_idx);
    const members = try collectObjectMembers(ast, type_index, body_idx, alloc);
    defer alloc.free(members); // arena 사용 시 무해, 일반 allocator 시 누수 방지

    var props_buf = std.ArrayList(schema.NamedShape(schema.PropTypeAnnotation)).empty;
    defer props_buf.deinit(alloc);
    var events_buf = std.ArrayList(schema.EventTypeShape).empty;
    defer events_buf.deinit(alloc);

    for (members) |sig_idx| {
        try classifyMember(ast, type_index, sig_idx, &props_buf, &events_buf, alloc);
    }

    return .{
        .name = component_name,
        .props = try props_buf.toOwnedSlice(alloc),
        .events = try events_buf.toOwnedSlice(alloc),
    };
}

/// declaration NodeIndex 를 받아 object body NodeIndex 반환.
/// `Readonly<{...}>` / `$ReadOnly<{...}>` wrapper 가 있으면 풀어준다.
///
/// 지원 declaration tag:
///   - ts_type_alias_declaration: extra[2] = value
///   - ts_interface_declaration:  extra[4] = body
///   - flow_type_alias_declaration: extra[2] = value
///   - flow_opaque_type:          extra[3] = value
///   - flow_interface_declaration: 미지원 (브레이스 skip 으로 body 보존 안 됨)
fn resolveDeclarationBody(
    ast: *const Ast,
    type_index: *const TypeIndex,
    decl_idx: NodeIndex,
) Error!NodeIndex {
    const node = ast.getNode(decl_idx);
    const value_idx: NodeIndex = switch (node.tag) {
        .ts_type_alias_declaration, .flow_type_alias_declaration => v: {
            const e = node.data.extra;
            if (e + 2 >= ast.extra_data.items.len) return error.InvalidNativePropsBody;
            break :v @enumFromInt(ast.extra_data.items[e + 2]);
        },
        .ts_interface_declaration => v: {
            const e = node.data.extra;
            if (e + 4 >= ast.extra_data.items.len) return error.InvalidNativePropsBody;
            break :v @enumFromInt(ast.extra_data.items[e + 4]);
        },
        .flow_opaque_type => v: {
            const e = node.data.extra;
            if (e + 3 >= ast.extra_data.items.len) return error.InvalidNativePropsBody;
            break :v @enumFromInt(ast.extra_data.items[e + 3]);
        },
        else => return error.InvalidNativePropsBody,
    };

    return unwrapWrapper(ast, type_index, value_idx);
}

/// `Readonly<T>` / `$ReadOnly<T>` 같은 well-known wrapper 를 풀어 inner object 반환.
/// Wrapper 가 아니면 입력 그대로.
fn unwrapWrapper(ast: *const Ast, type_index: *const TypeIndex, idx: NodeIndex) Error!NodeIndex {
    const node = ast.getNode(idx);
    const ref_name = switch (node.tag) {
        .ts_type_reference, .flow_type_reference => getTypeReferenceName(ast, node) orelse return idx,
        else => return idx,
    };

    if (!isReadonlyWrapperName(ref_name)) return idx;

    // type argument 추출 — Readonly<T> 의 T.
    const inner = getFirstTypeArgument(ast, node) orelse return idx;
    // 재귀 unwrap (이중 wrapper 케이스). 단, 제자리 무한루프 방지 — getFirstTypeArgument 결과만.
    return unwrapWrapper(ast, type_index, inner);
}

fn isReadonlyWrapperName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Readonly") or
        std.mem.eql(u8, name, "$ReadOnly");
}

/// type_reference node 에서 first type argument 의 NodeIndex 추출.
/// `Foo<A, B>` → A.
///
/// type_reference layout (`flow.zig:472`, `ts.zig:994`): `extra = [name_start, name_end, type_args]`.
/// type_args 는 ts_type_parameter_instantiation / flow_type_parameter_instantiation
/// 의 NodeIndex (NodeList layout = .list).
fn getFirstTypeArgument(ast: *const Ast, node: Node) ?NodeIndex {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return null;
    const args_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 2]);
    if (args_idx == .none) return null;

    const args_node = ast.getNode(args_idx);
    if (args_node.tag != .ts_type_parameter_instantiation and
        args_node.tag != .flow_type_parameter_instantiation) return null;

    const list = args_node.data.list;
    if (list.len == 0) return null;
    return @enumFromInt(ast.extra_data.items[list.start]);
}

/// type_reference 의 name 텍스트 추출. extra[0..2] 가 source 의 name span.
fn getTypeReferenceName(ast: *const Ast, node: Node) ?[]const u8 {
    const e = node.data.extra;
    if (e + 1 >= ast.extra_data.items.len) return null;
    const start = ast.extra_data.items[e];
    const end = ast.extra_data.items[e + 1];
    if (end <= start or end > ast.source.len) return null;
    return ast.source[start..end];
}

/// object body NodeIndex 의 멤버 list 추출.
/// 지원 tag: ts_type_literal, flow_object_type, flow_exact_object_type.
/// 그 외면 InvalidNativePropsBody.
fn collectObjectMembers(
    ast: *const Ast,
    type_index: *const TypeIndex,
    body_idx: NodeIndex,
    alloc: std.mem.Allocator,
) Error![]const NodeIndex {
    _ = type_index; // intersection unwrap 시 사용 예정

    const node = ast.getNode(body_idx);
    const list = switch (node.tag) {
        .ts_type_literal, .flow_object_type, .flow_exact_object_type => node.data.list,
        else => return error.InvalidNativePropsBody,
    };

    const out = try alloc.alloc(NodeIndex, list.len);
    var count: usize = 0;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const raw = ast.extra_data.items[list.start + i];
        const idx: NodeIndex = @enumFromInt(raw);
        const child = ast.getNode(idx);
        if (child.tag != .ts_property_signature and child.tag != .flow_property_signature) continue;
        out[count] = idx;
        count += 1;
    }
    return out[0..count];
}

/// property_signature 1 개를 분류해 props 또는 events 에 append.
fn classifyMember(
    ast: *const Ast,
    type_index: *const TypeIndex,
    sig_idx: NodeIndex,
    props: *std.ArrayList(schema.NamedShape(schema.PropTypeAnnotation)),
    events: *std.ArrayList(schema.EventTypeShape),
    alloc: std.mem.Allocator,
) Error!void {
    const sig = ast.getNode(sig_idx);
    const e = sig.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return error.UnsupportedPropType;

    const key_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    const type_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 1]);
    const flags = PropertySignatureFlags.fromU32(ast.extra_data.items[e + 2]);

    const key_name = extractKeyName(ast, key_idx) orelse return error.UnsupportedPropType;
    if (type_idx == .none) return error.UnsupportedPropType;

    if (isFunctionType(ast, type_idx)) {
        try events.append(alloc, .{
            .name = key_name,
            .bubbling_type = classifyEventBubbling(key_name),
            .optional = flags.optional,
            .argument = null, // PR #3b 스코프: argument 추출 미구현. PR #3b-2 에서 확장.
        });
        return;
    }

    // `DirectEventHandler<T>` / `BubblingEventHandler<T>` — RN codegen 의 명시적 event
    // wrapper. react-native-svg 의 fabric spec 들이 `onSvgLayout?: DirectEventHandler<E>`
    // 형태로 사용. wrapper 이름이 bubble vs direct 를 결정하므로 prop 이름 휴리스틱
    // (`onCapture`) 보다 우선.
    if (eventHandlerBubbling(ast, type_idx)) |bubbling| {
        try events.append(alloc, .{
            .name = key_name,
            .bubbling_type = bubbling,
            .optional = flags.optional,
            .argument = null,
        });
        return;
    }

    const prop_type = try mapPropType(ast, type_index, type_idx);
    try props.append(alloc, .{
        .name = key_name,
        .optional = flags.optional,
        .type_annotation = prop_type,
    });
}

/// property key NodeIndex → 텍스트.
///
/// 지원 tag:
///   - binding_identifier — Flow flow_property_signature 가 직접 생성
///   - identifier_reference — TS parsePropertyKey 결과
///   - string_literal — `'aria-label'?` 같은 quoted key (Flow)
fn extractKeyName(ast: *const Ast, key_idx: NodeIndex) ?[]const u8 {
    const node = ast.getNode(key_idx);
    return switch (node.tag) {
        .binding_identifier, .identifier_reference => ast.getText(node.data.string_ref),
        .string_literal => stripQuotes(ast.getText(node.data.string_ref)),
        else => null,
    };
}

/// `'aria-label'` → `aria-label`. quote 가 없으면 그대로 반환 (이미 식별자).
/// 주의: `string_literal` 노드의 span 은 따옴표 포함이므로 codegen 이 사용하기 전에
/// 벗겨야 함 (RN spec 의 view config 키는 unquoted 식별자 형식).
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const first = s[0];
    const last = s[s.len - 1];
    if ((first == '\'' or first == '"') and first == last) return s[1 .. s.len - 1];
    return s;
}

fn isFunctionType(ast: *const Ast, type_idx: NodeIndex) bool {
    const node = ast.getNode(type_idx);
    return node.tag == .ts_function_type or node.tag == .flow_function_type;
}

/// type 이 `DirectEventHandler<T>` / `BubblingEventHandler<T>` 면 해당 BubblingType 반환.
/// 그 외엔 null.
fn eventHandlerBubbling(ast: *const Ast, type_idx: NodeIndex) ?schema.BubblingType {
    const node = ast.getNode(type_idx);
    if (node.tag != .ts_type_reference and node.tag != .flow_type_reference) return null;
    const name = getTypeReferenceName(ast, node) orelse return null;
    return event_handler_names.get(name);
}

/// RN codegen 의 명시적 event wrapper — 이름이 bubble vs direct 결정.
const event_handler_names = std.StaticStringMap(schema.BubblingType).initComptime(.{
    .{ "DirectEventHandler", .direct },
    .{ "BubblingEventHandler", .bubble },
});

/// 이벤트 prop 이름 → bubble vs direct 분류.
/// 일반적 RN 컨벤션: `onCapture` 접미사가 있으면 direct, 그 외는 bubble.
/// 정확한 분류는 spec 별 paperBubblingType 메타로 결정되지만 PR #3b 스코프에서 단순화.
fn classifyEventBubbling(name: []const u8) schema.BubblingType {
    if (std.mem.endsWith(u8, name, "Capture")) return .direct;
    return .bubble;
}

/// alias 재귀 펼치기 깊이 제한. `type A = B; type B = A;` 같은 cycle 또는 비정상 깊은
/// alias chain (예: 16+ 단계) 이면 fail-fast. RN spec 에서 1-2 단계가 일반적이라 8 충분.
const MAX_ALIAS_DEPTH: u8 = 8;

/// type annotation NodeIndex → PropTypeAnnotation 매핑.
/// 모르는 형태는 UnsupportedPropType. caller 가 JS fallback 으로 처리.
fn mapPropType(
    ast: *const Ast,
    type_index: *const TypeIndex,
    type_idx: NodeIndex,
) Error!schema.PropTypeAnnotation {
    return mapPropTypeAt(ast, type_index, type_idx, 0);
}

fn mapPropTypeAt(
    ast: *const Ast,
    type_index: *const TypeIndex,
    type_idx: NodeIndex,
    depth: u8,
) Error!schema.PropTypeAnnotation {
    if (depth >= MAX_ALIAS_DEPTH) return error.UnsupportedPropType;

    const node = ast.getNode(type_idx);
    return switch (node.tag) {
        .ts_boolean_keyword, .flow_boolean_keyword => .{ .boolean = .{ .default = null } },
        .ts_string_keyword, .flow_string_keyword => .{ .string = .{ .default = null } },
        .ts_number_keyword, .flow_number_keyword => .{ .float = .{ .default = null } },
        // TS 'any' / Flow 'mixed' / 'any' → mixed (codegen 미사용 prop 으로 등록)
        .flow_any_keyword, .flow_mixed_keyword => .mixed,

        // type reference: reserved primitive / wrapper / numeric / alias 펼치기
        .ts_type_reference, .flow_type_reference => mapTypeReference(ast, type_index, node, depth),

        // RN runtime 이 nullable semantics 자체 처리 — wrapper 만 풀고 inner 매핑.
        .flow_nullable_type => mapPropTypeAt(ast, type_index, node.data.unary.operand, depth + 1),

        .ts_union_type, .flow_union_type => mapUnion(ast, node),

        else => error.UnsupportedPropType,
    };
}

/// Union 의 모든 element 가 string literal 이면 string_enum, 그 외엔 mixed.
fn mapUnion(ast: *const Ast, node: Node) Error!schema.PropTypeAnnotation {
    const list = node.data.list;
    if (list.len == 0) return .mixed;

    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const elem_idx: NodeIndex = @enumFromInt(ast.extra_data.items[list.start + i]);
        const elem = ast.getNode(elem_idx);
        if (elem.tag != .ts_literal_type and elem.tag != .flow_literal_type) return .mixed;
        const text = ast.getText(elem.data.string_ref);
        if (text.len < 2) return .mixed;
        const first = text[0];
        if (first != '\'' and first != '"') return .mixed;
    }

    // emitter 가 현재 string_enum 을 단순 `true` attribute 로 출력하므로 default/options
    // 슬라이스는 placeholder. 향후 emitter 확장 시 union element 텍스트를 stripQuote 후
    // options 로 채우도록 본 함수 확장.
    return .{ .string_enum = .{ .default = "", .options = &.{} } };
}

/// type reference 이름 → reserved primitive 매핑. 알려진 RN core 타입 이름들.
/// 매핑 안 되면 type_index 에서 alias 펼쳐 재귀.
fn mapTypeReference(
    ast: *const Ast,
    type_index: *const TypeIndex,
    node: Node,
    depth: u8,
) Error!schema.PropTypeAnnotation {
    const name = getTypeReferenceName(ast, node) orelse return error.UnsupportedPropType;

    if (wrapper_ref_names.get(name)) |kind| {
        const inner = getFirstTypeArgument(ast, node) orelse return error.UnsupportedPropType;
        const inner_prop = try mapPropTypeAt(ast, type_index, inner, depth + 1);
        return switch (kind) {
            // WithDefault<T, D>: D (default literal) 는 향후 PR — ts_literal_type 추출해
            // PropTypeAnnotation.default 채울 예정. 현재는 RN runtime 이 자체 default 사용.
            // UnsafeMixed<T> = T: react-native-svg 의 identity wrapper (folly::dynamic trick).
            .identity => inner_prop,
            .array => .{ .array = try toArrayElement(inner_prop) },
        };
    }

    if (reserved_ref_names.get(name)) |primitive| {
        return .{ .reserved = primitive };
    }
    if (numeric_ref_names.get(name)) |kind| {
        return numericKindToAnnotation(kind);
    }

    // type alias 펼치기 — 같은 파일에 정의된 type X = ... 면 X 의 정의를 재귀 매핑.
    if (type_index.get(name)) |alias_idx| {
        const alias_node = ast.getNode(alias_idx);
        const value_idx: NodeIndex = switch (alias_node.tag) {
            .ts_type_alias_declaration, .flow_type_alias_declaration => v: {
                const e = alias_node.data.extra;
                if (e + 2 >= ast.extra_data.items.len) return error.UnsupportedPropType;
                break :v @enumFromInt(ast.extra_data.items[e + 2]);
            },
            else => return error.UnsupportedPropType,
        };
        return mapPropTypeAt(ast, type_index, value_idx, depth + 1);
    }

    return error.UnresolvedTypeReference;
}

/// RN core 의 reserved type reference 이름 → primitive 매핑.
/// `GenerateViewConfigJs.js:43-108` 의 ReservedPropTypeAnnotation 매핑 그대로.
/// 이름 alias 는 RN 내부 (Flow `*Primitive`, public `*Value`/`*PropType`) 다 포함.
const reserved_ref_names = std.StaticStringMap(schema.ReservedPropPrimitive).initComptime(.{
    .{ "ColorValue", .color },
    .{ "ProcessedColorValue", .color },
    .{ "ColorPrimitive", .color },
    .{ "ImageSource", .image_source },
    .{ "ImageSourcePropType", .image_source },
    .{ "ImageSourcePrimitive", .image_source },
    .{ "PointValue", .point },
    .{ "PointPropType", .point },
    .{ "PointPrimitive", .point },
    .{ "EdgeInsetsValue", .edge_insets },
    .{ "EdgeInsetsPropType", .edge_insets },
    .{ "EdgeInsetsPrimitive", .edge_insets },
    .{ "ImageRequest", .image_request },
    .{ "ImageRequestPrimitive", .image_request },
    .{ "DimensionValue", .dimension },
    .{ "DimensionPrimitive", .dimension },
});

/// 1-인자 generic wrapper — 의미상 inner T 의 transform.
///   - `identity`: T 그대로 (`WithDefault<T, D>`, `UnsafeMixed<T>`).
///   - `array`: `ComponentArrayTypeAnnotation` 으로 lift (`Array<T>`, `ReadonlyArray<T>`).
const WrapperKind = enum { identity, array };
const wrapper_ref_names = std.StaticStringMap(WrapperKind).initComptime(.{
    .{ "WithDefault", .identity },
    .{ "UnsafeMixed", .identity },
    .{ "Array", .array },
    .{ "ReadonlyArray", .array },
});

/// codegen 명시적 numeric type alias — RN spec 에서 흔한 wrapper.
/// `Float`, `Int32`, `Double` 은 AST 의 keyword 가 아니라 type_reference 로 들어옴
/// (codegen 이 Flow `number` 와 구분해 명시적으로 사용하는 약속된 이름).
///
/// PropTypeAnnotation 자체를 StaticStringMap 값으로 두면 generic 타입 추론 실패 —
/// `enum(@enumFromInt(...))` 같은 핸들러가 필요해서 지표만 매핑하고 dispatch.
const NumericKind = enum { float, int32, double };
const numeric_ref_names = std.StaticStringMap(NumericKind).initComptime(.{
    .{ "Float", .float },
    .{ "Int32", .int32 },
    .{ "Double", .double },
});

fn numericKindToAnnotation(kind: NumericKind) schema.PropTypeAnnotation {
    return switch (kind) {
        .float => .{ .float = .{ .default = null } },
        .int32 => .{ .int32 = .{ .default = 0 } },
        .double => .{ .double = .{ .default = 0 } },
    };
}

/// `PropTypeAnnotation` → `ComponentArrayTypeAnnotation` (배열 element 한정).
/// codegen 의 ArrayTypeAnnotation 은 default/options 등 prop 메타를 가지지 않으므로
/// 단순 variant 매핑. `int32_enum` 과 중첩 array 는 RN codegen 에서도 미지원이라 동일.
fn toArrayElement(prop: schema.PropTypeAnnotation) Error!schema.ComponentArrayTypeAnnotation {
    return switch (prop) {
        .boolean => .boolean,
        .string => .string,
        .double => .double,
        .float => .float,
        .int32 => .int32,
        .mixed => .mixed,
        .reserved => |p| .{ .reserved = p },
        .string_enum => |e| .{ .string_enum = e },
        .object => |o| .{ .object = o.properties },
        // int32_enum, array (중첩) 는 RN codegen 도 미지원 — 동일 fail-fast.
        .int32_enum, .array => error.UnsupportedPropType,
    };
}
