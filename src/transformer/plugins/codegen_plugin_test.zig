//! codegen_plugin.zig 단위 테스트.
//!
//! plugin.transform 훅을 직접 호출해 입력 → 변환 결과 검증.

const std = @import("std");
const codegen_plugin = @import("codegen_plugin.zig");

fn callTransform(alloc: std.mem.Allocator, code: []const u8, id: []const u8) !?[]const u8 {
    const plugin = codegen_plugin.plugin();
    return plugin.transform.?(plugin.context, code, id, alloc);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to contain:\n  {s}\nactual:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

test "codegen_plugin: non-spec filename → null" {
    const code = "type X = { color: string };";
    const out = try callTransform(std.testing.allocator, code, "/path/to/foo.ts");
    try std.testing.expect(out == null);
}

test "codegen_plugin: spec filename without codegenNativeComponent → null" {
    const code = "type X = { color: string };";
    const out = try callTransform(std.testing.allocator, code, "/path/to/FooNativeComponent.ts");
    try std.testing.expect(out == null);
}

test "codegen_plugin: TS spec → emits __INTERNAL_VIEW_CONFIG and registry" {
    const code =
        \\type NativeProps = {
        \\  color: string;
        \\  enabled: boolean;
        \\};
        \\export default codegenNativeComponent<NativeProps>('MyView');
    ;
    const out_opt = try callTransform(std.testing.allocator, code, "/path/MyViewNativeComponent.ts");
    try std.testing.expect(out_opt != null);
    const out = out_opt.?;
    defer std.testing.allocator.free(out);

    try expectContains(out, "NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry')");
    try expectContains(out, "let nativeComponentName = 'MyView'");
    try expectContains(out, "const __INTERNAL_VIEW_CONFIG = {");
    try expectContains(out, "uiViewClassName: 'MyView'");
    try expectContains(out, "color: true");
    try expectContains(out, "enabled: true");
    try expectContains(
        out,
        "export default NativeComponentRegistry.get(nativeComponentName, () => __INTERNAL_VIEW_CONFIG)",
    );
}

test "codegen_plugin: ColorValue → reserved.color in output" {
    const code =
        \\type NativeProps = { tint: ColorValue };
        \\export default codegenNativeComponent<NativeProps>('Tinted');
    ;
    const out_opt = try callTransform(std.testing.allocator, code, "/path/TintedNativeComponent.ts");
    try std.testing.expect(out_opt != null);
    const out = out_opt.?;
    defer std.testing.allocator.free(out);

    try expectContains(out, "tint: { process: require('react-native/Libraries/StyleSheet/processColor').default }");
}

test "codegen_plugin: Readonly<{...}> wrapper unwrap" {
    const code =
        \\type NativeProps = Readonly<{ color: string }>;
        \\export default codegenNativeComponent<NativeProps>('X');
    ;
    const out_opt = try callTransform(std.testing.allocator, code, "/path/XNativeComponent.ts");
    try std.testing.expect(out_opt != null);
    const out = out_opt.?;
    defer std.testing.allocator.free(out);

    try expectContains(out, "color: true");
}

test "codegen_plugin: cross-file type reference → null (fallback)" {
    // ViewProps 가 type_index 에 없음 — schema_builder 가 UnresolvedTypeReference,
    // plugin 은 silent skip → 원본 사용.
    const code =
        \\type NativeProps = { extra: ViewProps };
        \\export default codegenNativeComponent<NativeProps>('X');
    ;
    const out = try callTransform(std.testing.allocator, code, "/path/XNativeComponent.ts");
    try std.testing.expect(out == null);
}

test "codegen_plugin: function-typed prop → event in output" {
    const code =
        \\type NativeProps = {
        \\  color: string;
        \\  onChange: (e: SyntheticEvent) => void;
        \\};
        \\export default codegenNativeComponent<NativeProps>('Btn');
    ;
    const out_opt = try callTransform(std.testing.allocator, code, "/path/BtnNativeComponent.ts");
    try std.testing.expect(out_opt != null);
    const out = out_opt.?;
    defer std.testing.allocator.free(out);

    try expectContains(out, "bubblingEventTypes: {");
    try expectContains(out, "topChange:");
    try expectContains(out, "phasedRegistrationNames");
}
