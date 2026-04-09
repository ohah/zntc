//! ZTS Bundler — Orchestrator
//!
//! 번들러의 최상위 공개 API. ResolveCache → ModuleGraph → Emitter 파이프라인을 조율.
//!
//! 사용법:
//!   var bundler = Bundler.init(allocator, .{
//!       .entry_points = &.{"src/index.ts"},
//!       .format = .esm,
//!   });
//!   defer bundler.deinit();
//!   const result = try bundler.bundle();
//!   defer result.deinit(allocator);

const std = @import("std");
const plugin_mod = @import("plugin.zig");
const types = @import("types.zig");
const BundlerDiagnostic = types.BundlerDiagnostic;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const Platform = @import("resolve_cache.zig").Platform;
const emitter = @import("emitter.zig");
const EmitOptions = emitter.EmitOptions;
const OutputFile = emitter.OutputFile;
const chunk_mod = @import("chunk.zig");
const Linker = @import("linker.zig").Linker;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const module_store = @import("module_store.zig");
const transpile_mod = @import("../transpile.zig");

pub const BundleOptions = struct {
    entry_points: []const []const u8,
    format: EmitOptions.Format = .esm,
    platform: Platform = .browser,
    external: []const []const u8 = &.{},
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    minify_syntax: bool = false,
    /// 스코프 호이스팅 활성화 (import/export 제거 + 변수 리네임). false면 기존 동작.
    scope_hoist: bool = true,
    /// tree-shaking 활성화 (미사용 export/모듈 제거). scope_hoist가 true일 때만 동작.
    tree_shaking: bool = true,
    /// code splitting 활성화. true이면 dynamic import 경계에서 청크를 분리하고
    /// 공유 모듈을 공통 청크로 추출한다. 결과는 BundleResult.outputs에 다중 파일로 반환.
    code_splitting: bool = false,
    /// dev mode: 각 모듈을 __zts_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// dev mode에서 per-module codes 수집 (HMR rebuild용). 초기 빌드에서는 false로 메모리 절감.
    collect_module_codes: bool = false,
    /// define 글로벌 치환 (--define:KEY=VALUE)
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    /// legacy decorator 변환 (--experimental-decorators / tsconfig)
    experimental_decorators: bool = false,
    /// emitDecoratorMetadata: __metadata 호출 주입 (NestJS/Angular DI)
    emit_decorator_metadata: bool = false,
    /// useDefineForClassFields=false (tsconfig)
    use_define_for_class_fields: bool = true,
    /// Unsupported features bitmask (ES/엔진 타겟에서 변환됨)
    unsupported: @import("../transformer/transformer.zig").TransformOptions.compat.UnsupportedFeatures = .{},
    /// package.json exports 커스텀 조건 (--conditions, esbuild 호환)
    conditions: []const []const u8 = &.{},
    /// 파이프라인 단계별 타이밍 출력 (--timing)
    timing: bool = false,
    /// symlink를 따라가지 않고 링크 자체 경로로 해석 (--preserve-symlinks)
    preserve_symlinks: bool = false,
    /// import 경로 별칭 (--alias:K=V). resolve 시 specifier 앞부분을 치환.
    alias: []const types.AliasEntry = &.{},
    /// 에셋/청크 URL prefix (--public-path). 동적 import 경로에 적용.
    public_path: []const u8 = "",
    /// 번들 출력 앞에 삽입할 텍스트 (--banner:js)
    banner_js: ?[]const u8 = null,
    /// 번들 출력 뒤에 삽입할 텍스트 (--footer:js)
    footer_js: ?[]const u8 = null,
    /// IIFE 포맷에서 export를 바인딩할 글로벌 변수명 (--global-name)
    global_name: ?[]const u8 = null,
    /// 출력 파일 확장자 오버라이드 (--out-extension:.js=.mjs)
    out_extension_js: ?[]const u8 = null,
    /// 소스맵 sourceRoot 필드 (--source-root)
    source_root: ?[]const u8 = null,
    /// 소스맵에 sourcesContent 포함 여부 (--sources-content=false로 제외)
    sources_content: bool = true,
    /// 소스맵 생성 (--sourcemap)
    sourcemap: bool = false,
    /// Sentry Debug ID (--sourcemap-debug-ids). 소스맵 + JS에 동일 UUID를 삽입.
    sourcemap_debug_ids: bool = false,
    /// 출력 파일명 (소스맵 참조용)
    output_filename: []const u8 = "bundle.js",
    /// UTF-8 문자를 이스케이프하지 않고 그대로 출력 (--charset=utf8)
    charset_utf8: bool = false,
    /// 엔트리 청크 파일명 패턴 (--entry-names, 기본: "[name]")
    entry_names: []const u8 = "[name]",
    /// 공통 청크 파일명 패턴 (--chunk-names, 기본: "[name]-[hash]")
    chunk_names: []const u8 = "[name]-[hash]",
    /// 에셋 파일명 패턴 (--asset-names, 기본: "[name]-[hash]")
    asset_names: []const u8 = "[name]-[hash]",
    /// 확장자별 로더 오버라이드 (--loader:.png=file)
    loader_overrides: []const types.LoaderOverride = &.{},
    /// legal comments 처리 모드 (--legal-comments)
    legal_comments: types.LegalComments = .default,
    /// metafile JSON 생성 (--metafile)
    metafile: bool = false,
    /// 번들 분석 출력 (--analyze). metafile을 내부적으로 강제 활성화.
    analyze: bool = false,
    /// 모든 모듈에 자동 import (--inject:./file.js). 절대 경로 목록.
    inject: []const []const u8 = &.{},
    /// 엔트리 모듈 직전에 실행할 모듈 (--run-before-main). 절대 경로 목록.
    /// Metro의 runBeforeMainModule과 동일 역할. inject와 같은 메커니즘으로
    /// 엔트리 의존성에 추가되어 먼저 실행된다.
    run_before_main: []const []const u8 = &.{},
    /// 번들 시작 시 즉시 실행 폴리필 (--polyfill). 절대 경로 목록.
    /// 파일 내용을 IIFE로 감싸서 런타임 헬퍼 앞에 인라인. 모듈 그래프에 미포함.
    polyfills: []const []const u8 = &.{},
    /// 예약 전역 식별자 (--global-identifier). scope hoisting 시 이 이름을 모듈 변수로
    /// 사용하지 않도록 리네이밍. RN의 polyfillGlobal()로 등록되는 이름 충돌 방지.
    global_identifiers: []const []const u8 = &.{},
    /// --shim-missing-exports: 존재하지 않는 export를 import할 때 에러 대신 undefined 제공.
    /// 롤다운 호환 — missing export에 대해 `var xxx = void 0;` shim 변수를 생성.
    shim_missing_exports: bool = false,
    /// --keep-names: minify 시 함수/클래스의 .name 프로퍼티 보존
    keep_names: bool = false,
    /// 플러그인 배열 (resolveId, load, transform, renderChunk, generateBundle 훅)
    plugins: []const plugin_mod.Plugin = &.{},
    /// Flow 모드 강제 활성화 (--flow). @flow pragma 없이도 .js/.jsx를 Flow로 파싱.
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화 (--platform=react-native 프리셋).
    jsx_in_js: bool = false,
    /// JSX 런타임 모드 (--jsx=classic|automatic|automatic-dev)
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    /// classic 모드 JSX factory (--jsx-factory)
    jsx_factory: []const u8 = "React.createElement",
    /// classic 모드 Fragment factory (--jsx-fragment)
    jsx_fragment: []const u8 = "React.Fragment",
    /// automatic 모드 import source (--jsx-import-source)
    jsx_import_source: []const u8 = "react",
    /// 커스텀 확장자 탐색 순서 (--resolve-extensions). 비어있으면 기본값 사용.
    resolve_extensions: []const []const u8 = &.{},
    /// package.json 필드 해석 순서 (--main-fields). 비어있으면 기본 (module → main).
    main_fields: []const []const u8 = &.{},
    /// Object.defineProperty에 configurable: true 추가 (RN/Hermes 호환).
    /// --platform=react-native에서 자동 활성화.
    configurable_exports: bool = false,
    /// 증분 빌드용 모�� 파싱 캐시. null이면 매번 전체 파싱.
    /// IncrementalBundler가 소유하고 빌드 간 보존한다.
    module_store: ?*@import("module_store.zig").PersistentModuleStore = null,
    /// --outbase: 엔트리 포인트 공통 기준 경로
    outbase: ?[]const u8 = null,
    /// --packages=external: 모든 bare import를 external 처리
    packages_external: bool = false,
    /// --ignore-annotations: @__PURE__, sideEffects 등 어노테이션 무시
    ignore_annotations: bool = false,
    /// --jsx-side-effects: 미사용 JSX를 tree-shake하지 않음
    jsx_side_effects: bool = false,
    /// --drop-labels: 제거할 labeled statement의 라벨 이름 목록
    drop_labels: []const []const u8 = &.{},
    /// --pure:NAME: 순수 함수로 마킹할 글로벌 함수명 목록
    pure: []const []const u8 = &.{},
    /// --tsconfig-raw: tsconfig.json 인라인 오버라이드 JSON
    tsconfig_raw: ?[]const u8 = null,
    /// --node-paths: NODE_PATH 추가 탐색 경로
    node_paths: []const []const u8 = &.{},
    /// --line-limit: 줄 길이 제한 (0=무제한)
    line_limit: u32 = 0,
    /// --preserve-modules: 모듈 1개 = 출력 파일 1개 (라이브러리 빌드용).
    /// code_splitting과 동일한 다중 파일 출력 경로를 사용한다.
    preserve_modules: bool = false,
    /// --preserve-modules-root: 출력 디렉토리 구조의 기준 경로.
    /// 이 경로를 기준으로 상대 경로를 계산하여 출력 파일 구조를 결정한다.
    /// null이면 엔트리 포인트들의 공통 부모 디렉토리를 자동 계산.
    preserve_modules_root: ?[]const u8 = null,

    pub const AliasEntry = types.AliasEntry;
};

pub const BundleResult = struct {
    /// 번들 출력 내용 (단일 파일). code_splitting=false일 때 사용. allocator 소유.
    output: []const u8,
    /// 소스맵 JSON (V3). null이면 소스맵 미생성. allocator 소유.
    sourcemap: ?[]const u8 = null,
    /// 다중 출력 파일. code_splitting=true일 때 사용. allocator 소유.
    /// null이면 단일 파일 모드 (output 필드 사용).
    outputs: ?[]OutputFile = null,
    /// 빌드 중 발생한 진단 메시지들. deep copy — 내부 문자열도 allocator 소유.
    diagnostics: ?[]OwnedDiagnostic,
    /// 번들에 포함된 모든 모듈의 절대 경로. allocator 소유. dev server watch용.
    module_paths: ?[]const []const u8 = null,
    /// dev mode: JS 모듈별 __zts_register(...) 코드. HMR 모듈 단위 업데이트용.
    /// id로 매칭 (module_paths와 인덱스 대응 아님). allocator 소유.
    module_dev_codes: ?[]const ModuleDevCode = null,
    /// asset 파일 출력 (file/copy 로더). allocator 소유.
    /// JS 청크와 별도로 출력 디렉토리에 복사해야 하는 파일들.
    asset_outputs: ?[]OutputFile = null,
    /// metafile JSON (--metafile). allocator 소유.
    metafile_json: ?[]const u8 = null,

    /// dev mode에서 모듈별 HMR 업데이트 코드. types.ModuleDevCode의 별칭.
    pub const ModuleDevCode = types.ModuleDevCode;

    /// 문자열 필드를 소유하는 diagnostic (graph 해제 후에도 유효).
    pub const OwnedDiagnostic = struct {
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        message: []const u8,
        file_path: []const u8,
        step: BundlerDiagnostic.Step,
        suggestion: ?[]const u8,
    };

    pub fn deinit(self: *const BundleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.sourcemap) |sm| allocator.free(sm);
        if (self.outputs) |outs| {
            for (outs) |o| {
                allocator.free(o.path);
                allocator.free(o.contents);
            }
            allocator.free(outs);
        }
        if (self.diagnostics) |diags| {
            for (diags) |d| {
                allocator.free(d.message);
                allocator.free(d.file_path);
                if (d.suggestion) |s| allocator.free(s);
            }
            allocator.free(diags);
        }
        if (self.module_paths) |paths| {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        if (self.module_dev_codes) |codes| {
            ModuleDevCode.freeAll(codes, allocator);
        }
        if (self.asset_outputs) |outs| {
            for (outs) |o| {
                allocator.free(o.path);
                allocator.free(o.contents);
            }
            allocator.free(outs);
        }
        if (self.metafile_json) |mf| allocator.free(mf);
    }

    pub fn hasErrors(self: *const BundleResult) bool {
        const diags = self.diagnostics orelse return false;
        for (diags) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn getDiagnostics(self: *const BundleResult) []const OwnedDiagnostic {
        return self.diagnostics orelse &[_]OwnedDiagnostic{};
    }
};

pub const Bundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,
    resolve_cache: ResolveCache,
    /// 외부 소유 ResolveCache 포인터. non-null이면 이것을 사용하고 resolve_cache 필드는 무시.
    resolve_cache_ref: ?*ResolveCache = null,

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) Bundler {
        return .{
            .allocator = allocator,
            .options = options,
            .resolve_cache = ResolveCache.init(allocator, .{
                .platform = options.platform,
                .external_patterns = options.external,
                .custom_conditions = options.conditions,
                .preserve_symlinks = options.preserve_symlinks,
                .alias = options.alias,
                .resolve_extensions = options.resolve_extensions,
                .main_fields = options.main_fields,
                .packages_external = options.packages_external,
                .node_paths = options.node_paths,
            }),
        };
    }

    /// 외부에서 소유하는 ResolveCache를 사용하는 생성자.
    /// resolve_cache_ref 포인터를 저장하므로 얕은 복사 없이 원본을 직접 참조한다.
    pub fn initWithResolveCache(allocator: std.mem.Allocator, options: BundleOptions, rc: *ResolveCache) Bundler {
        return .{
            .allocator = allocator,
            .options = options,
            .resolve_cache = rc.*, // resolve_cache_ref가 우선이므로 이 값은 사용 안 됨
            .resolve_cache_ref = rc,
        };
    }

    /// 실제 사용할 ResolveCache 포인터를 반환.
    fn getResolveCache(self: *Bundler) *ResolveCache {
        return self.resolve_cache_ref orelse &self.resolve_cache;
    }

    pub fn deinit(self: *Bundler) void {
        if (self.resolve_cache_ref == null) {
            self.resolve_cache.deinit();
        }
    }

    /// BundleOptions → EmitOptions 변환. 3개 경로(단일/splitting/dev)에서 공용.
    fn makeEmitOptions(self: *const Bundler) EmitOptions {
        return .{
            .format = self.options.format,
            .minify_whitespace = self.options.minify_whitespace,
            .minify_syntax = self.options.minify_syntax,
            .define = self.options.define,
            .platform = self.options.platform,
            .experimental_decorators = self.options.experimental_decorators,
            .emit_decorator_metadata = self.options.emit_decorator_metadata,
            .use_define_for_class_fields = self.options.use_define_for_class_fields,
            .unsupported = self.options.unsupported,
            .public_path = self.options.public_path,
            .banner_js = self.options.banner_js,
            .footer_js = self.options.footer_js,
            .global_name = self.options.global_name,
            .out_extension_js = self.options.out_extension_js,
            .source_root = self.options.source_root,
            .sources_content = self.options.sources_content,
            .output_filename = self.options.output_filename,
            .charset_utf8 = self.options.charset_utf8,
            .entry_names = self.options.entry_names,
            .chunk_names = self.options.chunk_names,
            .asset_names = self.options.asset_names,
            .legal_comments = self.options.legal_comments,
            .keep_names = self.options.keep_names,
            .jsx_runtime = self.options.jsx_runtime,
            .jsx_factory = self.options.jsx_factory,
            .jsx_fragment = self.options.jsx_fragment,
            .jsx_import_source = self.options.jsx_import_source,
            .sourcemap_debug_ids = self.options.sourcemap_debug_ids,
            .plugins = self.options.plugins,
            .polyfills = &.{}, // 호출자가 loadPolyfills()로 설정
            .run_before_main = self.options.run_before_main,
            .configurable_exports = self.options.configurable_exports,
        };
    }

    /// 출력 코드에서 Worker의 new URL("specifier", ...) 패턴을 worker 파일명 문자열로 교체.
    /// 코드를 한 번만 스캔하면서 모든 new URL( 패턴을 매칭 (다중 worker 순서 독립).
    fn rewriteWorkerURLs(self: *Bundler, code: []u8, graph: *ModuleGraph, worker_map: *std.StringHashMap([]const u8)) ![]const u8 {
        // specifier → worker filename 매핑 구축
        var spec_to_filename = std.StringHashMap([]const u8).init(self.allocator);
        defer spec_to_filename.deinit();
        for (graph.worker_entries.items) |we| {
            const filename = worker_map.get(we.resolved_path) orelse continue;
            const mod = &graph.modules.items[@intFromEnum(we.source_module)];
            if (we.record_index >= mod.import_records.len) continue;
            try spec_to_filename.put(mod.import_records[we.record_index].specifier, filename);
        }

        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(self.allocator);
        try result.ensureTotalCapacity(self.allocator, code.len);

        const needle = "new URL(";
        var pos: usize = 0;
        while (std.mem.indexOf(u8, code[pos..], needle)) |rel| {
            const abs_start = pos + rel;
            const after = abs_start + needle.len;
            // new URL("specifier", ...) — 따옴표 시작 확인
            if (after < code.len and code[after] == '"') {
                // specifier 끝 따옴표 찾기
                if (std.mem.indexOf(u8, code[after + 1 ..], "\"")) |quote_end| {
                    const spec = code[after + 1 .. after + 1 + quote_end];
                    // 닫는 괄호 찾기
                    if (std.mem.indexOf(u8, code[abs_start..], ")")) |paren_end| {
                        const replace_end = abs_start + paren_end + 1;
                        if (spec_to_filename.get(spec)) |filename| {
                            try result.appendSlice(self.allocator, code[pos..abs_start]);
                            try result.append(self.allocator, '"');
                            try result.appendSlice(self.allocator, "./");
                            try result.appendSlice(self.allocator, filename);
                            try result.append(self.allocator, '"');
                            pos = replace_end;
                            continue;
                        }
                    }
                }
            }
            // 매칭 안 되면 needle 지나서 계속
            try result.appendSlice(self.allocator, code[pos .. abs_start + needle.len]);
            pos = abs_start + needle.len;
        }
        try result.appendSlice(self.allocator, code[pos..]);

        self.allocator.free(code);
        return try result.toOwnedSlice(self.allocator);
    }

    const WorkerBuildResult = struct {
        filename: []const u8,
        contents: []const u8,
    };

    /// Worker 파일을 독립 IIFE 번들로 빌드한다.
    fn buildWorker(self: *Bundler, worker_path: []const u8) !WorkerBuildResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // worker용 resolve cache (부모와 공유하지 않음)
        var worker_resolve_cache = ResolveCache.init(arena_alloc, .{ .platform = self.getResolveCache().platform });

        var worker_graph = ModuleGraph.init(arena_alloc, &worker_resolve_cache);
        worker_graph.loader_overrides = self.options.loader_overrides;
        worker_graph.public_path = self.options.public_path;
        worker_graph.plugins = self.options.plugins;
        worker_graph.flow = self.options.flow;
        worker_graph.jsx_in_js = self.options.jsx_in_js;
        worker_graph.jsx_runtime = self.options.jsx_runtime;
        worker_graph.jsx_import_source = self.options.jsx_import_source;
        defer worker_graph.deinit();

        const entry_path = try arena_alloc.dupe(u8, worker_path);
        const entry_arr: [1][]const u8 = .{entry_path};
        try worker_graph.build(&entry_arr);

        // 링킹
        var worker_linker = Linker.init(arena_alloc, worker_graph.modules.items, .iife);
        try worker_linker.link();
        try worker_linker.computeRenames();
        if (self.options.minify_identifiers) {
            try worker_linker.computeMangling();
        }
        defer worker_linker.deinit();

        // emit (IIFE 포맷)
        var emit_opts = self.makeEmitOptions();
        emit_opts.format = .iife;
        const worker_result = try emitter.emitWithTreeShaking(
            arena_alloc,
            &worker_graph,
            emit_opts,
            &worker_linker,
            null,
        );
        const worker_output = worker_result.output;

        // content hash로 파일명 생성
        const hash = std.hash.Crc32.hash(worker_output);
        const basename = std.fs.path.stem(std.fs.path.basename(worker_path));
        const filename = try std.fmt.allocPrint(self.allocator, "{s}-{x:0>8}.js", .{ basename, hash });
        const contents = try self.allocator.dupe(u8, worker_output);

        return .{ .filename = filename, .contents = contents };
    }

    /// 번들 파이프라인 실행: resolve → graph → emit.
    pub fn bundle(self: *Bundler) !BundleResult {
        const timing = self.options.timing;
        var t_graph: u64 = 0;
        var t_link: u64 = 0;
        var t_shake: u64 = 0;
        var t_emit: u64 = 0;

        var timer: ?std.time.Timer = if (timing) std.time.Timer.start() catch null else null;

        // 0. RN dev mode: InitializeCore prelude 자동 주입 (롤리팝 방식).
        // RN에서 react-refresh는 InitializeCore → setUpReactRefresh에서 설정된다.
        // InitializeCore를 run_before_main에 추가하면 모듈 그래프 안에서 엔트리 전에 실행되어
        // __ReactRefresh가 컴포넌트 모듈보다 먼저 초기화된다.
        // (polyfill 단계에서 injectIntoGlobalHook을 호출하면 RN 네이티브 런타임 충돌)
        const original_rbm = self.options.run_before_main;
        defer {
            if (self.options.run_before_main.ptr != original_rbm.ptr) {
                self.allocator.free(self.options.run_before_main);
                self.options.run_before_main = original_rbm;
            }
        }
        var auto_init_core_path: ?[]const u8 = null;
        defer if (auto_init_core_path) |p| self.allocator.free(p);

        if (self.options.dev_mode and self.options.react_refresh and
            self.options.platform == .react_native)
        {
            const entry_dir = if (self.options.entry_points.len > 0)
                std.fs.path.dirname(self.options.entry_points[0]) orelse "."
            else
                ".";
            const init_core_rel = "node_modules/react-native/Libraries/Core/InitializeCore.js";

            auto_init_core_path = blk: {
                // entry_dir 기준 탐색
                const full = std.fs.path.join(self.allocator, &.{ entry_dir, init_core_rel }) catch break :blk null;
                defer self.allocator.free(full);
                if (std.fs.cwd().realpathAlloc(self.allocator, full)) |real| break :blk real else |_| {}
                // CWD 기준 탐색
                break :blk std.fs.cwd().realpathAlloc(self.allocator, init_core_rel) catch null;
            };

            if (auto_init_core_path) |init_path| {
                var already_present = false;
                for (self.options.run_before_main) |rbm| {
                    if (std.mem.eql(u8, rbm, init_path)) {
                        already_present = true;
                        break;
                    }
                }
                if (!already_present) {
                    const new_rbm = try self.allocator.alloc([]const u8, self.options.run_before_main.len + 1);
                    // InitializeCore를 맨 앞에 배치 (다른 run_before_main보다 먼저 실행)
                    new_rbm[0] = init_path;
                    @memcpy(new_rbm[1..], self.options.run_before_main);
                    self.options.run_before_main = new_rbm;
                }
            }
        }

        // 1. 모듈 그래프 구축
        var graph = ModuleGraph.init(self.allocator, self.getResolveCache());
        graph.dev_mode = self.options.dev_mode;
        graph.timing = timing;
        graph.loader_overrides = self.options.loader_overrides;
        graph.public_path = self.options.public_path;
        graph.asset_names = self.options.asset_names;
        // --inject와 --run-before-main을 합쳐서 엔트리 의존성으로 추가 (실행 순서: inject → run-before-main → entry)
        const combined_inject = if (self.options.run_before_main.len > 0)
            try std.mem.concat(self.allocator, []const u8, &.{ self.options.inject, self.options.run_before_main })
        else
            null;
        defer if (combined_inject) |c| self.allocator.free(c);
        graph.inject_files = combined_inject orelse self.options.inject;
        graph.plugins = self.options.plugins;
        graph.flow = self.options.flow;
        graph.jsx_in_js = self.options.jsx_in_js;
        graph.jsx_runtime = self.options.jsx_runtime;
        graph.jsx_import_source = self.options.jsx_import_source;
        defer graph.deinit();

        // graph.build() 또는 buildIncremental() 호출
        if (self.options.module_store) |store| {
            const inc_result = try graph.buildIncremental(self.options.entry_points, store);
            self.allocator.free(inc_result.reparsed_indices);
        } else {
            try graph.build(self.options.entry_points);
        }

        // Worker 별도 빌드: new Worker(new URL(...)) 패턴에서 수집된 worker 경로를 독립 IIFE로 빌드
        var worker_output_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = worker_output_map.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            worker_output_map.deinit();
        }
        var worker_output_files: std.ArrayList(OutputFile) = .empty;
        defer worker_output_files.deinit(self.allocator);

        for (graph.worker_entries.items) |we| {
            // 같은 worker 파일이 여러 곳에서 참조되면 한 번만 빌드
            if (worker_output_map.contains(we.resolved_path)) continue;

            const worker_result = self.buildWorker(we.resolved_path) catch {
                continue;
            };
            try worker_output_map.put(we.resolved_path, worker_result.filename);
            try worker_output_files.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, worker_result.filename),
                .contents = worker_result.contents,
            });
        }

        if (timer) |*t| {
            t_graph = t.read();
            t.reset();
        }

        // 2. 링킹 (scope hoisting)
        // code_splitting=true일 때는 글로벌 computeRenames를 건너뛴다.
        // 각 청크가 독립된 네임스페이스이므로 emitChunks에서 per-chunk로 처리.
        var linker: ?Linker = if (self.options.scope_hoist or self.options.dev_mode) blk: {
            var l = Linker.initWithGlobalIdentifiers(self.allocator, graph.modules.items, self.options.format, self.options.global_identifiers);
            l.shim_missing_exports = self.options.shim_missing_exports;
            l.dev_mode = self.options.dev_mode;
            try l.link();
            if (!self.options.code_splitting) {
                try l.computeRenames();
                if (self.options.minify_identifiers) {
                    try l.computeMangling();
                }
            }
            break :blk l;
        } else null;
        defer if (linker) |*l| l.deinit();

        if (timer) |*t| {
            t_link = t.read();
            t.reset();
        }

        // 2.5. Tree-shaking (scope_hoist + tree_shaking 둘 다 켜져 있을 때)
        // dev_mode에서는 tree-shaking 스킵 (개발 중 모든 코드 필요)
        var shaker: ?TreeShaker = if (!self.options.dev_mode and self.options.scope_hoist and self.options.tree_shaking) blk: {
            var s = try TreeShaker.init(self.allocator, graph.modules.items, &(linker.?));
            try s.analyze(self.options.entry_points);
            break :blk s;
        } else null;
        defer if (shaker) |*s| s.deinit();

        if (timer) |*t| {
            t_shake = t.read();
            t.reset();
        }

        // 2.7. 폴리필 파일 내용 로딩 (--polyfill)
        var polyfill_entries: std.ArrayList(EmitOptions.PolyfillEntry) = .empty;
        defer {
            for (polyfill_entries.items) |e| self.allocator.free(e.content);
            polyfill_entries.deinit(self.allocator);
        }
        for (self.options.polyfills) |poly_path| {
            const raw = std.fs.cwd().readFileAlloc(self.allocator, poly_path, 10 * 1024 * 1024) catch |err| {
                std.log.err("zts: cannot read polyfill file '{s}': {}", .{ poly_path, err });
                continue;
            };
            // Flow 모드일 때 트랜스파일하여 타입 구문 제거 (RN 폴리필은 Flow로 작성됨)
            const content = if (self.options.flow) blk: {
                const result = transpile_mod.transpile(self.allocator, raw, poly_path, .{
                    .flow = true,
                    .jsx_in_js = self.options.jsx_in_js,
                }) catch {
                    break :blk raw; // 트랜스파일 실패 시 원본 사용
                };
                self.allocator.free(raw);
                break :blk result.code;
            } else raw;
            try polyfill_entries.append(self.allocator, .{
                .name = std.fs.path.basename(poly_path),
                .content = content,
            });
        }

        // 2.8. React Refresh 런타임 주입 (dev mode)
        // react-refresh/runtime을 polyfill로 주입하여 __ReactRefresh 글로벌 설정.
        // HMR 런타임의 $RefreshReg$/$RefreshSig$가 이 글로벌을 참조한다.
        // RN: injectIntoGlobalHook은 InitializeCore가 적절한 시점에 호출하므로 스킵.
        // 브라우저: polyfill에서 직접 호출.
        if (self.options.dev_mode and self.options.react_refresh) blk: {
            // entry 디렉토리에서 node_modules/react-refresh를 직접 탐색
            const entry_dir = if (self.options.entry_points.len > 0)
                std.fs.path.dirname(self.options.entry_points[0]) orelse "."
            else
                ".";
            const dev_path = "node_modules/react-refresh/cjs/react-refresh-runtime.development.js";
            // entry_dir/node_modules 또는 CWD/node_modules에서 탐색
            const raw = blk2: {
                // entry_dir 기준
                const full_path = std.fs.path.join(self.allocator, &.{ entry_dir, dev_path }) catch break :blk;
                defer self.allocator.free(full_path);
                if (std.fs.cwd().readFileAlloc(self.allocator, full_path, 1024 * 1024)) |r| break :blk2 r else |_| {}
                // CWD 기준
                break :blk2 std.fs.cwd().readFileAlloc(self.allocator, dev_path, 1024 * 1024) catch {
                    std.log.warn("zts: react-refresh not found — install react-refresh for HMR", .{});
                    break :blk;
                };
            };
            const preamble =
                "(function(){" ++
                "var exports = {};" ++
                "var module = { exports: exports };" ++
                "var process = { env: { NODE_ENV: \"development\" } };\n";
            const epilogue = if (self.options.platform == .react_native)
                // RN: 글로벌 설정만. injectIntoGlobalHook은 InitializeCore가 처리.
                "\nvar __r = module.exports;" ++
                    "var __g = typeof globalThis !== \"undefined\" ? globalThis : typeof global !== \"undefined\" ? global : window;" ++
                    "__g.__ReactRefresh = __r;" ++
                    "__g.__REACT_REFRESH_RUNTIME__ = __r;" ++
                    "})();\n"
            else
                "\nvar __r = module.exports;" ++
                    "var __g = typeof globalThis !== \"undefined\" ? globalThis : typeof global !== \"undefined\" ? global : window;" ++
                    "__g.__ReactRefresh = __r;" ++
                    "__g.__REACT_REFRESH_RUNTIME__ = __r;" ++
                    "if (__r.injectIntoGlobalHook) __r.injectIntoGlobalHook(__g);" ++
                    "})();\n";
            const wrapped = std.mem.concat(self.allocator, u8, &.{ preamble, raw, epilogue }) catch break :blk;
            self.allocator.free(raw);
            try polyfill_entries.append(self.allocator, .{
                .name = "react-refresh-runtime",
                .content = wrapped,
            });
        }

        // 3. 번들 출력 생성
        var output: []const u8 = "";
        var outputs: ?[]OutputFile = null;

        // dev mode용 per-module codes + sourcemap
        var module_dev_codes_from_emit: ?[]const types.ModuleDevCode = null;
        var dev_sourcemap: ?[]const u8 = null;

        if (self.options.dev_mode) {
            // Dev mode: 프로덕션 파이프라인 재사용 (__commonJS/__esm 래핑 + HMR 런타임).
            var dev_emit_opts = self.makeEmitOptions();
            dev_emit_opts.sourcemap = true;
            dev_emit_opts.dev_mode = true;
            dev_emit_opts.root_dir = self.options.root_dir;
            dev_emit_opts.react_refresh = self.options.react_refresh;
            dev_emit_opts.collect_module_codes = self.options.collect_module_codes;
            dev_emit_opts.polyfills = polyfill_entries.items;
            dev_emit_opts.run_before_main = self.options.run_before_main;

            for (graph.modules.items) |*m| {
                m.dev_id = emitter.makeModuleId(m.path, self.options.root_dir);
            }

            const emit_result = try emitter.emitWithTreeShaking(
                self.allocator,
                &graph,
                dev_emit_opts,
                if (linker) |*l| l else null,
                null, // dev mode: tree-shaking 비활성
            );
            output = emit_result.output;
            module_dev_codes_from_emit = emit_result.module_codes;
            dev_sourcemap = emit_result.sourcemap;
        } else if (self.options.code_splitting or self.options.preserve_modules) {
            // Code splitting / preserve-modules 경로: 청크 그래프 생성 → 다중 파일 출력
            var chunk_graph = if (self.options.preserve_modules)
                try chunk_mod.generatePreserveModulesChunks(
                    self.allocator,
                    graph.modules.items,
                    self.options.entry_points,
                    if (shaker) |*s| s else null,
                )
            else
                try chunk_mod.generateChunks(
                    self.allocator,
                    graph.modules.items,
                    self.options.entry_points,
                    if (shaker) |*s| s else null,
                );
            defer chunk_graph.deinit();

            try chunk_mod.computeCrossChunkLinks(&chunk_graph, graph.modules.items, self.allocator, if (linker) |*l| l else null);

            var emit_opts = self.makeEmitOptions();
            emit_opts.preserve_modules = self.options.preserve_modules;
            emit_opts.preserve_modules_root = self.options.preserve_modules_root;
            outputs = try emitter.emitChunks(
                self.allocator,
                graph.modules.items,
                &chunk_graph,
                emit_opts,
                if (linker) |*l| l else null,
            );
            errdefer if (outputs) |outs| {
                for (outs) |o| {
                    self.allocator.free(o.path);
                    self.allocator.free(o.contents);
                }
                self.allocator.free(outs);
            };

            // output은 빈 문자열 — code splitting 시 outputs를 사용
            output = try self.allocator.dupe(u8, "");
        } else {
            // 단일 파일 경로 (tree shaking + 소스맵 지원)
            var emit_opts = self.makeEmitOptions();
            emit_opts.polyfills = polyfill_entries.items;
            if (self.options.sourcemap) emit_opts.sourcemap = true;
            const emit_result = try emitter.emitWithTreeShaking(
                self.allocator,
                &graph,
                emit_opts,
                if (linker) |*l| l else null,
                if (shaker) |*s| s else null,
            );
            output = emit_result.output;
            dev_sourcemap = emit_result.sourcemap;
        }
        errdefer self.allocator.free(output);

        // Worker URL 교체: 출력 코드에서 new URL("./worker.ts", "") → "./worker-[hash].js"
        if (graph.worker_entries.items.len > 0 and output.len > 0) {
            output = try self.rewriteWorkerURLs(@constCast(output), &graph, &worker_output_map);
        }

        if (timer) |*t| {
            t_emit = t.read();
        }

        // 타이밍 출력
        if (timing) {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            const total = t_graph + t_link + t_shake + t_emit;
            const module_count = graph.modules.items.len;
            stderr.print(
                \\
                \\  Bundle timing ({d} modules):
                \\    graph:      {d:.3} ms  (resolve + parse + finalize)
                \\    link:       {d:.3} ms
                \\    tree-shake: {d:.3} ms
                \\    emit:       {d:.3} ms  (transform + codegen)
                \\    ─────────────────
                \\    total:      {d:.3} ms
                \\
            , .{
                module_count,
                @as(f64, @floatFromInt(t_graph)) / 1_000_000.0,
                @as(f64, @floatFromInt(t_link)) / 1_000_000.0,
                @as(f64, @floatFromInt(t_shake)) / 1_000_000.0,
                @as(f64, @floatFromInt(t_emit)) / 1_000_000.0,
                @as(f64, @floatFromInt(total)) / 1_000_000.0,
            }) catch {};
        }

        // 4. 진단 메시지 deep copy (graph.deinit 후에도 문자열 유효하도록)
        const diagnostics: ?[]BundleResult.OwnedDiagnostic = if (graph.diagnostics.items.len > 0) blk: {
            const diags = try self.allocator.alloc(BundleResult.OwnedDiagnostic, graph.diagnostics.items.len);
            errdefer self.allocator.free(diags);
            // M1 수정: 부분 할당 후 OOM 시 이미 복사한 문자열 해제
            var filled: usize = 0;
            errdefer for (diags[0..filled]) |d| {
                self.allocator.free(d.message);
                self.allocator.free(d.file_path);
                if (d.suggestion) |s| self.allocator.free(s);
            };
            for (graph.diagnostics.items, 0..) |d, i| {
                diags[i] = .{
                    .code = d.code,
                    .severity = d.severity,
                    .message = try self.allocator.dupe(u8, d.message),
                    .file_path = try self.allocator.dupe(u8, d.file_path),
                    .step = d.step,
                    .suggestion = if (d.suggestion) |s| try self.allocator.dupe(u8, s) else null,
                };
                filled = i + 1;
            }
            break :blk diags;
        } else null;

        // 5. 모듈 경로 수집 (dev server watch용)
        const module_paths: ?[]const []const u8 = if (graph.modules.items.len > 0) blk: {
            const paths = try self.allocator.alloc([]const u8, graph.modules.items.len);
            errdefer self.allocator.free(paths);
            var path_count: usize = 0;
            errdefer for (paths[0..path_count]) |p| self.allocator.free(p);
            for (graph.modules.items) |m| {
                paths[path_count] = try self.allocator.dupe(u8, m.path);
                path_count += 1;
            }
            break :blk paths;
        } else null;

        // 5.5. Asset 파일 수집 (file/copy 로더 — 출력 디렉토리에 복사할 파일들)
        const asset_outputs: ?[]OutputFile = blk: {
            var asset_count: usize = 0;
            for (graph.modules.items) |m| {
                if (m.asset_data != null) asset_count += 1;
            }
            if (asset_count == 0) break :blk null;

            const outs = try self.allocator.alloc(OutputFile, asset_count);
            errdefer self.allocator.free(outs);
            var idx: usize = 0;
            for (graph.modules.items) |m| {
                if (m.asset_data) |ad| {
                    outs[idx] = .{
                        .path = try self.allocator.dupe(u8, ad.output_name),
                        .contents = try self.allocator.dupe(u8, ad.raw_content),
                    };
                    idx += 1;
                }
            }
            break :blk outs;
        };

        // 6. Dev mode: per-module codes (동일 타입이므로 변환 불필요)
        const module_dev_codes = module_dev_codes_from_emit;

        // 7. Metafile JSON 생성 (--metafile / --analyze)
        const metafile_json: ?[]const u8 = if (self.options.metafile or self.options.analyze)
            try generateMetafileJson(self.allocator, &graph, output, outputs)
        else
            null;

        // 8. Plugin: generateBundle 훅 — 번들 완료 후 모든 플러그인에 알림
        if (self.options.plugins.len > 0) {
            const runner = plugin_mod.PluginRunner.init(self.options.plugins);
            const gen_outputs: []const emitter.OutputFile = if (outputs) |outs|
                outs
            else
                &.{.{ .path = "bundle.js", .contents = output }};
            runner.runGenerateBundle(gen_outputs);
        }

        // Worker 출력 파일을 asset_outputs에 합침
        const final_asset_outputs: ?[]OutputFile = if (worker_output_files.items.len > 0 or asset_outputs != null) blk: {
            const existing = if (asset_outputs) |a| a.len else 0;
            const total = existing + worker_output_files.items.len;
            const merged = try self.allocator.alloc(OutputFile, total);
            if (asset_outputs) |a| {
                @memcpy(merged[0..a.len], a);
                self.allocator.free(a);
            }
            for (worker_output_files.items, 0..) |wf, i| {
                merged[existing + i] = wf;
            }
            break :blk merged;
        } else asset_outputs;

        // 증분 빌드: graph.deinit() 전에 모듈을 store로 이전.
        // putModule이 parse_arena 소유권을 store로 가져가므로
        // graph.deinit()에서 이중 해제가 발생하지 않는다.
        if (self.options.module_store) |store| {
            for (graph.modules.items) |*m| {
                if (m.parse_arena == null) continue; // disabled 등 arena 없는 모듈 스킵
                const mtime = ModuleGraph.getMtime(m.path) catch 0;
                store.putModule(m.path, m, mtime);
            }
        }

        return .{
            .output = output,
            .sourcemap = dev_sourcemap,
            .outputs = outputs,
            .diagnostics = diagnostics,
            .module_paths = module_paths,
            .module_dev_codes = module_dev_codes,
            .asset_outputs = final_asset_outputs,
            .metafile_json = metafile_json,
        };
    }
};

/// metafile JSON을 생성한다 (esbuild 호환 형식).
/// inputs: 각 모듈의 경로, 바이트 수, import 목록
/// outputs: 출력 파일의 경로, 바이트 수, 포함된 입력 모듈
fn generateMetafileJson(
    allocator: std.mem.Allocator,
    graph: *const @import("graph.zig").ModuleGraph,
    single_output: []const u8,
    multi_outputs: ?[]const OutputFile,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"inputs\": {");

    // inputs
    var first_input = true;
    for (graph.modules.items) |m| {
        if (m.path.len == 0) continue;
        if (!first_input) try buf.appendSlice(allocator, ",");
        first_input = false;
        try buf.appendSlice(allocator, "\n    ");
        try appendJsonString(&buf, allocator, m.path);
        try buf.appendSlice(allocator, ": { \"bytes\": ");
        try appendInt(&buf, allocator, m.source.len);
        // imports
        try buf.appendSlice(allocator, ", \"imports\": [");
        var first_imp = true;
        for (m.import_records) |rec| {
            if (rec.is_external) continue;
            if (rec.resolved.isNone()) continue;
            const dep_idx = @intFromEnum(rec.resolved);
            if (dep_idx >= graph.modules.items.len) continue;
            if (!first_imp) try buf.appendSlice(allocator, ", ");
            first_imp = false;
            try buf.appendSlice(allocator, "{ \"path\": ");
            try appendJsonString(&buf, allocator, graph.modules.items[dep_idx].path);
            try buf.appendSlice(allocator, ", \"kind\": ");
            try appendJsonString(&buf, allocator, @tagName(rec.kind));
            try buf.appendSlice(allocator, " }");
        }
        try buf.appendSlice(allocator, "] }");
    }

    try buf.appendSlice(allocator, "\n  },\n  \"outputs\": {");

    // outputs
    if (multi_outputs) |outs| {
        var first_out = true;
        for (outs) |o| {
            if (!first_out) try buf.appendSlice(allocator, ",");
            first_out = false;
            try buf.appendSlice(allocator, "\n    ");
            try appendJsonString(&buf, allocator, o.path);
            try buf.appendSlice(allocator, ": { \"bytes\": ");
            try appendInt(&buf, allocator, o.contents.len);
            try buf.appendSlice(allocator, " }");
        }
    } else if (single_output.len > 0) {
        try buf.appendSlice(allocator, "\n    \"bundle.js\": { \"bytes\": ");
        try appendInt(&buf, allocator, single_output.len);
        try buf.appendSlice(allocator, " }");
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");
    return buf.toOwnedSlice(allocator);
}

fn appendJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn appendInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: usize) !void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
    try buf.appendSlice(allocator, s);
}
