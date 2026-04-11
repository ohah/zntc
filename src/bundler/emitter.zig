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
const Codegen = @import("../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../codegen/sourcemap.zig");
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
    /// 소스맵 생성 활성화. dev mode에서는 번들 레벨 소스맵을 생성한다.
    sourcemap: bool = false,
    /// Sentry Debug ID. --sourcemap-debug-ids 활성화 시 true.
    /// 번들 끝에 `//# debugId=<UUID>` 주석을 추가하고, 소스맵 JSON에 `"debugId"` 필드를 삽입.
    sourcemap_debug_ids: bool = false,
    /// dev mode: 각 모듈을 __zts_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    /// null이면 절대 경로를 그대로 사용.
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
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
    /// 출력 파일 확장자 오버라이드 (.mjs, .cjs 등)
    out_extension_js: ?[]const u8 = null,
    /// 출력 파일명 (소스맵 참조용, 예: "out.js")
    output_filename: []const u8 = "bundle.js",
    /// 소스맵 sourceRoot 필드
    source_root: ?[]const u8 = null,
    /// 소스맵에 sourcesContent 포함 여부
    sources_content: bool = true,
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
    /// preserve-modules: 모듈 1개 = 출력 파일 1개
    preserve_modules: bool = false,
    /// preserve-modules-root: 출력 디렉토리 구조의 기준 경로
    preserve_modules_root: ?[]const u8 = null,

    pub const PolyfillEntry = struct {
        name: []const u8,
        content: []const u8,
    };

    pub const Format = types.Format;
};

pub const OutputFile = struct {
    path: []const u8,
    contents: []const u8,
};

/// 번들 출력 결과. output + 소스맵.
pub const EmitResult = struct {
    /// 번들 코드. allocator 소유.
    output: []const u8,
    /// 소스맵 JSON (V3). null이면 소스맵 미생성. allocator 소유.
    sourcemap: ?[]const u8 = null,
    /// dev mode per-module codes (HMR용). null이면 미수집. allocator 소유.
    module_codes: ?[]const types.ModuleDevCode = null,

    pub fn deinit(self: *const EmitResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.sourcemap) |sm| allocator.free(sm);
        if (self.module_codes) |codes| types.ModuleDevCode.freeAll(codes, allocator);
    }
};

/// 모듈 그래프를 단일 번들로 출력한다.
pub fn emit(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
) !EmitResult {
    return emitWithTreeShaking(allocator, graph, options, linker, null);
}

/// tree-shaking 적용된 번들 출력. shaker가 null이면 모든 모듈 포함 (기존 동작).
pub fn emitWithTreeShaking(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
    shaker: ?*const TreeShaker,
) !EmitResult {
    // 1. JS/JSON 모듈 필터 + exec_index 순으로 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (graph.modules.items, 0..) |*m, i| {
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
    const factory_fn = if (has_tla) "(async function() {\n" else "(function() {\n";

    // UMD/AMD: external specifier 수집 (dependency array + factory params 생성용)
    var ext_specifiers: std.ArrayList([]const u8) = .empty;
    defer ext_specifiers.deinit(allocator);
    if (options.format == .umd or options.format == .amd) {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (sorted.items) |m| {
            for (m.import_records) |rec| {
                if (rec.is_external and !seen.contains(rec.specifier)) {
                    try seen.put(rec.specifier, {});
                    try ext_specifiers.append(allocator, rec.specifier);
                }
            }
        }
    }

    // UMD/AMD: specifier → factory 매개변수명 precompute
    var ext_param_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (ext_param_names.items) |n| allocator.free(n);
        ext_param_names.deinit(allocator);
    }
    for (ext_specifiers.items) |spec| {
        try ext_param_names.append(allocator, try types.specifierToParamName(allocator, spec));
    }

    // 포맷별 prologue
    try emitFormatPrologue(&output, allocator, options.format, options.global_name, factory_fn, has_tla, ext_specifiers.items, ext_param_names.items);

    // 폴리필 주입 (--polyfill): IIFE로 감싸서 즉시 실행.
    // Metro/롤다운과 동일하게 모듈 그래프 밖에서 런타임 헬퍼보다 먼저 실행.
    for (options.polyfills) |poly| {
        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "// --- polyfill: ");
            try output.appendSlice(allocator, poly.name);
            try output.appendSlice(allocator, " ---\n");
        }
        try output.appendSlice(allocator, "(function(){");
        if (!options.minify_whitespace) try output.append(allocator, '\n');
        try output.appendSlice(allocator, poly.content);
        if (!options.minify_whitespace) try output.append(allocator, '\n');
        try output.appendSlice(allocator, "})();\n");
    }

    // 런타임 헬퍼 주입
    try emitBundleRuntimeHelpers(&output, allocator, sorted.items, options);

    // TLA 검증: 비-ESM 출력에서 TLA 사용 시 경고 주석 삽입.
    // Top-Level Await는 ESM 전용 기능이므로 CJS/IIFE 포맷에서는 동작하지 않는다.
    // DFS로 exec_index가 부여된 모듈만 확인한다 — 동적 import로만 도달하는 모듈은
    // exec_index가 maxInt(u32)이며, 비동기 로딩이므로 경고 불필요.
    if (options.format != .esm) {
        for (sorted.items) |m| {
            if (m.uses_top_level_await and m.exec_index != std.math.maxInt(u32)) {
                try output.appendSlice(allocator, "/* [ZTS WARNING] Top-level await requires ESM output format. */\n");
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
            if (m.is_entry_point) break :blk @intFromEnum(m.index);
        }
        break :blk null;
    };

    // Phase 1: used_names 사전 계산 (순차 — 모듈 간 의존)
    const used_names_list = try computeAllUsedNames(allocator, sorted.items, graph, shaker);
    defer {
        for (used_names_list) |un| {
            allocator.free(un.names);
        }
        allocator.free(used_names_list);
    }

    // Phase 2: emitModule 병렬 실행 (2개 이상이면 스레드 풀, 아니면 순차)
    var results = try allocator.alloc(ModuleEmitResult, sorted.items.len);
    defer {
        for (results) |r| {
            if (r.code) |c| allocator.free(c);
            if (r.mappings) |m| allocator.free(m);
        }
        allocator.free(results);
    }
    for (results) |*r| r.* = .{};

    var use_pool = sorted.items.len >= 2;
    var pool: std.Thread.Pool = undefined;
    if (use_pool) {
        use_pool = if (pool.init(.{ .allocator = allocator })) |_| true else |_| false;
    }
    defer if (use_pool) pool.deinit();

    if (use_pool) {
        var wg: std.Thread.WaitGroup = .{};
        for (sorted.items, 0..) |m, i| {
            const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            pool.spawnWg(&wg, emitModuleThread, .{ allocator, m, options, linker, is_entry, used_names, shaker, &results[i] });
        }
        pool.waitAndWork(&wg);
    } else {
        for (sorted.items, 0..) |m, i| {
            const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
            const used_names: ?[]const []const u8 = if (used_names_list[i].all_used) null else used_names_list[i].names;
            results[i].code = emitModule(allocator, m, options, linker, is_entry, used_names, shaker, &results[i].helpers, &results[i].mappings, &results[i].preamble_lines) catch null;
        }
    }

    // Phase 3: 순차 합류 — exec_index 순서대로 concat + helpers 합산 + 소스맵 수집
    var module_output: std.ArrayList(u8) = .empty;
    defer module_output.deinit(allocator);

    // dev mode per-module code 수집 (HMR용)
    var dev_module_codes: std.ArrayList(types.ModuleDevCode) = .empty;
    if (options.dev_mode and options.collect_module_codes) {
        try dev_module_codes.ensureTotalCapacity(allocator, sorted.items.len);
    }
    errdefer {
        for (dev_module_codes.items) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
        }
        dev_module_codes.deinit(allocator);
    }

    // 소스맵 빌더 (소스맵 활성화 시)
    var bundle_sm: ?SourceMap.SourceMapBuilder = if (options.sourcemap) blk: {
        var sm = SourceMap.SourceMapBuilder.init(allocator);
        sm.source_root = options.source_root orelse "";
        sm.sources_content = options.sources_content;
        break :blk sm;
    } else null;
    defer if (bundle_sm) |*sm| sm.deinit();

    // output에 이미 추가된 prologue/banner/polyfill/runtime helper 줄 수 추적
    // (module_output과 별도로 output에 먼저 들어감 — 아래에서 합류 시 사용)
    // 이 시점에서는 아직 runtime helper가 추가되지 않았으므로 0으로 시작하고
    // merge 시 output.items의 줄 수를 기준 오프셋으로 사용
    var module_line: u32 = 0;

    for (sorted.items, 0..) |m, i| {
        // helpers 합산 (bitwise OR)
        collected_helpers = @bitCast(@as(u32, @bitCast(collected_helpers)) | @as(u32, @bitCast(results[i].helpers)));

        const code = results[i].code orelse continue;

        // --run-before-main: 엔트리 모듈 직전에 해당 모듈의 require/init 호출 삽입.
        // __esm 래핑된 엔트리(RN)는 emitEsmWrappedModule에서 body 안에 삽입.
        const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
        if (is_entry and options.run_before_main.len > 0 and m.wrap_kind != .esm) {
            const before_len = module_output.items.len;
            try appendRunBeforeMainCalls(&module_output, allocator, graph.modules.items, options.run_before_main);
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
                    options.sources_content,
                    false,
                );
            }
        }

        try module_output.appendSlice(allocator, code);
        module_line += @intCast(std.mem.count(u8, code, "\n"));
        if (!options.minify_whitespace) {
            try module_output.append(allocator, '\n');
            module_line += 1;
        }

        // dev mode: per-module code를 HMR eval 가능한 형태로 수집.
        // IIFE로 래핑 + 런타임 헬퍼 로컬 alias로 eval() 스코프에서 접근 가능.
        if (options.dev_mode and options.collect_module_codes) {
            const mod_id = makeModuleId(m.path, options.root_dir);
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
            });
            try dev_module_codes.append(allocator, .{
                .id = try allocator.dupe(u8, mod_id),
                .code = hmr_code,
            });
        }
    }

    // ES2015 런타임 헬퍼 주입: transformer가 실제 사용한 헬퍼만 주입
    try rt.appendRuntimeHelpers(&output, allocator, collected_helpers, options.minify_whitespace, options.unsupported.arrow);

    // prologue(banner/polyfill/runtime helper) 줄 수 → 소스맵 오프셋에 반영
    // module_output 합류 전에 계산해야 함 — 합류 후에 세면 전체 줄 수가 됨
    const prologue_lines: u32 = @intCast(std.mem.count(u8, output.items, "\n"));

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

    // 래핑된 엔트리 자동 호출: __commonJS → require_xxx(), __esm → init_xxx().
    // RN 플랫폼에서는 엔트리도 __esm 래핑되므로 init_xxx() 호출이 필요.
    if (entry_idx) |ei| {
        for (sorted.items) |em| {
            if (@intFromEnum(em.index) == ei and em.wrap_kind.isWrapped()) {
                try appendModuleCall(&output, allocator, em);
                break;
            }
        }
    }

    // 포맷별 epilogue
    try emitFormatEpilogue(&output, allocator, options.format);

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
    const debug_id: ?[]const u8 = if (options.sourcemap_debug_ids) blk: {
        SourceMap.generateUuidV4(&debug_id_buf);
        break :blk &debug_id_buf;
    } else null;

    // 소스맵 JSON 생성
    var sourcemap_json: ?[]const u8 = null;
    if (bundle_sm) |*sm| {
        // prologue 줄 수를 모든 매핑에 추가
        if (prologue_lines > 0) {
            for (sm.mappings.items) |*mapping| {
                mapping.generated_line += prologue_lines;
            }
        }

        // prologue 전체(banner/polyfill/runtime helper/HMR runtime)를 가상 소스 "<runtime>"으로 매핑.
        // DevTools가 prologue 프레임을 자동으로 무시하고 유저 코드 프레임을 표시.
        // prologue_lines가 0이면 prologue가 없으므로 스킵.
        if (prologue_lines > 0) {
            const runtime_src_idx = try sm.addSource("node_modules/.zts/runtime.js");
            if (options.sources_content) {
                try sm.addSourceContent("// zts bundle runtime (polyfills, helpers)\n");
            }
            try sm.addIgnoredSource(runtime_src_idx);
            // identity mapping: prologue의 모든 줄을 <runtime>에 매핑
            for (0..prologue_lines) |line| {
                try sm.addMapping(.{
                    .generated_line = @intCast(line),
                    .generated_column = 0,
                    .source_index = runtime_src_idx,
                    .original_line = @intCast(line),
                    .original_column = 0,
                });
            }
        }

        // debugId 설정
        sm.debug_id = debug_id;
        const json = try sm.generateJSON(options.output_filename);
        sourcemap_json = try allocator.dupe(u8, json);
    }

    // 소스맵 참조 추가
    if (sourcemap_json != null) {
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

    return .{
        .output = try output.toOwnedSlice(allocator),
        .sourcemap = sourcemap_json,
        .module_codes = if (dev_module_codes.items.len > 0) try dev_module_codes.toOwnedSlice(allocator) else null,
    };
}

// --- Dev mode utilities (emitter/dev.zig) ---
const dev = @import("emitter/dev.zig");
pub const addModuleMappings = dev.addModuleMappings;
pub const makeModuleId = dev.makeModuleId;

/// 소스맵 sources 배열에 사용할 경로를 반환.
/// RN 플랫폼은 Metro 호환 절대 경로, 다른 플랫폼은 root_dir 기준 상대 경로.
pub fn sourcemapSourcePath(path: []const u8, options: EmitOptions) []const u8 {
    if (options.platform == .react_native) return path;
    return makeModuleId(path, options.root_dir);
}

// --- Chunks functions (emitter/chunks.zig) ---
const chunks = @import("emitter/chunks.zig");
pub const emitChunks = chunks.emitChunks;
pub const contentHash = chunks.contentHash;
pub const applyNamingPattern = chunks.applyNamingPattern;
const computeAllUsedNames = chunks.computeAllUsedNames;

/// 스레드 풀에서 실행되는 emitModule 래퍼.
const ModuleEmitResult = struct {
    code: ?[]const u8 = null,
    helpers: RuntimeHelpers = .{},
    mappings: ?[]const SourceMap.Mapping = null,
    /// preamble(cjs_import_preamble 등)과 래핑 헤더로 인해 codegen 매핑과 어긋나는 줄 수.
    preamble_lines: u32 = 0,
};

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
        types.makeRequireVarName(allocator, mod.path) catch return
    else
        types.makeInitVarName(allocator, mod.path) catch return;
    defer allocator.free(call_name);
    if (mod.wrap_kind != .cjs and mod.uses_top_level_await) {
        try output.appendSlice(allocator, "await ");
    }
    try output.appendSlice(allocator, call_name);
    try output.appendSlice(allocator, "();\n");
}

/// run-before-main 모듈의 호출 코드를 output에 추가한다.
pub fn appendRunBeforeMainCalls(output: *std.ArrayList(u8), allocator: std.mem.Allocator, modules: anytype, run_before_main: []const []const u8) !void {
    for (run_before_main) |rbm_path| {
        for (modules) |*rbm| {
            if (std.mem.eql(u8, rbm.path, rbm_path)) {
                try appendModuleCall(output, allocator, rbm);
                break;
            }
        }
    }
}

fn emitModuleThread(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
    result: *ModuleEmitResult,
) void {
    result.code = emitModule(allocator, module, options, linker, is_entry, used_names, shaker, &result.helpers, &result.mappings, &result.preamble_lines) catch null;
}

/// 단일 모듈을 Transformer → Codegen 파이프라인으로 처리.
/// 모듈별 arena에 AST가 보존되어 있으므로 재파싱 불필요.
/// emitChunks에서도 사용하므로 pub으로 노출.
pub fn emitModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_export_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
    helpers_out: ?*RuntimeHelpers,
    mappings_out: ?*?[]const SourceMap.Mapping,
    preamble_lines_out: ?*u32,
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
    const apply_refresh = options.react_refresh and
        std.mem.indexOf(u8, module.path, "/node_modules/") == null;
    var transformer = try Transformer.init(arena_alloc, ast, .{
        .react_refresh = apply_refresh,
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .emit_decorator_metadata = options.emit_decorator_metadata,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .unsupported = options.unsupported,
        .drop_labels = options.drop_labels,
        .jsx_transform = jsx_active,
        .jsx_runtime = options.jsx_runtime,
        .jsx_factory = options.jsx_factory,
        .jsx_fragment = options.jsx_fragment,
        .jsx_import_source = options.jsx_import_source,
        .jsx_filename = module.path,
    });
    // symbol_ids 전파: semantic analyzer가 생성한 원본 AST의 symbol_ids를
    // transformer가 ast 기준으로 재매핑
    if (module.semantic) |sem| {
        transformer.initSymbolIds(sem.symbol_ids) catch return error.OutOfMemory;
    }
    // jsxDEV source info 계산용 line offsets
    transformer.line_offsets = module.line_offsets;
    const root = try transformer.transform();

    // AST 미니파이어: --minify 시 constant folding 등 AST 레벨 최적화
    if (options.minify_syntax) {
        @import("../transformer/minify.zig").minify(&transformer.ast);
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
            &transformer.ast,
            @intFromEnum(module.index),
            is_entry,
            override_syms,
        );
        // transformer가 전파한 symbol_ids를 메타데이터에 설정
        if (override_syms) |syms| {
            md.symbol_ids = syms;
        }
        // statement-level tree-shaking: StmtInfo 기반 도달성 분석으로 미사용 statement 제거.
        // rolldown 방식: 심볼 인덱스로 추적하여 linker rename 후에도 정확한 판정.
        if (used_export_names) |names| {
            if (!is_entry and !module.wrap_kind.isWrapped()) {
                stmt_shake: {
                    const sem = module.semantic orelse {
                        statement_shaker.markUnusedStatements(
                            arena_alloc,
                            &transformer.ast,
                            root,
                            names,
                            &md.skip_nodes,
                        ) catch {};
                        break :stmt_shake;
                    };
                    const sym_ids: []const ?u32 = if (transformer.symbol_ids.items.len > 0)
                        transformer.symbol_ids.items
                    else
                        sem.symbol_ids;

                    // 크로스-모듈 BFS 결과: tree-shaker의 reachable_stmts로 skip_nodes 설정
                    const mod_idx: u32 = @intFromEnum(module.index);
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
                        if (stmt_info_mod.build(arena_alloc, &transformer.ast, sem.symbols, sym_ids)) |maybe_infos| {
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
                                                    if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                                                        used_sym_buf.append(arena_alloc, @intCast(sym_idx)) catch {};
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

        metadata = md;
    }

    // Cross-module @__NO_SIDE_EFFECTS__ 전파:
    // import한 함수가 원본 모듈에서 no_side_effects로 선언되었으면
    // 현재 모듈의 해당 호출에 is_pure 플래그를 자동 설정한다.
    if (linker) |l| {
        const sym_ids = if (metadata) |md| md.symbol_ids else &.{};
        propagateCrossModulePurity(l, module, &transformer.ast, sym_ids, arena_alloc);
    }

    // Identifier mangling은 단일 파일 트랜스파일(main.zig)에서만 적용.
    // 번들 모드에서는 linker의 scope hoisting과 이름 충돌 해결이 먼저 필요하므로
    // 별도 통합이 필요 (후속 PR).

    // __esm 모듈: AST 수준 var/function 호이스팅 (esbuild/rolldown 방식)
    if (module.wrap_kind == .esm) {
        const esm_result = try emitEsmWrappedModule(
            allocator,
            arena_alloc,
            &transformer.ast,
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
        return esm_result.code;
    }

    // Codegen: AST → JS 문자열
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.ast, .{
        .minify_whitespace = options.minify_whitespace,
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
        .sourcemap = options.sourcemap,
        .source_root = options.source_root orelse "",
        .sources_content = options.sources_content,
        // keepNames: codegen이 rename된 함수/클래스를 수집
        .keep_names = options.keep_names,
        // JSX: Transformer가 이미 call_expression으로 lowering 완료.
        // codegen은 jsx_element/jsx_fragment를 만나지 않으므로 JSX 옵션 불필요.
        // dev mode: import.meta.hot → __zts_make_hot("dev_id")
        .dev_module_id = if (options.dev_mode and module.dev_id.len > 0) module.dev_id else null,
        .import_records = module.import_records,
    });
    // 소스맵용: line_offsets와 소스 파일 등록
    if (options.sourcemap) {
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
            try wrapped.appendSlice(allocator, "=__commonJS({\"");
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
        // preamble_lines: preamble 내 줄바꿈 수 (코드 매핑 오프셋용)
        if (preamble_lines_out) |out| {
            if (preamble) |p| {
                out.* = @intCast(std.mem.count(u8, p, "\n"));
            }
        }
        return try std.mem.concat(allocator, u8, &.{
            preamble orelse "",
            code,
            final_exports orelse "",
        });
    }

    // arena 해제 전에 복사 (caller 소유)
    return try allocator.dupe(u8, code);
}

/// JSON 모듈을 CJS 형태로 출력: __commonJS 래핑 + module.exports = <JSON content>
/// Disabled 모듈: platform=browser에서 Node 빌트인 모듈을 빈 __commonJS wrapper로 출력.
/// esbuild 호환 형식: var require_util = __commonJS({ "(disabled)"(exports, module) {} });
fn emitDisabledModule(allocator: std.mem.Allocator, module: *const Module, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, module.path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, "=__commonJS({\"(disabled)\"(exports,module){}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"(disabled)\"(exports, module) {\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}

/// Asset 모듈을 출력한다 (CJS wrap 패턴).
/// source에 값 표현식이 저장되어 있고, __commonJS wrapper로 래핑.
/// linker가 `require_X()` 호출을 생성하므로, 모든 포맷에서 CJS 패턴을 사용.
fn emitAssetModule(allocator: std.mem.Allocator, module: *const Module, options: EmitOptions) !?[]const u8 {
    if (module.source.len == 0) return null;
    return emitCjsWrapper(allocator, module.path, module.source, options.minify_whitespace);
}

/// __commonJS wrapper 출력 (Asset 모듈용).
/// var require_X = __commonJS({ "filename"(exports, module) { module.exports = <source>; } });
fn emitCjsWrapper(allocator: std.mem.Allocator, path: []const u8, source: []const u8, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, "=__commonJS({\"");
        try buf.appendSlice(allocator, std.fs.path.basename(path));
        try buf.appendSlice(allocator, "\"(exports,module){module.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, "}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"");
        try buf.appendSlice(allocator, std.fs.path.basename(path));
        try buf.appendSlice(allocator, "\"(exports, module) {\nmodule.exports=");
        try buf.appendSlice(allocator, source);
        try buf.appendSlice(allocator, ";\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}

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
    const module_index: u32 = @intFromEnum(module.index);

    // 1단계: no_side_effects인 import binding의 local symbol_id를 수집한다.
    // 비트셋 대신 bool 배열 사용 — 스택 256개, 초과 시 arena fallback.
    var has_any_pure = false;
    const sym_count = sem.symbols.len;
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
        if (canon_mod_idx >= linker.modules.len) continue;
        const target_module = linker.modules[canon_mod_idx];
        const target_sem = target_module.semantic orelse continue;

        if (target_sem.scope_maps.len == 0) continue;
        const target_scope = target_sem.scope_maps[0];

        // default export는 local_name이 다를 수 있음 ("default" → 실제 함수명)
        const target_sym_name = if (std.mem.eql(u8, resolved.canonical.export_name, "default"))
            linker.getExportLocalName(canon_mod_idx, "default") orelse resolved.canonical.export_name
        else
            resolved.canonical.export_name;

        const target_sym_idx = target_scope.get(target_sym_name) orelse continue;
        if (target_sym_idx >= target_sem.symbols.len) continue;
        if (!target_sem.symbols[target_sym_idx].decl_flags.no_side_effects) continue;

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
    options: EmitOptions,
) !void {
    // 런타임 헬퍼 주입: 래핑 모듈 유형에 따라 필요한 헬퍼 결정.
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    for (sorted_modules) |m| {
        if (m.wrap_kind == .cjs) needs_cjs_runtime = true;
        if (m.wrap_kind == .esm) needs_esm_wrap_runtime = true;
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
        // __toESM, __copyProps, __defProp은 CJS/ESM 양쪽에서 공유
        try rt.appendCjsRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    if (options.unsupported.async_await) {
        try rt.appendAsyncRuntime(output, allocator, options.minify_whitespace, options.unsupported.arrow);
    }
    // dev mode: HMR 런타임 주입 (__zts_modules, __zts_require, __zts_apply_update 등).
    // HMR 런타임이 $RefreshReg$/$RefreshSig$도 정의하므로 별도 스텁 불필요.
    if (options.dev_mode) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.HMR_RUNTIME_MIN else rt.HMR_RUNTIME);
    } else if (options.react_refresh) {
        // 비-dev 모드에서 react_refresh만 활성화된 경우 스텁 주입
        try output.appendSlice(allocator, rt.REFRESH_STUB);
    }
}

/// 청크별 런타임 헬퍼 주입.
/// emitChunks에서 사용.
pub fn emitChunkRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    modules: []const Module,
    options: EmitOptions,
    collected_helpers: ?RuntimeHelpers,
) !void {
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    var needs_to_binary = false;
    for (chunk.modules.items) |mod_idx| {
        const mi = @intFromEnum(mod_idx);
        if (mi < modules.len) {
            if (modules[mi].wrap_kind == .cjs) needs_cjs_runtime = true;
            if (modules[mi].wrap_kind == .esm) needs_esm_wrap_runtime = true;
            if (modules[mi].loader == .binary) needs_to_binary = true;
        }
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
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

// --- 포맷별 래핑 (prologue/epilogue) ---

/// 포맷별 prologue를 output에 추가한다.
fn emitFormatPrologue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    format: types.Format,
    global_name: ?[]const u8,
    factory_fn: []const u8,
    has_tla: bool,
    external_specifiers: []const []const u8,
    ext_param_names: []const []const u8,
) !void {
    switch (format) {
        .iife => {
            if (has_tla) {
                try output.appendSlice(allocator, "/* [ZTS WARNING] Top-level await requires ESM output format. */\n");
            }
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
            if (has_tla) {
                try output.appendSlice(allocator, "/* [ZTS WARNING] Top-level await requires ESM output format. */\n");
            }
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
            if (has_tla) {
                try output.appendSlice(allocator, "/* [ZTS WARNING] Top-level await requires ESM output format. */\n");
            }
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
fn emitFormatEpilogue(output: *std.ArrayList(u8), allocator: std.mem.Allocator, format: types.Format) !void {
    switch (format) {
        .iife => try output.appendSlice(allocator, "})();\n"),
        .umd, .amd => try output.appendSlice(allocator, "});\n"),
        .cjs, .esm => {},
    }
}
