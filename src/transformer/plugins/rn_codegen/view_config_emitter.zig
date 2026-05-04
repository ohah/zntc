//! View Config Emitter — `ComponentShape` → JS 문자열.
//!
//! `@react-native/codegen` 의 `GenerateViewConfigJs.generate()` (`lib/generators/components/
//! GenerateViewConfigJs.js:210-298`) 와 동등한 출력을 생성한다. 출력은 spec 파일에 그대로
//! inline 되어 RN 런타임 (`NativeComponentRegistry.get`) 이 바이트 단위로 비교 — Metro
//! 의 emit 결과와 정합해야 한다.
//!
//! 출력 형식 (RN 0.78 호환):
//!
//! ```js
//! const __INTERNAL_VIEW_CONFIG = {
//!   uiViewClassName: 'ComponentName',
//!   validAttributes: {
//!     color: { process: require('react-native/Libraries/StyleSheet/processColor').default },
//!     onSomeEvent: true,
//!     ...
//!   },
//!   bubblingEventTypes: {
//!     topSomeEvent: { phasedRegistrationNames: { bubbled: 'onSomeEvent', captured: 'onSomeEventCapture' } }
//!   },
//!   directEventTypes: {
//!     topOtherEvent: { registrationName: 'onOtherEvent' }
//!   }
//! };
//! ```
//!
//! RN 버전 매트릭스: 현재는 가장 옛 형태 (0.78 호환) 로 emit. RN 0.85+ 가 도입한
//! `ReactNativeStyleAttributes.colorAttribute` 같은 신 형태는 옛 RN 에 없으므로
//! 하위 호환을 위해 옛 형태 유지. 새 RN minor 에서 emit 형태가 깨지면 version 분기
//! 추가 (#2348 § 7).
//!
//! 메모리: caller 가 alloc 제공. 반환 슬라이스는 alloc 소유 — caller 가 free.

const std = @import("std");
const schema = @import("schema.zig");

/// RN 0.78+ 호환 require() 문자열 — `validAttributes` 의 reserved primitive 매핑.
/// RN 0.85+ 가 도입한 `ReactNativeStyleAttributes.colorAttribute` 같은 신 형태는 옛 RN 에 없어
/// 하위 호환을 위해 옛 형태 유지. 새 RN minor 가 emit 형태를 깨면 (~연 1회, #2348 § 7)
/// 본 const set 을 버전별로 분기.
const REQUIRE_PROCESS_COLOR =
    "{ process: require('react-native/Libraries/StyleSheet/processColor').default }";
const REQUIRE_RESOLVE_ASSET_SOURCE =
    "{ process: require('react-native/Libraries/Image/resolveAssetSource') }";
const REQUIRE_POINTS_DIFFER =
    "{ diff: require('react-native/Libraries/Utilities/differ/pointsDiffer') }";
const REQUIRE_INSETS_DIFFER =
    "{ diff: require('react-native/Libraries/Utilities/differ/insetsDiffer') }";
const REQUIRE_PROCESS_COLOR_ARRAY =
    "{ process: require('react-native/Libraries/StyleSheet/processColorArray') }";

/// ComponentShape 를 view config JS 문자열로 직렬화.
/// 반환된 슬라이스는 `alloc` 으로 할당 — caller 가 `alloc.free()` 책임.
pub fn emit(shape: schema.ComponentShape, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "const __INTERNAL_VIEW_CONFIG = {\n");

    // RN runtime 의 `uiViewClassName` 은 Paper(legacy) 호환을 위해 `paperComponentName`
    // 우선 사용 — `shape.nativeName()`. RN native 측이 RCT-prefix 형태로 등록한 클래스를
    // 못 찾으면 컴포넌트 렌더링 자체가 깨짐 (#2462).
    try buf.appendSlice(alloc, "  uiViewClassName: '");
    try buf.appendSlice(alloc, shape.nativeName());
    try buf.appendSlice(alloc, "',\n");

    try emitValidAttributes(&buf, shape, alloc);

    if (countByBubbling(shape.events, .bubble) > 0) {
        try emitBubblingEventTypes(&buf, shape.events, alloc);
    }
    if (countByBubbling(shape.events, .direct) > 0) {
        try emitDirectEventTypes(&buf, shape.events, alloc);
    }

    try buf.appendSlice(alloc, "};\n");
    return buf.toOwnedSlice(alloc);
}

fn countByBubbling(events: []const schema.EventTypeShape, kind: schema.BubblingType) usize {
    var n: usize = 0;
    for (events) |e| if (e.bubbling_type == kind) {
        n += 1;
    };
    return n;
}

fn emitValidAttributes(
    buf: *std.ArrayList(u8),
    shape: schema.ComponentShape,
    alloc: std.mem.Allocator,
) !void {
    try buf.appendSlice(alloc, "  validAttributes: {\n");
    for (shape.props) |prop| {
        try buf.appendSlice(alloc, "    ");
        try emitKey(buf, prop.name, alloc);
        try buf.appendSlice(alloc, ": ");
        try emitAttributeValue(buf, prop.type_annotation, alloc);
        try buf.appendSlice(alloc, ",\n");
    }
    // 모든 이벤트도 validAttributes 에 `true` 로 등록 (Metro 동일).
    for (shape.events) |event| {
        try buf.appendSlice(alloc, "    ");
        try emitKey(buf, event.name, alloc);
        try buf.appendSlice(alloc, ": true,\n");
    }
    try buf.appendSlice(alloc, "  },\n");
}

/// prop / event 이름이 식별자로 적합하면 그대로, `aria-label` 같은 dash 포함이면 quote.
fn emitKey(buf: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    if (isValidIdentifier(name)) {
        try buf.appendSlice(alloc, name);
    } else {
        try buf.append(alloc, '\'');
        try buf.appendSlice(alloc, name);
        try buf.append(alloc, '\'');
    }
}

/// ASCII-only identifier 검증. JS 자체는 unicode 식별자 허용하지만 RN spec 의 prop
/// 이름은 영문/숫자/언더스코어/달러로 제한됨 (Metro/codegen 컨벤션). unicode prop 은
/// 어차피 RN 런타임이 못 다루므로 quoted key 처리로 fallback.
fn isValidIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!isIdentStart(first)) return false;
    for (name[1..]) |c| if (!isIdentPart(c)) return false;
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// `PropTypeAnnotation` → validAttributes value JS 표현.
/// 매핑은 `GenerateViewConfigJs.js:43-108` 의 `getReactDiffProcessValue()` 와 동등.
fn emitAttributeValue(
    buf: *std.ArrayList(u8),
    type_ann: schema.PropTypeAnnotation,
    alloc: std.mem.Allocator,
) !void {
    switch (type_ann) {
        .boolean, .string, .int32, .float, .double, .mixed, .string_enum, .int32_enum => {
            try buf.appendSlice(alloc, "true");
        },
        .reserved => |primitive| try emitReservedPrimitive(buf, primitive, alloc),
        .object => {
            // nested object — 현재 schema_builder 미지원이라 도달 안 함. 안전상 true.
            try buf.appendSlice(alloc, "true");
        },
        .array => |element| try emitArrayElement(buf, element, alloc),
    }
}

fn emitReservedPrimitive(
    buf: *std.ArrayList(u8),
    primitive: schema.ReservedPropPrimitive,
    alloc: std.mem.Allocator,
) !void {
    switch (primitive) {
        .color => try buf.appendSlice(alloc, REQUIRE_PROCESS_COLOR),
        .image_source => try buf.appendSlice(alloc, REQUIRE_RESOLVE_ASSET_SOURCE),
        .point => try buf.appendSlice(alloc, REQUIRE_POINTS_DIFFER),
        .edge_insets => try buf.appendSlice(alloc, REQUIRE_INSETS_DIFFER),
        // image_request, dimension — 기본 처리만, RN 0.78 에선 별도 wrapper 없음.
        .image_request, .dimension => try buf.appendSlice(alloc, "true"),
    }
}

fn emitArrayElement(
    buf: *std.ArrayList(u8),
    element: schema.ComponentArrayTypeAnnotation,
    alloc: std.mem.Allocator,
) !void {
    switch (element) {
        .reserved => |p| switch (p) {
            .color => try buf.appendSlice(alloc, REQUIRE_PROCESS_COLOR_ARRAY),
            else => try buf.appendSlice(alloc, "true"),
        },
        else => try buf.appendSlice(alloc, "true"),
    }
}

fn emitBubblingEventTypes(
    buf: *std.ArrayList(u8),
    events: []const schema.EventTypeShape,
    alloc: std.mem.Allocator,
) !void {
    try buf.appendSlice(alloc, "  bubblingEventTypes: {\n");
    for (events) |event| {
        if (event.bubbling_type != .bubble) continue;
        try emitBubblingEntry(buf, event.name, alloc);
    }
    try buf.appendSlice(alloc, "  },\n");
}

fn emitDirectEventTypes(
    buf: *std.ArrayList(u8),
    events: []const schema.EventTypeShape,
    alloc: std.mem.Allocator,
) !void {
    try buf.appendSlice(alloc, "  directEventTypes: {\n");
    for (events) |event| {
        if (event.bubbling_type != .direct) continue;
        try emitDirectEntry(buf, event.name, alloc);
    }
    try buf.appendSlice(alloc, "  },\n");
}

fn emitBubblingEntry(buf: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    // event name `on*` → 키는 `top*`, bubbled 는 원본 (`onChange`), captured 는 `onChangeCapture`.
    const top_name = try toTopEventName(name, alloc);
    defer alloc.free(top_name);

    try buf.appendSlice(alloc, "    ");
    try buf.appendSlice(alloc, top_name);
    try buf.appendSlice(alloc, ": { phasedRegistrationNames: { bubbled: '");
    try buf.appendSlice(alloc, name);
    try buf.appendSlice(alloc, "', captured: '");
    try buf.appendSlice(alloc, name);
    try buf.appendSlice(alloc, "Capture' } },\n");
}

fn emitDirectEntry(buf: *std.ArrayList(u8), name: []const u8, alloc: std.mem.Allocator) !void {
    const top_name = try toTopEventName(name, alloc);
    defer alloc.free(top_name);

    try buf.appendSlice(alloc, "    ");
    try buf.appendSlice(alloc, top_name);
    try buf.appendSlice(alloc, ": { registrationName: '");
    try buf.appendSlice(alloc, name);
    try buf.appendSlice(alloc, "' },\n");
}

/// `onChange` → `topChange`. `GenerateViewConfigJs.js:153-160` 의
/// `normalizeInputEventName` 와 동등.
///
/// RN spec 컨벤션상 event prop 은 항상 `on` prefix — schema_builder 가 function-typed
/// prop 만 event 로 분류하므로 이 진입점에서 `on` prefix 없는 케이스는 spec 위반.
/// 디버그 빌드에서 assert 로 잡고, release 에선 입력 그대로 사용.
fn toTopEventName(name: []const u8, alloc: std.mem.Allocator) ![]u8 {
    std.debug.assert(std.mem.startsWith(u8, name, "on") and name.len > 2);
    const stem = name[2..];
    const out = try alloc.alloc(u8, 3 + stem.len);
    @memcpy(out[0..3], "top");
    @memcpy(out[3..], stem);
    return out;
}
