//! view_config_emitter.zig 단위 테스트.
//!
//! 직접 ComponentShape 를 만들어 emit() 통과시키고 출력 문자열을 검증.
//! schema_builder + emitter 통합은 각 별개 테스트로 격리.

const std = @import("std");
const schema = @import("schema.zig");
const emitter = @import("view_config_emitter.zig");

const NamedShape = schema.NamedShape;

/// 출력에 expected 부분 문자열이 포함되는지 검증 (전체 비교는 fragility 큼).
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to contain:\n  {s}\nactual:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "view_config_emitter: empty component" {
    const shape: schema.ComponentShape = .{
        .name = "EmptyView",
        .props = &.{},
        .events = &.{},
    };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "const __INTERNAL_VIEW_CONFIG = {");
    try expectContains(out, "uiViewClassName: 'EmptyView'");
    try expectContains(out, "validAttributes: {");
    try expectContains(out, "};");
    // empty 라 bubblingEventTypes / directEventTypes 키는 등장하지 않아야 함.
    try std.testing.expect(std.mem.indexOf(u8, out, "bubblingEventTypes") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "directEventTypes") == null);
}

test "view_config_emitter: primitive props → true" {
    const props = [_]NamedShape(schema.PropTypeAnnotation){
        .{ .name = "enabled", .optional = false, .type_annotation = .{ .boolean = .{ .default = null } } },
        .{ .name = "label", .optional = false, .type_annotation = .{ .string = .{ .default = null } } },
        .{ .name = "size", .optional = false, .type_annotation = .{ .float = .{ .default = null } } },
    };
    const shape: schema.ComponentShape = .{ .name = "Btn", .props = &props, .events = &.{} };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "enabled: true");
    try expectContains(out, "label: true");
    try expectContains(out, "size: true");
}

test "view_config_emitter: ColorValue → processColor wrapper" {
    const props = [_]NamedShape(schema.PropTypeAnnotation){
        .{ .name = "tint", .optional = false, .type_annotation = .{ .reserved = .color } },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &props, .events = &.{} };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "tint: { process: require('react-native/Libraries/StyleSheet/processColor').default }");
}

test "view_config_emitter: ImageSource / Point / EdgeInsets → diff/process require" {
    const props = [_]NamedShape(schema.PropTypeAnnotation){
        .{ .name = "src", .optional = false, .type_annotation = .{ .reserved = .image_source } },
        .{ .name = "origin", .optional = false, .type_annotation = .{ .reserved = .point } },
        .{ .name = "insets", .optional = false, .type_annotation = .{ .reserved = .edge_insets } },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &props, .events = &.{} };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "src: { process: require('react-native/Libraries/Image/resolveAssetSource') }");
    try expectContains(out, "origin: { diff: require('react-native/Libraries/Utilities/differ/pointsDiffer') }");
    try expectContains(out, "insets: { diff: require('react-native/Libraries/Utilities/differ/insetsDiffer') }");
}

test "view_config_emitter: bubble events → bubblingEventTypes with phasedRegistrationNames" {
    const events = [_]schema.EventTypeShape{
        .{ .name = "onChange", .bubbling_type = .bubble, .optional = false },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &.{}, .events = &events };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    // event validAttributes 는 RN 0.83 codegen 과 동일하게 platform wrapper 로 감싼다.
    try expectContains(out, "ConditionallyIgnoredEventHandlers({");
    try expectContains(out, "onChange: true");
    try expectContains(out, "bubblingEventTypes: {");
    try expectContains(out, "topChange: { phasedRegistrationNames: { bubbled: 'onChange', captured: 'onChangeCapture' } }");
    try std.testing.expect(std.mem.indexOf(u8, out, "directEventTypes") == null);
}

test "view_config_emitter: direct events → directEventTypes with registrationName" {
    const events = [_]schema.EventTypeShape{
        .{ .name = "onScrollCapture", .bubbling_type = .direct, .optional = false },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &.{}, .events = &events };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "directEventTypes: {");
    try expectContains(out, "topScrollCapture: { registrationName: 'onScrollCapture' }");
    try std.testing.expect(std.mem.indexOf(u8, out, "bubblingEventTypes") == null);
}

test "view_config_emitter: mixed bubble + direct events" {
    const events = [_]schema.EventTypeShape{
        .{ .name = "onChange", .bubbling_type = .bubble, .optional = false },
        .{ .name = "onScrollCapture", .bubbling_type = .direct, .optional = false },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &.{}, .events = &events };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "bubblingEventTypes: {");
    try expectContains(out, "topChange:");
    try expectContains(out, "directEventTypes: {");
    try expectContains(out, "topScrollCapture:");
    try expectContains(out, "ConditionallyIgnoredEventHandlers({");
    try expectContains(out, "onChange: true");
    try expectContains(out, "onScrollCapture: true");
}

test "view_config_emitter: dash-containing key gets quoted" {
    const props = [_]NamedShape(schema.PropTypeAnnotation){
        .{ .name = "aria-label", .optional = false, .type_annotation = .{ .string = .{ .default = null } } },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &props, .events = &.{} };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "'aria-label': true");
}

test "view_config_emitter: array<color> → processColorArray" {
    const props = [_]NamedShape(schema.PropTypeAnnotation){
        .{
            .name = "colors",
            .optional = false,
            .type_annotation = .{ .array = .{ .reserved = .color } },
        },
    };
    const shape: schema.ComponentShape = .{ .name = "X", .props = &props, .events = &.{} };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    try expectContains(out, "colors: { process: require('react-native/Libraries/StyleSheet/processColorArray') }");
}

test "view_config_emitter: full shape — name + 2 props + 2 events" {
    const props = [_]NamedShape(schema.PropTypeAnnotation){
        .{ .name = "color", .optional = false, .type_annotation = .{ .reserved = .color } },
        .{ .name = "enabled", .optional = false, .type_annotation = .{ .boolean = .{ .default = null } } },
    };
    const events = [_]schema.EventTypeShape{
        .{ .name = "onChange", .bubbling_type = .bubble, .optional = false },
        .{ .name = "onLayout", .bubbling_type = .direct, .optional = false },
    };
    const shape: schema.ComponentShape = .{ .name = "MyView", .props = &props, .events = &events };

    const out = try emitter.emit(shape, std.testing.allocator);
    defer std.testing.allocator.free(out);

    // 핵심 영역 모두 포함 확인.
    try expectContains(out, "uiViewClassName: 'MyView'");
    try expectContains(out, "color: { process: require");
    try expectContains(out, "enabled: true");
    try expectContains(out, "onChange: true");
    try expectContains(out, "onLayout: true");
    try expectContains(out, "topChange: { phasedRegistrationNames");
    try expectContains(out, "topLayout: { registrationName: 'onLayout' }");
}
