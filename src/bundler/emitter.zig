//! ZTS Bundler — Emitter
//!
//! 모듈 그래프의 모듈들을 exec_index 순서로 변환+코드젠하여
//! 단일 파일 번들로 출력한다.
//!
//! 책임:
//!   - exec_index 순서 정렬
//!   - 각 모듈: Transformer → Codegen
//!   - 포맷별 래핑 (ESM/CJS/IIFE)
//!   - import/export 처리는 linker(별도 PR)에서 담당
//!
//! 설계:
//!   - Rollup 방식: emitter(finaliser)와 linker 분리 (유지보수 우선)
//!   - D058: exec_index 순서 = ESM 실행 순서

const std = @import("std");
const profile = @import("../profile.zig");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;
const rt = @import("runtime_helpers.zig");

const chunk_mod = @import("chunk.zig");
const ChunkGraph = chunk_mod.ChunkGraph;
const Chunk = chunk_mod.Chunk;
const ChunkIndex = types.ChunkIndex;
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Transformer = @import("../transformer/transformer.zig").Transformer;
const RuntimeHelpers = @import("../transformer/transformer.zig").RuntimeHelpers;
const CompiledModule = @import("compiled_module.zig").CompiledModule;
const cache_mod = @import("compiled_cache.zig");
pub const CompiledOutputCache = cache_mod.CompiledOutputCache;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../codegen/sourcemap.zig");
const error_codes = @import("../error_codes.zig");

/// ZTS0002 TLA+non-ESM 경고 주석. comptime 고정 — 코드/메시지가 error_codes와 항상 일치.
const tla_warning_comment = "/* [" ++ error_codes.Code.tla_requires_esm_format.format() ++ "] " ++ error_codes.Code.tla_requires_esm_format.message() ++ ". */\n";
const Linker = @import("linker.zig").Linker;
const LinkingMetadata = @import("linker.zig").LinkingMetadata;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const statement_shaker = @import("statement_shaker.zig");
const stmt_info_mod = @import("stmt_info.zig");
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const plugin_mod = @import("plugin.zig");

pub const EmitOptions = struct {
    format: Format = .esm,
    minify_whitespace: bool = false,
    /// AST 레벨 최적화 (constant folding, DCE 등)
    minify_syntax: bool = false,
    /// Identifier mangle 활성화 (linker 가 주 mangle 을 담당하지만 private field mangle 은
    /// AST-level pass 가 별도로 수행 — 이 플래그로 게이트).
    minify_identifiers: bool = false,
    /// 소스맵 관련 옵션 묶음. 하위 필드: enable / debug_ids / function_map / lazy /
    /// source_root / sources_content. `SourceMapOptions` 정의는 `codegen/sourcemap.zig`.
    sourcemap: SourceMap.SourceMapOptions = .{},
    /// dev mode: 각 모듈을 __zts_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    /// null이면 절대 경로를 그대로 사용.
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// Reanimated worklet 네이티브 변환.
    worklet_transform: bool = false,
    /// worklet의 `__pluginVersion` 값. null이면 ZTS 기본 상수.
    worklet_plugin_version: ?[]const u8 = null,
    /// dev mode에서 per-module codes 수집 여부.
    /// false면 output만 생성하고 module_dev_codes를 건너뛴다 (초기 빌드용, 메모리 절감).
    /// true면 HMR 업데이트용 module_dev_codes를 수집한다 (rebuild용).
    collect_module_codes: bool = false,
    /// define 글로벌 치환 (--define:KEY=VALUE)
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    /// legacy decorator 변환
    experimental_decorators: bool = false,
    /// emitDecoratorMetadata: __metadata 주입
    emit_decorator_metadata: bool = false,
    /// useDefineForClassFields=false
    use_define_for_class_fields: bool = true,
    /// verbatimModuleSyntax=true: unused value import 를 elide 하지 않음.
    verbatim_module_syntax: bool = false,
    /// Unsupported features bitmask (ES/엔진 타겟에서 변환됨)
    unsupported: @import("../transformer/transformer.zig").TransformOptions.compat.UnsupportedFeatures = .{},
    /// 타겟 플랫폼. import.meta polyfill 방식을 결정한다.
    platform: @import("../codegen/codegen.zig").Platform = .browser,
    /// 에셋/청크 URL prefix (동적 import 경로에 적용)
    public_path: []const u8 = "",
    /// 번들 출력 앞에 삽입할 텍스트
    banner_js: ?[]const u8 = null,
    /// 번들 출력 뒤에 삽입할 텍스트
    footer_js: ?[]const u8 = null,
    /// IIFE 포맷에서 export를 바인딩할 글로벌 변수명
    global_name: ?[]const u8 = null,
    /// IIFE external → 전역 식별자 매핑 (rollup `output.globals` 호환, #1824).
    /// 예: `{ specifier="react", global_name="React" }` →
    /// `var Lib = (function(react){...})(React);`. 비어있으면 IIFE 는 external 없이 emit.
    globals: []const types.GlobalEntry = &.{},
    /// 출력 파일 확장자 오버라이드 (.mjs, .cjs 등)
    out_extension_js: ?[]const u8 = null,
    /// 출력 파일명 (소스맵 참조용, 예: "out.js")
    output_filename: []const u8 = "bundle.js",
    /// UTF-8 문자를 이스케이프하지 않고 그대로 출력
    charset_utf8: bool = false,
    /// 엔트리 청크 파일명 패턴 (예: "[name]", "[name]-[hash]", "[dir]/[name]-[hash]")
    entry_names: []const u8 = "[name]",
    /// 공통 청크 파일명 패턴 (예: "[name]-[hash]", "chunks/[name]-[hash]")
    chunk_names: []const u8 = "[name]-[hash]",
    /// 에셋 파일명 패턴 (예: "[name]-[hash]", "assets/[name]-[hash]")
    asset_names: []const u8 = "[name]-[hash]",
    /// legal comments 처리 모드
    legal_comments: types.LegalComments = .default,
    /// --keep-names: minify 시 함수/클래스 .name 프로퍼티 보존
    keep_names: bool = false,
    /// --drop-labels: 특정 라벨의 labeled statement 제거
    drop_labels: []const []const u8 = &.{},
    /// JSX 런타임 모드
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    /// classic 모드 JSX factory
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 Fragment factory
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source
    jsx_import_source: []const u8 = "react",
    /// 플러그인 배열. bundler에서 전파.
    plugins: []const plugin_mod.Plugin = &.{},
    /// 번들 시작 시 즉시 실행 폴리필. 각 항목은 { .name, .content }.
    /// IIFE로 감싸서 런타임 헬퍼 앞에 인라인. 파일 I/O는 bundler에서 완료.
    polyfills: []const PolyfillEntry = &.{},
    /// 엔트리 모듈 직전에 실행할 모듈 경로 (--run-before-main).
    /// 해당 모듈의 require_xxx() / init_xxx() 호출을 엔트리 코드 앞에 삽입.
    run_before_main: []const []const u8 = &.{},
    /// Object.defineProperty에 configurable: true 추가 (RN/Hermes 호환).
    configurable_exports: bool = false,
    /// strict execution order: __esm factory 밖으로 함수를 호이스팅하지 않음.
    /// Rolldown의 strictExecutionOrder와 동일. Babel worklet 플러그인 등이
    /// function declaration을 var assignment(factory 패턴)로 변환하면
    /// 호이스팅이 깨지므로, 모든 코드를 factory 안에 유지하여 init 순서 보장.
    /// React Native 빌드에서 기본 활성화 권장.
    strict_execution_order: bool = false,
    /// Metro `guardedLoadModule` 호환: entry trigger (`init_X()` 또는
    /// `require_X()`) 호출을 try/catch + `ErrorUtils.reportFatalError(e)` 로 wrap.
    /// module factory 가 throw 해도 부팅이 막히지 않고 RN 표준 LogBox 에 fatal 로
    /// 표시. Metro 의 `guardedLoadModule` (top-level `__r` wrapper) 와 동등 mechanism.
    /// `ErrorUtils` 미정의 환경 (test / browser) 에선 throw 그대로 re-throw.
    /// 발견 계기: iOS 26.4 Hermes 가 `Location` 등 spec global 을 immutable
    /// descriptor (`configurable: false`) 로 미리 등록 + expo-metro-runtime 가
    /// 가드 없이 `defineProperty` 호출 → throw → 부팅 실패. mechanism 은 OS/엔진
    /// 무관이라 모든 module factory throw 케이스 커버. RN 플랫폼 default 활성 권장.
    entry_error_guard: bool = false,
    /// Prologue 에 `console.error` setter intercept 주입 — 각 RegExp source string 이
    /// match 하는 console.error 호출을 silent swallow. 비어있으면 intercept 자체 emit X.
    /// `entry_error_guard` 와 직교 — consumer 가 환경 (e.g. expo) 감지 후 패턴 주입.
    /// vanilla RN CLI 빌드는 비어있어 dead code 0.
    silent_console_error_patterns: []const []const u8 = &.{},
    /// preserve-modules: 모듈 1개 = 출력 파일 1개
    preserve_modules: bool = false,
    /// preserve-modules-root: 출력 디렉토리 구조의 기준 경로
    preserve_modules_root: ?[]const u8 = null,

    /// Compiled output cache (HMR/watch 전용, in-memory).
    /// 주입되면 변경 안 된 모듈의 emit 을 스킵하고 cache 의 결과를 재사용.
    /// null 이거나 모듈의 `mtime == 0` 이면 cache 비활성 — 항상 emit.
    compiled_cache: ?*CompiledOutputCache = null,

    pub const PolyfillEntry = struct {
        name: []const u8,
        content: []const u8,
        /// 원본 폴리필 파일 경로. 소스맵 sources 등록용. null이면 sources에 등록하지 않는다.
        path: ?[]const u8 = null,
    };

    pub const Format = types.Format;
};

pub const OutputFile = struct {
    path: []const u8,
    contents: []const u8,
    /// code splitting 시 이 chunk 에 포함된 모듈들의 절대경로 (rolldown `chunk.moduleIds` 호환).
    /// 단일 번들 모드 및 asset output 은 빈 slice. caller 가 소유 — deinit 에서 해제.
    module_ids: []const []const u8 = &.{},
    /// 이 chunk 가 import 하는 다른 chunk 들의 출력 path 목록.
    imports: []const []const u8 = &.{},
    /// 이 chunk 가 export 하는 심볼 이름 (cross-chunk 검증용).
    exports: []const []const u8 = &.{},
    /// "chunk" (JS/TS 번들 결과) / "asset" (binary/text/file/dataurl 로더 output).
    kind: Kind = .chunk,

    pub const Kind = enum { chunk, asset };

    pub fn deinit(self: OutputFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.contents);
        for (self.module_ids) |id| allocator.free(id);
        if (self.module_ids.len > 0) allocator.free(self.module_ids);
        for (self.imports) |im| allocator.free(im);
        if (self.imports.len > 0) allocator.free(self.imports);
        for (self.exports) |ex| allocator.free(ex);
        if (self.exports.len > 0) allocator.free(self.exports);
    }
};

/// 번들 출력 결과. output + 소스맵.
pub const EmitResult = struct {
    /// 번들 코드. allocator 소유.
    output: []const u8,
    /// Eager 소스맵 JSON (V3). null 이면 소스맵 미생성 혹은 lazy 경로. allocator 소유.
    sourcemap: ?[]const u8 = null,
    /// Lazy 번들 sourcemap builder (Issue #1727 Phase B).
    /// `EmitOptions.lazy_sourcemap = true` 일 때 JSON 을 emit 단계에서 생성하지 않고 builder 를
    /// 이관하여 NAPI getter (`getBundleSourceMap`) 호출 시점에 generateJSON 을 수행한다.
    /// `sourcemap` 과 상호 배타. allocator 소유 — deinit 시 builder.deinit() + destroy.
    sourcemap_builder: ?*SourceMap.SourceMapBuilder = null,
    /// dev mode per-module codes (HMR용). null이면 미수집. allocator 소유.
    module_codes: ?[]const types.ModuleDevCode = null,

    pub fn deinit(self: *const EmitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.sourcemap) |sm| allocator.free(sm);
        if (self.sourcemap_builder) |sm| {
            sm.deinit();
            allocator.destroy(sm);
        }
        if (self.module_codes) |codes| types.ModuleDevCode.freeAll(codes, allocator);
    }
};

/// 모듈 그래프를 단일 번들로 출력한다.
pub fn emit(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: *const EmitOptions,
    linker: ?*const Linker,
) !EmitResult {
    return emitWithTreeShaking(allocator, graph, options, linker, null);
}

/// tree-shaking 적용된 번들 출력. shaker가 null이면 모든 모듈 포함 (기존 동작).
pub fn emitWithTreeShaking(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: *const EmitOptions,
    linker: ?*const Linker,
    shaker: ?*const TreeShaker,
) !EmitResult {
    // 1. JS/JSON 모듈 필터 + exec_index 순으로 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (0..graph.moduleCount()) |i| {
        const m = graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        const is_asset = m.loader.isAsset() and m.source.len > 0;
        const is_js = (m.module_type == .javascript or m.module_type == .json) and (m.ast != null or m.is_disabled or is_asset);
        if (is_js) {
            // tree-shaking: 미포함 모듈 스킵
            if (shaker) |s| {
                if (!s.isIncluded(@intCast(i))) continue;
            }
            try sorted.append(allocator, m);
        }
    }

    std.mem.sort(*const Module, sorted.items, {}, Module.bundleOrderLessThan);

    // 2. 각 모듈을 변환 + 코드젠
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // banner 삽입 (포맷별 prologue 직전)
    if (options.banner_js) |banner| {
        try output.appendSlice(allocator, banner);
        try output.append(allocator, '\n');
    }

    // TLA 포함 여부: 래핑 포맷에서 async로 감싸야 하는지 결정
    const has_tla = blk: {
        for (sorted.items) |m| {
            if (m.uses_top_level_await) break :blk true;
        }
        break :blk false;
    };
    // IIFE 래퍼는 내부에 `this`/`arguments`/`new.target`을 노출하지 않으므로
    // arrow 전환이 시맨틱을 바꾸지 않는다. ES5 타겟처럼 arrow 미지원 환경에서만
    // 기존 `function` 형태를 유지 (#1580, esbuild 관행과 동일).
    const use_arrow = !options.unsupported.arrow;

    // UMD/AMD/IIFE: external specifier 수집 (dependency array + factory params 생성용).
    // IIFE 는 globals 매핑된 spec 만 수집 — 매핑 안 된 external 은 unresolved 로 취급되어
    // linker 가 fatal_diagnostics 로 에러 발행 (#1791).
    var ext_specifiers: std.ArrayList([]const u8) = .empty;
    defer ext_specifiers.deinit(allocator);
    // IIFE 는 globals 매핑된 spec 에 대응되는 전역 인자를 수집한다. UMD/AMD 는 사용 안 함.
    var iife_ext_globals: std.ArrayList([]const u8) = .empty;
    defer iife_ext_globals.deinit(allocator);
    const collect_externals = options.format == .umd or options.format == .amd or
        (options.format == .iife and options.globals.len > 0);
    if (collect_externals) {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (sorted.items) |m| {
            for (m.import_records) |rec| {
                if (!rec.is_external or seen.contains(rec.specifier)) continue;
                if (options.format == .iife) {
                    // IIFE: globals 매핑이 있는 spec 만 factory 파라미터에 수록.
                    // 매핑이 없는 external 은 linker 가 fatal diagnostic 으로 처리.
                    if (types.GlobalEntry.lookup(options.globals, rec.specifier)) |gname| {
                        try seen.put(rec.specifier, {});
                        try ext_specifiers.append(allocator, rec.specifier);
                        try iife_ext_globals.append(allocator, gname);
                    }
                } else {
                    try seen.put(rec.specifier, {});
                    try ext_specifiers.append(allocator, rec.specifier);
                }
            }
        }
    }

    // specifier → factory 매개변수명 precompute (UMD/AMD/IIFE 공통)
    var ext_param_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (ext_param_names.items) |n| allocator.free(n);
        ext_param_names.deinit(allocator);
    }
    for (ext_specifiers.items) |spec| {
        try ext_param_names.append(allocator, try types.specifierToParamName(allocator, spec));
    }

    // IIFE + externals 가 있으면 factory_fn 을 param 포함 형태로 조립 (#1824).
    // 예: `(function(React, ReactDom) {\n`. 그 외에는 정적 문자열 사용.
    const factory_fn_static = if (has_tla)
        (if (use_arrow) "(async () => {\n" else "(async function() {\n")
    else
        (if (use_arrow) "(() => {\n" else "(function() {\n");
    const factory_fn_owned: ?[]const u8 = blk: {
        if (options.format != .iife or ext_param_names.items.len == 0) break :blk null;
        const prefix = if (has_tla)
            (if (use_arrow) "(async (" else "(async function(")
        else
            (if (use_arrow) "((" else "(function(");
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, prefix);
        for (ext_param_names.items, 0..) |n, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, n);
        }
        if (use_arrow) {
            try buf.appendSlice(allocator, ") => {\n");
        } else {
            try buf.appendSlice(allocator, ") {\n");
        }
        break :blk try buf.toOwnedSlice(allocator);
    };
    defer if (factory_fn_owned) |s| allocator.free(s);
    const factory_fn: []const u8 = factory_fn_owned orelse factory_fn_static;

    // emit_prelude: 포맷 prologue + polyfill 주입 + runtime helper 준비.
    // emit_module_pass 시작점 (`Phase 1: used_names`) 직전에 end.
    var prelude_scope = profile.begin(.emit_prelude);

    // 포맷별 prologue
    try emitFormatPrologue(&output, allocator, options.format, options.global_name, factory_fn, ext_specifiers.items, ext_param_names.items);

    // 폴리필 주입 (--polyfill): IIFE로 감싸서 즉시 실행.
    // Metro/롤다운과 동일하게 모듈 그래프 밖에서 런타임 헬퍼보다 먼저 실행.
    const PolyfillRange = struct {
        content_start_line: u32,
        content_line_count: u32,
        entry: *const EmitOptions.PolyfillEntry,
    };
    var polyfill_ranges: std.ArrayList(PolyfillRange) = .empty;
    defer polyfill_ranges.deinit(allocator);

    // output에 누적 추가된 줄 수를 인라인 추적 (전체 버퍼 재스캔 방지).
    var output_line: u32 = @intCast(std.mem.count(u8, output.items, "\n"));

    for (options.polyfills) |*poly| {
        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "// --- polyfill: ");
            try output.appendSlice(allocator, poly.name);
            try output.appendSlice(allocator, " ---\n");
            output_line += 1;
        }
        try output.appendSlice(allocator, "(function(){");
        if (!options.minify_whitespace) {
            try output.append(allocator, '\n');
            output_line += 1;
        }

        const content_start = output_line;
        try output.appendSlice(allocator, poly.content);
        output_line += @intCast(std.mem.count(u8, poly.content, "\n"));
        if (!options.minify_whitespace) {
            try output.append(allocator, '\n');
            output_line += 1;
        }

        if (options.sourcemap.enable and poly.path != null) {
            try polyfill_ranges.append(allocator, .{
                .content_start_line = content_start,
                .content_line_count = output_line - content_start,
                .entry = poly,
            });
        }

        try output.appendSlice(allocator, "})();\n");
        output_line += 1;
    }

    // 런타임 헬퍼 주입
    try emitBundleRuntimeHelpers(&output, allocator, sorted.items, options);

    // TLA 검증: 비-ESM 출력에서 TLA 사용 시 경고 주석 삽입.
    // Top-Level Await는 ESM 전용 기능이므로 CJS/IIFE/UMD/AMD 포맷에서는 동작하지 않는다.
    // DFS로 exec_index가 부여된 모듈만 확인한다 — 동적 import로만 도달하는 모듈은
    // exec_index가 maxInt(u32)이며, 비동기 로딩이므로 경고 불필요.
    if (options.format != .esm) {
        for (sorted.items) |m| {
            if (m.uses_top_level_await and m.exec_index != std.math.maxInt(u32)) {
                try output.appendSlice(allocator, tla_warning_comment);
                break;
            }
        }
    }

    // ESM 출력 + external: esbuild와 동일하게 require() preamble만 사용.
    // import 구문이 없으면 Node가 CJS로 파싱하여 require()가 동작한다.
    // (createRequire shim은 ESM 파싱을 유발하여 var 재선언 에러를 일으킴)

    // 런타임 헬퍼 수집: 모듈별 transform에서 실제 사용된 헬퍼만 추적
    var collected_helpers: RuntimeHelpers = .{};

    // 엔트리 모듈 인덱스 (final exports / CJS auto-invoke용).
    // Module.is_entry_point 플래그로 정확히 식별 — 정렬 순서나 exec_index와 무관.
    const entry_idx: ?u32 = blk: {
        for (sorted.items) |m| {
            if (m.is_entry_point) break :blk m.index.toU32();
        }
        break :blk null;
    };

    prelude_scope.end();

    // emit_module_pass: Phase 1 (used_names 사전 계산) + Phase 1.5 (compiled cache
    // lookup) + Phase 2 (emitModule 병렬/순차) + Phase 2.5 (cache put). transform /
    // codegen 실제 호출이 이 범위에서 발생.
    var module_pass_scope = profile.begin(.emit_module_pass);

    // Phase 1: used_names 사전 계산 (순차 — 모듈 간 의존)
    const used_names_list = try computeAllUsedNames(allocator, sorted.items, graph, shaker);
    defer {
        for (used_names_list) |un| {
            allocator.free(un.names);
        }
        allocator.free(used_names_list);
    }

    // Phase 2: emitModule 병렬 실행 (2개 이상이면 스레드 풀, 아니면 순차)
    var results = try allocator.alloc(CompiledModule, sorted.items.len);
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }
    for (results) |*r| r.* = .{};

    // Phase 1.5: compiled output cache lookup. input_hashes 는 Phase 2.5 put 에
    // 재사용 — miss 당 hash 를 두 번 계산하지 않기 위함.
    var hit_mask = try allocator.alloc(bool, sorted.items.len);
    defer allocator.free(hit_mask);
    @memset(hit_mask, false);
    var input_hashes = try allocator.alloc(u64, sorted.items.len);
    defer allocator.free(input_hashes);
    @memset(input_hashes, 0);

    const options_hash: u64 = if (options.compiled_cache != null)
        cache_mod.computeOptionsHash(options)
    else
        0;

    if (options.compiled_cache) |cache| {
        for (sorted.items, 0..) |m, i| {
            if (m.mtime == 0) {
                cache.skipped_no_mtime += 1;
                continue; // mtime unknown → cache 비활성
            }
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            const input_hash = cache_mod.computeInputHash(m, options_hash, used_names, graph);
            input_hashes[i] = input_hash;
            const hit = cache.tryHit(m.path, input_hash) orelse continue;
            results[i] = hit.dupe(allocator) catch continue;
            hit_mask[i] = true;
        }
    }

    var use_pool = sorted.items.len >= 2;
    var pool: std.Thread.Pool = undefined;
    if (use_pool) {
        use_pool = if (pool.init(.{ .allocator = allocator })) |_| true else |_| false;
    }
    defer if (use_pool) pool.deinit();

    if (use_pool) {
        var wg: std.Thread.WaitGroup = .{};
        for (sorted.items, 0..) |m, i| {
            if (hit_mask[i]) continue;
            const is_entry = if (entry_idx) |ei| m.index.toU32() == ei else false;
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            pool.spawnWg(&wg, emitModuleThread, .{ allocator, m, options, linker, is_entry, used_names, shaker, &results[i] });
        }
        pool.waitAndWork(&wg);
    } else {
        for (sorted.items, 0..) |m, i| {
            if (hit_mask[i]) continue;
            const is_entry = if (entry_idx) |ei| m.index.toU32() == ei else false;
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            results[i].code = emitModule(allocator, m, options, linker, is_entry, used_names, shaker, &results[i].helpers, &results[i].mappings, &results[i].preamble_lines, &results[i].fn_map_json, &results[i].entry_chain) catch null;
        }
    }

    // Phase 2.5: miss 결과를 cache 에 put. StringHashMap.put 은 thread-unsafe 이므로
    // 병렬 emit 완료 후 순차 처리. put 실패는 다음 빌드에서 재시도되므로 silent continue.
    if (options.compiled_cache) |cache| {
        for (sorted.items, 0..) |m, i| {
            if (hit_mask[i]) continue;
            if (m.mtime == 0) continue;
            if (results[i].code == null) continue;
            cache.put(m.path, input_hashes[i], results[i]) catch continue;
        }
    }

    module_pass_scope.end();

    // emit_concat: Phase 3 순차 합류 — exec_index 순서대로 module concat + runtime
    // helper 합산 + 소스맵 매핑 누적 + renderChunk 훅 + epilogue.
    var concat_scope = profile.begin(.emit_concat);

    // Phase 3: 순차 합류 — exec_index 순서대로 concat + helpers 합산 + 소스맵 수집
    var module_output: std.ArrayList(u8) = .empty;
    defer module_output.deinit(allocator);

    // RSC: 디렉티브가 첫 문장이어야 인식되므로 entry 모듈의 prologue를 호이스트.
    var hoisted_directives: std.ArrayList(u8) = .empty;
    defer hoisted_directives.deinit(allocator);

    // dev mode per-module code 수집 (HMR용)
    var dev_module_codes: std.ArrayList(types.ModuleDevCode) = .empty;
    if (options.dev_mode and options.collect_module_codes) {
        try dev_module_codes.ensureTotalCapacity(allocator, sorted.items.len);
    }
    errdefer {
        for (dev_module_codes.items) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
            if (c.map) |m| allocator.free(m);
            if (c.sm_builder) |sm| {
                sm.deinit();
                allocator.destroy(sm);
            }
        }
        dev_module_codes.deinit(allocator);
    }

    // 소스맵 빌더 (소스맵 활성화 시). eager 경로는 stack 할당으로 기존 zero-overhead 유지.
    // lazy 경로 (Issue #1727) 에서만 return 직전 heap 으로 얕은 복사 이동 — ArrayList 의 items
    // 포인터는 이미 allocator 소유이므로 payload 를 heap SourceMapBuilder 로 옮겨도 double-free
    // 없음. `bundle_sm_moved = true` 시 본 함수의 defer 가 deinit 을 건너뛰어 원본은 drain 된다.
    var bundle_sm: ?SourceMap.SourceMapBuilder = if (options.sourcemap.enable) blk: {
        var sm = SourceMap.SourceMapBuilder.init(allocator);
        sm.source_root = options.sourcemap.source_root orelse "";
        sm.sources_content = options.sourcemap.sources_content;
        break :blk sm;
    } else null;
    var bundle_sm_moved = false;
    defer if (!bundle_sm_moved) {
        if (bundle_sm) |*sm| sm.deinit();
    };

    // per-source function map JSON 목록 (sources 추가 순서와 1:1 대응).
    // sourcemap + sourcemap_function_map 활성화 시에만 사용.
    var per_source_fn_maps: std.ArrayList(?[]const u8) = .empty;
    defer per_source_fn_maps.deinit(allocator);

    // output에 이미 추가된 prologue/banner/polyfill/runtime helper 줄 수 추적
    // (module_output과 별도로 output에 먼저 들어감 — 아래에서 합류 시 사용)
    // 이 시점에서는 아직 runtime helper가 추가되지 않았으므로 0으로 시작하고
    // merge 시 output.items의 줄 수를 기준 오프셋으로 사용
    var module_line: u32 = 0;

    // module_output pre-size: 합계 capacity 를 한 번 확보해 concat 루프의 모듈별 appendSlice
    // 가 매번 grow (~log2(N) realloc) 하는 비용을 제거 (Issue #1727 §1).
    var module_output_estimate: usize = 0;
    for (sorted.items, 0..) |m, i| {
        const code = results[i].code orelse continue;
        module_output_estimate += code.len;
        if (!options.minify_whitespace) {
            // `"// --- " + basename + " ---\n"` (12 + basename) + 모듈 말미 개행 1
            module_output_estimate += std.fs.path.basename(m.path).len + 13;
        }
    }
    try module_output.ensureTotalCapacity(allocator, module_output_estimate);

    for (sorted.items, 0..) |m, i| {
        // helpers 합산 (bitwise OR)
        collected_helpers = @bitCast(@as(u32, @bitCast(collected_helpers)) | @as(u32, @bitCast(results[i].helpers)));

        const code = results[i].code orelse continue;

        // --run-before-main: 엔트리 모듈 직전에 해당 모듈의 require/init 호출 삽입.
        // __esm 래핑된 엔트리(RN)는 emitEsmWrappedModule에서 body 안에 삽입.
        const is_entry = if (entry_idx) |ei| m.index.toU32() == ei else false;
        if (is_entry and options.run_before_main.len > 0 and m.wrap_kind != .esm) {
            const before_len = module_output.items.len;
            try appendRunBeforeMainCalls(&module_output, allocator, graph, options.run_before_main, options);
            module_line += @intCast(std.mem.count(u8, module_output.items[before_len..], "\n"));
        }

        if (!options.minify_whitespace) {
            try module_output.appendSlice(allocator, "// --- ");
            try module_output.appendSlice(allocator, std.fs.path.basename(m.path));
            try module_output.appendSlice(allocator, " ---\n");
            module_line += 1;
        }

        // 소스맵: 모듈 매핑을 번들 오프셋으로 조정하여 추가
        if (bundle_sm) |*sm| {
            if (results[i].mappings) |maps| {
                try addModuleMappings(
                    sm,
                    sourcemapSourcePath(m.path, options),
                    m.source,
                    maps,
                    module_line,
                    results[i].preamble_lines,
                    options.sourcemap.sources_content,
                    false,
                );
                // function map: source 추가 순서와 동기화
                if (options.sourcemap.function_map) {
                    try per_source_fn_maps.append(allocator, results[i].fn_map_json);
                }
            }
        }

        // RSC: ESM entry 모듈만 호이스트 대상. IIFE/CJS는 의미 없음.
        const code_to_append = if (is_entry and options.format == .esm)
            chunks.extractLeadingDirectives(code, &hoisted_directives, allocator) catch code
        else
            code;

        try module_output.appendSlice(allocator, code_to_append);
        module_line += @intCast(std.mem.count(u8, code_to_append, "\n"));
        if (!options.minify_whitespace) {
            try module_output.append(allocator, '\n');
            module_line += 1;
        }

        // dev mode: per-module code를 HMR eval 가능한 형태로 수집.
        // IIFE로 래핑 + 런타임 헬퍼 로컬 alias로 eval() 스코프에서 접근 가능.
        if (options.dev_mode and options.collect_module_codes) {
            const mod_id = makeModuleId(m.path, options.root_dir);

            // sourcemap 활성 시 `//# sourceURL=<mod_id>` 주석을 eval 코드 끝에 덧붙여
            // DevTools 가 익명 eval 스크립트(VM:1) 대신 모듈 경로로 표시하게 한다.
            // `sourceMappingURL` 은 dev server 가 라우트 컨벤션에 맞춰 별도 부착 —
            // ZTS 는 서버 URL 구조를 모르므로 여기서는 `sourceURL` 만 담당.
            // IIFE 끝 뒤에 위치하므로 `HMR_PREAMBLE_LINES` 오프셋에는 영향 없음.
            var source_url_buf: []const u8 = "";
            defer if (source_url_buf.len > 0) allocator.free(source_url_buf);
            if (options.sourcemap.enable) {
                source_url_buf = try std.fmt.allocPrint(allocator, "//# sourceURL={s}\n", .{mod_id});
            }

            const hmr_code = try std.mem.concat(allocator, u8, &.{
                "(function(){\n",
                "var __esm=__zts_g.__esm,__export=__zts_g.__export,__commonJS=__zts_g.__commonJS,",
                "__defProp=__zts_g.__defProp,__toESM=__zts_g.__toESM,__toCommonJS=__zts_g.__toCommonJS,",
                "__zts_modules=__zts_g.__zts_modules,__zts_make_hot=__zts_g.__zts_make_hot,",
                "__zts_resolveRefresh=__zts_g.__zts_resolveRefresh||function(){return null},",
                "__zts_isReactRefreshBoundary=__zts_g.__zts_isReactRefreshBoundary,",
                "__zts_enqueueUpdate=__zts_g.__zts_enqueueUpdate,",
                "__zts_reload=__zts_g.__zts_reload;\n",
                code,
                "\n})();\n",
                source_url_buf,
            });

            // 모듈별 standalone sourcemap (Issue #1248): HMR 클라이언트가 전체 번들
            // sourcemap을 재처리하지 않고 변경 모듈만 매핑할 수 있게 한다.
            // 위 hmr_code preamble은 항상 정확히 2줄 — IIFE 시작 + var alias 줄.
            // eager 는 stack 유지. lazy (Issue #1727) 는 return 직전 heap 으로 얕은 복사 이동.
            const HMR_PREAMBLE_LINES: u32 = 2;
            var module_map: ?[]const u8 = null;
            var module_sm_builder: ?*SourceMap.SourceMapBuilder = null;
            if (options.sourcemap.enable) {
                if (results[i].mappings) |maps| {
                    var mod_sm = SourceMap.SourceMapBuilder.init(allocator);
                    var mod_sm_moved = false;
                    defer if (!mod_sm_moved) mod_sm.deinit();
                    mod_sm.sources_content = options.sourcemap.sources_content;
                    try addModuleMappings(
                        &mod_sm,
                        sourcemapSourcePath(m.path, options),
                        m.source,
                        maps,
                        HMR_PREAMBLE_LINES,
                        results[i].preamble_lines,
                        options.sourcemap.sources_content,
                        false,
                    );
                    if (options.sourcemap.lazy) {
                        const heap_sm = try allocator.create(SourceMap.SourceMapBuilder);
                        heap_sm.* = mod_sm;
                        heap_sm.fixSelfReferences();
                        mod_sm_moved = true;
                        module_sm_builder = heap_sm;
                    } else {
                        _ = try mod_sm.generateJSON(mod_id);
                        // buf 소유권 이전 — dupe + deinit-free 라운드트립 회피
                        module_map = try mod_sm.buf.toOwnedSlice(allocator);
                    }
                }
            }

            try dev_module_codes.append(allocator, .{
                .id = try allocator.dupe(u8, mod_id),
                .code = hmr_code,
                .map = module_map,
                .sm_builder = module_sm_builder,
            });
        }
    }

    // ES2015 런타임 헬퍼 주입: transformer가 실제 사용한 헬퍼만 주입
    try rt.appendRuntimeHelpers(&output, allocator, collected_helpers, options.minify_whitespace, options.unsupported.arrow);

    // prologue(banner/polyfill/runtime helper) 줄 수 → 소스맵 오프셋에 반영
    // module_output 합류 전에 계산해야 함 — 합류 후에 세면 전체 줄 수가 됨
    const prologue_lines: u32 = @intCast(std.mem.count(u8, output.items, "\n"));

    if (hoisted_directives.items.len > 0) {
        try output.insertSlice(allocator, 0, hoisted_directives.items);
    }

    // 모듈 코드 합류
    try output.appendSlice(allocator, module_output.items);

    // Plugin: renderChunk 훅 — 단일 파일 모드에서도 적용
    if (options.plugins.len > 0) {
        const runner = plugin_mod.PluginRunner.init(options.plugins);
        const rc_result = runner.runRenderChunk(output.items, "bundle", allocator) catch |err| switch (err) {
            error.PluginFailed => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (rc_result) |result| {
            output.clearRetainingCapacity();
            try output.appendSlice(allocator, result);
            allocator.free(result);
        }
    }

    // 래핑된 엔트리 자동 호출. Metro `getAppendScripts` 와 동등 — `runBeforeMainModule`
    // + entry 각 path 마다 separate `__r(N);` (= 독립 outer `__zts_guarded(...)`) 로 emit.
    if (entry_idx) |ei| {
        for (sorted.items, 0..) |em, ei_idx| {
            if (em.index.toU32() == ei and em.wrap_kind.isWrapped()) {
                if (results[ei_idx].entry_chain) |chain| {
                    try output.appendSlice(allocator, chain);
                }
                try appendGuardedModuleCall(&output, allocator, em, options);
                break;
            }
        }
    }

    // 포맷별 epilogue
    try emitFormatEpilogue(&output, allocator, options.format, iife_ext_globals.items);

    // legal comments (eof 모드): 모든 모듈의 legal comment를 파일 끝에 모아서 출력
    const lc_mode = resolveDefaultLegalComments(options.legal_comments, options.minify_whitespace);
    if (lc_mode == .eof or lc_mode == .linked or lc_mode == .external) {
        try collectLegalComments(&output, allocator, sorted.items, lc_mode);
    }

    // footer 삽입 (포맷별 epilogue 직후)
    if (options.footer_js) |footer| {
        try output.appendSlice(allocator, footer);
        try output.append(allocator, '\n');
    }

    // Sentry Debug ID (UUID v4) — sourcemap_debug_ids 활성화 시 생성
    var debug_id_buf: [36]u8 = undefined;
    const debug_id: ?[]const u8 = if (options.sourcemap.debug_ids) blk: {
        SourceMap.generateUuidV4(&debug_id_buf);
        break :blk &debug_id_buf;
    } else null;

    concat_scope.end();

    // emit_sourcemap_finalize: 소스맵 V3 JSON 생성 (mapping VLQ 인코딩 + sources
    // 내용 첨부 + debugId 삽입) + 번들 끝의 sourceMappingURL 주석 추가.
    // Lazy 경로 (Issue #1727) 에서는 builder 상태만 확정하고 JSON 생성은 NAPI getter
    // 호출 시점으로 연기 — 본 sub-phase 가 실측상 0ms 로 수렴. builder 의 debug_id 및
    // 매핑 조정은 emit 단계에서 수행.
    var sm_finalize_scope = profile.begin(.emit_sourcemap_finalize);
    defer sm_finalize_scope.end();

    var sourcemap_json: ?[]const u8 = null;
    if (bundle_sm) |*sm| {
        // prologue 줄 수를 모든 매핑에 추가
        if (prologue_lines > 0) {
            for (sm.mappings.items) |*mapping| {
                mapping.generated_line += prologue_lines;
            }
        }

        // prologue를 가상 소스 "<runtime>"으로 매핑하고 polyfill은 별도 source로 매핑.
        // DevTools가 vendored 프레임을 ignoreList로 스킵 → 유저 코드 프레임을 노출.
        if (prologue_lines > 0) {
            const runtime_src_idx = try addIdentitySource(sm, "node_modules/.zts/runtime.js", "// zts bundle runtime (polyfills, helpers)\n", options.sourcemap.sources_content);
            try sm.addIgnoredSource(runtime_src_idx);

            // polyfill content 라인을 건너뛰며 runtime identity 매핑 추가.
            // polyfill_ranges는 삽입 순서가 곧 시작 라인 오름차순.
            var cursor: u32 = 0;
            for (polyfill_ranges.items) |r| {
                try addIdentityMappings(sm, runtime_src_idx, cursor, r.content_start_line - cursor, cursor);
                cursor = r.content_start_line + r.content_line_count;
            }
            if (cursor < prologue_lines) {
                try addIdentityMappings(sm, runtime_src_idx, cursor, prologue_lines - cursor, cursor);
            }

            for (polyfill_ranges.items) |r| {
                const src_idx = try addIdentitySource(sm, r.entry.path.?, r.entry.content, options.sourcemap.sources_content);
                try sm.addIgnoredSource(src_idx);
                try addIdentityMappings(sm, src_idx, r.content_start_line, r.content_line_count, 0);
            }
        }

        // debugId 설정 — bundle.js 의 `//# debugId=` 주석과 동일 UUID 를 builder 에 보관.
        // lazy 경로에서는 builder 가 emit 밖으로 이관되므로 내부 버퍼에 복사해 저장 (stack
        // `debug_id_buf` 의 수명은 emit 함수 스코프로 제한됨).
        if (debug_id) |did| sm.setDebugId(did);

        if (!options.sourcemap.lazy) {
            // function map: identity source(polyfill/runtime)는 null 패딩
            if (options.sourcemap.function_map and per_source_fn_maps.items.len > 0) {
                while (per_source_fn_maps.items.len < sm.sources.items.len) {
                    try per_source_fn_maps.append(allocator, null);
                }
                const json = try sm.generateJSONWithPerSourceFunctionMaps(
                    allocator,
                    options.output_filename,
                    per_source_fn_maps.items,
                );
                sourcemap_json = try allocator.dupe(u8, json);
            } else {
                const json = try sm.generateJSON(options.output_filename);
                sourcemap_json = try allocator.dupe(u8, json);
            }
        }
    }

    // 소스맵 참조 추가. Lazy 경로에서도 bungae 의 `/bundle.js.map` 라우트가 serve 하므로
    // 주석은 항상 붙여 DevTools 가 fetch 하게 한다.
    if (options.sourcemap.enable) {
        try output.appendSlice(allocator, "//# sourceMappingURL=");
        if (options.dev_mode) try output.append(allocator, '/'); // dev 서버용 절대 경로
        try output.appendSlice(allocator, options.output_filename);
        try output.appendSlice(allocator, ".map\n");
    }

    // debugId 주석 추가 (sourceMappingURL 뒤)
    if (debug_id) |did| {
        try output.appendSlice(allocator, "//# debugId=");
        try output.appendSlice(allocator, did);
        try output.append(allocator, '\n');
    }

    // Lazy 경로: stack bundle_sm 을 heap 으로 얕은 복사. ArrayList items 포인터는 allocator 가
    // 소유하므로 payload 만 heap 으로 옮겨도 double-free 없음. flag 토글 후 본 함수 defer 는 skip.
    // 반드시 `toOwnedSlice` 성공 후 이관 — 실패 시 defer 가 원본 builder 를 정리.
    const output_slice = try output.toOwnedSlice(allocator);
    const module_codes_slice = if (dev_module_codes.items.len > 0) try dev_module_codes.toOwnedSlice(allocator) else null;
    const builder_to_return: ?*SourceMap.SourceMapBuilder = if (options.sourcemap.lazy and bundle_sm != null) blk: {
        const heap_sm = try allocator.create(SourceMap.SourceMapBuilder);
        heap_sm.* = bundle_sm.?;
        heap_sm.fixSelfReferences();
        bundle_sm_moved = true;
        break :blk heap_sm;
    } else null;
    return .{
        .output = output_slice,
        .sourcemap = sourcemap_json,
        .sourcemap_builder = builder_to_return,
        .module_codes = module_codes_slice,
    };
}

// --- Dev mode utilities (emitter/dev.zig) ---
const dev = @import("emitter/dev.zig");
pub const addModuleMappings = dev.addModuleMappings;
pub const makeModuleId = dev.makeModuleId;

/// 소스맵 sources 배열에 사용할 경로를 반환.
/// RN 플랫폼은 Metro 호환 절대 경로, 다른 플랫폼은 root_dir 기준 상대 경로.
pub fn sourcemapSourcePath(path: []const u8, options: *const EmitOptions) []const u8 {
    if (options.platform == .react_native) return path;
    return makeModuleId(path, options.root_dir);
}

// --- Chunks functions (emitter/chunks.zig) ---
const chunks = @import("emitter/chunks.zig");
pub const emitChunks = chunks.emitChunks;
pub const contentHash = chunks.contentHash;
pub const applyNamingPattern = chunks.applyNamingPattern;
const computeAllUsedNames = chunks.computeAllUsedNames;

/// JS 예약어이거나 유효한 식별자가 아니면 프로퍼티 키에 따옴표가 필요.
pub fn needsPropertyQuote(name: []const u8) bool {
    if (name.len == 0) return true;
    // JS 예약어 중 export 이름으로 자주 등장하는 것만 체크
    const reserved = [_][]const u8{
        "default", "class",      "function", "var",    "let",    "const",
        "if",      "else",       "for",      "while",  "do",     "switch",
        "case",    "break",      "continue", "return", "throw",  "try",
        "catch",   "finally",    "new",      "delete", "typeof", "void",
        "in",      "instanceof", "this",     "with",   "yield",  "await",
        "import",  "export",     "extends",  "super",  "enum",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    // 첫 문자가 숫자이거나 특수문자이면 따옴표 필요
    if (name[0] >= '0' and name[0] <= '9') return true;
    if (name[0] != '_' and name[0] != '$' and !(name[0] >= 'a' and name[0] <= 'z') and !(name[0] >= 'A' and name[0] <= 'Z')) return true;
    return false;
}

/// 들여쓰기를 적용하여 텍스트를 ArrayList에 추가. 줄바꿈 뒤에 탭을 삽입.
pub fn appendIndented(wrapped: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        try wrapped.append(allocator, c);
        if (c == '\n') try wrapped.append(allocator, '\t');
    }
}

/// 모듈의 wrap_kind에 따라 require_xxx() 또는 init_xxx() 호출 코드를 생성한다.
/// run-before-main, 엔트리 자동 호출, star export init 등에서 공용.
pub fn appendModuleCall(output: *std.ArrayList(u8), allocator: std.mem.Allocator, mod: anytype) !void {
    const call_name = if (mod.wrap_kind == .cjs)
        try types.makeRequireVarName(allocator, mod.path)
    else
        try mod.allocInitName(allocator);
    defer allocator.free(call_name);
    if (mod.wrap_kind != .cjs and mod.uses_top_level_await) {
        try output.appendSlice(allocator, "await ");
    }
    try output.appendSlice(allocator, call_name);
    try output.appendSlice(allocator, "();\n");
}

/// `entry_error_guard` 활성 시 init 호출을 `__zts_guarded(callName)` 패턴으로 emit.
/// helper (`__zts_guarded`) 는 prologue 에 주입되어 outermost 호출만 실제 wrap.
/// 비활성 시 기존 `appendModuleCall` 와 동등.
/// TLA (`uses_top_level_await`) 인 경우 `await` 가 lambda 안에 들어가야 하므로 wrap 안 함.
pub fn appendGuardedModuleCall(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    mod: anytype,
    options: *const EmitOptions,
) !void {
    if (!mod.shouldGuard(options.entry_error_guard)) {
        try appendModuleCall(output, allocator, mod);
        return;
    }
    const call_name = if (mod.wrap_kind == .cjs)
        try types.makeRequireVarName(allocator, mod.path)
    else
        try mod.allocInitName(allocator);
    defer allocator.free(call_name);
    // `__zts_guarded(callName)` — fn 인자로 함수 식별자만 전달. helper 가 fn() 호출.
    try output.appendSlice(allocator, "__zts_guarded(");
    try output.appendSlice(allocator, call_name);
    try output.appendSlice(allocator, ");\n");
}

/// run-before-main 모듈의 호출 코드를 output에 추가한다.
/// `entry_error_guard` 활성 시 각 rbm 호출도 `__zts_guarded(...)` 로 wrap —
/// Metro `getAppendScripts` 가 `runBeforeMainModule` 의 각 path 마다 별도
/// `__r(N);` (= guardedLoadModule outer 호출) 을 emit 하는 것과 동등.
pub fn appendRunBeforeMainCalls(output: *std.ArrayList(u8), allocator: std.mem.Allocator, graph: *const @import("graph.zig").ModuleGraph, run_before_main: []const []const u8, options: *const EmitOptions) !void {
    for (run_before_main) |rbm_path| {
        var it = graph.modulesIterator();
        while (it.next()) |rbm| {
            if (std.mem.eql(u8, rbm.path, rbm_path)) {
                try appendGuardedModuleCall(output, allocator, rbm, options);
                break;
            }
        }
    }
}

fn emitModuleThread(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: *const EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
    result: *CompiledModule,
) void {
    result.code = emitModule(allocator, module, options, linker, is_entry, used_names, shaker, &result.helpers, &result.mappings, &result.preamble_lines, &result.fn_map_json, &result.entry_chain) catch null;
}

/// 단일 모듈을 Transformer → Codegen 파이프라인으로 처리.
/// 모듈별 arena에 AST가 보존되어 있으므로 재파싱 불필요.
/// emitChunks에서도 사용하므로 pub으로 노출.
pub fn emitModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: *const EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_export_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
    helpers_out: ?*RuntimeHelpers,
    mappings_out: ?*?[]const SourceMap.Mapping,
    preamble_lines_out: ?*u32,
    fn_map_json_out: ?*?[]const u8,
    entry_chain_out: ?*?[]const u8,
) !?[]const u8 {
    // Disabled 모듈 (platform=browser에서 Node 빌트인): 빈 __commonJS wrapper 출력.
    // esbuild 호환: var require_X = __commonJS({ "(disabled)"(exports, module) {} });
    if (module.is_disabled) {
        return emitDisabledModule(allocator, module, options.minify_whitespace);
    }

    // Asset 모듈: JSON 모듈과 동일한 패턴으로 출력.
    // source에 값 표현식이 저장되어 있고, var asset_X = <source>; 형태로 출력.
    if (module.loader.isAsset() and module.source.len > 0) {
        if (module.loader == .binary) {
            if (helpers_out) |h| h.to_binary = true;
        }
        return emitAssetModule(allocator, module, options);
    }

    const ast = &(module.ast orelse return null);

    // 변환용 arena (Transformer/Codegen 내부 메모리)
    var emit_arena = std.heap.ArenaAllocator.init(allocator);
    defer emit_arena.deinit();
    const arena_alloc = emit_arena.allocator();

    // Transformer: TS 타입 스트리핑, define 치환, decorator 변환, JSX lowering 등
    // JSX lowering: 번들 모드에서 Transformer가 jsx_element → call_expression 변환.
    // classic: React.createElement() 호출, automatic: _jsx/_jsxs/_jsxDEV 호출.
    // graph.zig의 synthetic import가 automatic 모드 바인딩을 처리.
    const jsx_active = ast.has_jsx;
    const is_user_code = std.mem.indexOf(u8, module.path, "/node_modules/") == null;
    const apply_refresh = options.react_refresh and is_user_code;
    const builtin = @import("../transformer/plugins/builtin.zig");
    // worklet 변환은 react-native/@react-native 코어만 제외, 나머지 node_modules는 포함
    // (reanimated/worklets 내부에도 "worklet" 디렉티브가 있으므로)
    const exclude_worklet = options.worklet_transform and
        (std.mem.indexOf(u8, module.path, "/node_modules/react-native/") != null or
            std.mem.indexOf(u8, module.path, "/node_modules/@react-native/") != null);
    const merged_plugins = builtin.collect(.{
        .worklet = options.worklet_transform and !exclude_worklet,
    }, options.plugins, arena_alloc) catch return error.OutOfMemory;

    var transformer = try Transformer.init(arena_alloc, ast, .{
        .react_refresh = apply_refresh,
        .plugins = merged_plugins,
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .emit_decorator_metadata = options.emit_decorator_metadata,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .verbatim_module_syntax = options.verbatim_module_syntax,
        .unsupported = options.unsupported,
        .drop_labels = options.drop_labels,
        .jsx_transform = jsx_active,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = module.path,
        .worklet_plugin_version = options.worklet_plugin_version,
        .minify_syntax = options.minify_syntax,
        .minify_whitespace = options.minify_whitespace,
        .keep_names = options.keep_names,
        // emit 단계 transformer 는 helper import emit 안 함 — graph pre-pass 가 이미 처리.
        .emit_runtime_helper_imports = false,
    });
    // #1961: graph parse 단계의 transformer pre-pass 결과가 있으면 hydrate.
    // transformer.transform() 은 ast.transformed_root 가 set 이면 즉시 cached root 반환 →
    // emit 단계에서 동일 transform 재실행 없이 graph 단계의 결과를 그대로 사용.
    if (module.transform_cache) |cache| {
        transformer.runtime_helpers = cache.runtime_helpers;
        if (cache.symbol_ids.len > 0) {
            transformer.symbol_ids.appendSlice(arena_alloc, cache.symbol_ids) catch return error.OutOfMemory;
        }
        if (module.semantic) |sem| {
            transformer.symbols = sem.symbols.items;
            transformer.references = sem.references;
        }
    } else if (module.semantic) |sem| {
        // legacy 경로: graph pre-pass 미실행 (asset/disabled/JSON 등). semantic 만 hydrate.
        transformer.initSymbolIds(sem.symbol_ids) catch return error.OutOfMemory;
        transformer.symbols = sem.symbols.items;
        transformer.references = sem.references;
    }
    // jsxDEV source info 계산용 line offsets
    transformer.line_offsets = module.line_offsets;
    const root = try transformer.transform();

    // AST constant folding + dead branch DCE — --minify 여부와 무관하게 항상 실행(#1552).
    // minify.zig는 실제로는 const fold / if DCE / logical short-circuit 전용 — 식별자
    // mangling/주석 제거 같은 compression 은 없다. `--define`으로 치환된 상수 비교
    // (`"production" === "production"`)나 `if (false)` dead branch를 bundle 기본 모드에서도
    // 접어야 rolldown/esbuild와 동등한 DCE 효과를 낸다.
    //
    // Dead store (#1644 PR1): semantic 정보가 있을 때만 unused declaration 제거 활성.
    // tree-shaker 가 top-level export 미사용은 이미 커버하지만, 함수 내부 local 은 여기서 처리.
    //
    // **dev_mode 예외**: HMR rebuild 체감 우선 — minify pass 전체 skip. fold/dead-store/
    // inline 은 출력 품질 개선이지 correctness 가 아니라 런타임 의미 동일. Metro 가
    // dev 에서 아무 minify 안 하는 것과 동일한 trade-off.
    if (!options.dev_mode) {
        const minify_mod = @import("../transformer/minify.zig");
        const ctx: minify_mod.MinifyCtx = if (module.semantic) |sem| .{
            .symbols = sem.symbols.items,
            .symbol_ids = transformer.symbol_ids.items,
            .scopes = sem.scopes,
            .unresolved_globals = &sem.unresolved_references,
            .references = sem.references,
        } else .empty;
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
    }

    // 런타임 헬퍼 사용 추적: transformer가 설정한 플래그를 out parameter로 전달
    // packed struct(u32)이므로 bitwise OR로 한번에 합친다
    if (helpers_out) |h| {
        h.* = @bitCast(@as(u32, @bitCast(h.*)) | @as(u32, @bitCast(transformer.runtime_helpers)));
    }

    // Linker 메타데이터 생성 (있으면) — ast 기준으로 구축
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*m| m.deinit();

    if (linker) |l| {
        // transformer가 생성한 symbol_ids (있으면 우선 사용)
        const override_syms: ?[]const ?u32 = if (transformer.symbol_ids.items.len > 0)
            transformer.symbol_ids.items
        else
            null;
        // ast 기준으로 skip_nodes 구축 (transformer 이후이므로 노드 인덱스가 ast와 일치)
        var md = try l.buildMetadataForAst(
            transformer.ast,
            module.index.toU32(),
            is_entry,
            override_syms,
        );
        // transformer가 전파한 symbol_ids를 메타데이터에 설정
        if (override_syms) |syms| {
            md.symbol_ids = syms;
        }
        // #1791 IIFE unresolved build-time diag 를 linker 의 공용 `fatal_diagnostics`
        // 로 소유권 이전. mutex 는 공용 리스트의 append 만 보호 — `md.pending_diagnostics`
        // 자체는 per-module 이라 경쟁 없음. `@constCast` 는 `ns_cache_mutex` (linker.zig:1877)
        // 와 동일 관행. free 후 필드를 비워 md.deinit 의 double-free 방지.
        if (md.pending_diagnostics.len > 0) {
            const linker_mut = @constCast(l);
            linker_mut.diagnostics_mutex.lock();
            defer linker_mut.diagnostics_mutex.unlock();
            for (md.pending_diagnostics) |d| {
                try linker_mut.fatal_diagnostics.append(l.allocator, d);
            }
            l.allocator.free(md.pending_diagnostics);
            md.pending_diagnostics = &.{};
        }
        // statement-level tree-shaking: StmtInfo 기반 도달성 분석으로 미사용 statement 제거.
        // rolldown 방식: 심볼 인덱스로 추적하여 linker rename 후에도 정확한 판정.
        //
        // **dev_mode 예외**: HMR rebuild 체감 우선. 미사용 statement 를 skip_nodes 로
        // 마킹하는 것은 출력 크기 최적화지 correctness 가 아니다 — 포함해도 런타임 의미 동일.
        // dev 번들은 크기 허용, speed 우선 (Metro/esbuild 관습).
        if (!options.dev_mode) {
            if (used_export_names) |names| {
                if (!is_entry and !module.wrap_kind.isWrapped()) {
                    stmt_shake: {
                        const sem = module.semantic orelse {
                            statement_shaker.markUnusedStatements(
                                arena_alloc,
                                transformer.ast,
                                root,
                                names,
                                &md.skip_nodes,
                                null,
                            ) catch {};
                            break :stmt_shake;
                        };
                        const sym_ids: []const ?u32 = if (transformer.symbol_ids.items.len > 0)
                            transformer.symbol_ids.items
                        else
                            sem.symbol_ids;

                        // 크로스-모듈 BFS 결과: tree-shaker의 reachable_stmts로 skip_nodes 설정
                        const mod_idx: u32 = module.index.toU32();
                        if (shaker) |s| {
                            if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                                // 변환 후 AST의 program statement list에서 span 매칭
                                const new_root = transformer.ast.nodes.items[transformer.ast.nodes.items.len - 1];
                                if (new_root.tag == .program and new_root.data.list.len > 0) {
                                    const new_list = new_root.data.list;
                                    if (new_list.start + new_list.len <= transformer.ast.extra_data.items.len) {
                                        const new_stmt_indices = transformer.ast.extra_data.items[new_list.start .. new_list.start + new_list.len];
                                        for (ts_infos.stmts, 0..) |ts_stmt, si| {
                                            if (s.isStmtReachable(mod_idx, @intCast(si))) continue;
                                            // 변환 후 top-level statement만 스캔 (O(stmts) not O(nodes))
                                            for (new_stmt_indices) |raw_ni| {
                                                const ni = @as(usize, raw_ni);
                                                if (ni >= transformer.ast.nodes.items.len) continue;
                                                const new_node = transformer.ast.nodes.items[ni];
                                                if (new_node.span.start == ts_stmt.span.start and
                                                    new_node.span.end == ts_stmt.span.end and
                                                    ni < md.skip_nodes.capacity())
                                                {
                                                    md.skip_nodes.set(ni);
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // tree-shaker 없으면 기존 방식 (모듈 내부 computeReachable)
                            if (stmt_info_mod.build(arena_alloc, transformer.ast, sem.symbols.items, sym_ids, &sem.unresolved_references)) |maybe_infos| {
                                if (maybe_infos) |infos| {
                                    var used_sym_buf: std.ArrayListUnmanaged(u32) = .empty;
                                    defer used_sym_buf.deinit(arena_alloc);
                                    if (sem.scope_maps.len > 0) {
                                        for (names) |name| {
                                            if (sem.scope_maps[0].get(name)) |sym_idx| {
                                                used_sym_buf.append(arena_alloc, @intCast(sym_idx)) catch continue;
                                            } else {
                                                for (module.export_bindings) |eb| {
                                                    if (std.mem.eql(u8, eb.exported_name, name)) {
                                                        if (eb.symbol.semanticIndex()) |sym_idx| {
                                                            used_sym_buf.append(arena_alloc, sym_idx) catch {};
                                                        }
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if (infos.computeReachable(arena_alloc, used_sym_buf.items)) |reachable| {
                                        for (infos.stmts, 0..) |stmt, si| {
                                            if (!reachable.isSet(si) and stmt.node_idx < md.skip_nodes.capacity()) {
                                                md.skip_nodes.set(stmt.node_idx);
                                            }
                                        }
                                    } else |_| {}
                                }
                            } else |_| {}
                        }
                    }
                }
            }
        }

        metadata = md;
    }

    // Cross-module @__NO_SIDE_EFFECTS__ 전파:
    // import한 함수가 원본 모듈에서 no_side_effects로 선언되었으면
    // 현재 모듈의 해당 호출에 is_pure 플래그를 자동 설정한다.
    //
    // **dev_mode 예외**: is_pure 플래그는 minify 의 DCE 만이 읽는다. dev_mode 에선
    // minify pass 전체가 skip 되므로 전파 결과가 소비되지 않는다. HMR rebuild 체감
    // 우선 — scope map 스캔 + 2단계 AST 순회 비용 제거.
    if (linker) |l| {
        if (!options.dev_mode) {
            const sym_ids = if (metadata) |md| md.symbol_ids else &.{};
            propagateCrossModulePurity(l, module, transformer.ast, sym_ids, arena_alloc);
        }
    }

    // Identifier mangling은 단일 파일 트랜스파일(main.zig)에서만 적용.
    // 번들 모드에서는 linker의 scope hoisting과 이름 충돌 해결이 먼저 필요하므로
    // 별도 통합이 필요 (후속 PR).

    // Top-level const/let → var 다운그레이드 (#1630) — scope-hoist + minify_syntax 조합에서만.
    // module 이 IIFE / __commonJS / __esm 로 감싸져 top-level 이 function scope 가 되므로
    // block-scope 의미 변경 위험 없음. dev 빌드에선 원본 kind 유지 (DX) — esbuild/rolldown
    // 동일 관습. mergeDecls 직전에 호출해 var 끼리 연쇄 merge 극대화.
    if (linker != null and options.minify_syntax) {
        @import("../transformer/minify.zig").downgradeToVar(transformer.ast);
    }

    // Private field name mangle (#1632 Phase 1) — `#commit_callbacks` 같은 긴 이름을
    // class 별 독립 범위로 `#a`, `#b`, ... 단축. JS 언어 규약상 private name 은 선언된
    // class body 바깥에서 참조 불가 → per-class 안전. minify_identifiers 플래그와 묶음.
    if (options.minify_identifiers) {
        @import("../codegen/private_mangler.zig").manglePrivateFields(transformer.ast);
    }

    // 인접 선언 merge (#1588) — tree-shake 직후에 실행해 skip_nodes 결정과 충돌 방지.
    // `var A=1; var B=2;`에서 `B`만 미사용으로 마킹된 경우, 먼저 merge했다면 합쳐진
    // statement는 A가 사용되므로 제거 불가 → B의 초기화식이 살아남아 죽은 심볼을 참조.
    // 순서: transform → minify(fold) → tree-shake → downgradeToVar → mergeDecls → codegen.
    // dev_mode 에선 skip — 병합은 출력 크기 최적화용이라 런타임 의미 불변. HMR 체감 우선.
    if (!options.dev_mode) {
        @import("../transformer/minify.zig").mergeDecls(
            transformer.ast,
            if (metadata) |*m| @as(?*const std.DynamicBitSet, &m.skip_nodes) else null,
        );
    }

    // __esm 모듈: AST 수준 var/function 호이스팅 (esbuild/rolldown 방식)
    if (module.wrap_kind == .esm) {
        const esm_result = try emitEsmWrappedModule(
            allocator,
            arena_alloc,
            transformer.ast,
            root,
            module,
            if (metadata) |*m| @as(?*const LinkingMetadata, m) else null,
            linker,
            options,
        );
        // ESM 모듈의 소스맵 매핑을 결과에 반영
        if (mappings_out) |mout| {
            mout.* = esm_result.mappings;
        }
        // entry_error_guard + entry: chain 을 entry_chain_out 으로 전달.
        // 비-entry 또는 비-guard 면 entry_chain == null.
        if (entry_chain_out) |out| {
            out.* = esm_result.entry_chain;
        } else if (esm_result.entry_chain) |c| {
            // out 을 받지 않으면 owned chain 을 누수 — 안전하게 free.
            allocator.free(c);
        }
        return esm_result.code;
    }

    // Codegen: AST → JS 문자열
    var cg = Codegen.initWithOptions(arena_alloc, transformer.ast, .{
        .minify_whitespace = options.minify_whitespace,
        // Peephole boolean 축약 등 codegen-레벨 출력 최적화(#1552).
        .minify_syntax = options.minify_syntax,
        // scope-hoisted 모듈은 항상 ESM codegen 사용 (bare declarations).
        // __commonJS 래핑 모듈만 CJS codegen (module.exports = ...).
        // 래핑 모듈(CJS/ESM)은 CJS codegen: import→require 변환
        .module_format = if (module.wrap_kind.isWrapped()) .cjs else .esm,
        // __esm 모듈: exports.x/module.exports 생성 억제 (__export()가 대신 처리)
        .skip_cjs_exports = module.wrap_kind == .esm,
        // __esm 모듈: const → var (TDZ 방지)
        .use_var_for_imports = module.wrap_kind == .esm,
        .linking_metadata = if (metadata) |*m| m else null,
        // 번들 모드에서 ESM이 아니면 import.meta → {} 치환 (esbuild 호환)
        // Node.js는 import.meta를 보면 ESM으로 재파싱하려 해서 에러 발생
        .replace_import_meta = options.format != .esm,
        .platform = options.platform,
        // --charset=utf8 → ascii_only=false (명시적 보장)
        .ascii_only = false,
        // 소스맵 옵션 전달
        .sourcemap = options.sourcemap.enable,
        .source_root = options.sourcemap.source_root orelse "",
        .sources_content = options.sourcemap.sources_content,
        // keepNames: codegen이 rename된 함수/클래스를 수집
        .keep_names = options.keep_names,
        // Metro function map: sourcemap 활성화 시에만 수집
        .sourcemap_function_map = options.sourcemap.enable and options.sourcemap.function_map,
        // JSX: Transformer가 이미 call_expression으로 lowering 완료.
        // codegen은 jsx_element/jsx_fragment를 만나지 않으므로 JSX 옵션 불필요.
        // dev mode: import.meta.hot → __zts_make_hot("dev_id")
        .dev_module_id = if (options.dev_mode and module.dev_id.len > 0) module.dev_id else null,
        .import_records = module.import_records,
    });
    // 소스맵용: line_offsets와 소스 파일 등록
    if (options.sourcemap.enable) {
        cg.line_offsets = module.line_offsets;
        try cg.addSourceFile(sourcemapSourcePath(module.path, options));
    }
    var code = try cg.generate(root);

    // React Fast Refresh: 컴포넌트가 있는 모듈에 hot.accept() 자동 삽입.
    // accept() 없으면 __zts_apply_update가 full reload로 fallback.
    if (options.dev_mode and options.react_refresh and module.dev_id.len > 0) {
        if (std.mem.indexOf(u8, code, "$RefreshReg$") != null) {
            code = try std.mem.concat(arena_alloc, u8, &.{
                code,
                "\n__zts_make_hot(\"",
                module.dev_id,
                "\").accept();\n",
            });
        }
    }

    // 소스맵 매핑 복사 (arena 해제 전에)
    if (mappings_out) |mout| {
        if (cg.sm_builder) |*sm| {
            if (sm.mappings.items.len > 0) {
                mout.* = try allocator.dupe(SourceMap.Mapping, sm.mappings.items);
            }
        }
    }

    // function map JSON 직렬화 (활성화 시, arena 해제 전에)
    if (fn_map_json_out) |fmout| {
        if (cg.fn_map_builder) |*fm| {
            if (fm.namesSlice().len > 0) {
                var json_buf: std.ArrayList(u8) = .empty;
                try fm.appendJson(&json_buf);
                fmout.* = try allocator.dupe(u8, json_buf.items);
                json_buf.deinit(arena_alloc);
            }
        }
    }

    // Plugin: transform 훅은 graph.zig에서 파싱 전에 호출 (Rolldown 호환).
    // emitModule에서는 중복 호출하지 않는다.

    // keepNames: codegen이 generate() 내에서 직접 __name() 호출을 buf에 append.
    // entries가 있으면 런타임 헬퍼 플래그만 설정.
    if (cg.keep_names_entries.items.len > 0) {
        if (helpers_out) |h| h.keep_names = true;
    }

    // CJS 래핑: __commonJS 팩토리 함수로 감싸기
    if (module.wrap_kind == .cjs) {
        const basename = module.wrapperId();
        const preamble_code = if (metadata) |md| md.cjs_import_preamble else null;

        const var_name = try types.makeRequireVarName(allocator, module.path);
        defer allocator.free(var_name);

        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);

        if (options.minify_whitespace) {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, "=" ++ rt.NAMES.CJS_FACTORY_MIN ++ "({\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports,module){");
            if (preamble_code) |p| try wrapped.appendSlice(allocator, p);
            try wrapped.appendSlice(allocator, code);
            try wrapped.appendSlice(allocator, "}});");
            if (preamble_lines_out) |out| out.* = 0;
        } else {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, " = __commonJS({\n\t\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports, module) {\n");
            // preamble_lines: 래퍼 헤더 2줄 + preamble 내 줄바꿈 수
            if (preamble_lines_out) |out| {
                var pl: u32 = 2; // "var ... = __commonJS({\n" + '"..."(exports, module) {\n'
                if (preamble_code) |p| pl += @intCast(std.mem.count(u8, p, "\n"));
                out.* = pl;
            }
            if (preamble_code) |p| try appendIndented(&wrapped, allocator, p);
            try appendIndented(&wrapped, allocator, code);
            try wrapped.appendSlice(allocator, "\n\t}\n});\n");
        }

        return try allocator.dupe(u8, wrapped.items);
    }

    // __esm 래핑은 emitEsmWrappedModule()에서 처리 (early return)

    // CJS import preamble + final_exports를 하나의 concat으로 합침 (중간 할당 누수 방지)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const raw_final_exports = if (metadata) |md| md.final_exports else null;

    // 래핑 포맷 (IIFE/UMD/AMD): "export { x }" → "return { x }" 변환 (factory 반환값).
    // 래핑 + globalName 없음: export 구문은 syntax error → 제거.
    // CJS: export 구문은 불필요 (CJS 래핑이 exports 처리).
    // linker는 format-agnostic하게 "export {}" 를 생성하므로, emitter에서 포맷별 치환/제거.
    var wrapped_return_buf: ?[]const u8 = null;
    defer if (wrapped_return_buf) |buf| allocator.free(buf);

    const final_exports = if (raw_final_exports) |fe| blk: {
        if (options.format.isWrappedFormat()) {
            if (options.format != .iife or options.global_name != null) {
                if (std.mem.startsWith(u8, fe, "export {")) {
                    wrapped_return_buf = try std.mem.concat(allocator, u8, &.{ "return {", fe["export {".len..] });
                    break :blk wrapped_return_buf.?;
                }
            }
            // 래핑 포맷 (globalName 없음, IIFE): export는 syntax error이므로 제거
            break :blk @as(?[]const u8, null);
        }
        if (options.format == .cjs) {
            break :blk @as(?[]const u8, null);
        }
        break :blk fe;
    } else null;

    if (preamble != null or final_exports != null) {
        // RSC: 디렉티브가 preamble보다 위에 와야 인식 (preserve-modules에서 자체 파일이 되는 경우).
        var dir_buf: std.ArrayList(u8) = .empty;
        defer dir_buf.deinit(allocator);
        const code_no_dir = chunks.extractLeadingDirectives(code, &dir_buf, allocator) catch code;

        // preamble_lines: 디렉티브 + preamble 내 줄바꿈 수 (코드 매핑 오프셋용)
        if (preamble_lines_out) |out| {
            var pl: u32 = @intCast(std.mem.count(u8, dir_buf.items, "\n"));
            if (preamble) |p| pl += @intCast(std.mem.count(u8, p, "\n"));
            out.* = pl;
        }
        return try std.mem.concat(allocator, u8, &.{
            dir_buf.items,
            preamble orelse "",
            code_no_dir,
            final_exports orelse "",
        });
    }

    // arena 해제 전에 복사 (caller 소유)
    return try allocator.dupe(u8, code);
}

// --- CJS wrap functions (emitter/cjs_wrap.zig) ---
const cjs_wrap = @import("emitter/cjs_wrap.zig");
const emitDisabledModule = cjs_wrap.emitDisabledModule;
const emitAssetModule = cjs_wrap.emitAssetModule;
pub const emitCjsWrapper = cjs_wrap.emitCjsWrapper;

/// Cross-module @__NO_SIDE_EFFECTS__ 전파.
///
/// 단일 모듈 내에서는 semantic analyzer가 callee symbol의 no_side_effects 플래그를 보고
/// call_expression에 is_pure를 자동 설정한다 (analyzer.zig:863-876).
/// 하지만 cross-module import의 경우, importing 모듈의 semantic analyzer는 원본 모듈의
/// symbol을 모르므로 is_pure가 설정되지 않는다.
///
/// 이 함수는 linker가 해석한 import→export 바인딩을 활용하여:
/// 1. import한 symbol이 원본 모듈에서 no_side_effects로 선언되었는지 확인
/// 2. 해당 symbol을 callee로 사용하는 call_expression에 is_pure 플래그 설정
fn propagateCrossModulePurity(
    linker: *const Linker,
    module: *const Module,
    ast: *Ast,
    symbol_ids: []const ?u32,
    allocator: std.mem.Allocator,
) void {
    const sem = module.semantic orelse return;
    if (sem.scope_maps.len == 0) return;
    if (module.import_bindings.len == 0) return;
    const module_scope = sem.scope_maps[0];
    const module_index: u32 = module.index.toU32();

    // 1단계: no_side_effects인 import binding의 local symbol_id를 수집한다.
    // 비트셋 대신 bool 배열 사용 — 스택 256개, 초과 시 arena fallback.
    var has_any_pure = false;
    const sym_count = sem.symbols.items.len;
    if (sym_count == 0) return;

    var pure_flags_buf: [256]bool = .{false} ** 256;
    const pure_flags: []bool = if (sym_count <= 256)
        pure_flags_buf[0..sym_count]
    else
        allocator.alloc(bool, sym_count) catch return;
    defer if (sym_count > 256) allocator.free(pure_flags);
    if (sym_count > 256) @memset(pure_flags, false);

    for (module.import_bindings) |ib| {
        if (ib.kind == .namespace) continue;

        const resolved = linker.getResolvedBinding(module_index, ib.local_span) orelse continue;

        const canon_mod_idx = @intFromEnum(resolved.canonical.module_index);
        const target_module = linker.graph.getModule(resolved.canonical.module_index) orelse continue;
        const target_sem = target_module.semantic orelse continue;

        if (target_sem.scope_maps.len == 0) continue;
        const target_scope = target_sem.scope_maps[0];

        // default export는 local_name이 다를 수 있음 ("default" → 실제 함수명)
        const target_sym_name = if (std.mem.eql(u8, resolved.canonical.export_name, "default"))
            linker.getExportLocalName(canon_mod_idx, "default") orelse resolved.canonical.export_name
        else
            resolved.canonical.export_name;

        const target_sym_idx = target_scope.get(target_sym_name) orelse continue;
        if (target_sym_idx >= target_sem.symbols.items.len) continue;
        if (!target_sem.symbols.items[target_sym_idx].decl_flags.no_side_effects) continue;

        const local_sym_idx = module_scope.get(ib.local_name) orelse continue;
        if (local_sym_idx >= sym_count) continue;

        pure_flags[local_sym_idx] = true;
        has_any_pure = true;
    }

    if (!has_any_pure) return;

    // 2단계: ast의 call/new expression 중 callee가 pure import이면 is_pure 설정
    const CallFlags = @import("../parser/ast.zig").CallFlags;

    for (ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;

        const e = node.data.extra;
        if (!ast.hasExtra(e, 3)) continue;

        const callee_idx = ast.readExtraNode(e, 0);
        if (callee_idx.isNone()) continue;
        const callee_ni = @intFromEnum(callee_idx);

        if (callee_ni >= ast.nodes.items.len) continue;
        if (ast.nodes.items[callee_ni].tag != .identifier_reference) continue;

        if (callee_ni >= symbol_ids.len) continue;
        const sym_idx = symbol_ids[callee_ni] orelse continue;
        if (sym_idx >= sym_count) continue;

        if (pure_flags[sym_idx]) {
            ast.extra_data.items[e + 3] |= CallFlags.is_pure;
        }
    }
}

/// 런타임 헬퍼 문자열을 ArrayList에 주입한다 (re-export for backward compat).
pub const appendRuntimeHelpers = rt.appendRuntimeHelpers;

/// 번들 레벨 런타임 헬퍼 주입 (CJS interop + decorator + async).
/// emitWithTreeShaking에서 사용.
fn emitBundleRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    sorted_modules: []const *const Module,
    options: *const EmitOptions,
) !void {
    // 런타임 헬퍼 주입: 래핑 모듈 유형에 따라 필요한 헬퍼 결정.
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    for (sorted_modules) |m| {
        if (m.wrap_kind == .cjs) needs_cjs_runtime = true;
        if (m.wrap_kind == .esm) needs_esm_wrap_runtime = true;
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
        // Node ESM 출력에 CJS wrapper가 섞이면 wrapper 내부 `require()`가 런타임에 미정의.
        // createRequire shim은 runtime helper 정의보다 먼저 와야 `__commonJS` 래퍼가 참조 가능 (#1456).
        if (needs_cjs_runtime and options.platform == .node and options.format == .esm) {
            try rt.appendRequireShim(output, allocator, options.minify_whitespace);
        }
        // __toESM, __copyProps, __defProp은 CJS/ESM 양쪽에서 공유
        try rt.appendCjsRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    // __async는 이후 appendRuntimeHelpers(collected_helpers)에서 실제 사용 여부 기반으로
    // 주입됨 — 여기서 target 기반으로 또 주입하면 중복 emit 된다.
    // dev mode: HMR 런타임 주입 (__zts_modules, __zts_require, __zts_apply_update 등).
    // HMR 런타임이 $RefreshReg$/$RefreshSig$도 정의하므로 별도 스텁 불필요.
    if (options.dev_mode) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.HMR_RUNTIME_MIN else rt.HMR_RUNTIME);
    } else if (options.react_refresh) {
        // 비-dev 모드에서 react_refresh만 활성화된 경우 스텁 주입
        try output.appendSlice(allocator, rt.REFRESH_STUB);
    }
    // entry_error_guard: Metro `guardedLoadModule` 동등 mechanism 의 helper 주입.
    // 실제 wrap 은 emit 단계에서 module init 호출 site 별로 `__zts_guarded(fn)` 으로 emit.
    if (options.entry_error_guard) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.GUARDED_RUNTIME_MIN else rt.GUARDED_RUNTIME);
    }
    // silent_console_error_patterns: 패턴 비어있으면 emit X — vanilla RN 등 trigger 없는
    // 환경에서 dead code 0. consumer 가 환경 (e.g. expo) 감지 후 패턴 주입.
    try rt.emitConsoleErrorInterceptInto(output, allocator, options.silent_console_error_patterns, options.minify_whitespace);
}

/// 청크별 런타임 헬퍼 주입.
/// emitChunks에서 사용.
pub fn emitChunkRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    graph: *const ModuleGraph,
    options: *const EmitOptions,
    collected_helpers: ?RuntimeHelpers,
) !void {
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    var needs_to_binary = false;
    for (chunk.modules.items) |mod_idx| {
        const m = graph.getModule(mod_idx) orelse continue;
        if (m.wrap_kind == .cjs) needs_cjs_runtime = true;
        if (m.wrap_kind == .esm) needs_esm_wrap_runtime = true;
        if (m.loader == .binary) needs_to_binary = true;
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
        // 단일 번들 경로와 동일: Node ESM + CJS wrap이면 createRequire shim 필요 (#1456)
        if (needs_cjs_runtime and options.platform == .node and options.format == .esm) {
            try rt.appendRequireShim(output, allocator, options.minify_whitespace);
        }
        try rt.appendCjsRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    if (collected_helpers) |h| {
        if (h.es_decorator) {
            try output.appendSlice(allocator, if (options.minify_whitespace) rt.ES_DECORATOR_RUNTIME_MIN else rt.ES_DECORATOR_RUNTIME);
        }
    }
    // splitting 모드에서는 collected_helpers가 null로 전달되므로 per-chunk 사용 여부를
    // 알 수 없다 → target 기반으로 주입 (단일-번들 모드와 달리 이 경로에선 appendRuntimeHelpers
    // 가 다시 호출되지 않으므로 중복 아님).
    if (options.unsupported.async_await) {
        try rt.appendAsyncRuntime(output, allocator, options.minify_whitespace, options.unsupported.arrow);
    }
    if (needs_to_binary) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.TO_BINARY_RUNTIME_MIN else rt.TO_BINARY_RUNTIME);
    }
    if (options.keep_names) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.KEEP_NAMES_RUNTIME_MIN else rt.KEEP_NAMES_RUNTIME);
    }
}

/// default → 실제 모드로 해석. default는 minify 시 eof, 아니면 inline.
fn resolveDefaultLegalComments(mode: types.LegalComments, minify: bool) types.LegalComments {
    if (mode != .default) return mode;
    return if (minify) .eof else .@"inline";
}

/// eof/linked/external 모드에서 legal comments를 수집하여 출력 끝에 추가.
/// 중복 제거: 같은 텍스트의 주석은 한 번만 출력.
fn collectLegalComments(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    sorted_modules: []const *const Module,
    mode: types.LegalComments,
) !void {
    _ = mode; // linked/external 분기는 향후 확장
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var has_any = false;

    for (sorted_modules) |m| {
        for (m.legal_comments) |comment_text| {
            const gop = try seen.getOrPut(allocator, comment_text);
            if (gop.found_existing) continue;
            if (!has_any) {
                try output.appendSlice(allocator, "\n");
                has_any = true;
            }
            try output.appendSlice(allocator, comment_text);
            try output.append(allocator, '\n');
        }
    }
}

/// 노드 인덱스에 대해 rename이 적용된 최종 이름을 반환한다.
/// metadata의 symbol_ids → renames 조회. rename이 없으면 fallback 반환.
pub fn resolveNodeName(md: ?*const LinkingMetadata, node_idx: u32, fallback: []const u8) []const u8 {
    if (md) |m| {
        if (node_idx < m.symbol_ids.len) {
            if (m.symbol_ids[node_idx]) |sid| {
                if (m.renames.get(sid)) |renamed| return renamed;
            }
        }
    }
    return fallback;
}

/// import_declaration 노드에서 binding 이름을 수집한다 (호이스팅용).
pub fn collectImportBindingNames(
    esm_ast: *const Ast,
    stmt_node: anytype,
    md: ?*const LinkingMetadata,
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
) !void {
    const ie = stmt_node.data.extra;
    if (ie + 2 >= esm_ast.extra_data.items.len) return;
    const iextras = esm_ast.extra_data.items[ie .. ie + 3];
    const ispecs_start = iextras[0];
    const ispecs_len = iextras[1];
    if (ispecs_len == 0) return;
    const ispecs = esm_ast.extra_data.items[ispecs_start .. ispecs_start + ispecs_len];
    for (ispecs) |spec_raw| {
        const spec_node = esm_ast.nodes.items[spec_raw];
        switch (spec_node.tag) {
            .import_default_specifier, .import_namespace_specifier => {
                const name = esm_ast.getText(spec_node.data.string_ref);
                try out.append(allocator, resolveNodeName(md, spec_raw, name));
            },
            .import_specifier => {
                const local_idx = spec_node.data.binary.right;
                if (!local_idx.isNone()) {
                    const local_node = esm_ast.nodes.items[@intFromEnum(local_idx)];
                    const name = esm_ast.getText(local_node.data.string_ref);
                    const resolved = resolveNodeName(md, @intFromEnum(local_idx), name);
                    // namespace 접근 패턴 rename (__ns_N.prop)은 var 선언에 넣을 수 없음.
                    // namespace 변수는 dev_ns_vars로 별도 호이스팅됨.
                    if (std.mem.indexOfScalar(u8, resolved, '.') != null) continue;
                    try out.append(allocator, resolved);
                }
            },
            else => {},
        }
    }
}

/// __esm 래핑 모듈의 코드를 생성한다 (rolldown 방식: function 호이스팅 + live binding).
///
/// 출력 구조:
///   var exports_xxx = {};
///   var hoisted_var1;                      ← var/class 이름 호이스팅
///   function hoisted_fn() { ... }          ← function 선언 호이스팅 (canonical 변수 직접 참조)
///   __export(exports_xxx, { ... });        ← lazy getter (래퍼 밖)
// --- ESM wrap functions (emitter/esm_wrap.zig) ---
const esm_wrap = @import("emitter/esm_wrap.zig");
const emitEsmWrappedModule = esm_wrap.emitEsmWrappedModule;

/// source 등록 + (선택) sourcesContent 등록을 한 번에. source_index 반환.
fn addIdentitySource(sm: *SourceMap.SourceMapBuilder, path: []const u8, content: []const u8, include_content: bool) !u32 {
    const idx = try sm.addSource(path);
    if (include_content) try sm.addSourceContent(content);
    return idx;
}

/// generated_line[gen_start..gen_start+count)를 (col=0, source_idx, original_line=orig_start+i, col=0)로 매핑.
fn addIdentityMappings(sm: *SourceMap.SourceMapBuilder, source_idx: u32, gen_start: u32, count: u32, orig_start: u32) !void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try sm.addMapping(.{
            .generated_line = gen_start + i,
            .generated_column = 0,
            .source_index = source_idx,
            .original_line = orig_start + i,
            .original_column = 0,
        });
    }
}

// --- 포맷별 래핑 (prologue/epilogue) ---

/// 포맷별 prologue를 output에 추가한다.
fn emitFormatPrologue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    format: types.Format,
    global_name: ?[]const u8,
    factory_fn: []const u8,
    external_specifiers: []const []const u8,
    ext_param_names: []const []const u8,
) !void {
    switch (format) {
        .iife => {
            if (global_name) |gn| {
                if (std.mem.indexOfScalar(u8, gn, '.') != null) {
                    try output.appendSlice(allocator, "/* [ZTS WARNING] Dotted globalName (\"");
                    try output.appendSlice(allocator, gn);
                    try output.appendSlice(allocator, "\") is not yet supported. Use a simple name. */\n");
                    try output.appendSlice(allocator, factory_fn);
                } else {
                    try output.appendSlice(allocator, "var ");
                    try output.appendSlice(allocator, gn);
                    try output.appendSlice(allocator, " = ");
                    try output.appendSlice(allocator, factory_fn);
                }
            } else {
                try output.appendSlice(allocator, factory_fn);
            }
        },
        .umd => {
            try output.appendSlice(allocator, "(function(root, factory) {\n");
            try output.appendSlice(allocator, "  if (typeof define === \"function\" && define.amd) define([");
            try writeDepArray(output, allocator, external_specifiers);
            try output.appendSlice(allocator, "], factory);\n");
            try output.appendSlice(allocator, "  else if (typeof module === \"object\" && module.exports) module.exports = factory(");
            try writeCjsRequireList(output, allocator, external_specifiers);
            try output.appendSlice(allocator, ");\n");
            if (global_name) |gn| {
                try output.appendSlice(allocator, "  else root.");
                try output.appendSlice(allocator, gn);
                try output.appendSlice(allocator, " = factory(");
            } else {
                try output.appendSlice(allocator, "  else factory(");
            }
            try writeGlobalsList(output, allocator, ext_param_names);
            try output.appendSlice(allocator, ");\n");
            try output.appendSlice(allocator, "})(typeof self !== \"undefined\" ? self : this, function(");
            try writeParamList(output, allocator, ext_param_names);
            try output.appendSlice(allocator, ") {\n");
        },
        .amd => {
            try output.appendSlice(allocator, "define([");
            try writeDepArray(output, allocator, external_specifiers);
            try output.appendSlice(allocator, "], function(");
            try writeParamList(output, allocator, ext_param_names);
            try output.appendSlice(allocator, ") {\n");
        },
        .cjs => try output.appendSlice(allocator, "\"use strict\";\n"),
        .esm => {},
    }
}

// UMD/AMD prologue 헬퍼: 반복되는 리스트 출력을 공유.

fn writeDepArray(output: *std.ArrayList(u8), allocator: std.mem.Allocator, specifiers: []const []const u8) !void {
    for (specifiers, 0..) |spec, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.append(allocator, '"');
        try output.appendSlice(allocator, spec);
        try output.append(allocator, '"');
    }
}

fn writeCjsRequireList(output: *std.ArrayList(u8), allocator: std.mem.Allocator, specifiers: []const []const u8) !void {
    for (specifiers, 0..) |spec, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, "require(\"");
        try output.appendSlice(allocator, spec);
        try output.appendSlice(allocator, "\")");
    }
}

fn writeGlobalsList(output: *std.ArrayList(u8), allocator: std.mem.Allocator, names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, "root.");
        try output.appendSlice(allocator, name);
    }
}

fn writeParamList(output: *std.ArrayList(u8), allocator: std.mem.Allocator, names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, name);
    }
}

/// 포맷별 epilogue를 output에 추가한다.
/// `iife_globals_args` 는 IIFE + external globals 매핑이 있을 때만 non-empty —
/// `})(React, ReactDom);` 형태로 factory 호출 인자를 부착한다 (#1824).
fn emitFormatEpilogue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    format: types.Format,
    iife_globals_args: []const []const u8,
) !void {
    switch (format) {
        .iife => {
            if (iife_globals_args.len > 0) {
                try output.appendSlice(allocator, "})(");
                for (iife_globals_args, 0..) |arg, i| {
                    if (i > 0) try output.appendSlice(allocator, ", ");
                    try output.appendSlice(allocator, arg);
                }
                try output.appendSlice(allocator, ");\n");
            } else {
                try output.appendSlice(allocator, "})();\n");
            }
        },
        .umd, .amd => try output.appendSlice(allocator, "});\n"),
        .cjs, .esm => {},
    }
}
