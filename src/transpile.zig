//! 단일 소스 트랜스파일 — I/O 없는 순수 함수.
//!
//! 입력: 소스 문자열 + 파일 경로(확장자 감지용) + 옵션
//! 출력: 변환된 JS 코드 (allocator 소유, caller가 free)
//!
//! 용도:
//!   - main.zig의 CLI transpileFile에서 핵심 로직으로 사용
//!   - bundler에서 폴리필 Flow strip
//!   - 향후 NAPI 바인딩의 단일 파일 API

const std = @import("std");
const builtin = @import("builtin");
const Scanner = @import("lexer/mod.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const ast_mod = @import("parser/ast.zig");
const Ast = ast_mod.Ast;
const ast_walk = @import("parser/ast_walk.zig");
const SemanticAnalyzer = @import("semantic/mod.zig").SemanticAnalyzer;
const Transformer = @import("transformer/transformer.zig").Transformer;
const TransformOptions = @import("transformer/transformer.zig").TransformOptions;
const BindingLite = @import("transformer/transformer.zig").BindingLite;
const DefineEntry = @import("transformer/transformer.zig").DefineEntry;
const Codegen = @import("codegen/codegen.zig").Codegen;
const SourceMap = @import("codegen/sourcemap.zig");
const Mangler = @import("codegen/mod.zig").mangler;
const module_parser = @import("parser/module.zig");
const bundler_types = @import("bundler/types.zig");
const LinkingMetadata = @import("bundler/linker.zig").LinkingMetadata;
const rt = @import("bundler/runtime_helpers.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const OwnedDiagnostic = @import("diagnostic.zig").OwnedDiagnostic;
const string_list = @import("util/string_list.zig");
const debug_log = @import("debug_log.zig");

const SemanticRequirement = enum {
    none,
    bindings,
    full,
};

const SemanticPlanReason = enum {
    simple_ts_strip,
    disabled_by_env,
    stop_after_semantic,
    non_ts_source,
    flow_source,
    jsx_source,
    option_requires_transform_semantic,
    target_requires_downlevel,
    module_format_requires_semantic,
    ast_requires_runtime_transform,
    import_shape_requires_full_semantic,
    binding_shadow_requires_full_semantic,
    named_import_binding_elision,
};

const TransformPlan = struct {
    semantic: SemanticRequirement,
    reason: SemanticPlanReason,
    strip_types_only: bool = false,
};

/// `buildTransformPlan` 의 게이팅 입력. 각 플래그는 plan 분기에서 1회씩만 소비되므로,
/// 카테고리별로 묶어 둔다 (개별 tag 단위 정보가 필요해지면 분리).
const AstFacts = struct {
    /// `import_declaration` 노드 존재 여부. binding-lite elision 가능성 판정.
    has_import_declaration: bool = false,
    /// default / namespace import — binding-lite 는 named 만 다루므로 모두 full path 로 위임.
    has_non_named_import: bool = false,
    /// class / private / decorator / TS 런타임 구문 (`enum`, `namespace`, `import =`,
    /// `export =`, `namespace export`) / `using` — runtime transform 필요.
    has_runtime_sensitive_syntax: bool = false,
};

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

    // --- 코드 생성 ---
    module_format: @import("codegen/codegen.zig").ModuleFormat = .esm,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    ascii_only: bool = false,
    charset_utf8: bool = false,
    quote_style: @import("codegen/codegen.zig").QuoteStyle = .double,
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
    platform: @import("codegen/codegen.zig").Platform = .browser,

    // --- JSX ---
    jsx_runtime: @import("codegen/codegen.zig").JsxRuntime = .classic,
    jsx_factory: []const u8 = "React.createElement",
    jsx_fragment: []const u8 = "React.Fragment",
    jsx_import_source: []const u8 = "react",

    // --- 타겟 ---
    /// ES 타겟. null이면 타겟 제한 검증 없음.
    /// es2022 미만에서 top-level await 사용 시 진단을 발생시킨다.
    es_target: ?@import("transformer/compat.zig").ESTarget = null,
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
    target: ?@import("transformer/compat.zig").ESTarget = null,
    unsupported: ?u32 = null,
    flow: ?bool = null,
    jsxInJs: ?bool = null,
    jsx: ?@import("codegen/codegen.zig").JsxRuntime = null,
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
    format: ?@import("codegen/codegen.zig").ModuleFormat = null,
    quotes: ?@import("codegen/codegen.zig").QuoteStyle = null,
    platform: ?@import("codegen/codegen.zig").Platform = null,
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
    // 이 필드들은 transpile 모드에선 무시. `applyZtsConfigJson` 이 CliOptions 의
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
/// `optionsFromJson` (TranspileOptions) 와 `main.applyZtsConfigJson` (CliOptions) 가 공유 —
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
    const compat = @import("transformer/compat.zig");

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
    const TsConfig = @import("config.zig").TsConfig;
    const tsconfig_merge = @import("tsconfig_merge.zig");
    const can_load_tsconfig_file = @import("builtin").os.tag != .wasi and @import("builtin").os.tag != .freestanding;
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

pub const TranspileError = error{
    ParseError,
    SemanticError,
    TransformError,
    CodegenError,
    OutOfMemory,
};

/// 에러 발생 시 호출되는 콜백. scanner와 source가 유효한 동안 호출됨.
/// main.zig에서 코드 프레임 출력용으로 사용.
pub const ErrorCallback = *const fn (
    source: []const u8,
    file_path: []const u8,
    scanner: *const Scanner,
    errors: []const Diagnostic,
) void;

pub const TranspileResult = struct {
    /// 변환된 JS 코드. allocator 소유.
    code: []const u8,
    /// 소스맵 JSON (sourcemap=true일 때). allocator 소유. null이면 미생성.
    sourcemap: ?[]const u8 = null,
    /// 런타임 헬퍼 포함 여부
    has_helpers: bool = false,
    /// 시맨틱 에러 목록 (tsc 호환: codegen과 함께 반환).
    /// allocator 소유. 각 항목은 arena에서 복사된 OwnedDiagnostic.
    /// 파서 에러는 throw 경로라 여기 담기지 않는다 — on_error 콜백 참조.
    diagnostics: []const OwnedDiagnostic = &.{},
    /// 소스의 줄 시작 오프셋. diagnostics 렌더링에 필요.
    /// allocator 소유. diagnostics가 비었으면 비어 있을 수 있다.
    line_offsets: []const u32 = &.{},

    pub fn deinit(self: *TranspileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.sourcemap) |sm| allocator.free(sm);
        for (self.diagnostics) |d| d.deinit(allocator);
        if (self.diagnostics.len > 0) allocator.free(self.diagnostics);
        if (self.line_offsets.len > 0) allocator.free(self.line_offsets);
    }
};

/// `prefix` 가 null/빈 문자열이면 `body` 그대로, 아니면 `prefix + body` 의 새 buffer 반환.
/// OOM 시 fallback 으로 body 그대로 반환 (transpile output 보존). JSX/cssProp 의 module-level
/// import auto-inject 둘 다 같은 모양이라 공유.
fn prependImportLine(allocator: std.mem.Allocator, prefix: ?[]const u8, body: []const u8) []const u8 {
    const p = prefix orelse return body;
    if (p.len == 0) return body;
    var combined: std.ArrayList(u8) = .empty;
    combined.ensureTotalCapacity(allocator, p.len + body.len) catch return body;
    combined.appendSliceAssumeCapacity(p);
    combined.appendSliceAssumeCapacity(body);
    return combined.items;
}

var fast_path_disabled_once = std.once(computeFastPathDisabledByEnv);
var fast_path_disabled_value: bool = false;

fn computeFastPathDisabledByEnv() void {
    if (comptime builtin.os.tag == .wasi and !builtin.link_libc) {
        fast_path_disabled_value = false;
        return;
    }
    fast_path_disabled_value = std.process.hasEnvVarConstant("ZTS_DISABLE_TRANSPILE_FAST_PATH");
}

fn transpileFastPathDisabledByEnv() bool {
    fast_path_disabled_once.call();
    return fast_path_disabled_value;
}

fn collectAstFacts(ast: *const Ast) AstFacts {
    var facts: AstFacts = .{};

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .import_declaration => facts.has_import_declaration = true,
            .import_default_specifier,
            .import_namespace_specifier,
            => facts.has_non_named_import = true,

            .class_declaration,
            .class_expression,
            .private_identifier,
            .private_field_expression,
            .decorator,
            .ts_enum_declaration,
            .ts_module_declaration,
            .ts_import_equals_declaration,
            .ts_export_assignment,
            .ts_namespace_export_declaration,
            => facts.has_runtime_sensitive_syntax = true,

            .variable_declaration => {
                if (ast.variableDeclarationKind(node).isUsing()) {
                    facts.has_runtime_sensitive_syntax = true;
                }
            },

            else => {},
        }
    }

    return facts;
}

// 한 함수 / 한 var 리스트 / 한 import 절에서 매칭되는 import 이름 수의 상한.
// 초과 시 scan 은 over-conservative 로 full route 를 택하고 mark 는 shadow 를 누락해도
// outer import 가 used 로 마킹되어 import 가 보존된다.
const binding_lite_max_shadows: usize = 64;

// default/namespace specifier 는 collectAstFacts 에서 has_non_named_import 로 잡혀
// buildTransformPlan 이 이미 full 로 라우팅하므로 여기서는 named 만 본다.
// import local 노드는 identifier_reference 로 태깅되므로 binding_identifier 필터에 자연히 빠진다.
// 함수 파라미터 / catch / block lexical shadow 는 binding-lite walker 가 scope-aware 로
// 처리한다. top-level shadow, `var` shadow, walker buffer overflow 처럼 declaration-order
// 또는 scope 의미가 애매한 케이스만 full 로 보낸다.
fn hasUnsupportedNamedImportLocalBindingShadow(ast: *const Ast) bool {
    var names_buf: [binding_lite_max_shadows][]const u8 = undefined;
    var names_len: usize = 0;

    for (ast.nodes.items) |import_node| {
        if (import_node.tag != .import_declaration) continue;
        const import_decl = module_parser.readImportDeclExtras(ast, import_node.data.extra);
        var i: u32 = 0;
        while (i < import_decl.specs_len) : (i += 1) {
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[import_decl.specs_start + i]);
            if (spec_idx.isNone()) continue;
            const spec = ast.getNode(spec_idx);
            if (spec.tag != .import_specifier) continue;
            if ((spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

            const local_idx = spec.data.binary.right;
            if (local_idx.isNone()) continue;
            // barrel 파일 등 비현실적 import 수는 보수적으로 full route.
            if (names_len == names_buf.len) return true;
            names_buf[names_len] = ast.getText(ast.getNode(local_idx).span);
            names_len += 1;
        }
    }

    if (names_len == 0) return false;

    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag != .program) continue;
        return scanForUnsupportedBindingLiteShadow(ast, @enumFromInt(raw_idx), names_buf[0..names_len], 0, false, null);
    }
    return false;
}

// match_count 는 호출자가 누적한다. binding pattern 하나(=formal_parameters/catch param)
// 안에서는 fresh counter 로도 의미가 같지만, `var a, b, c` 처럼 한 var 리스트의
// 누적 shadow 수를 봐야 하는 경우엔 호출자가 같은 counter 를 재사용한다.
fn bindingPatternImportShadowOverflow(ast: *const Ast, idx: ast_mod.NodeIndex, names: []const []const u8, match_count: *usize) bool {
    // walker 의 alloc 실패는 의미상 "scan 불완전" 이라 conservative-keep (overflow 로 간주) 로 fallback.
    // 정상 path 는 ast.allocator 가 transpile arena 라 사실상 bump-allocator → 실패 거의 없음.
    var it = ast_walk.bindingIdentifiers(ast.allocator, ast, idx, .{ .cover_grammar_assignment = true }) catch return true;
    defer it.deinit();
    while (it.next() catch return true) |leaf_idx| {
        const leaf = ast.getNode(leaf_idx);
        const name = ast.getText(leaf.span);
        if (string_list.contains(names, name)) {
            match_count.* += 1;
            if (match_count.* > binding_lite_max_shadows) return true;
        }
    }
    return false;
}

fn functionExpressionInnerName(ast: *const Ast, node: ast_mod.Node) ?[]const u8 {
    if (node.tag != .function_expression and node.tag != .function) return null;
    const name_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[node.data.extra]);
    if (name_idx.isNone()) return null;
    return ast.getText(ast.getNode(name_idx).span);
}

fn functionExpressionNameImportShadowOverflow(ast: *const Ast, node: ast_mod.Node, names: []const []const u8, match_count: *usize) bool {
    const name = functionExpressionInnerName(ast, node) orelse return false;
    if (string_list.contains(names, name)) {
        match_count.* += 1;
        if (match_count.* > binding_lite_max_shadows) return true;
    }
    return false;
}

// 함수 body 안에서 nested function/arrow 를 건너뛰며 non-lexical `var` 선언의 binding pattern 을
// 모두 방문한다. visitor 가 true 를 반환하면 즉시 abort. overflow 검사 / shadow 수집 두 사용처가
// 동일 트리 순회를 공유하도록 모은 헬퍼.
fn walkFunctionVarBindingPatterns(
    ast: *const Ast,
    idx: ast_mod.NodeIndex,
    ctx: anytype,
    comptime onBindingPattern: fn (@TypeOf(ctx), ast_mod.NodeIndex) bool,
) bool {
    if (idx.isNone()) return false;
    const node = ast.getNode(idx);
    switch (node.tag) {
        .function_declaration,
        .function_expression,
        .function,
        .arrow_function_expression,
        => return false,
        .variable_declaration => if (!ast.variableDeclarationKind(node).isLexical()) {
            const list_start = ast.extra_data.items[node.data.extra + 1];
            const list_len = ast.extra_data.items[node.data.extra + 2];
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + i]);
                if (decl_idx.isNone()) continue;
                const decl = ast.getNode(decl_idx);
                if (decl.tag != .variable_declarator) continue;
                if (onBindingPattern(ctx, @enumFromInt(ast.extra_data.items[decl.data.extra]))) return true;
            }
        },
        else => {},
    }

    var it = ast_walk.children(ast, node);
    while (it.next()) |child_idx| {
        if (walkFunctionVarBindingPatterns(ast, child_idx, ctx, onBindingPattern)) return true;
    }
    return false;
}

fn scanVariableDeclarationForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) bool {
    const list_start = ast.extra_data.items[node.data.extra + 1];
    const list_len = ast.extra_data.items[node.data.extra + 2];
    // 함수 scope 안이면 호출자가 누적 카운터를 넘기고, 모듈 scope 면 statement 로컬 카운터로 폴백.
    // before snapshot 은 lex/non-lex top-level fallback 결정에 쓰는 statement-local 카운트를 분리해
    // 둔다 — 같은 함수의 다른 var statement 가 누적한 값을 자기 것으로 오인하지 않게.
    var local_count: usize = 0;
    const counter = fn_shadow_count orelse &local_count;
    const before = counter.*;
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + i]);
        if (decl_idx.isNone()) continue;
        const decl = ast.getNode(decl_idx);
        if (decl.tag != .variable_declarator) continue;
        const binding_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra]);
        if (bindingPatternImportShadowOverflow(ast, binding_idx, names, counter)) return true;
        const init_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra + 2]);
        if (scanForUnsupportedBindingLiteShadow(ast, init_idx, names, scope_depth, inside_function, fn_shadow_count)) return true;
    }

    if (counter.* == before) return false;
    if (ast.variableDeclarationKind(node).isLexical()) return scope_depth == 0;
    return !inside_function;
}

fn scanChildrenForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    child_scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) bool {
    var it = ast_walk.children(ast, node);
    while (it.next()) |child_idx| {
        if (scanForUnsupportedBindingLiteShadow(ast, child_idx, names, child_scope_depth, inside_function, fn_shadow_count)) return true;
    }
    return false;
}

// 함수/arrow scope 의 params + body 를 같은 카운터로 한 번씩만 순회. arrow 와 function 양쪽이 공유.
fn scanFunctionScopeParamsAndBody(
    ast: *const Ast,
    params_idx: ast_mod.NodeIndex,
    body_idx: ast_mod.NodeIndex,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: *usize,
) bool {
    if (scanForUnsupportedBindingLiteShadow(ast, params_idx, names, scope_depth, inside_function, fn_shadow_count)) return true;
    return scanForUnsupportedBindingLiteShadow(ast, body_idx, names, scope_depth + 1, true, fn_shadow_count);
}

fn scanFunctionForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    node: ast_mod.Node,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
) bool {
    const e = node.data.extra;
    // function_expression / function 의 extras[0] 은 inner-only self-name 이라 outer scope binding
    // 으로 스캔하면 안 되고 함수-스코프 카운터에만 누적한다. function_declaration 은 extras[0] 이
    // outer 에 노출되는 binding 이므로 일반 스캔 경로 (fn_shadow_count=null) 를 그대로 탄다.
    const is_function_expression = node.tag != .function_declaration;
    // 한 함수 scope 안에서 누적되는 shadow 수. 함수-식 self-name + params + body 안 var binding 합산.
    // BindingLite collector (markBindingLiteFunctionScope) 가 모으는 set 과 동일 — overflow 시 fallback.
    var fn_shadow_count: usize = 0;
    if (is_function_expression and functionExpressionNameImportShadowOverflow(ast, node, names, &fn_shadow_count)) return true;
    if (!is_function_expression and scanForUnsupportedBindingLiteShadow(ast, @enumFromInt(ast.extra_data.items[e]), names, scope_depth, inside_function, null)) return true;
    return scanFunctionScopeParamsAndBody(
        ast,
        @enumFromInt(ast.extra_data.items[e + 1]),
        @enumFromInt(ast.extra_data.items[e + 2]),
        names,
        scope_depth,
        inside_function,
        &fn_shadow_count,
    );
}

fn scanForUnsupportedBindingLiteShadow(
    ast: *const Ast,
    idx: ast_mod.NodeIndex,
    names: []const []const u8,
    scope_depth: usize,
    inside_function: bool,
    fn_shadow_count: ?*usize,
) bool {
    if (idx.isNone()) return false;
    const node = ast.getNode(idx);
    switch (node.tag) {
        // scope_depth: program 은 0, block/body 진입마다 +1. inside_function: function/arrow body
        // 이하 ancestry. 두 값을 함께 쓰는 이유는 scanVariableDeclarationForUnsupp 의 return 두 줄이
        // truth table — top-level lexical (lex && depth==0) 또는 모듈-스코프 var (!lex && !inside_function)
        // 만 import 를 가리는 fallback 조건이고, 함수 내 var 는 nearest function scope 에만 머물러 outer
        // use 를 안 가린다.
        .program => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, 0, false, null),
        .block_statement => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, scope_depth + 1, inside_function, fn_shadow_count),
        .function_body => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, scope_depth + 1, true, fn_shadow_count),
        .formal_parameters => {
            var local_count: usize = 0;
            const counter = fn_shadow_count orelse &local_count;
            return bindingPatternImportShadowOverflow(ast, idx, names, counter);
        },
        .catch_clause => {
            // catch 매개변수는 catch block scope 에만 binding 되어 BindingLite 의 함수-scope shadow set
            // 에 합산되지 않는다. 단일 catch 안 overflow 만 별도 fresh counter 로 검사한다.
            var local_count: usize = 0;
            if (bindingPatternImportShadowOverflow(ast, node.data.binary.left, names, &local_count)) return true;
            return scanForUnsupportedBindingLiteShadow(ast, node.data.binary.right, names, scope_depth + 1, inside_function, fn_shadow_count);
        },
        .function_declaration,
        .function_expression,
        .function,
        => return scanFunctionForUnsupportedBindingLiteShadow(ast, node, names, scope_depth, inside_function),
        .arrow_function_expression => {
            const e = node.data.extra;
            // arrow 도 자기 function scope 를 가지므로 새 카운터를 연다. function 과 같은 헬퍼 공유.
            var arrow_shadow_count: usize = 0;
            return scanFunctionScopeParamsAndBody(
                ast,
                @enumFromInt(ast.extra_data.items[e]),
                @enumFromInt(ast.extra_data.items[e + 1]),
                names,
                scope_depth,
                inside_function,
                &arrow_shadow_count,
            );
        },
        .variable_declaration => return scanVariableDeclarationForUnsupportedBindingLiteShadow(ast, node, names, scope_depth, inside_function, fn_shadow_count),
        .binding_identifier => return string_list.contains(names, ast.getText(node.span)),
        else => return scanChildrenForUnsupportedBindingLiteShadow(ast, node, names, scope_depth, inside_function, fn_shadow_count),
    }
}

fn optionsRequireTransformSemantic(options: TranspileOptions) bool {
    return options.minify_identifiers or
        options.minify_syntax or
        options.minify_whitespace or
        options.drop_console or
        options.drop_debugger or
        options.define.len > 0 or
        !options.use_define_for_class_fields or
        options.experimental_decorators or
        options.emit_decorator_metadata;
}

fn buildTransformPlan(
    options: TranspileOptions,
    parser: *const Parser,
    ast: *const Ast,
    fast_path_disabled: bool,
) TransformPlan {
    if (fast_path_disabled) return .{ .semantic = .full, .reason = .disabled_by_env };
    if (options.stop_after == .semantic) return .{ .semantic = .full, .reason = .stop_after_semantic };

    // Flow 는 `non_ts_source` 보다 먼저 분류 — `// @flow` 주석이 붙은 `.js` 입력이
    // generic JS fallback 으로 잘못 집계되지 않도록 한다.
    if (parser.is_flow) return .{ .semantic = .full, .reason = .flow_source };
    // JS 파일은 보존 의미가 TS 와 달라 (값 import 가 type-only 라도 side-effect 가능 등)
    // fast path 적용 범위에서 제외 — full semantic 경로에서 진단 손실 없이 처리.
    if (parser.source_mode != .ts) return .{ .semantic = .full, .reason = .non_ts_source };
    if (ast.has_jsx) return .{ .semantic = .full, .reason = .jsx_source };

    if (optionsRequireTransformSemantic(options)) {
        return .{ .semantic = .full, .reason = .option_requires_transform_semantic };
    }
    if (options.unsupported.hasAny() or options.es_target != null) {
        return .{ .semantic = .full, .reason = .target_requires_downlevel };
    }
    if (options.module_format != .esm) {
        return .{ .semantic = .full, .reason = .module_format_requires_semantic };
    }

    // 파서가 `export = expr` 을 NodeIndex.none 으로 drop 하므로 (parser/module.zig) AST tag
    // 검사로는 잡을 수 없음 — 소스 substring 으로만 감지 가능. 이후 facts 게이트보다 비싼
    // 스캔이지만, runtime-sensitive 검사보다 먼저 short-circuit 되는 편이 일관됨.
    if (std.mem.indexOf(u8, ast.source, "export =") != null) {
        return .{ .semantic = .full, .reason = .ast_requires_runtime_transform };
    }

    const facts = collectAstFacts(ast);
    if (facts.has_non_named_import) {
        return .{ .semantic = .full, .reason = .import_shape_requires_full_semantic };
    }
    if (facts.has_runtime_sensitive_syntax) {
        return .{ .semantic = .full, .reason = .ast_requires_runtime_transform };
    }
    if (facts.has_import_declaration) {
        if (hasUnsupportedNamedImportLocalBindingShadow(ast)) {
            return .{ .semantic = .full, .reason = .binding_shadow_requires_full_semantic };
        }
        return .{
            .semantic = .bindings,
            .reason = .named_import_binding_elision,
            .strip_types_only = true,
        };
    }

    return .{
        .semantic = .none,
        .reason = .simple_ts_strip,
        .strip_types_only = true,
    };
}

fn collectBindingLite(allocator: std.mem.Allocator, ast: *const Ast) !BindingLite {
    var bindings: std.ArrayList(BindingLite.NamedImport) = .empty;
    errdefer bindings.deinit(allocator);

    for (ast.nodes.items) |node| {
        if (node.tag != .import_declaration) continue;
        const import_decl = module_parser.readImportDeclExtras(ast, node.data.extra);
        var i: u32 = 0;
        while (i < import_decl.specs_len) : (i += 1) {
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[import_decl.specs_start + i]);
            if (spec_idx.isNone()) continue;
            const spec = ast.getNode(spec_idx);
            if (spec.tag != .import_specifier) continue;
            if ((spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

            const local_idx = spec.data.binary.right;
            if (local_idx.isNone()) continue;
            const local = ast.getNode(local_idx);
            try bindings.append(allocator, .{ .local_name = ast.getText(local.span) });
        }
    }

    var lite = BindingLite{ .named_imports = try bindings.toOwnedSlice(allocator) };
    if (lite.named_imports.len == 0) return lite;
    const no_shadowed_names: []const []const u8 = &.{};
    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag != .program) continue;
        markBindingLiteValueUses(ast, @enumFromInt(raw_idx), &lite, true, no_shadowed_names);
        break;
    }
    return lite;
}

fn markBindingLiteUse(lite: *BindingLite, name: []const u8, shadowed_names: []const []const u8) void {
    if (string_list.contains(shadowed_names, name)) return;
    for (lite.named_imports) |*binding| {
        if (std.mem.eql(u8, binding.local_name, name)) {
            binding.used_as_value = true;
            return;
        }
    }
}

fn appendBindingLiteShadowName(buf: [][]const u8, len: *usize, name: []const u8) void {
    if (string_list.contains(buf[0..len.*], name)) return;
    // 상한 초과 shadow 는 그대로 두면 outer import 가 used 로 잘못 마킹될 위험이 있다 — over-conservative
    // 로 동작해 import 유지. 실제로는 한 함수에 binding_lite_max_shadows 개 동시 shadow 는 비현실적.
    if (len.* >= buf.len) return;
    buf[len.*] = name;
    len.* += 1;
}

fn collectBindingLitePatternShadows(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *const BindingLite, buf: [][]const u8, len: *usize) void {
    if (len.* >= buf.len) return;
    // walker alloc 실패 시 그냥 중단 — 호출자는 buf 가 빈 상태면 기존대로 conservative path 가 잡는다.
    var it = ast_walk.bindingIdentifiers(ast.allocator, ast, idx, .{ .cover_grammar_assignment = true }) catch return;
    defer it.deinit();
    while (it.next() catch return) |leaf_idx| {
        const leaf = ast.getNode(leaf_idx);
        // import 이름과 매칭되는 binding 만 shadow set 에 추가. cover-grammar 결과인
        // identifier_reference / assignment_target_identifier 도 동일 처리.
        const name = ast.getText(leaf.span);
        if (lite.namedImportValueUse(name) != null) appendBindingLiteShadowName(buf, len, name);
    }
}

fn collectBindingLiteVariableDeclarationShadows(ast: *const Ast, node: ast_mod.Node, lite: *const BindingLite, buf: [][]const u8, len: *usize) void {
    const list_start = ast.extra_data.items[node.data.extra + 1];
    const list_len = ast.extra_data.items[node.data.extra + 2];
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + i]);
        if (decl_idx.isNone()) continue;
        const decl = ast.getNode(decl_idx);
        if (decl.tag != .variable_declarator) continue;
        collectBindingLitePatternShadows(ast, @enumFromInt(ast.extra_data.items[decl.data.extra]), lite, buf, len);
    }
}

fn collectBindingLiteFunctionVarShadows(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *const BindingLite, buf: [][]const u8, len: *usize) void {
    const Ctx = struct {
        ast: *const Ast,
        lite: *const BindingLite,
        buf: [][]const u8,
        len: *usize,
    };
    const visit = struct {
        fn onBindingPattern(c: Ctx, binding_idx: ast_mod.NodeIndex) bool {
            collectBindingLitePatternShadows(c.ast, binding_idx, c.lite, c.buf, c.len);
            // buf 가 가득 차면 더 append 해도 silent drop 이라 더 순회할 이유가 없다.
            return c.len.* >= c.buf.len;
        }
    }.onBindingPattern;
    _ = walkFunctionVarBindingPatterns(
        ast,
        idx,
        Ctx{ .ast = ast, .lite = lite, .buf = buf, .len = len },
        visit,
    );
}

fn collectBindingLiteFunctionExpressionNameShadow(ast: *const Ast, node: ast_mod.Node, lite: *const BindingLite, buf: [][]const u8, len: *usize) void {
    const name = functionExpressionInnerName(ast, node) orelse return;
    if (lite.namedImportValueUse(name) != null) appendBindingLiteShadowName(buf, len, name);
}

fn collectBindingLiteListLexicalShadows(ast: *const Ast, list: ast_mod.NodeList, lite: *const BindingLite, buf: [][]const u8, len: *usize) void {
    if (list.start + list.len > ast.extra_data.items.len) return;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const child_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list.start + i]);
        if (child_idx.isNone()) continue;
        const child = ast.getNode(child_idx);
        if (child.tag == .variable_declaration and ast.variableDeclarationKind(child).isLexical()) {
            collectBindingLiteVariableDeclarationShadows(ast, child, lite, buf, len);
        }
    }
}

fn markBindingLiteBlockScope(
    ast: *const Ast,
    node: ast_mod.Node,
    lite: *BindingLite,
    parent_shadowed: []const []const u8,
) void {
    var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
    var shadow_len: usize = 0;
    for (parent_shadowed) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
    collectBindingLiteListLexicalShadows(ast, node.data.list, lite, &shadow_buf, &shadow_len);
    markBindingLiteListValueUses(ast, node.data.list, lite, true, shadow_buf[0..shadow_len]);
}

fn markBindingPatternDefaultValueUses(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *BindingLite, shadowed_names: []const []const u8) void {
    if (idx.isNone()) return;
    const node = ast.getNode(idx);
    switch (node.tag) {
        .assignment_pattern,
        .assignment_expression,
        .assignment_target_with_default,
        => {
            markBindingPatternDefaultValueUses(ast, node.data.binary.left, lite, shadowed_names);
            markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
        },
        .array_pattern,
        .object_pattern,
        => markBindingLiteListValueUses(ast, node.data.list, lite, false, shadowed_names),
        .binding_rest_element,
        .rest_element,
        .assignment_target_rest,
        => markBindingPatternDefaultValueUses(ast, node.data.unary.operand, lite, shadowed_names),
        .binding_property,
        .assignment_target_property_identifier,
        .assignment_target_property_property,
        => markBindingPatternDefaultValueUses(ast, node.data.binary.right, lite, shadowed_names),
        else => {},
    }
}

fn markBindingLiteListValueUses(ast: *const Ast, list: ast_mod.NodeList, lite: *BindingLite, value_context: bool, shadowed_names: []const []const u8) void {
    if (list.start + list.len > ast.extra_data.items.len) return;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[list.start + i]), lite, value_context, shadowed_names);
    }
}

fn markBindingLiteFunctionScope(
    ast: *const Ast,
    lite: *BindingLite,
    parent_shadowed: []const []const u8,
    node: ast_mod.Node,
    params_idx: ast_mod.NodeIndex,
    body_idx: ast_mod.NodeIndex,
) void {
    var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
    var shadow_len: usize = 0;
    for (parent_shadowed) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
    collectBindingLiteFunctionExpressionNameShadow(ast, node, lite, &shadow_buf, &shadow_len);
    collectBindingLitePatternShadows(ast, params_idx, lite, &shadow_buf, &shadow_len);
    collectBindingLiteFunctionVarShadows(ast, body_idx, lite, &shadow_buf, &shadow_len);
    const combined = shadow_buf[0..shadow_len];
    markBindingLiteValueUses(ast, params_idx, lite, false, combined);
    markBindingLiteValueUses(ast, body_idx, lite, true, combined);
}

fn markBindingLiteValueUses(ast: *const Ast, idx: ast_mod.NodeIndex, lite: *BindingLite, value_context: bool, shadowed_names: []const []const u8) void {
    if (idx.isNone()) return;
    const node = ast.getNode(idx);

    if (Transformer.isTypeOnlyNode(node.tag) or node.tag.isTypeOnlyDeclaration()) return;

    switch (node.tag) {
        .identifier_reference,
        .assignment_target_identifier,
        => {
            if (value_context) markBindingLiteUse(lite, ast.getText(node.span), shadowed_names);
            return;
        },
        .binding_identifier,
        .import_declaration,
        .import_specifier,
        .import_default_specifier,
        .import_namespace_specifier,
        .import_attribute,
        => return,
        .block_statement,
        .function_body,
        => {
            markBindingLiteBlockScope(ast, node, lite, shadowed_names);
            return;
        },
        .catch_clause => {
            var shadow_buf: [binding_lite_max_shadows][]const u8 = undefined;
            var shadow_len: usize = 0;
            for (shadowed_names) |name| appendBindingLiteShadowName(&shadow_buf, &shadow_len, name);
            collectBindingLitePatternShadows(ast, node.data.binary.left, lite, &shadow_buf, &shadow_len);
            markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadow_buf[0..shadow_len]);
            return;
        },
        .try_statement => {
            markBindingLiteValueUses(ast, node.data.ternary.a, lite, true, shadowed_names);
            markBindingLiteValueUses(ast, node.data.ternary.b, lite, true, shadowed_names);
            markBindingLiteValueUses(ast, node.data.ternary.c, lite, true, shadowed_names);
            return;
        },
        .export_specifier => {
            markBindingLiteValueUses(ast, node.data.binary.left, lite, true, shadowed_names);
            return;
        },
        .export_named_declaration => {
            const x = module_parser.readExportNamedExtras(ast, node.data.extra);
            markBindingLiteValueUses(ast, x.decl, lite, true, shadowed_names);
            markBindingLiteListValueUses(ast, .{ .start = x.specs_start, .len = x.specs_len }, lite, true, shadowed_names);
            return;
        },
        .variable_declaration => {
            const list_start = ast.extra_data.items[node.data.extra + 1];
            const list_len = ast.extra_data.items[node.data.extra + 2];
            markBindingLiteListValueUses(ast, .{ .start = list_start, .len = list_len }, lite, true, shadowed_names);
            return;
        },
        .variable_declarator => {
            markBindingPatternDefaultValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra]), lite, shadowed_names);
            markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra + 2]), lite, true, shadowed_names);
            return;
        },
        .function_declaration,
        .function_expression,
        .function,
        => {
            const e = node.data.extra;
            markBindingLiteFunctionScope(
                ast,
                lite,
                shadowed_names,
                node,
                @enumFromInt(ast.extra_data.items[e + 1]),
                @enumFromInt(ast.extra_data.items[e + 2]),
            );
            return;
        },
        .arrow_function_expression => {
            const e = node.data.extra;
            markBindingLiteFunctionScope(
                ast,
                lite,
                shadowed_names,
                node,
                @enumFromInt(ast.extra_data.items[e]),
                @enumFromInt(ast.extra_data.items[e + 1]),
            );
            return;
        },
        .formal_parameters => {
            markBindingLiteListValueUses(ast, node.data.list, lite, false, shadowed_names);
            return;
        },
        .assignment_pattern,
        .assignment_target_with_default,
        => {
            markBindingLiteValueUses(ast, node.data.binary.left, lite, false, shadowed_names);
            markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
            return;
        },
        // `(Foo = Bar()) =>` 같이 cover-grammar 로 패턴 자리에 남은 assignment_expression 은
        // value_context=false (formal_parameters 진입) 에서만 LHS=binding/RHS=value 로 쪼갠다.
        // expression context (`Foo = expr;`) 는 LHS 가 assignment_target_identifier 라 default
        // child walk 로 그대로 value_context=true 가 전파돼야 import 가 use 마킹된다.
        .assignment_expression => {
            if (!value_context) {
                markBindingLiteValueUses(ast, node.data.binary.left, lite, false, shadowed_names);
                markBindingLiteValueUses(ast, node.data.binary.right, lite, true, shadowed_names);
                return;
            }
        },
        .formal_parameter => {
            const e = node.data.extra;
            markBindingPatternDefaultValueUses(ast, @enumFromInt(ast.extra_data.items[e]), lite, shadowed_names);
            markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[e + 2]), lite, true, shadowed_names);
            return;
        },
        .object_property => {
            const key = node.data.binary.left;
            const value = node.data.binary.right;
            if (value.isNone()) {
                markBindingLiteValueUses(ast, key, lite, true, shadowed_names);
            } else {
                const key_node = ast.getNode(key);
                if (key_node.tag == .computed_property_key) markBindingLiteValueUses(ast, key, lite, true, shadowed_names);
                markBindingLiteValueUses(ast, value, lite, true, shadowed_names);
            }
            return;
        },
        .static_member_expression,
        .private_field_expression,
        => {
            markBindingLiteValueUses(ast, @enumFromInt(ast.extra_data.items[node.data.extra]), lite, true, shadowed_names);
            return;
        },
        else => {},
    }

    var it = ast_walk.children(ast, node);
    while (it.next()) |child_idx| {
        markBindingLiteValueUses(ast, child_idx, lite, value_context, shadowed_names);
    }
}

/// 소스 문자열을 트랜스파일한다. I/O 없음, 순수 함수.
///
/// file_path는 확장자 감지용으로만 사용 (실제 파일 읽기 안 함).
/// 반환된 code/sourcemap은 allocator 소유 — caller가 deinit() 해야 함.
pub fn transpile(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) TranspileError!TranspileResult {
    return transpileWithCallback(allocator, source, file_path, options, null);
}

/// 에러 콜백 포함 트랜스파일. 파서/시맨틱 에러 시 콜백을 호출한 뒤 에러를 반환.
pub fn transpileWithCallback(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
    on_error: ?ErrorCallback,
) TranspileError!TranspileResult {
    return transpileWithCallbackInternal(
        allocator,
        source,
        file_path,
        options,
        on_error,
        transpileFastPathDisabledByEnv(),
    );
}

fn transpileWithCallbackInternal(
    allocator: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
    on_error: ?ErrorCallback,
    fast_path_disabled: bool,
) TranspileError!TranspileResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 1. 파싱
    var scanner = Scanner.init(arena_alloc, source) catch return error.OutOfMemory;

    // --stop-after=scan: 파서 호출 없이 토큰 drain 만 수행 (profile/debug 용).
    // Scanner 가 lazy 이므로 next() 로 EOF 까지 소비해야 실제 tokenization 비용이 발생.
    if (options.stop_after == .scan) {
        scanner.next() catch return error.ParseError;
        while (scanner.token.kind != .eof) {
            scanner.next() catch return error.ParseError;
        }
        return .{ .code = try allocator.dupe(u8, "") };
    }

    var parser = Parser.init(arena_alloc, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));

    if (parser.source_mode != .ts) {
        if (options.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true;
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                parser.is_unambiguous = true;
            }
        } else {
            parser.configureFlowFromPath(file_path);
        }
    }
    if (options.jsx_in_js and parser.source_mode != .ts) {
        parser.is_jsx = true;
    }
    _ = parser.parse() catch return error.ParseError;
    if (parser.errors.items.len > 0) {
        if (on_error) |cb| cb(source, file_path, &scanner, parser.errors.items);
        return error.ParseError;
    }

    if (options.stop_after == .parse) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    const transform_plan = buildTransformPlan(options, &parser, &parser.ast, fast_path_disabled);
    // 포맷 문자열을 변경하면 `tests/benchmark/profile.ts` 의 `tracePlan` 정규식도
    // 함께 갱신해야 한다 — `semantic=...`, `reason=...` 키 이름을 그대로 유지.
    debug_log.print(
        .transform_plan,
        "file={s} semantic={s} reason={s} strip_types_only={}\n",
        .{ file_path, @tagName(transform_plan.semantic), @tagName(transform_plan.reason), transform_plan.strip_types_only },
    );

    // 2. Semantic analysis
    var analyzer_storage: ?SemanticAnalyzer = null;
    var binding_lite_storage: ?BindingLite = null;
    if (transform_plan.semantic == .full) {
        analyzer_storage = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        var analyzer = &analyzer_storage.?;
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = parser.source_mode == .ts;
        analyzer.is_flow = parser.is_flow;
        analyzer.es_target = options.es_target;
        analyzer.unsupported = options.unsupported;
        analyzer.analyze() catch return error.SemanticError;
        // tsc 호환: 시맨틱 에러가 있어도 codegen 을 진행한다 — 콜백으로 stderr 통지 후
        // 변환 결과도 함께 반환.
        if (analyzer.errors.items.len > 0) {
            if (on_error) |cb| cb(source, file_path, &scanner, analyzer.errors.items);
        }
    } else if (transform_plan.semantic == .bindings) {
        binding_lite_storage = try collectBindingLite(arena_alloc, &parser.ast);
    }

    if (options.stop_after == .semantic) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    // 3. Identifier mangling (--minify-identifiers)
    var mangle_result: ?Mangler.ManglerResult = null;
    defer if (mangle_result) |*mr| mr.deinit();

    if (options.minify_identifiers) {
        const analyzer = &(analyzer_storage.?);
        if (analyzer.symbols.items.len > 0 and analyzer.scope_maps.items.len > 0) {
            mangle_result = Mangler.mangle(arena_alloc, .{
                .scopes = analyzer.scopes.items,
                .symbols = analyzer.symbols.items,
                .scope_maps = analyzer.scope_maps.items,
                .references = analyzer.references.items,
                .source = source,
            }) catch null;
        }
    }

    // 4. 변환
    var transformer = try Transformer.init(arena_alloc, &parser.ast, .{
        .drop_console = options.drop_console,
        .drop_debugger = options.drop_debugger,
        .define = options.define,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .experimental_decorators = options.experimental_decorators,
        .emit_decorator_metadata = options.emit_decorator_metadata,
        .verbatim_module_syntax = options.verbatim_module_syntax,
        .unsupported = options.unsupported,
        // JSX lowering: JSX가 있는 모듈에서만 활성화
        .jsx_transform = parser.ast.has_jsx,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = file_path,
        // #1621: standalone transpile 경로도 minify 시 runtime helper 축약 이름 사용.
        .minify_whitespace = options.minify_whitespace,
    });
    if (analyzer_storage) |*analyzer| {
        transformer.initSymbolIds(analyzer.symbol_ids.items) catch return error.TransformError;
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
    } else if (binding_lite_storage) |*binding_lite| {
        transformer.binding_lite = binding_lite;
    }
    transformer.line_offsets = scanner.line_offsets.items;
    const root = transformer.transform() catch return error.TransformError;

    if (options.stop_after == .transform) {
        return .{ .code = try allocator.dupe(u8, "") };
    }

    if (options.minify_syntax) {
        const analyzer = &(analyzer_storage.?);
        const minify_mod = @import("transformer/minify.zig");
        const ctx: minify_mod.MinifyCtx = .{
            .symbols = analyzer.symbols.items,
            .symbol_ids = transformer.symbol_ids.items,
            .scopes = analyzer.scopes.items,
            .unresolved_globals = null,
            .references = analyzer.references.items,
            .allow_top_level_inline = options.minify_syntax,
        };
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
        minify_mod.mergeDecls(transformer.ast, null);
    }

    // 5. Mangling 메타데이터 구성. skip_nodes는 arena-owned이라 별도 deinit 불필요
    // (함수 종료 시 arena.deinit으로 일괄 해제).
    var mangle_metadata: ?LinkingMetadata = null;

    if (mangle_result) |*mr| {
        const node_count = transformer.ast.nodes.items.len;
        mangle_metadata = .{
            .skip_nodes = std.DynamicBitSet.initEmpty(arena_alloc, node_count) catch return error.OutOfMemory,
            .renames = mr.renames,
            .final_exports = null,
            .symbol_ids = if (transformer.symbol_ids.items.len > 0)
                transformer.symbol_ids.items
            else
                &.{},
            // 단일 파일 transpile: codegen 의 scope-hoisted 전용 분기를 타지 않도록 false.
            .is_bundle_context = false,
            .allocator = arena_alloc,
        };
    }

    // 6. 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, transformer.ast, .{
        .module_format = options.module_format,
        .minify_whitespace = options.minify_whitespace,
        .minify_syntax = options.minify_syntax,
        .sourcemap = options.sourcemap,
        .ascii_only = if (options.charset_utf8) false else options.ascii_only,
        .quote_style = options.quote_style,
        .linking_metadata = if (mangle_metadata) |*mm| mm else null,
        .platform = options.platform,
        .source_root = options.source_root,
        .sources_content = options.sources_content,
        .strip_hashbang = options.unsupported.hashbang,
        .assert_no_raw_private_syntax = options.unsupported.requiresPrivateDownlevel(),
        // JSX: Transformer가 이미 call_expression으로 lowering 완료. codegen에 JSX 옵션 불필요.
    });
    cg.comments = scanner.comments.items;
    if (options.sourcemap) {
        cg.addSourceFile(file_path) catch {};
        cg.line_offsets = scanner.line_offsets.items;
    }
    const raw_output = cg.generate(root) catch return error.CodegenError;

    // 6.5. JSX import prepend (transformer가 JSX lowering 수행한 경우)
    const jsx_import_str: ?[]const u8 = if (transformer.jsx_import_info.hasImports()) blk: {
        const is_dev = options.jsx_runtime == .automatic_dev;
        break :blk transformer.jsx_import_info.buildImportString(arena_alloc, options.jsx_import_source, is_dev);
    } else null;
    const jsx_output = prependImportLine(arena_alloc, jsx_import_str, raw_output);

    // 6.6. styled-components cssProp auto-inject — 사용자 코드에 styled import 가 없는데
    // cssProp transform 이 일어난 경우 program 시작에 styled import 추가. binding 이름은
    // collision detection 후 결정된 `css_prop_inject_name` 사용.
    const css_prop_import: ?[]const u8 = if (transformer.plugins.styled_components.css_prop_needs_import) blk: {
        const name = transformer.plugins.styled_components.css_prop_inject_name;
        break :blk std.fmt.allocPrint(arena_alloc, "import {s} from \"styled-components\";\n", .{name}) catch null;
    } else null;
    const css_prop_output = prependImportLine(arena_alloc, css_prop_import, jsx_output);

    // 7. 런타임 헬퍼 prepend
    const rh = transformer.runtime_helpers;
    const has_helpers = rh.hasAny();
    const output = if (has_helpers) blk: {
        var buf: std.ArrayList(u8) = .empty;
        rt.appendRuntimeHelpers(&buf, arena_alloc, rh, options.minify_whitespace, transformer.runtime_es5_compat) catch
            break :blk css_prop_output;
        buf.appendSlice(arena_alloc, css_prop_output) catch break :blk css_prop_output;
        break :blk buf.items;
    } else css_prop_output;

    // 8. Sentry Debug ID (UUID v4) — sourcemap_debug_ids 활성화 시 생성
    var debug_id_buf: [36]u8 = undefined;
    const debug_id: ?[]const u8 = if (options.sourcemap_debug_ids) blk: {
        SourceMap.generateUuidV4(&debug_id_buf);
        break :blk &debug_id_buf;
    } else null;

    // 9. 소스맵 생성. map.file 필드는 출력 파일명을 가리켜야 함 (Source Map Rev3
    // spec — source path 가 아닌 *생성된* 파일). caller 가 sourcemap_output_filename
    // 을 알려주면 그 값을, 아니면 빈 문자열 (spec 상 optional 필드 — invalid 한
    // source path 보다 안전. CLI 는 main.zig 에서 자동 set, library/NAPI 호출자는
    // 직접 전달 권장). #2217.
    const map_file_name: []const u8 = options.sourcemap_output_filename;
    var sourcemap_json: ?[]const u8 = null;
    if (options.sourcemap) {
        if (cg.sm_builder) |*sm| {
            sm.debug_id = debug_id;
            if (sm.generateJSON(map_file_name) catch null) |sm_json| {
                sourcemap_json = allocator.dupe(u8, sm_json) catch null;
            }
        }
    }

    // 10. footer 부착: sourceMappingURL (#2217) + debugId.
    // sourcemap_output_filename 이 있으면 `//# sourceMappingURL=<file>.map` 도 emit.
    // debugId 와 함께 부착하면 Sentry/DevTools 가 둘 다 인식.
    const need_sm_footer = options.sourcemap and
        sourcemap_json != null and
        options.sourcemap_output_filename.len > 0;
    const final_output = if (debug_id != null or need_sm_footer) blk: {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(arena_alloc, output) catch break :blk output;
        if (output.len > 0 and output[output.len - 1] != '\n') {
            buf.append(arena_alloc, '\n') catch break :blk output;
        }
        if (need_sm_footer) {
            buf.appendSlice(arena_alloc, "//# sourceMappingURL=") catch break :blk output;
            buf.appendSlice(arena_alloc, options.sourcemap_output_filename) catch break :blk output;
            buf.appendSlice(arena_alloc, ".map\n") catch break :blk output;
        }
        if (debug_id) |did| {
            buf.appendSlice(arena_alloc, "//# debugId=") catch break :blk output;
            buf.appendSlice(arena_alloc, did) catch break :blk output;
            buf.append(arena_alloc, '\n') catch break :blk output;
        }
        break :blk buf.items;
    } else output;

    // Arena 밖으로 복제 (arena는 함수 종료 시 defer로 해제 — line 167).
    // mangle_metadata.skip_nodes는 arena-owned이므로 별도 deinit 불필요.
    const result_code = allocator.dupe(u8, final_output) catch return error.OutOfMemory;
    errdefer allocator.free(result_code);

    // 시맨틱 에러 복사: arena → allocator. 실패 시 이미 복사된 항목들 roll back.
    const semantic_errors: []const Diagnostic = if (analyzer_storage) |*analyzer|
        analyzer.errors.items
    else
        &.{};
    const owned_diagnostics: []const OwnedDiagnostic = if (semantic_errors.len == 0) &.{} else blk: {
        const buf = allocator.alloc(OwnedDiagnostic, semantic_errors.len) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (buf[0..filled]) |d| d.deinit(allocator);
            allocator.free(buf);
        }
        for (semantic_errors) |d| {
            buf[filled] = try OwnedDiagnostic.init(d, allocator);
            filled += 1;
        }
        break :blk buf;
    };
    errdefer {
        for (owned_diagnostics) |d| d.deinit(allocator);
        if (owned_diagnostics.len > 0) allocator.free(owned_diagnostics);
    }

    // line_offsets도 복사 (diagnostics 렌더링용). 에러 없으면 생략.
    const owned_line_offsets: []const u32 = if (semantic_errors.len == 0)
        &.{}
    else
        allocator.dupe(u32, scanner.line_offsets.items) catch return error.OutOfMemory;

    return .{
        .code = result_code,
        .sourcemap = sourcemap_json,
        .has_helpers = has_helpers,
        .diagnostics = owned_diagnostics,
        .line_offsets = owned_line_offsets,
    };
}

fn testTransformPlan(source: []const u8, file_path: []const u8, options: TranspileOptions) !TransformPlan {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(std.fs.path.extension(file_path));
    if (parser.source_mode != .ts) {
        if (options.flow) {
            parser.is_flow = true;
            scanner.has_flow_pragma = true;
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                parser.is_unambiguous = true;
            }
        } else {
            parser.configureFlowFromPath(file_path);
        }
    }
    if (options.jsx_in_js and parser.source_mode != .ts) {
        parser.is_jsx = true;
    }
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    return buildTransformPlan(options, &parser, &parser.ast, false);
}

fn expectFastFullParity(
    expected: SemanticRequirement,
    source: []const u8,
    file_path: []const u8,
    options: TranspileOptions,
) !void {
    const plan = try testTransformPlan(source, file_path, options);
    try std.testing.expectEqual(expected, plan.semantic);

    var fast = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        file_path,
        options,
        null,
        false,
    );
    defer fast.deinit(std.testing.allocator);

    var full = try transpileWithCallbackInternal(
        std.testing.allocator,
        source,
        file_path,
        options,
        null,
        true,
    );
    defer full.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(full.code, fast.code);
    try std.testing.expectEqual(full.has_helpers, fast.has_helpers);
    try std.testing.expectEqual(@as(usize, 0), fast.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), full.diagnostics.len);
}

test "TransformPlan: simple TypeScript strip skips semantic" {
    const plan = try testTransformPlan(
        "export const x: number = 1;\nexport function f(v: string): string { return v; }\ninterface Foo { x: number }\ntype Bar = string;\n",
        "input.ts",
        .{},
    );

    try std.testing.expectEqual(SemanticRequirement.none, plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.simple_ts_strip, plan.reason);
    try std.testing.expect(plan.strip_types_only);
}

test "TransformPlan: runtime-sensitive syntax keeps full semantic" {
    const cases = [_]struct {
        source: []const u8,
        reason: SemanticPlanReason,
    }{
        .{ .source = "enum Color { Red }\n", .reason = .ast_requires_runtime_transform },
        .{ .source = "namespace N { export const x = 1 }\n", .reason = .ast_requires_runtime_transform },
        .{ .source = "class C { #x = 1 }\n", .reason = .ast_requires_runtime_transform },
    };

    for (cases) |case| {
        const plan = try testTransformPlan(case.source, "input.ts", .{});
        try std.testing.expectEqual(SemanticRequirement.full, plan.semantic);
        try std.testing.expectEqual(case.reason, plan.reason);
    }
}

test "TransformPlan: Flow source is classified before generic non-TS source" {
    const flow_plan = try testTransformPlan("// @flow\nconst value: string = 'x';\n", "input.js", .{ .flow = true });
    try std.testing.expectEqual(SemanticRequirement.full, flow_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.flow_source, flow_plan.reason);

    const js_plan = try testTransformPlan("const value = 1;\n", "input.js", .{});
    try std.testing.expectEqual(SemanticRequirement.full, js_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.non_ts_source, js_plan.reason);
}

test "TransformPlan: named import TypeScript strip uses binding-lite semantic" {
    const plan = try testTransformPlan(
        "import { type A, B } from './bar';\nexport const x: A = B();\n",
        "input.ts",
        .{},
    );

    try std.testing.expectEqual(SemanticRequirement.bindings, plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.named_import_binding_elision, plan.reason);
    try std.testing.expect(plan.strip_types_only);
}

test "TransformPlan: scope-local named import shadows stay on binding-lite route" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
    }{
        .{
            .name = "block lexical shadow with outer value use",
            .source =
            \\import { Foo } from "./lib";
            \\{ const Foo = 1; Foo; }
            \\Foo();
            ,
        },
        .{
            .name = "catch binding shadow with try body value use",
            .source =
            \\import { Foo } from "./lib";
            \\try { Foo(); } catch (Foo) { Foo; }
            ,
        },
        .{
            .name = "nested block shadow with outer value use",
            .source =
            \\import { Foo } from "./lib";
            \\{
            \\  { const Foo = 1; Foo; }
            \\  Foo();
            \\}
            ,
        },
        .{
            .name = "block lexical shadow covers earlier references in the same block",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  Foo;
            \\  const Foo = Bar();
            \\}
            \\Foo();
            ,
        },
        .{
            .name = "function var shadow with outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\function f() { var Foo = Bar(); return Foo; }
            \\Foo();
            ,
        },
        .{
            .name = "function block var shadow stays function scoped",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\function f() {
            \\  if (ok) { var Foo = Bar(); }
            \\  return Foo;
            \\}
            \\Foo();
            ,
        },
        .{
            .name = "named function expression self-name shadows import locally",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\const fn = function Foo() { return Foo; };
            \\Foo();
            \\Bar();
            ,
        },
        .{
            .name = "named function expression self-name shadows parameter default",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\const fn = function Foo(value = Foo) { return value; };
            \\Bar();
            ,
        },
    };

    for (cases) |case| {
        const plan = try testTransformPlan(case.source, "input.ts", .{});
        std.testing.expectEqual(SemanticRequirement.bindings, plan.semantic) catch |err| {
            std.debug.print("scope-local route failed for case '{s}', reason={s}\n", .{ case.name, @tagName(plan.reason) });
            return err;
        };
    }
}

test "TransformPlan: ambiguous or overflowing named import shadows keep full semantic" {
    const top_level = try testTransformPlan(
        "import { Foo } from './x';\nconst Foo = 1;\nexport { Foo };\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.full, top_level.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, top_level.reason);

    const top_level_block_var_shadow = try testTransformPlan(
        "import { Foo } from './x';\n{ var Foo = 1; }\nFoo();\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.full, top_level_block_var_shadow.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, top_level_block_var_shadow.reason);

    const function_decl_shadow = try testTransformPlan(
        "import { Foo } from './x';\nfunction outer() { function Foo() {} return Foo; }\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.full, function_decl_shadow.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, function_decl_shadow.reason);

    const function_var_shadow = try testTransformPlan(
        "import { Foo } from './x';\nfunction f() { var Foo = 1; return Foo; }\n",
        "input.ts",
        .{},
    );
    try std.testing.expectEqual(SemanticRequirement.bindings, function_var_shadow.semantic);
    try std.testing.expectEqual(SemanticPlanReason.named_import_binding_elision, function_var_shadow.reason);

    var function_expression_overflow_source: std.ArrayList(u8) = .empty;
    defer function_expression_overflow_source.deinit(std.testing.allocator);
    try function_expression_overflow_source.appendSlice(std.testing.allocator, "import { Foo");
    var j: usize = 0;
    while (j < 64) : (j += 1) {
        try function_expression_overflow_source.writer(std.testing.allocator).print(", I{d}", .{j});
    }
    try function_expression_overflow_source.appendSlice(std.testing.allocator, " } from './x';\nconst fn = function Foo(");
    j = 0;
    while (j < 64) : (j += 1) {
        try function_expression_overflow_source.writer(std.testing.allocator).print("I{d},", .{j});
    }
    try function_expression_overflow_source.appendSlice(std.testing.allocator, ") { return Foo; };\n");
    const function_expression_overflow_plan = try testTransformPlan(function_expression_overflow_source.items, "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, function_expression_overflow_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, function_expression_overflow_plan.reason);

    var overflow_source: std.ArrayList(u8) = .empty;
    defer overflow_source.deinit(std.testing.allocator);
    try overflow_source.appendSlice(std.testing.allocator, "import {");
    var i: usize = 0;
    while (i < 65) : (i += 1) {
        try overflow_source.writer(std.testing.allocator).print(" I{d},", .{i});
    }
    try overflow_source.appendSlice(std.testing.allocator, " } from './x';\nfunction f(");
    i = 0;
    while (i < 65) : (i += 1) {
        try overflow_source.writer(std.testing.allocator).print("I{d},", .{i});
    }
    try overflow_source.appendSlice(std.testing.allocator, ") {}\n");
    const overflow_plan = try testTransformPlan(overflow_source.items, "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, overflow_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.binding_shadow_requires_full_semantic, overflow_plan.reason);
}

test "TransformPlan: default and namespace imports keep full semantic" {
    const default_plan = try testTransformPlan("import Foo from './bar';\nexport const x = 1;\n", "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, default_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.import_shape_requires_full_semantic, default_plan.reason);

    const namespace_plan = try testTransformPlan("import * as Foo from './bar';\nexport const x = 1;\n", "input.ts", .{});
    try std.testing.expectEqual(SemanticRequirement.full, namespace_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.import_shape_requires_full_semantic, namespace_plan.reason);
}

test "TransformPlan: semantic-sensitive options keep full semantic" {
    const compat = @import("transformer/compat.zig");

    const minify_plan = try testTransformPlan("export const x: number = 1;\n", "input.ts", .{
        .minify_identifiers = true,
    });
    try std.testing.expectEqual(SemanticRequirement.full, minify_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.option_requires_transform_semantic, minify_plan.reason);

    const cjs_plan = try testTransformPlan("export const x: number = 1;\n", "input.ts", .{
        .module_format = .cjs,
    });
    try std.testing.expectEqual(SemanticRequirement.full, cjs_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.module_format_requires_semantic, cjs_plan.reason);

    const downlevel_plan = try testTransformPlan("export const x: number = 1;\n", "input.ts", .{
        .unsupported = compat.fromESTarget(.es5),
        .es_target = .es5,
    });
    try std.testing.expectEqual(SemanticRequirement.full, downlevel_plan.semantic);
    try std.testing.expectEqual(SemanticPlanReason.target_requires_downlevel, downlevel_plan.reason);
}

test "TransformPlan parity: fast TS strip matches full semantic output" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
    }{
        .{
            .name = "exported const with primitive annotation",
            .source =
            \\export const value: number = 1;
            ,
        },
        .{
            .name = "function params and return annotations",
            .source =
            \\export function add(a: number, b: number): number {
            \\  return a + b;
            \\}
            ,
        },
        .{
            .name = "interface and type-only declarations",
            .source =
            \\interface User { id: string; age?: number }
            \\type Maybe<T> = T | null;
            \\export const id: Maybe<string> = "a";
            ,
        },
        .{
            .name = "generic function and type parameters",
            .source =
            \\export function first<T extends { id: string }>(items: T[]): T | undefined {
            \\  return items[0];
            \\}
            ,
        },
        .{
            .name = "TS expression wrappers",
            .source =
            \\const raw: unknown = "value";
            \\export const a = raw as string;
            \\export const b = raw satisfies unknown;
            \\export const c = (raw as string)!;
            ,
        },
        .{
            .name = "default function declaration",
            .source =
            \\export default function main(input: string): string {
            \\  return input;
            \\}
            ,
        },
        .{
            .name = "directives and comments",
            .source =
            \\"use client";
            \\// keep the directive at the top
            \\export const action: () => void = () => {};
            ,
        },
    };

    for (cases) |case| {
        expectFastFullParity(.none, case.source, "input.ts", .{}) catch |err| {
            std.debug.print("fast/full parity failed for case '{s}'\n", .{case.name});
            return err;
        };
    }
}

test "TransformPlan parity: binding-lite named import elision matches full semantic output" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        options: TranspileOptions = .{},
    }{
        .{
            .name = "inline type specifier removed and value specifier kept",
            .source =
            \\import { type A, B } from "./lib";
            \\export const value: A = B();
            ,
        },
        .{
            .name = "named import used only in type annotation is removed",
            .source =
            \\import { A } from "./lib";
            \\export function f(value: A): void {}
            ,
        },
        .{
            .name = "named import used in value expression is kept",
            .source =
            \\import { B } from "./lib";
            \\export const value = B();
            ,
        },
        .{
            .name = "aliased named import follows local binding",
            .source =
            \\import { Foo as Bar, Used } from "./lib";
            \\export type T = Bar;
            \\export const value = Used();
            ,
        },
        .{
            .name = "string named import follows alias binding",
            .source =
            \\import { "x" as x, y } from "./lib";
            \\export type T = typeof y;
            \\export const value = x();
            ,
        },
        .{
            .name = "multiple declarations and side effect import",
            .source =
            \\import "./setup";
            \\import { A, B } from "./a";
            \\import { C as D } from "./b";
            \\export type T = A | D;
            \\export const value = B();
            ,
        },
        .{
            .name = "export specifier is value use",
            .source =
            \\import { A } from "./lib";
            \\export { A };
            ,
        },
        .{
            .name = "computed property key is value use",
            .source =
            \\import { A } from "./lib";
            \\export const value = { [A]: 1 };
            ,
        },
        .{
            .name = "shorthand property is value use",
            .source =
            \\import { A } from "./lib";
            \\export const value = { A };
            ,
        },
        .{
            .name = "default parameter initializer is value use",
            .source =
            \\import { A } from "./lib";
            \\export function f(value = A()) {
            \\  return value;
            \\}
            ,
        },
        .{
            .name = "nested function body reference is value use",
            .source =
            \\import { A } from "./lib";
            \\export function outer() {
            \\  return function inner() {
            \\    return A();
            \\  };
            \\}
            ,
        },
        .{
            .name = "function parameter shadow does not keep import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f(Foo = Foo) {
            \\  return Foo;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "arrow parameter shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const before = Foo();
            \\export const fn = (Foo) => Foo;
            \\export const after = Bar();
            ,
        },
        .{
            .name = "parameter shadow default can still use another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f(Foo = Bar()) {
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "object destructuring parameter shadows import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f({ Foo }) {
            \\  return Foo;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "object destructuring parameter default uses another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f({ x: Foo = Bar() }) {
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "array destructuring parameter default uses another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f([Foo = Bar()]) {
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "rest parameter shadows import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f(...Foo) {
            \\  return Foo.length;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "nested function parameter shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function outer() {
            \\  const first = Foo();
            \\  function inner(Foo = Bar()) {
            \\    return Foo;
            \\  }
            \\  return first + inner();
            \\}
            ,
        },
        .{
            .name = "nested arrow parameter shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const outer = () => {
            \\  const inner = (Foo = Bar()) => Foo;
            \\  return Foo() + inner();
            \\};
            ,
        },
        .{
            .name = "catch binding shadow does not hide try body import use",
            .source =
            \\import { Foo } from "./lib";
            \\try { Foo(); } catch (Foo) { Foo; }
            ,
        },
        .{
            .name = "block lexical shadow does not hide outer import use",
            .source =
            \\import { Foo } from "./lib";
            \\{ const Foo = 1; Foo; }
            \\Foo();
            ,
        },
        .{
            .name = "nested block lexical shadow does not hide outer import use",
            .source =
            \\import { Foo } from "./lib";
            \\{
            \\  { const Foo = 1; Foo; }
            \\  Foo();
            \\}
            ,
        },
        .{
            .name = "nested function catch and block shadows stay scoped",
            .source =
            \\import { Foo, Bar, Baz } from "./lib";
            \\export function outer(Foo = Bar()) {
            \\  try {
            \\    Baz();
            \\  } catch (Bar) {
            \\    { const Baz = Bar; Baz; }
            \\  }
            \\  return Foo;
            \\}
            \\export const value = Bar();
            ,
        },
        .{
            .name = "function var shadow does not keep import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export function f() {
            \\  var Foo = Bar();
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "nested function var shadow does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const before = Foo();
            \\export function outer() {
            \\  if (ok) { var Foo = Bar(); }
            \\  return Foo;
            \\}
            ,
        },
        .{
            .name = "named function expression self-name does not keep import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const fn = function Foo() {
            \\  return Foo;
            \\};
            \\export const value = Bar();
            ,
        },
        .{
            .name = "named function expression self-name does not hide outer value use",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\export const fn = function Foo(value = Foo) {
            \\  return value;
            \\};
            \\export const value = Foo() + Bar();
            ,
        },
        .{
            .name = "local declaration initializer can use another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  const Foo = Bar();
            \\  Foo;
            \\}
            ,
        },
        .{
            .name = "type-only import use mixed with value import use",
            .source =
            \\import { Foo, Bar, type Baz } from "./lib";
            \\type T = Foo | Baz;
            \\{ const Foo = 1; Foo; }
            \\export const value: T = Bar();
            ,
        },
        .{
            .name = "block lexical shadow covers declaration initializer order",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  Foo;
            \\  const Foo = Bar();
            \\}
            \\Foo();
            ,
        },
        .{
            .name = "destructuring local shadow initializer can use another import",
            .source =
            \\import { Foo, Bar } from "./lib";
            \\{
            \\  const { value: Foo = Bar() } = source;
            \\  Foo;
            \\}
            ,
        },
        .{
            // assignment_expression LHS (`Foo = expr`) 가 expression context 에서 walker arm
            // 에 잡혀 value_context=false 로 강제되면 import 가 잘못 elide 된다 — regression guard.
            .name = "assignment to imported name in expression keeps import",
            .source =
            \\import { Foo } from "./lib";
            \\Foo = something();
            ,
        },
        .{
            .name = "verbatim keeps value import but removes inline type specifier",
            .source =
            \\import { type A, B } from "./lib";
            \\export function f(value: A): void {}
            ,
            .options = .{ .verbatim_module_syntax = true },
        },
    };

    for (cases) |case| {
        expectFastFullParity(.bindings, case.source, "input.ts", case.options) catch |err| {
            std.debug.print("binding-lite parity failed for case '{s}'\n", .{case.name});
            return err;
        };
    }
}

test "TransformPlan: full-route guards for binding-lite follow-up" {
    const compat = @import("transformer/compat.zig");
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        path: []const u8 = "input.ts",
        options: TranspileOptions = .{},
    }{
        .{ .name = "default import", .source = "import Foo from './x';\nexport const x = 1;\n" },
        .{ .name = "namespace import", .source = "import * as Foo from './x';\nexport const x = 1;\n" },
        .{ .name = "jsx", .source = "import { Foo } from './x';\nexport const x = <Foo />;\n", .path = "input.tsx" },
        .{ .name = "enum", .source = "import { Foo } from './x';\nenum E { A }\n" },
        .{ .name = "namespace", .source = "import { Foo } from './x';\nnamespace N { export const x = 1 }\n" },
        .{ .name = "import equals", .source = "import { Foo } from './x';\nimport Bar = require('bar');\n" },
        .{ .name = "export assignment", .source = "import { Foo } from './x';\nexport = Foo;\n" },
        .{ .name = "class", .source = "import { Foo } from './x';\nclass C {}\n" },
        .{ .name = "private", .source = "import { Foo } from './x';\nconst obj = Foo.#x;\n" },
        .{ .name = "decorator", .source = "import { Foo } from './x';\n@dec class C {}\n" },
        .{ .name = "using", .source = "import { Foo } from './x';\nusing resource = Foo();\n" },
        .{ .name = "minify", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .minify_syntax = true } },
        .{ .name = "define", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .define = &.{.{ .key = "DEBUG", .value = "false" }} } },
        .{ .name = "drop", .source = "import { Foo } from './x';\nconsole.log(Foo);\n", .options = .{ .drop_console = true } },
        .{ .name = "cjs", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .module_format = .cjs } },
        .{ .name = "downlevel", .source = "import { Foo } from './x';\nFoo();\n", .options = .{ .unsupported = compat.fromESTarget(.es5), .es_target = .es5 } },
        .{ .name = "flow", .source = "import { Foo } from './x';\nexport const x: Foo = 1;\n", .path = "input.js", .options = .{ .flow = true } },
    };

    for (cases) |case| {
        const plan = testTransformPlan(case.source, case.path, case.options) catch |err| {
            std.debug.print("full-route guard parse failed for case '{s}'\n", .{case.name});
            return err;
        };
        std.testing.expectEqual(SemanticRequirement.full, plan.semantic) catch |err| {
            std.debug.print("full-route guard failed for case '{s}', reason={s}\n", .{ case.name, @tagName(plan.reason) });
            return err;
        };
    }
}
