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
//!   - **Inheritance composition** (#2348 후속): TS `interface X extends A, B { ... }` 의
//!     base 가 같은 파일에 정의돼 있으면 재귀 unwrap 후 멤버 머지. 같은 파일에 없으면
//!     cross-file (ViewProps 등) — silent skip (RN 런타임이 등록).
//!   - **Intersection**: TS `A & B & {...}` — 각 operand 재귀 처리. base 가 type ref 면
//!     인헤리턴스와 동일 정책.
//!   - Property → PropTypeAnnotation 매핑 (`GenerateViewConfigJs.js:43-108` 참고)
//!   - Function-typed prop (`(event: T) => void`) → EventTypeShape
//!   - Identity / default wrapper: `WithDefault<T, D>`, `UnsafeMixed<T>` → inner T
//!   - Generic array: `Array<T>` / `ReadonlyArray<T>` → ComponentArrayTypeAnnotation
//!   - Flow nullable: `?T` → inner T (RN runtime 이 nullable semantics 처리)
//!   - Union: 모든 element 가 string literal 이면 `string_enum`, 아니면 `mixed`
//!   - Explicit event wrapper: `DirectEventHandler<T>` / `BubblingEventHandler<T>`
//!     → EventTypeShape (wrapper 이름이 bubble vs direct 결정)
//!
//! Cross-file type reference (`import type { ViewProps }`) 는 silent skip —
//! 인헤리턴스 base 일 때는 RN 런타임 등록에 위임, prop type 일 때는 `mixed` 처리 또는
//! `error.UnresolvedTypeReference` (caller 가 JS fallback 으로 처리, #2348 § 5).
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
    /// **Reserved for strict mode**: 인헤리턴스 지원 도입 (#2348 후속) 이후 hot path
    /// 에서는 `mapTypeReference` 가 `.mixed` 로 permissive fallback. 현재 throw 안 됨.
    /// 추후 `BUNGAE_CODEGEN_FALLBACK=strict` 같은 toggle 도입 시 재활성화 예정.
    /// public error code (`zts1400`) 호환을 위해 enum 변형 유지.
    UnresolvedTypeReference,
    /// 인식 못 하는 prop type 형태.
    UnsupportedPropType,
    /// NativeProps 가 object literal 도 wrapper 도 아님.
    InvalidNativePropsBody,
    /// 인헤리턴스 / 인터섹션 chain 깊이 한계 초과 (cycle 또는 이상 구조).
    InheritanceTooDeep,
    OutOfMemory,
};

/// 인헤리턴스 / intersection / wrapper / type ref 추적 시 stack overflow / cycle 방어.
/// RN 실제 spec 패턴은 2-3 레벨 — 10 은 충분히 보수적.
const max_inheritance_depth: u8 = 10;

/// 인헤리턴스 walk 시 같은 declaration 을 두 번 진입하지 않도록 추적. diamond inheritance
/// (`Props extends A, B; A extends Common; B extends Common`) 에서 Common 의 멤버가 중복
/// 출현하는 것 방지. 또한 transitive 그래프에서 shared base 재방문으로 인한 O(n²) 도 차단.
const VisitedSet = std.AutoHashMapUnmanaged(NodeIndex, void);

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
    var visited: VisitedSet = .{};
    defer visited.deinit(alloc);
    var members_buf = std.ArrayList(NodeIndex).empty;
    defer members_buf.deinit(alloc);
    try collectAllMembers(ast, type_index, native_props_idx, &members_buf, &visited, 0, alloc);

    var props_buf = std.ArrayList(schema.NamedShape(schema.PropTypeAnnotation)).empty;
    defer props_buf.deinit(alloc);
    var events_buf = std.ArrayList(schema.EventTypeShape).empty;
    defer events_buf.deinit(alloc);

    for (members_buf.items) |sig_idx| {
        try classifyMember(ast, type_index, sig_idx, &props_buf, &events_buf, alloc);
    }

    // TS/Flow override 시멘틱 정합 (#2418): 같은 이름 prop/event 가 base + derived 양쪽에
    // 있으면 position 은 base (첫 occurrence 유지), type 은 derived (마지막 occurrence) 가 이김.
    try dedupByName(schema.NamedShape(schema.PropTypeAnnotation), &props_buf, alloc);
    try dedupByName(schema.EventTypeShape, &events_buf, alloc);

    return .{
        .name = component_name,
        .props = try props_buf.toOwnedSlice(alloc),
        .events = try events_buf.toOwnedSlice(alloc),
    };
}

/// 같은 `.name` 을 가진 항목을 dedup. **TS/Flow override 시멘틱 정합**:
///   - position: 첫 occurrence (`keyof T` / IDE 자동완성과 동일한 declaration order)
///   - type: 마지막 occurrence (derived 가 base 의 타입을 override)
///
/// O(n) — name → write_index HashMap 으로 단일 패스. 첫 등장이면 append, 재등장이면
/// 이전 슬롯 덮어쓰기 (last-type wins, position 보존).
fn dedupByName(comptime T: type, list: *std.ArrayList(T), alloc: std.mem.Allocator) !void {
    var first_idx: std.StringHashMapUnmanaged(usize) = .{};
    defer first_idx.deinit(alloc);

    var write: usize = 0;
    for (list.items) |item| {
        if (first_idx.get(item.name)) |slot| {
            list.items[slot] = item; // last-type override
        } else {
            list.items[write] = item;
            try first_idx.put(alloc, item.name, write);
            write += 1;
        }
    }
    list.shrinkRetainingCapacity(write);
}

/// declaration 1 개로부터 _자기 본문 + 인헤리턴스 chain 의 모든 base_ 의 멤버 평탄화 수집.
///
/// 지원 declaration tag:
///   - ts_interface_declaration: extends list 재귀 + 본문 멤버
///   - ts_type_alias_declaration / flow_type_alias_declaration / flow_opaque_type:
///     value 가 intersection / type ref / object literal 인지에 따라 분기 (collectMembersFromValue)
///
/// 같은 파일 내 base 만 추적, 못 찾으면 silent skip (cross-file ViewProps 등은 RN 런타임 위임).
fn collectAllMembers(
    ast: *const Ast,
    type_index: *const TypeIndex,
    decl_idx: NodeIndex,
    out: *std.ArrayList(NodeIndex),
    visited: *VisitedSet,
    depth: u8,
    alloc: std.mem.Allocator,
) Error!void {
    if (depth > max_inheritance_depth) return error.InheritanceTooDeep;

    // diamond / shared-base 중복 방문 차단.
    const v = try visited.getOrPut(alloc, decl_idx);
    if (v.found_existing) return;

    const node = ast.getNode(decl_idx);
    switch (node.tag) {
        .ts_interface_declaration, .flow_interface_declaration => {
            // 두 태그 모두 layout: [name, type_params, extends_start, extends_len, body].
            // TS interface 와 Flow interface 의 schema_builder 처리 동등 (#2348 후속, #2416).
            const e = node.data.extra;
            if (e + 4 >= ast.extra_data.items.len) return error.InvalidNativePropsBody;
            // extends list — 본문 머지 _전에_ base 먼저 (override 시 본문이 이김 같지만
            // codegen 은 모두 합쳐 RN 런타임에 등록하므로 순서 무관).
            const extends_start = ast.extra_data.items[e + 2];
            const extends_len = ast.extra_data.items[e + 3];
            var i: u32 = 0;
            while (i < extends_len) : (i += 1) {
                const ref_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extends_start + i]);
                try collectMembersFromTypeRef(ast, type_index, ref_idx, out, visited, depth + 1, alloc);
            }
            const body_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 4]);
            try collectMembersFromValue(ast, type_index, body_idx, out, visited, depth + 1, alloc);
        },
        .ts_type_alias_declaration, .flow_type_alias_declaration => {
            const e = node.data.extra;
            if (e + 2 >= ast.extra_data.items.len) return error.InvalidNativePropsBody;
            const value_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 2]);
            try collectMembersFromValue(ast, type_index, value_idx, out, visited, depth + 1, alloc);
        },
        .flow_opaque_type => {
            const e = node.data.extra;
            if (e + 3 >= ast.extra_data.items.len) return error.InvalidNativePropsBody;
            const value_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 3]);
            try collectMembersFromValue(ast, type_index, value_idx, out, visited, depth + 1, alloc);
        },
        else => return error.InvalidNativePropsBody,
    }
}

/// type 의 value (object literal / intersection / type reference / wrapper) 에서 멤버 추출.
/// 재귀 — wrapper / intersection operand / type ref 모두 통과시켜 평탄화.
fn collectMembersFromValue(
    ast: *const Ast,
    type_index: *const TypeIndex,
    value_idx: NodeIndex,
    out: *std.ArrayList(NodeIndex),
    visited: *VisitedSet,
    depth: u8,
    alloc: std.mem.Allocator,
) Error!void {
    if (depth > max_inheritance_depth) return error.InheritanceTooDeep;
    // body 가 비어 있는 declaration (예: flow_interface_declaration body=.none) — silent skip.
    if (value_idx.isNone()) return;

    const unwrapped = try unwrapWrapper(ast, type_index, value_idx);
    const node = ast.getNode(unwrapped);
    switch (node.tag) {
        .ts_intersection_type => {
            // realloc-safe — collectMembersFromValue 재귀가 addNode/addExtras 가능 (#2422 패턴).
            var iter = ast.iterateExtraList(node.data.list);
            while (iter.next()) |op| {
                try collectMembersFromValue(ast, type_index, op, out, visited, depth + 1, alloc);
            }
        },
        .ts_type_reference, .flow_type_reference => {
            try collectMembersFromTypeRef(ast, type_index, unwrapped, out, visited, depth + 1, alloc);
        },
        .ts_type_literal, .flow_object_type, .flow_exact_object_type => {
            try collectObjectMembersInto(ast, type_index, unwrapped, out, visited, depth + 1, alloc);
        },
        // 그 외 (string literal, primitive, function 등) — base 로 부적절. silent skip.
        else => return,
    }
}

/// type reference 1 개를 처리 — name 조회 후 same-file declaration 발견 시 재귀 추적.
/// cross-file (lookup 실패) 은 silent skip.
fn collectMembersFromTypeRef(
    ast: *const Ast,
    type_index: *const TypeIndex,
    ref_idx: NodeIndex,
    out: *std.ArrayList(NodeIndex),
    visited: *VisitedSet,
    depth: u8,
    alloc: std.mem.Allocator,
) Error!void {
    if (depth > max_inheritance_depth) return error.InheritanceTooDeep;

    const ref_node = ast.getNode(ref_idx);
    if (ref_node.tag != .ts_type_reference and ref_node.tag != .flow_type_reference) return;

    const ref_name = getTypeReferenceName(ast, ref_node) orelse return;
    const last = lastSegment(ref_name);

    // wrapper (Readonly<T> 등) 이면 inner 로 풀어 재귀.
    if (isReadonlyWrapperName(last)) {
        const inner = getNthTypeArgument(ast, ref_node, 0) orelse return;
        try collectMembersFromValue(ast, type_index, inner, out, visited, depth + 1, alloc);
        return;
    }

    // TS utility types `Pick<T, K>` / `Omit<T, K>` (#2417) — T 의 멤버 수집 후 K 의
    // string union 으로 필터. K 가 cross-file alias (예: `keyof RemoteX`) 면 silent skip.
    if (std.mem.eql(u8, last, "Pick") or std.mem.eql(u8, last, "Omit")) {
        const is_pick = std.mem.eql(u8, last, "Pick");
        try collectPickOmitMembers(ast, type_index, ref_node, is_pick, out, visited, depth + 1, alloc);
        return;
    }

    // same-file lookup — found 면 declaration body 재귀. Namespace 가 있으면 (점 포함)
    // local type_index 에 없으니 자연스레 cross-file 분기로 떨어짐.
    if (type_index.get(ref_name)) |decl_idx| {
        try collectAllMembers(ast, type_index, decl_idx, out, visited, depth + 1, alloc);
        return;
    }

    // cross-file (e.g. ViewProps from 'react-native') — silent skip per #2348 plan.
}

/// `Pick<T, K>` / `Omit<T, K>` 처리 (#2417). K 는 single string literal 또는 그 union 만
/// 지원 — 그 외 (type ref 등) silent skip. Parser 가 union 을 flat NodeList 로 저장
/// (`ts.zig:649`, `flow.zig:126`) 하므로 단일 레벨만 보면 됨.
fn collectPickOmitMembers(
    ast: *const Ast,
    type_index: *const TypeIndex,
    ref_node: Node,
    is_pick: bool,
    out: *std.ArrayList(NodeIndex),
    visited: *VisitedSet,
    depth: u8,
    alloc: std.mem.Allocator,
) Error!void {
    const t_idx = getNthTypeArgument(ast, ref_node, 0) orelse return;
    const k_idx = getNthTypeArgument(ast, ref_node, 1) orelse return;

    // K 의 string literal 이름들을 stack 에 수집. 미지원 K 면 null → silent skip.
    var k_names_buf: [32][]const u8 = undefined;
    const k_names = collectStringLiteralNames(ast, k_idx, &k_names_buf) orelse return;

    var t_members = std.ArrayList(NodeIndex).empty;
    defer t_members.deinit(alloc);
    try collectMembersFromValue(ast, type_index, t_idx, &t_members, visited, depth + 1, alloc);

    for (t_members.items) |sig_idx| {
        const sig = ast.getNode(sig_idx);
        if (sig.tag != .ts_property_signature and sig.tag != .flow_property_signature) {
            try out.append(alloc, sig_idx); // spread 등 비-property 는 통과
            continue;
        }
        const key_idx: NodeIndex = @enumFromInt(ast.extra_data.items[sig.data.extra]);
        const name = extractKeyName(ast, key_idx) orelse continue;
        const in_k = stringInList(name, k_names);
        if (in_k == is_pick) try out.append(alloc, sig_idx);
    }
}

/// K 가 string literal (또는 그 union) 이면 이름들을 buf 에 채우고 슬라이스 반환.
/// 32 개 초과하거나 미지원 형태 (type ref, non-string literal) 면 null.
fn collectStringLiteralNames(ast: *const Ast, k_idx: NodeIndex, buf: *[32][]const u8) ?[][]const u8 {
    const k = ast.getNode(k_idx);
    switch (k.tag) {
        .ts_literal_type, .flow_literal_type => {
            const name = stripStringLiteral(ast, k) orelse return null;
            buf[0] = name;
            return buf[0..1];
        },
        .ts_union_type, .flow_union_type => {
            const len = k.data.list.len;
            if (len == 0 or len > buf.len) return null;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const elem = ast.readExtraNodeUnchecked(k.data.list.start, i);
                buf[i] = stripStringLiteral(ast, ast.getNode(elem)) orelse return null;
            }
            return buf[0..len];
        },
        else => return null,
    }
}

/// literal_type 노드가 quoted string 이면 unquoted text 반환, 아니면 null.
fn stripStringLiteral(ast: *const Ast, node: Node) ?[]const u8 {
    if (node.tag != .ts_literal_type and node.tag != .flow_literal_type) return null;
    const text = ast.getText(node.data.string_ref);
    if (text.len < 2) return null;
    if (text[0] != '\'' and text[0] != '"') return null;
    return stripQuotes(text);
}

fn stringInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// object body NodeIndex 의 property_signature 를 out 에 append. 비-object body 는 silent skip.
/// `flow_object_spread_property` (`{...A}`) 는 argument 의 type ref 로 재귀 (#2416).
fn collectObjectMembersInto(
    ast: *const Ast,
    type_index: *const TypeIndex,
    body_idx: NodeIndex,
    out: *std.ArrayList(NodeIndex),
    visited: *VisitedSet,
    depth: u8,
    alloc: std.mem.Allocator,
) Error!void {
    if (depth > max_inheritance_depth) return error.InheritanceTooDeep;

    const node = ast.getNode(body_idx);
    const list = switch (node.tag) {
        .ts_type_literal, .flow_object_type, .flow_exact_object_type => node.data.list,
        else => return,
    };

    // realloc-safe — spread argument 재귀가 collectMembersFromValue 통해 extra_data grow 가능.
    var iter = ast.iterateExtraList(list);
    while (iter.next()) |idx| {
        const child = ast.getNode(idx);
        switch (child.tag) {
            .ts_property_signature, .flow_property_signature => try out.append(alloc, idx),
            .flow_object_spread_property => {
                // Flow spread `...A` — argument 의 type ref 로 재귀. cross-file 은 silent skip.
                try collectMembersFromValue(ast, type_index, child.data.unary.operand, out, visited, depth + 1, alloc);
            },
            else => continue,
        }
    }
}

/// `Readonly<T>` / `$ReadOnly<T>` 같은 well-known wrapper 를 풀어 inner object 반환.
/// Wrapper 가 아니면 입력 그대로.
fn unwrapWrapper(ast: *const Ast, type_index: *const TypeIndex, idx: NodeIndex) Error!NodeIndex {
    const node = ast.getNode(idx);
    const ref_name = switch (node.tag) {
        .ts_type_reference, .flow_type_reference => getTypeReferenceName(ast, node) orelse return idx,
        else => return idx,
    };

    if (!isReadonlyWrapperName(lastSegment(ref_name))) return idx;

    // type argument 추출 — Readonly<T> 의 T.
    const inner = getNthTypeArgument(ast, node, 0) orelse return idx;
    // 재귀 unwrap (이중 wrapper 케이스). 단, 제자리 무한루프 방지 — index=0 결과만.
    return unwrapWrapper(ast, type_index, inner);
}

fn isReadonlyWrapperName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Readonly") or
        std.mem.eql(u8, name, "$ReadOnly");
}

/// type_reference node 에서 0-indexed type argument 추출. `Foo<A, B>` 의 index=0 → A.
/// type_reference layout (`flow.zig:472`, `ts.zig:994`): `extra = [name_start, name_end, type_args]`.
/// type_args 는 ts_type_parameter_instantiation / flow_type_parameter_instantiation (NodeList layout).
fn getNthTypeArgument(ast: *const Ast, node: Node, index: u32) ?NodeIndex {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return null;
    const args_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 2]);
    if (args_idx == .none) return null;

    const args_node = ast.getNode(args_idx);
    if (args_node.tag != .ts_type_parameter_instantiation and
        args_node.tag != .flow_type_parameter_instantiation) return null;

    if (index >= args_node.data.list.len) return null;
    return ast.readExtraNodeUnchecked(args_node.data.list.start, index);
}

/// type_reference 의 name 텍스트 추출. extra[0..2] 가 source 의 name span.
/// Namespace-qualified (`NS.Foo`) 형태도 source 그대로 (점 포함) 반환 — caller 가
/// well-known map lookup 시 `lastSegment` 로 마지막 segment 만 비교해야 한다.
fn getTypeReferenceName(ast: *const Ast, node: Node) ?[]const u8 {
    const e = node.data.extra;
    if (e + 1 >= ast.extra_data.items.len) return null;
    const start = ast.extra_data.items[e];
    const end = ast.extra_data.items[e + 1];
    if (end <= start or end > ast.source.len) return null;
    return ast.source[start..end];
}

/// Qualified name 의 마지막 segment 반환 — `import type { X as NS } from '...'` 후
/// `NS.Foo` 형태의 RN 0.85+ 표준 패턴 (`CodegenTypes as CT` 등) 을 well-known map
/// (event_handler_names / wrapper_ref_names / reserved_ref_names / numeric_ref_names)
/// 매칭에 동등 처리하기 위한 helper. 점 없으면 입력 그대로.
///
/// 주의: type_index (사용자 정의 alias) lookup 에는 사용 X — `NS.LocalAlias` 가
/// 우연히 같은 이름의 로컬 alias 와 매칭되어 cross-namespace pollution 일어남.
fn lastSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return name[dot + 1 ..];
    return name;
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
    return event_handler_names.get(lastSegment(name));
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

    var iter = ast.iterateExtraList(list);
    while (iter.next()) |elem_idx| {
        if (stripStringLiteral(ast, ast.getNode(elem_idx)) == null) return .mixed;
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
    const last = lastSegment(name);

    if (wrapper_ref_names.get(last)) |kind| {
        const inner = getNthTypeArgument(ast, node, 0) orelse return error.UnsupportedPropType;
        const inner_prop = try mapPropTypeAt(ast, type_index, inner, depth + 1);
        return switch (kind) {
            // WithDefault<T, D>: D (default literal) 는 향후 PR — ts_literal_type 추출해
            // PropTypeAnnotation.default 채울 예정. 현재는 RN runtime 이 자체 default 사용.
            // UnsafeMixed<T> = T: react-native-svg 의 identity wrapper (folly::dynamic trick).
            .identity => inner_prop,
            .array => .{ .array = try toArrayElement(inner_prop) },
        };
    }

    if (reserved_ref_names.get(last)) |primitive| {
        return .{ .reserved = primitive };
    }
    if (numeric_ref_names.get(last)) |kind| {
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

    // 동일-파일 정의 없음 + 모든 알려진 wrapper / reserved / numeric 등록에도 없음 →
    // cross-file user-defined ref. RN runtime 은 mixed 를 accept-any 로 처리하므로
    // permissive fallback. 특히 react-native-svg 의 `UnsafeMixed<NumberProp>` 같은
    // wrapper 안에 들어 있으면 `UnsafeMixed` 자체 의도가 "loose typing" 이라 정합.
    // strict 검증이 필요하면 사용자가 BUNGAE_CODEGEN_FALLBACK=js 로 JS plugin 위임.
    return .mixed;
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
