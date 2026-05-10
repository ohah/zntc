const std = @import("std");
const builtin = @import("builtin");
const codegen = @import("../codegen/codegen.zig");
const transformer = @import("../transformer/transformer.zig");
const bundler_types = @import("../bundler/types.zig");

const DefineEntry = transformer.DefineEntry;
const TransformOptions = transformer.TransformOptions;

/// 파이프라인 조기 종료 지점. `--stop-after=<phase>` / `stopAfter` 옵션과 매핑.
///
/// 주로 debug/profile 용 — 특정 phase 까지만 실행하고 빈 output 반환. 예를 들어
/// `stop_after = .parse` 이면 AST 는 생성되지만 semantic/transform/codegen 은 skip.
/// `--profile` 과 결합해 phase 별 비용을 격리 측정할 수 있다.
pub const StopAfter = enum {
    scan,
    parse,
    semantic,
    transform,
    codegen,

    pub fn fromString(s: []const u8) ?StopAfter {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, "scan")) return .scan;
        if (std.ascii.eqlIgnoreCase(trimmed, "parse")) return .parse;
        if (std.ascii.eqlIgnoreCase(trimmed, "semantic")) return .semantic;
        if (std.ascii.eqlIgnoreCase(trimmed, "transform")) return .transform;
        if (std.ascii.eqlIgnoreCase(trimmed, "codegen")) return .codegen;
        return null;
    }
};

pub const TranspileOptions = struct {
    // --- 파싱 ---
    flow: bool = false,
    jsx_in_js: bool = false,

    /// 파이프라인 조기 종료 지점. null(기본)이면 codegen 까지 실행.
    /// 지정 시 해당 phase 이후 단계는 skip — debug/profile 용.
    stop_after: ?StopAfter = null,

    // --- 변환 ---
    define: []const DefineEntry = &.{},
    unsupported: TransformOptions.compat.UnsupportedFeatures = .{},
    use_define_for_class_fields: bool = true,
    experimental_decorators: bool = false,
    emit_decorator_metadata: bool = false,
    verbatim_module_syntax: bool = false,
    /// tsconfig.json 경로 (파일 또는 디렉토리). 설정 시 로드해서 compilerOptions 적용.
    /// CLI `-p`/`--project` 의 프로그램적 등가물 — NAPI/WASM 경로에서 같은 동작을 JS 에 제공.
    tsconfig_path: ?[]const u8 = null,
    drop_console: bool = false,
    drop_debugger: bool = false,
    /// React Fast Refresh transform — `$RefreshReg$` (component registration) emit.
    /// loader 등 single-file transpile 경로용 surface (bundler 의 build option 과 별개).
    react_refresh: bool = false,
    /// `react_refresh` 위에 `$RefreshSig$` (hook signature) emit 까지 활성화.
    /// default false — Metro 정책 (signature 없음) 보존, RN build 무영향. opt-in 시
    /// babel-plugin-react-refresh 동등 (component body 시작에 _s() 삽입 + 모듈 끝 _s(Comp, "sig")).
    react_refresh_hook_signatures: bool = false,

    // --- 코드 생성 ---
    module_format: codegen.ModuleFormat = .esm,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    ascii_only: bool = false,
    charset_utf8: bool = false,
    quote_style: codegen.QuoteStyle = .double,
    sourcemap: bool = false,
    /// Sentry Debug ID (--sourcemap-debug-ids). 소스맵 + JS에 동일 UUID를 삽입.
    sourcemap_debug_ids: bool = false,
    /// `--sourcemap` 시 sourceMappingURL footer + map.file 필드에 사용할 출력 파일명
    /// (basename only, 확장자 포함 e.g. "out.js"). null/empty 면 footer 안 부착하고
    /// map.file 은 source path 로 fallback (NAPI/library mode 처럼 *어디로 쓰일지
    /// 모르는* 케이스 — 호출자가 후처리). #2217.
    sourcemap_output_filename: []const u8 = "",
    source_root: []const u8 = "",
    sources_content: bool = true,
    platform: codegen.Platform = .browser,

    // --- JSX ---
    jsx_runtime: codegen.JsxRuntime = .classic,
    jsx_factory: []const u8 = "React.createElement",
    jsx_fragment: []const u8 = "React.Fragment",
    jsx_import_source: []const u8 = "react",

    // --- 타겟 ---
    /// ES 타겟. null이면 타겟 제한 검증 없음.
    /// es2022 미만에서 top-level await 사용 시 진단을 발생시킨다.
    es_target: ?@import("../transformer/compat.zig").ESTarget = null,
};

/// WASM/NAPI 진입점 공용 JSON payload DTO.
/// TS 쪽 TranspileOptions와 camelCase 필드명으로 매핑된다.
/// 모든 필드가 optional이라 누락되어도 기본값 유지.
///
/// enum 타입은 Zig enum을 직접 사용 — std.json이 enum tag name으로 parse.
/// JS 래퍼가 kebab-case "react-native" → "react_native"로 변환해 전달한다.
///
/// 이 struct는 JSON schema emitter(tools/emit_schema.zig)가 comptime
/// `@typeInfo`로 반사해 단일 소스 보장. 필드를 바꾸면 schema도 함께 재생성.
pub const ConfigOptionsDto = struct {
    target: ?@import("../transformer/compat.zig").ESTarget = null,
    unsupported: ?u32 = null,
    flow: ?bool = null,
    jsxInJs: ?bool = null,
    reactRefresh: ?bool = null,
    reactRefreshHookSignatures: ?bool = null,
    jsx: ?codegen.JsxRuntime = null,
    jsxFactory: ?[]const u8 = null,
    jsxFragment: ?[]const u8 = null,
    jsxImportSource: ?[]const u8 = null,
    dropConsole: ?bool = null,
    dropDebugger: ?bool = null,
    asciiOnly: ?bool = null,
    charsetUtf8: ?bool = null,
    experimentalDecorators: ?bool = null,
    emitDecoratorMetadata: ?bool = null,
    useDefineForClassFields: ?bool = null,
    verbatimModuleSyntax: ?bool = null,
    tsconfigPath: ?[]const u8 = null,
    /// inline tsconfig JSON 문자열 (esbuild 의 `tsconfigRaw` 와 동일 의미).
    /// 설정 시 파일 기반 `tsconfigPath` 와 자동 탐색을 모두 무시 — raw 가 단일 진실 원천.
    tsconfigRaw: ?[]const u8 = null,
    format: ?codegen.ModuleFormat = null,
    quotes: ?codegen.QuoteStyle = null,
    platform: ?codegen.Platform = null,
    minifyWhitespace: ?bool = null,
    minifyIdentifiers: ?bool = null,
    minifySyntax: ?bool = null,
    sourcemap: ?bool = null,
    /// 출력 형식 — `"linked"` / `"external"` / `"inline"` (#2152). missing 시 linked.
    /// transpile 모드에선 미사용 (single-file, mode 의미 없음). bundler 만 사용.
    sourcemapMode: ?[]const u8 = null,
    /// CJS / UMD entry export 형식 — `"auto"` / `"named"` / `"default"` / `"none"` (#2159).
    /// missing 시 auto. transpile 모드에선 미사용 — bundler 만.
    outputExports: ?[]const u8 = null,
    sourcemapDebugIds: ?bool = null,
    sourcesContent: ?bool = null,
    sourceRoot: ?[]const u8 = null,
    define: ?[]const DefineEntry = null,
    /// `--stop-after=<phase>` 동등. JSON 값은 `scan`/`parse`/`semantic`/`transform`/`codegen`.
    stopAfter: ?StopAfter = null,

    // ─── bundler-only 필드 (#2105 / Phase 2-3) ─────────────────────────────────
    // 이 필드들은 transpile 모드에선 무시. `applyZntcConfigJson` 이 CliOptions 의
    // bundler 리스트로 매핑한다. function-form `manualChunks` 는 JS-only 라
    // JSON 에서는 record form (`[{name, patterns}]`) 만 지원.
    external: ?[]const []const u8 = null,
    alias: ?[]const AliasDto = null,
    loader: ?[]const LoaderDto = null,
    conditions: ?[]const []const u8 = null,
    resolveExtensions: ?[]const []const u8 = null,
    mainFields: ?[]const []const u8 = null,
    banner: ?[]const u8 = null,
    footer: ?[]const u8 = null,
    assetNames: ?[]const u8 = null,
    chunkNames: ?[]const u8 = null,
    entryNames: ?[]const u8 = null,
    preserveModules: ?bool = null,
    preserveModulesRoot: ?[]const u8 = null,
    inlineDynamicImports: ?bool = null,
    manualChunks: ?[]const ManualChunkDto = null,
};

pub const TranspileOptionsDto = ConfigOptionsDto;

/// `AliasDto` / `ManualChunkDto` 는 `bundler/types.zig` 의 entry 타입과 layout 동일 —
/// silent drift 방지용 직접 재사용 (별도 DTO 유지 시 두 정의 동기화 의무 발생).
/// `LoaderDto` 만 string 표현 vs enum 차이로 별도 유지.
pub const AliasDto = bundler_types.AliasEntry;
pub const ManualChunkDto = bundler_types.ManualChunkEntry;

pub const LoaderDto = struct {
    ext: []const u8,
    loader: []const u8,
};

/// `ConfigOptionsDto` 의 transpile-shaped 필드를 target 으로 매핑하는 공통 helper.
/// `optionsFromJson` (TranspileOptions) 와 `main.applyZntcConfigJson` (CliOptions) 가 공유 —
/// 두 함수의 매핑이 drift 하지 않도록 single source of truth. (memory P2 deferred)
///
/// `dupe_strings` 가 true 면 string 필드를 `allocator.dupe` 로 복사 (long-lived target).
/// false 면 dto 의 string slice 를 그대로 borrow (arena/parsed-from-json lifetime).
///
/// 모든 boolean 필드는 dto 명시 시 always override (true/false 둘 다 set). esbuild/rolldown
/// 정책과 일치 — config 의 explicit 값이 default 를 덮어쓴다.
///
/// caller 가 처리해야 할 차이:
/// - `define` (struct field name 차이: `define` vs `define_list`)
/// - `stopAfter` (struct field name 차이: `stop_after` vs `core_stop_after`)
/// - `tsconfig` merge / bundler-only 필드 (target struct 별로 다름)
pub fn applyTranspileSharedFields(
    target: anytype,
    dto: *const ConfigOptionsDto,
    allocator: std.mem.Allocator,
    comptime dupe_strings: bool,
) !void {
    const compat = @import("../transformer/compat.zig");

    if (dto.target) |t| {
        target.es_target = t;
        // unsupported 가 명시되지 않았으면 target 으로부터 자동 도출.
        if (dto.unsupported == null) {
            target.unsupported = compat.fromESTarget(t);
        }
    }
    if (dto.unsupported) |u| target.unsupported = @bitCast(u);
    if (dto.flow) |v| target.flow = v;
    if (dto.jsxInJs) |v| target.jsx_in_js = v;
    // CliOptions 미보유 — bundler 는 BuildOptionsCommon 으로 별도 surface 사용.
    if (dto.reactRefresh) |v| if (@hasField(@TypeOf(target.*), "react_refresh")) {
        target.react_refresh = v;
    };
    if (dto.reactRefreshHookSignatures) |v| if (@hasField(@TypeOf(target.*), "react_refresh_hook_signatures")) {
        target.react_refresh_hook_signatures = v;
    };
    if (dto.jsx) |v| target.jsx_runtime = v;
    if (dto.jsxFactory) |s| if (s.len > 0) {
        target.jsx_factory = if (dupe_strings) try allocator.dupe(u8, s) else s;
    };
    if (dto.jsxFragment) |s| if (s.len > 0) {
        target.jsx_fragment = if (dupe_strings) try allocator.dupe(u8, s) else s;
    };
    if (dto.jsxImportSource) |s| if (s.len > 0) {
        target.jsx_import_source = if (dupe_strings) try allocator.dupe(u8, s) else s;
    };
    if (dto.dropConsole) |v| target.drop_console = v;
    if (dto.dropDebugger) |v| target.drop_debugger = v;
    if (dto.asciiOnly) |v| target.ascii_only = v;
    if (dto.charsetUtf8) |v| target.charset_utf8 = v;
    if (dto.experimentalDecorators) |v| target.experimental_decorators = v;
    if (dto.emitDecoratorMetadata) |v| target.emit_decorator_metadata = v;
    if (dto.useDefineForClassFields) |v| target.use_define_for_class_fields = v;
    if (dto.verbatimModuleSyntax) |v| target.verbatim_module_syntax = v;
    if (dto.tsconfigPath) |s| if (s.len > 0) {
        const dup = if (dupe_strings) try allocator.dupe(u8, s) else s;
        // CliOptions 는 historical 이유로 같은 의미 필드를 `project_path` 로 보유 (`-p` /
        // `--project` / `--tsconfig-path` 모두 이 한 필드로 통일). TranspileOptions 는
        // `tsconfig_path` 사용. 둘 중 존재하는 쪽으로 set.
        const T = @TypeOf(target.*);
        if (@hasField(T, "tsconfig_path")) {
            target.tsconfig_path = dup;
        } else if (@hasField(T, "project_path")) {
            target.project_path = dup;
        }
    };
    if (dto.format) |v| target.module_format = v;
    if (dto.quotes) |v| target.quote_style = v;
    if (dto.platform) |v| target.platform = v;
    if (dto.minifyWhitespace) |v| target.minify_whitespace = v;
    if (dto.minifyIdentifiers) |v| target.minify_identifiers = v;
    if (dto.minifySyntax) |v| target.minify_syntax = v;
    if (dto.sourcemap) |v| target.sourcemap = v;
    if (dto.sourcemapDebugIds) |v| target.sourcemap_debug_ids = v;
    if (dto.sourcesContent) |v| target.sources_content = v;
    if (dto.sourceRoot) |s| if (s.len > 0) {
        target.source_root = if (dupe_strings) try allocator.dupe(u8, s) else s;
    };
}

/// JSON payload를 파싱해 `TranspileOptions`로 변환한다.
/// allocator는 arena 권장 — 반환된 값의 문자열/슬라이스 수명을 책임진다.
/// `findTsconfigUpward` / `loadFromPath` 가 dup 한 메모리도 같은 arena 가 reap.
///
/// `entry_path` 가 non-null 이고 명시적 `tsconfigPath` 가 없으면, `dirname(entry_path)` 부터
/// 위로 올라가며 `tsconfig.json` 을 자동 탐색한다 (esbuild/vite 식 zero-config).
/// `entry_path` 가 디렉토리 부분이 없는 bare filename (예: `"input.ts"`) 이면 cwd 부터 탐색.
/// 자동 탐색을 원치 않는 caller (예: file 시스템 접근이 없는 WASM) 는 `null` 을 전달.
///
/// 오류: JSON 파싱 실패 / 알 수 없는 enum 문자열 → error 반환.
pub fn optionsFromJson(
    allocator: std.mem.Allocator,
    json: []const u8,
    entry_path: ?[]const u8,
) !TranspileOptions {
    const parsed = std.json.parseFromSliceLeaky(ConfigOptionsDto, allocator, json, .{ .ignore_unknown_fields = true }) catch return error.InvalidOptions;

    var opts: TranspileOptions = .{};

    try applyTranspileSharedFields(&opts, &parsed, allocator, false);
    if (parsed.define) |d| opts.define = d;
    if (parsed.stopAfter) |v| opts.stop_after = v;

    // tsconfig 로드 + merge — JSON 에 명시적으로 설정된 값이 tsconfig 값을 덮어쓴다.
    // raw 우선 (esbuild 동등): `tsconfigRaw` 가 있으면 file 기반 path / 자동 탐색 모두 무시.
    // raw 파싱 실패는 사용자 입력 에러로 명시적 propagate, file 실패는 ambient 라 silent.
    // WASM 타겟은 file 시스템 접근 불가 — file/자동 탐색 분기 모두 스킵 (raw 는 무관하게 동작).
    const TsConfig = @import("../config.zig").TsConfig;
    const tsconfig_merge = @import("../tsconfig_merge.zig");
    const can_load_tsconfig_file = builtin.os.tag != .wasi and builtin.os.tag != .freestanding;
    const ts: TsConfig = blk: {
        if (parsed.tsconfigRaw) |raw| {
            break :blk TsConfig.parseFromString(allocator, raw) catch return error.InvalidOptions;
        }
        if (can_load_tsconfig_file) {
            // 명시 path > entry 디렉토리에서 위로 자동 탐색 (esbuild/vite 식 zero-config).
            const resolved_path: ?[]const u8 = opts.tsconfig_path orelse find: {
                const path = entry_path orelse break :find null;
                break :find TsConfig.autodiscoverFromEntry(allocator, path);
            };
            if (resolved_path) |p| {
                break :blk TsConfig.loadFromPath(allocator, p) catch TsConfig{};
            }
        }
        break :blk TsConfig{};
    };
    // arena 가 ts._allocated_strings 도 reap — 개별 deinit 금지 (CLAUDE.md memory 가이드).

    const merged = tsconfig_merge.merge(&ts, .{
        .experimental_decorators = parsed.experimentalDecorators,
        .emit_decorator_metadata = parsed.emitDecoratorMetadata,
        .use_define_for_class_fields = parsed.useDefineForClassFields,
        .verbatim_module_syntax = parsed.verbatimModuleSyntax,
        .sourcemap = parsed.sourcemap,
        .es_target = parsed.target,
        .unsupported = if (parsed.unsupported) |u| @bitCast(u) else null,
        .jsx_runtime = parsed.jsx,
        .jsx_factory = parsed.jsxFactory,
        .jsx_fragment = parsed.jsxFragment,
        .jsx_import_source = parsed.jsxImportSource,
    });
    opts.experimental_decorators = merged.experimental_decorators;
    opts.emit_decorator_metadata = merged.emit_decorator_metadata;
    opts.use_define_for_class_fields = merged.use_define_for_class_fields;
    opts.verbatim_module_syntax = merged.verbatim_module_syntax;
    opts.sourcemap = merged.sourcemap;
    opts.es_target = merged.es_target;
    opts.unsupported = merged.unsupported;
    opts.jsx_runtime = merged.jsx_runtime;
    opts.jsx_factory = merged.jsx_factory;
    opts.jsx_fragment = merged.jsx_fragment;
    opts.jsx_import_source = merged.jsx_import_source;

    return opts;
}
