//! tsconfig.json compilerOptions → ZNTC 트랜스파일/번들 옵션 병합 헬퍼.
//!
//! `transpile.zig optionsFromJson`, `packages/core/src/napi_entry.zig parseBuildOptions`,
//! `main.zig` CLI 3 경로에 산재하던 머지 규칙을 한 곳에 모은다.
//! 모든 경로가 동일한 우선순위(명시적 사용자 값 > tsconfig > default)를 공유.
//!
//! 사용법:
//!   const explicit = ExplicitFlags{ .verbatim_module_syntax = js_value };
//!   const merged = merge(&tsconfig, explicit);
//!   options.verbatim_module_syntax = merged.verbatim_module_syntax;

const std = @import("std");
const compat = @import("transformer/compat.zig");
const codegen = @import("codegen/codegen.zig");
const TsConfig = @import("config.zig").TsConfig;

/// 사용자(CLI/JS/JSON)가 명시적으로 설정한 값. null = 미지정 → tsconfig fallback.
pub const ExplicitFlags = struct {
    experimental_decorators: ?bool = null,
    emit_decorator_metadata: ?bool = null,
    use_define_for_class_fields: ?bool = null,
    verbatim_module_syntax: ?bool = null,
    sourcemap: ?bool = null,
    /// 명시적으로 설정된 ES 타겟. null이고 `unsupported` 도 null이면 tsconfig의 "target" 문자열을 파싱.
    es_target: ?compat.ESTarget = null,
    /// 명시적으로 계산된 unsupported bitmask (browserslist 해석 결과 등).
    /// non-null 이면 es_target 기반 fallback 을 우회한다.
    unsupported: ?compat.UnsupportedFeatures = null,
    /// 명시적으로 설정된 JSX 런타임. null 이면 tsconfig 의 "jsx" 문자열을 매핑.
    jsx_runtime: ?codegen.JsxRuntime = null,
    /// 명시적 jsx factory. null = 미지정 → tsconfig fallback.
    jsx_factory: ?[]const u8 = null,
    /// 명시적 jsx fragment. null = 미지정 → tsconfig fallback.
    jsx_fragment: ?[]const u8 = null,
    /// 명시적 jsx import source. null = 미지정 → tsconfig fallback.
    jsx_import_source: ?[]const u8 = null,
};

/// 모든 필드가 확정된 최종 값.
pub const MergedFlags = struct {
    experimental_decorators: bool,
    emit_decorator_metadata: bool,
    use_define_for_class_fields: bool,
    verbatim_module_syntax: bool,
    sourcemap: bool,
    es_target: ?compat.ESTarget,
    unsupported: compat.UnsupportedFeatures,
    jsx_runtime: codegen.JsxRuntime,
    jsx_factory: []const u8,
    jsx_fragment: []const u8,
    jsx_import_source: []const u8,
};

/// tsconfig 의 "jsx" 문자열 값을 ZNTC 의 `JsxRuntime` 으로 매핑.
/// "preserve" 와 인식 못 하는 값은 null — caller 가 default(`.classic`) 를 적용.
fn mapTsConfigJsxToRuntime(tsconfig_jsx: ?[]const u8) ?codegen.JsxRuntime {
    const s = tsconfig_jsx orelse return null;
    if (std.mem.eql(u8, s, "react")) return .classic;
    if (std.mem.eql(u8, s, "react-jsx")) return .automatic;
    if (std.mem.eql(u8, s, "react-jsxdev")) return .automatic_dev;
    return null;
}

/// `ExplicitFlags` 와 tsconfig 값을 우선순위 규칙에 따라 병합한다.
/// `emit_decorator_metadata` 는 `experimental_decorators` 가 활성화된 경우에만
/// tsconfig 값이 적용되도록 강제 — tsc 공식 규칙.
pub fn merge(ts: *const TsConfig, explicit: ExplicitFlags) MergedFlags {
    const experimental_decorators = explicit.experimental_decorators orelse ts.experimental_decorators;
    const es_target: ?compat.ESTarget = explicit.es_target orelse blk: {
        if (ts.target) |t_str| break :blk std.meta.stringToEnum(compat.ESTarget, t_str);
        break :blk null;
    };
    return .{
        .experimental_decorators = experimental_decorators,
        .emit_decorator_metadata = explicit.emit_decorator_metadata orelse
            (ts.emit_decorator_metadata and experimental_decorators),
        .use_define_for_class_fields = explicit.use_define_for_class_fields orelse
            (ts.use_define_for_class_fields orelse true),
        .verbatim_module_syntax = explicit.verbatim_module_syntax orelse ts.verbatim_module_syntax,
        .sourcemap = explicit.sourcemap orelse ts.source_map,
        .es_target = es_target,
        .unsupported = explicit.unsupported orelse blk: {
            if (es_target) |t| break :blk compat.fromESTarget(t);
            break :blk .{};
        },
        .jsx_runtime = explicit.jsx_runtime orelse mapTsConfigJsxToRuntime(ts.jsx) orelse .classic,
        .jsx_factory = explicit.jsx_factory orelse ts.jsx_factory,
        .jsx_fragment = explicit.jsx_fragment orelse ts.jsx_fragment_factory,
        .jsx_import_source = explicit.jsx_import_source orelse ts.jsx_import_source,
    };
}

// ─── 테스트 ───

test "merge: explicit values win over tsconfig" {
    var ts = TsConfig{};
    ts.experimental_decorators = true;
    ts.verbatim_module_syntax = true;

    const merged = merge(&ts, .{
        .experimental_decorators = false,
        .verbatim_module_syntax = false,
    });
    try std.testing.expect(merged.experimental_decorators == false);
    try std.testing.expect(merged.verbatim_module_syntax == false);
}

test "merge: tsconfig fills unset fields" {
    var ts = TsConfig{};
    ts.verbatim_module_syntax = true;
    ts.experimental_decorators = true;

    const merged = merge(&ts, .{});
    try std.testing.expect(merged.experimental_decorators == true);
    try std.testing.expect(merged.verbatim_module_syntax == true);
}

test "merge: emit_decorator_metadata requires experimental_decorators" {
    var ts = TsConfig{};
    ts.emit_decorator_metadata = true;
    // experimental_decorators 가 켜지지 않았으면 emit_decorator_metadata 도 비활성 (tsc 규칙)
    const merged_off = merge(&ts, .{});
    try std.testing.expect(merged_off.emit_decorator_metadata == false);

    // experimental_decorators 가 켜지면 함께 활성
    ts.experimental_decorators = true;
    const merged_on = merge(&ts, .{});
    try std.testing.expect(merged_on.emit_decorator_metadata == true);
}

test "merge: target string is parsed to ESTarget" {
    var ts = TsConfig{};
    ts.target = "es2020";
    const merged = merge(&ts, .{});
    try std.testing.expect(merged.es_target != null);
    try std.testing.expect(merged.es_target.? == .es2020);
    // unsupported 비트도 자동 파생
    try std.testing.expect(merged.unsupported.top_level_await);
}

test "merge: explicit unsupported wins over target-derived" {
    var ts = TsConfig{};
    ts.target = "es2020";
    const merged = merge(&ts, .{
        .unsupported = .{},
    });
    try std.testing.expect(merged.unsupported.top_level_await == false);
}

test "merge: jsx runtime maps tsconfig 'jsx' string" {
    var ts = TsConfig{};

    ts.jsx = "react";
    try std.testing.expect(merge(&ts, .{}).jsx_runtime == .classic);

    ts.jsx = "react-jsx";
    try std.testing.expect(merge(&ts, .{}).jsx_runtime == .automatic);

    ts.jsx = "react-jsxdev";
    try std.testing.expect(merge(&ts, .{}).jsx_runtime == .automatic_dev);
}

test "merge: explicit jsx runtime wins over tsconfig" {
    var ts = TsConfig{};
    ts.jsx = "react-jsx";
    const merged = merge(&ts, .{ .jsx_runtime = .classic });
    try std.testing.expect(merged.jsx_runtime == .classic);
}

test "merge: preserve / unknown jsx falls back to default classic" {
    var ts = TsConfig{};

    ts.jsx = "preserve";
    try std.testing.expect(merge(&ts, .{}).jsx_runtime == .classic);

    ts.jsx = "react-native";
    try std.testing.expect(merge(&ts, .{}).jsx_runtime == .classic);
}

test "merge: jsx factory/fragment/importSource pass through tsconfig" {
    var ts = TsConfig{};
    ts.jsx_factory = "h";
    ts.jsx_fragment_factory = "Frag";
    ts.jsx_import_source = "preact";
    const merged = merge(&ts, .{});
    try std.testing.expectEqualStrings("h", merged.jsx_factory);
    try std.testing.expectEqualStrings("Frag", merged.jsx_fragment);
    try std.testing.expectEqualStrings("preact", merged.jsx_import_source);
}

test "merge: explicit jsx factory wins over tsconfig" {
    var ts = TsConfig{};
    ts.jsx_factory = "tsconfigFactory";
    ts.jsx_fragment_factory = "tsconfigFragment";
    ts.jsx_import_source = "tsconfigSource";
    const merged = merge(&ts, .{
        .jsx_factory = "explicitFactory",
        .jsx_fragment = "explicitFragment",
        .jsx_import_source = "explicitSource",
    });
    try std.testing.expectEqualStrings("explicitFactory", merged.jsx_factory);
    try std.testing.expectEqualStrings("explicitFragment", merged.jsx_fragment);
    try std.testing.expectEqualStrings("explicitSource", merged.jsx_import_source);
}

test "merge: jsx defaults preserved when neither tsconfig nor explicit set" {
    const ts = TsConfig{};
    const merged = merge(&ts, .{});
    // TsConfig 의 default 가 그대로 흘러 옴 — TsConfig 가 단일 진실 원천.
    try std.testing.expect(merged.jsx_runtime == .classic);
    try std.testing.expectEqualStrings("React.createElement", merged.jsx_factory);
    try std.testing.expectEqualStrings("React.Fragment", merged.jsx_fragment);
    try std.testing.expectEqualStrings("react", merged.jsx_import_source);
}
