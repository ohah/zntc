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

test "codegen_plugin: non-js/ts extension → null (fast skip)" {
    const code = "export default codegenNativeComponent<X>('Foo');";
    const out = try callTransform(std.testing.allocator, code, "/path/foo.css");
    try std.testing.expect(out == null);
}

test "codegen_plugin: file without codegenNativeComponent marker → null" {
    const code = "type X = { color: string };";
    const out = try callTransform(std.testing.allocator, code, "/path/to/FooNativeComponent.ts");
    try std.testing.expect(out == null);
}

test "codegen_plugin: filename without NativeComponent suffix is processed" {
    // filename suffix 제약 제거 — AST 레벨 (findComponentName) 이 spec 파일 정확히 식별.
    // 사용자 정의 spec (e.g. `MySpec.ts`) 도 codegenNativeComponent 호출 있으면 변환.
    const code =
        \\type NativeProps = { color: string };
        \\export default codegenNativeComponent<NativeProps>('My');
    ;
    const out_opt = try callTransform(std.testing.allocator, code, "/path/MySpec.ts");
    try std.testing.expect(out_opt != null);
    const out = out_opt.?;
    defer std.testing.allocator.free(out);
    try expectContains(out, "uiViewClassName: 'My'");
}

test "codegen_plugin: marker present but not in export default → null (AST-level reject)" {
    // 단순 substring 매치는 통과하지만 AST 레벨에서 export default 가 아니므로 거부.
    const code =
        \\const codegenNativeComponent = require('rn');
        \\const x = codegenNativeComponent('Foo');
    ;
    const out = try callTransform(std.testing.allocator, code, "/path/Helper.ts");
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

test "codegen_plugin: cross-file type reference → mixed (permissive, #2348 후속)" {
    // ViewProps 가 type_index 에 없음. 종전엔 schema_builder 가 UnresolvedTypeReference 던져
    // plugin 이 fallback 했지만, 인헤리턴스 지원 도입 시 base 의 prop type 으로 노출되는
    // cross-file ref (NumberProp 등) 가 spec 통째 거부 야기 → permissive `mixed` 로 변경.
    // 현재는 변환 성공 (mixed prop 으로 inline). strict 검증 필요 시 사용자가
    // BUNGAE_CODEGEN_FALLBACK=js 로 JS plugin 위임.
    const code =
        \\type NativeProps = { extra: ViewProps };
        \\export default codegenNativeComponent<NativeProps>('X');
    ;
    const out_opt = try callTransform(std.testing.allocator, code, "/path/XNativeComponent.ts");
    try std.testing.expect(out_opt != null);
    const out = out_opt.?;
    defer std.testing.allocator.free(out);
    // mixed prop 은 emitter 에서 단순 attribute 로 처리.
    try expectContains(out, "uiViewClassName");
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
