//! ZNTC Bundler — Module Graph
//!
//! 진입점에서 시작하여 모든 의존성을 재귀적으로 탐색하고,
//! DFS 후위 순서로 ESM 실행 순서(exec_index)를 부여한다.
//!
//! 설계:
//!   - D057: 모듈 그래프가 번들러의 기반
//!   - D058: DFS 후위 순서 = ESM 실행 순서
//!   - D065: 순환 참조 감지 (in_stack 배열, Rollup 알고리즘)
//!   - D076: DFS 순회
//!   - D078: 양방향 인접 리스트 (Module.addDependency)
//!   - D079: import_scanner.extractImports로 import 추출
//!
//! 참고:
//!   - references/rollup/src/utils/executionOrder.ts
//!   - references/rolldown/crates/rolldown/src/module_loader/
//!   - references/bun/src/bundler/LinkerContext.zig

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const BundlerDiagnostic = types.BundlerDiagnostic;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const runtime_polyfills = @import("runtime_polyfills.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const ResolveCache = resolve_cache_mod.ResolveCache;
const fs = @import("fs.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const profile = @import("../profile.zig");
const Span = @import("../lexer/token.zig").Span;
const plugin_mod = @import("plugin.zig");
const MpscChannel = @import("mpsc_channel.zig").MpscChannel;
const transformer_mod = @import("../transformer/transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const runtime_helper_modules = @import("../runtime_helper_modules.zig");
pub const module_store = @import("module_store.zig");
const phase_mod = @import("phase.zig");
pub const ModulePhase = phase_mod.ModulePhase;
pub const ParseAccessor = phase_mod.ParseAccessor;
pub const ResolveAccessor = phase_mod.ResolveAccessor;
pub const LinkAccessor = phase_mod.LinkAccessor;
const graph_transform_prepass = @import("graph/transform_prepass.zig");
const graph_project_root = @import("graph/project_root.zig");
const findProjectRoot = graph_project_root.findProjectRoot;
const graph_package_side_effects = @import("graph/package_side_effects.zig");
const graph_parse_helpers = @import("graph/parse_helpers.zig");
const graph_plugins = @import("graph/plugins.zig");
const graph_requested_exports = @import("graph/requested_exports.zig");
const graph_runtime_polyfills = @import("graph/runtime_polyfills.zig");
const graph_state = @import("graph/state.zig");
const graph_parser_metadata = @import("graph/parser_metadata.zig");
const graph_accessors = @import("graph/accessors.zig");
const graph_cycles = @import("graph/cycles.zig");

pub const determineExportsKind = graph_parse_helpers.determineExportsKind;

pub const ModuleGraph = struct {
    pub const matchSideEffectsPatterns = graph_package_side_effects.matchPatterns;
    const configureParserForModule = graph_parse_helpers.configureParserForModule;
    const isFlowPath = graph_parse_helpers.isFlowPath;
    const mergeImportBindings = graph_parse_helpers.mergeImportBindings;
    const mergeImportRecords = graph_parse_helpers.mergeImportRecords;
    const moduleTypeForLoader = graph_parse_helpers.moduleTypeForLoader;
    const suppressRuntimeHelperInternalUnresolved = graph_parse_helpers.suppressRuntimeHelperInternalUnresolved;
    const requestAllExports = graph_requested_exports.requestAll;
    const requestNamedExport = graph_requested_exports.requestNamed;
    pub const shouldLinkResolvedRecordForModule = graph_requested_exports.shouldLinkResolvedRecordForModule;
    pub const hasDeferredRequestedImports = graph_requested_exports.hasDeferredRequestedImports;
    pub const getModule = graph_accessors.getModule;
    pub const moduleCount = graph_accessors.moduleCount;
    pub const findModuleByPath = graph_accessors.findModuleByPath;
    pub const moduleAtMut = graph_accessors.moduleAtMut;
    pub const modulesIterator = graph_accessors.modulesIterator;
    const dfs = graph_cycles.dfs;
    const markCyclesViaDynamic = graph_cycles.markViaDynamic;
    pub const shouldRunTransformerPrePass = graph_transform_prepass.shouldRun;
    pub const runTransformerPrePass = graph_transform_prepass.run;
    pub const resyncModuleMetadataAfterConstMaterialization = graph_transform_prepass.resyncAfterConstMaterialization;
    pub const resyncModuleMetadataAfterAstMutation = graph_transform_prepass.resyncAfterAstMutation;
    const graph_package_info = @import("graph/package_info.zig");
    pub const lookupPkgInfo = graph_package_info.lookupPkgInfo;
    pub const applySideEffectsFromPackageJson = graph_package_info.applySideEffectsFromPackageJson;
    const isPackageTypeModule = graph_package_info.isPackageTypeModule;

    allocator: std.mem.Allocator,
    /// Module storage. SegmentedList 는 append 시에도 기존 포인터를 무효화하지
    /// 않아서 worker race-safety 를 보장한다 (#1779 PR #3). prealloc=0 은 전량
    /// heap chunk — Module 이 수백 바이트라 stack pre-alloc 비효율.
    modules: ModuleList = .{},
    path_to_module: std.StringHashMap(ModuleIndex),
    requested_exports: std.AutoHashMapUnmanaged(u32, RequestedExports) = .{},
    requested_exports_mutex: std.Thread.Mutex = .{},
    diagnostics: std.ArrayList(BundlerDiagnostic),
    owned_diagnostic_strings: std.ArrayList([]const u8) = .empty,
    resolve_cache: *ResolveCache,
    source_read_cache: fs.ReadFileCache = .{},
    /// 병렬 워커에서 diagnostics 접근 보호용 mutex
    diag_mutex: std.Thread.Mutex = .{},

    /// 패키지 단위 package.json 정보 캐시. pkg_dir_path → (is_module, side_effects).
    /// `type: "module"` 과 `sideEffects` 를 **한 번의 pkg.json parse** 로 추출 (#1744).
    /// 키는 module_path 의 substring (graph 수명 동안 유효) — dupe 불필요.
    /// scanWorker 병렬 호출 대응으로 Mutex 보호 + double-check pattern.
    pkg_info_cache: std.StringHashMapUnmanaged(PkgInfo) = .{},
    /// pkg_info_cache 병렬 접근 보호.
    pkg_info_cache_mutex: std.Thread.Mutex = .{},

    // DFS 상태
    exec_counter: u32 = 0,
    cycle_counter: u32 = 0,

    /// dev mode: HMR을 위해 모든 모듈을 강제 래핑 (__esm).
    dev_mode: bool = false,
    /// `output.inlineDynamicImports` 런타임 부분. true 면 dynamic-import target 모듈을
    /// `__esm` 래핑해서 lazy 평가 + 모듈 namespace 동일성 보존. emitter 가 `import("./x")`
    /// 호출을 래퍼 init/exports 호출로 재작성한다.
    inline_dynamic_imports: bool = false,
    /// build-time 정적 평가 entries. parser inline scan (require.context 등 #1579 Phase 2.6) 활용.
    /// bundler 가 BundleOptions.define 으로 설정. transformer 의 define 치환과 동일 entries.
    defines: []const @import("../parser/scan_results.zig").DefineEntry = &.{},
    /// 확장자별 로더 오버라이드 (--loader:.png=file). bundler에서 전달.
    loader_overrides: []const types.LoaderOverride = &.{},
    /// 에셋/청크 URL prefix (--public-path). asset 로더에서 사용.
    public_path: []const u8 = "",
    /// 에셋 파일명 패턴 (--asset-names). asset 로더에서 사용.
    asset_names: []const u8 = "[name]-[hash]",
    /// Metro AssetRegistry 모듈 경로. null이면 URL 문자열, 값이 있으면 registerAsset 래핑.
    asset_registry: ?[]const u8 = null,
    /// 엔트리 포인트 기준 디렉토리. [dir] 패턴 치환에 사용.
    /// entry point들의 공통 부모 디렉토리 (esbuild --outbase에 해당).
    entry_dir: []const u8 = "",
    /// Metro `projectRoot` 호환 — asset httpServerLocation 계산의 기준점.
    /// 미설정 시 build() 호출 중 entry_dir에서 위로 올라가며 첫 package.json
    /// 위치를 자동 감지. RN CLI의 기본 동작과 동일.
    project_root: []const u8 = "",
    /// --inject 파일 목록. build()에서 모든 엔트리의 의존성으로 추가.
    inject_files: []const []const u8 = &.{},
    /// --run-before-main 파일 목록. inject 뒤, 사용자 엔트리 앞에 실행된다.
    run_before_main_files: []const []const u8 = &.{},
    /// JS wrapper가 core-js-compat로 계산한 runtime-polyfill 후보 계획.
    runtime_polyfills: ?runtime_polyfills.Plan = null,
    /// graph usage aggregation 후 실제로 선택된 core-js root paths.
    runtime_polyfill_roots: std.ArrayListUnmanaged([]const u8) = .empty,
    /// --pure:CALLEE 목록. parser AST의 call/new에 기존 pure flag를 부여한다.
    pure: []const []const u8 = &.{},
    /// package.json sideEffects / pure annotation 신호를 무시하고 보수적으로 포함.
    ignore_annotations: bool = false,
    /// 플러그인 배열. bundler에서 전파.
    plugins: []const plugin_mod.Plugin = &.{},
    /// 최대 워커 스레드 수. 0이면 기본값(CPU 코어 수). 1이면 단일 스레드 (플러그인 IPC 디버깅용).
    max_threads: u32 = 0,
    /// Flow 모드 강제 활성화 (--flow). bundler에서 전파.
    flow: bool = false,
    /// .js 파일에서도 JSX 파싱 활성화 (--platform=react-native 프리셋).
    jsx_in_js: bool = false,
    /// JSX 런타임 모드. automatic/automatic-dev이면 jsx-runtime import를 자동 주입.
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    /// JSX import source (--jsx-import-source). 기본: "react".
    jsx_import_source: []const u8 = "react",
    /// JSX runtime specifier 캐시. 모든 모듈에서 동일하므로 한 번만 할당.
    jsx_specifier_cache: ?[]const u8 = null,
    /// Worker 엔트리: new Worker(new URL(...)) 패턴에서 수집된 worker 파일 경로.
    /// 메인 그래프에는 모듈로 추가하지 않고, bundler에서 별도 빌드한다.
    worker_entries: std.ArrayList(WorkerEntry) = .empty,

    /// `worklet "directive"` plugin 활성 여부 — bundler 가 BundleOptions.worklet_transform 으로 set.
    /// graph 가 직접 사용 (parseModule 의 worklet exclude 휴리스틱).
    worklet_transform: bool = false,
    /// RN view config codegen plugin 활성 여부 (#2348). codegen_plugin 의 transform 훅 활성화.
    codegen_transform: bool = false,
    /// React Fast Refresh — dev_mode + user_code 에 transformer 가 등록 코드 주입.
    /// graph 가 직접 사용 (parseModule 의 is_user_code 분기).
    react_refresh: bool = false,
    /// styled-components 1st-party transform — user_code 에 displayName 주입.
    /// react_refresh 와 동일하게 node_modules 는 건드리지 않음 (선언자 이름 수집 무의미).
    styled_components: bool = false,
    /// styled-components.ssr 옵션 — false 면 componentId 생략 (displayName 만).
    styled_components_ssr: bool = true,
    /// styled-components.minify 옵션 — CSS template whitespace collapse.
    styled_components_minify: bool = false,
    /// styled-components.fileName 옵션 — displayName 에 `<basename>__` prefix.
    styled_components_file_name: bool = true,
    /// styled-components.pure 옵션 — `/* @__PURE__ */` annotation (tree-shaking).
    styled_components_pure: bool = false,
    /// styled-components.namespace 옵션 — componentId 에 `<namespace>__` prefix.
    styled_components_namespace: []const u8 = "",
    /// styled-components.meaninglessFileNames 옵션 — displayName fallback basename list.
    styled_components_meaningless_file_names: []const []const u8 = &.{"index"},
    /// styled-components.topLevelImportPaths 옵션 — vendored fork import source list.
    styled_components_top_level_import_paths: []const []const u8 = &.{},
    /// styled-components.cssProp 옵션 — `<div css={...}>` extract (후속 PR 에서 transform 구현).
    styled_components_css_prop: bool = false,
    /// emotion 1st-party transform (compiler.emotion).
    emotion: bool = false,
    /// emotion.autoLabel 모드 — `.never` / `.always` (default) / `.dev_only`.
    emotion_auto_label: @import("../transformer/transformer.zig").AutoLabelMode = .always,
    /// emotion.sourceMap 옵션 — true 면 css 템플릿 끝에 inline sourceMap 주석을 append.
    emotion_source_map: bool = false,
    /// emotion.labelFormat 옵션 — label 이름 포맷 템플릿 (`[local]`/`[filename]`/`[dirname]`).
    emotion_label_format: []const u8 = "",
    /// emotion.importMap re-export 케이스 단순화 — vendored emotion css source list.
    emotion_extra_css_sources: []const []const u8 = &.{},
    /// emotion.importMap re-export 케이스 단순화 — vendored emotion styled source list.
    emotion_extra_styled_sources: []const []const u8 = &.{},
    /// code splitting 활성화. helper module virtual import (#1961) 는 splitting 모드에서만
    /// 활성 — single-bundle 모드는 helper module 의 declaration 이 statement-level shake
    /// 로 elide 되는 회귀가 있어 기존 preamble 모델 유지.
    code_splitting: bool = false,
    /// preserve-modules 활성화. 원본 모듈별 출력 파일 보존이 계약이므로 tree-shaker의
    /// cross-module 축약이 모듈 경계를 제거하지 않도록 한다.
    preserve_modules: bool = false,
    /// identifier mangling 활성화. transformer pre-pass 이후 생성된 임시 binding도
    /// mangler 입력에 포함하려고 transformed AST semantic을 재구축할 때 사용.
    minify_identifiers: bool = false,

    /// transformer pre-pass 의 옵션 base (#1961). bundler 가 init 시 BundleOptions →
    /// TransformOptions 매핑을 1회 채움. parseModule 이 base 를 복사 후 per-module
    /// override (`react_refresh`, `plugins`, `jsx_transform`, `jsx_filename`,
    /// `emit_runtime_helper_imports`) 만 추가하여 transformer.init 호출.
    /// 옵션 추가 시 갱신 site 가 1 곳 (bundler.zig) 으로 좁혀 drift 방지.
    transform_options_base: transformer_mod.TransformOptions = .{},

    /// Runtime helper virtual module plugin (#1961) 의 `SourceOptions`.
    /// graph 가 build() 동안 owner — `Plugin.context` 에서 `*const SourceOptions` 로 참조.
    helper_plugin_opts: runtime_helper_modules.SourceOptions = .{},
    /// `self.plugins` 앞에 ZNTC builtin runtime helper plugin 을 prepend 한 slice.
    /// `graph.allocator` 소유. `ensureBuiltinPlugins` 에서 lazy 초기화 후 PluginRunner.init
    /// 호출 site 들이 이걸 참조.
    plugins_with_helpers: ?[]plugin_mod.Plugin = null,
    /// Hook fast-path gate: 사용자 plugin 이 해당 hook 을 등록하지 않았고 helper virtual id
    /// 도 아니면 PluginRunner 호출 자체를 생략한다. `ensureBuiltinPlugins` 에서 1회 채움.
    has_user_resolve_id_plugins: bool = false,
    has_user_load_plugins: bool = false,
    /// transform 은 user plugin 또는 builtin RN codegen 이 활성이면 실행 — 둘을 합친 게이트.
    has_transform_plugins: bool = false,

    pub const PkgInfo = graph_state.PkgInfo;
    pub const WorkerEntry = graph_state.WorkerEntry;
    const RequestedExports = graph_state.RequestedExports;

    pub fn init(allocator: std.mem.Allocator, resolve_cache: *ResolveCache) ModuleGraph {
        return .{
            .allocator = allocator,
            // modules 는 default (.{}) 로 빈 SegmentedList.
            .path_to_module = std.StringHashMap(ModuleIndex).init(allocator),
            .diagnostics = .empty,
            .resolve_cache = resolve_cache,
        };
    }

    pub fn deinit(self: *ModuleGraph) void {
        var mod_it = self.modules.iterator(0);
        while (mod_it.next()) |m| {
            // import_records, import_bindings, export_bindings는 parse_arena 소유.
            // parse_arena.deinit()이 일괄 해제하므로 명시적 free 불필요.
            m.deinit(self.allocator); // parse_arena.deinit() + dependencies/importers 해제
        }
        self.modules.deinit(self.allocator);
        var key_it = self.path_to_module.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.path_to_module.deinit();
        var req_it = self.requested_exports.valueIterator();
        while (req_it.next()) |req| req.deinit(self.allocator);
        self.requested_exports.deinit(self.allocator);
        var pi_it = self.pkg_info_cache.valueIterator();
        while (pi_it.next()) |info| info.side_effects.deinit(self.allocator);
        self.pkg_info_cache.deinit(self.allocator);
        self.source_read_cache.deinit(self.allocator);
        for (self.owned_diagnostic_strings.items) |s| self.allocator.free(s);
        self.owned_diagnostic_strings.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        for (self.worker_entries.items) |we| {
            self.allocator.free(we.resolved_path);
        }
        self.worker_entries.deinit(self.allocator);
        if (self.jsx_specifier_cache) |s| self.allocator.free(s);
        if (self.plugins_with_helpers) |p| self.allocator.free(p);
        self.runtime_polyfill_roots.deinit(self.allocator);
    }

    const ensureBuiltinPlugins = graph_plugins.ensureBuiltinPlugins;
    pub const pluginRunnerWithBuiltins = graph_plugins.pluginRunnerWithBuiltins;
    pub const shouldRunResolveId = graph_plugins.shouldRunResolveId;
    pub const runPluginLoadForModule = graph_plugins.runLoadForModule;
    pub const runPluginTransformForModule = graph_plugins.runTransformForModule;
    pub const materializeParserMetadata = graph_parser_metadata.materialize;

    // ============================================================
    // Module accessor API (#1779 PR #1a + PR #3)
    //
    // 외부 코드는 `modules` storage 에 직접 접근하지 않고 아래 메서드 사용.
    // SegmentedList 로 교체 (#1779 PR #3) 하면서 append 시에도 기존 *Module
    // 포인터가 유효하게 유지된다 — worker race-safety 의 핵심 불변식.
    //
    // - read 는 누구나: `getModule(idx)` → `?*const Module`
    // - mutate 는 phase-tagged accessor 경유: `parseAccessor()` / `resolveAccessor()` /
    //   `linkAccessor()` (정의는 phase.zig)
    // - `moduleAtMut` 는 accessor 내부 전용. 다른 호출자는 phase accessor 를 쓸 것.
    // ============================================================

    /// Parse phase mutation accessor 발급. parser/scanner worker 가 자기 module 의
    /// AST/semantic/source 등을 write 할 때 사용. 정의는 phase.zig.
    pub inline fn parseAccessor(self: *ModuleGraph) phase_mod.ParseAccessor {
        return .{ .graph = self };
    }

    /// Resolve phase mutation accessor 발급. main thread 의 import 매칭 결과 적용용.
    pub inline fn resolveAccessor(self: *ModuleGraph) phase_mod.ResolveAccessor {
        return .{ .graph = self };
    }

    /// Link phase mutation accessor 발급. DFS exec_index/cycle_group 부여용.
    pub inline fn linkAccessor(self: *ModuleGraph) phase_mod.LinkAccessor {
        return .{ .graph = self };
    }

    /// modules storage. `std.SegmentedList` 대신 `StableSegmentedList` 사용 — 후자가
    /// shelf pointer 배열도 고정 크기라 append 가 절대 pointer 무효화 안 함 (#1779).
    /// `std.SegmentedList` 는 `dynamic_segments` (ArrayListUnmanaged) 가 grow 시 realloc →
    /// worker 가 shelf pointer 읽는 중이면 stale (CI Stress test 에서 재현된 race).
    pub const ModuleList = graph_state.ModuleList;
    pub const ModulesIterator = graph_state.ModulesIterator;

    /// 확장자에 대한 로더를 결정한다.
    /// --loader 오버라이드가 있으면 우선 사용, 없으면 확장자 기본값.
    fn resolveLoader(self: *const ModuleGraph, ext: []const u8) types.ParsedLoader {
        for (self.loader_overrides) |override| {
            if (std.mem.eql(u8, override.ext, ext)) {
                return .{ .loader = override.loader, .module_type = override.module_type };
            }
        }
        return types.ParsedLoader.fromExtension(ext);
    }

    /// 진입점들로부터 모듈 그래프를 구축한다.
    /// Phase 1: 모든 모듈 등록 + 파싱 + import resolve (BFS)
    /// Phase 2: DFS로 exec_index + 순환 감지
    pub fn build(self: *ModuleGraph, entry_points: []const []const u8) !void {
        // #1961: ZNTC builtin runtime helper plugin 을 plugin slice 앞에 prepend.
        // 워커 스레드에서 호출하기 전 단일 thread 진입점에서 1회만.
        self.ensureBuiltinPlugins();

        // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용)
        if (self.entry_dir.len == 0 and entry_points.len > 0) {
            self.entry_dir = std.fs.path.dirname(entry_points[0]) orelse "";
        }
        // project_root 자동 감지 (미지정 시): entry_dir에서 위로 올라가며 첫 package.json
        if (self.project_root.len == 0 and self.entry_dir.len > 0) {
            self.project_root = findProjectRoot(self.allocator, self.entry_dir) catch self.entry_dir;
        }

        // --inject 파일을 먼저 모듈 그래프에 추가
        var inject_indices: std.ArrayList(types.ModuleIndex) = .empty;
        defer inject_indices.deinit(self.allocator);
        for (self.inject_files) |inject_path| {
            const idx = try self.addModule(inject_path);
            _ = try self.requestAllExports(idx);
            try inject_indices.append(self.allocator, idx);
        }

        // --run-before-main 파일도 graph root 로 먼저 등록하되, 엔트리 연결은
        // runtime-polyfill root 선별 이후에 수행한다.
        var run_before_main_indices: std.ArrayList(types.ModuleIndex) = .empty;
        defer run_before_main_indices.deinit(self.allocator);
        for (self.run_before_main_files) |rbm_path| {
            const idx = try self.addModule(rbm_path);
            _ = try self.requestAllExports(idx);
            try run_before_main_indices.append(self.allocator, idx);
        }

        // Phase 1: 이벤트 큐 기반 스캔 (esbuild 스타일).
        // 워커: parseModule + resolve → 채널 send (그래프 변형 없음)
        // 메인: 채널 recv → 결과 적용 + addModule → 즉시 새 워커 스폰
        // 배치 경계 없이 모듈 발견 즉시 파싱 시작 → CPU 유휴 시간 최소화.
        var discover_scope = profile.begin(.graph_discover);
        for (entry_points) |entry_path| {
            const idx = try self.addModule(entry_path);
            _ = try self.requestAllExports(idx);
        }

        var spawned_up_to: usize = 0;
        if (self.max_threads == 0 and self.modules.count() == 1) {
            // Tiny graphs spend more time opening the pool/channel than scanning the first batch.
            // Keep the initial bounded batch on the main thread, then fall back to the pool if it
            // discovers more work.
            spawned_up_to = try self.scanModuleRangeSequential(0, 1);
            const pending_after_entry = self.modules.count() - spawned_up_to;
            if (pending_after_entry > 0 and pending_after_entry <= 16) {
                spawned_up_to = try self.scanModuleRangeSequential(spawned_up_to, self.modules.count());
            }
        }

        if (spawned_up_to < self.modules.count()) {
            var pool: std.Thread.Pool = undefined;
            const pool_opts: std.Thread.Pool.Options = if (self.max_threads > 0)
                .{ .allocator = self.allocator, .n_jobs = self.max_threads }
            else
                .{ .allocator = self.allocator };
            const pool_ok = if (pool.init(pool_opts)) |_| true else |_| false;
            defer if (pool_ok) pool.deinit();

            if (!pool_ok) {
                try self.discoverPendingModulesSequential(spawned_up_to);
            } else {
                var channel = MpscChannel(ScanResult).init(self.allocator);
                defer channel.deinit();

                var inflight: usize = 0;

                // Spawn the initial modules: entries, inject files, and run-before-main files.
                while (spawned_up_to < self.modules.count()) : (spawned_up_to += 1) {
                    const m = self.modules.at(spawned_up_to);
                    if (m.state == .ready) continue; // Skip disabled modules.
                    const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                    pool.spawn(scanWorker, .{ self, idx, &channel }) catch {
                        // Fall back to the main thread if the pool cannot spawn this job.
                        scanWorker(self, idx, &channel);
                    };
                    inflight += 1;
                }

                // Apply each worker result, then immediately dispatch newly discovered modules.
                while (inflight > 0) {
                    const result = channel.recv();
                    inflight -= 1;
                    try self.applyScanResult(result);

                    // Dispatch newly discovered modules without waiting for a batch boundary.
                    while (spawned_up_to < self.modules.count()) : (spawned_up_to += 1) {
                        const m = self.modules.at(spawned_up_to);
                        if (m.state == .ready) continue;
                        const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                        pool.spawn(scanWorker, .{ self, idx, &channel }) catch {
                            scanWorker(self, idx, &channel);
                        };
                        inflight += 1;
                    }
                }
            }
        }

        var runtime_indices: std.ArrayList(types.ModuleIndex) = .empty;
        defer runtime_indices.deinit(self.allocator);
        try self.applyRuntimePolyfills(&runtime_indices);
        try self.linkExecutionRoots(entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);
        discover_scope.end();

        try self.finalizeGraph(entry_points);
    }

    fn applyRuntimePolyfills(self: *ModuleGraph, runtime_indices: *std.ArrayList(ModuleIndex)) !void {
        const plan = self.runtime_polyfills orelse return;

        var scope = profile.begin(.graph_runtime_polyfills);
        defer scope.end();

        var selected: std.ArrayList(runtime_polyfills.ResolvedModule) = .empty;
        defer selected.deinit(self.allocator);
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        switch (plan.mode) {
            .entry => {
                var aggregate_scope = profile.begin(.graph_runtime_polyfills_aggregate);
                defer aggregate_scope.end();
                for (plan.entry_modules) |module| {
                    try graph_runtime_polyfills.selectModule(self.allocator, &selected, &seen, plan, module, "entry");
                }
            },
            .usage => {
                var used: runtime_polyfills.FeatureSet = .{};
                defer used.deinit(self.allocator);
                {
                    var aggregate_scope = profile.begin(.graph_runtime_polyfills_aggregate);
                    defer aggregate_scope.end();
                    const count = self.modules.count();
                    for (0..count) |i| {
                        const m = self.modules.at(i);
                        var collect_scope = profile.begin(.graph_runtime_polyfills_collect);
                        var module_usage = try runtime_polyfills.collectModuleUsage(self.allocator, m);
                        defer module_usage.deinit(self.allocator);
                        collect_scope.end();
                        if (!module_usage.isEmpty()) graph_runtime_polyfills.logUsage(m.path, module_usage);
                        try used.merge(self.allocator, module_usage);
                    }
                }
                for (plan.candidates) |candidate| {
                    const module: runtime_polyfills.ResolvedModule = .{
                        .module = candidate.module,
                        .path = candidate.path,
                    };
                    if (used.has(candidate.feature)) {
                        try graph_runtime_polyfills.selectModule(self.allocator, &selected, &seen, plan, module, candidate.feature);
                    } else {
                        graph_runtime_polyfills.logUnusedCandidate(candidate);
                    }
                }
            },
        }

        for (plan.include) |module| {
            try graph_runtime_polyfills.selectModule(self.allocator, &selected, &seen, plan, module, "include");
        }

        if (selected.items.len == 0) return;

        var inject_scope = profile.begin(.graph_runtime_polyfills_inject);
        defer inject_scope.end();
        const discover_start = self.modules.count();
        for (selected.items) |module| {
            const idx = try self.addModule(module.path);
            _ = try self.requestAllExports(idx);
            if (self.moduleAtMut(idx)) |m| {
                m.is_context_dep = true;
            }
            try runtime_indices.append(self.allocator, idx);
            try self.runtime_polyfill_roots.append(self.allocator, module.path);
            graph_runtime_polyfills.logPrelude(plan, module);
        }
        try self.discoverPendingModulesSequential(discover_start);
    }

    fn discoverPendingModulesSequential(self: *ModuleGraph, start_index: usize) !void {
        var parse_start = start_index;
        while (parse_start < self.modules.count()) {
            const parse_end = self.modules.count();
            for (parse_start..parse_end) |j| {
                const m = self.modules.at(j);
                if (m.state == .ready) continue;
                self.parseModule(@enumFromInt(@as(u32, @intCast(j))));
            }
            for (parse_start..parse_end) |i| {
                const m_ptr = self.modules.at(i);
                if (m_ptr.state == .ready) continue;
                self.applySideEffectsFromPackageJson(m_ptr);
                m_ptr.state = .ready;
            }
            for (parse_start..parse_end) |i| {
                const m_ptr = self.modules.at(i);
                if (m_ptr.is_disabled or m_ptr.is_external) continue;
                try self.resolveModuleImports(@enumFromInt(@as(u32, @intCast(i))));
                try self.applyContextDepResults(i);
            }
            parse_start = parse_end;
        }
    }

    fn linkExecutionRoots(
        self: *ModuleGraph,
        entry_points: []const []const u8,
        inject_indices: []const ModuleIndex,
        runtime_indices: []const ModuleIndex,
        run_before_main_indices: []const ModuleIndex,
    ) !void {
        if (inject_indices.len == 0 and runtime_indices.len == 0 and run_before_main_indices.len == 0) return;
        for (entry_points) |entry_path| {
            const entry_idx = self.path_to_module.get(entry_path) orelse continue;
            const ei = @intFromEnum(entry_idx);
            if (ei >= self.modules.count()) continue;
            for (inject_indices) |inject_idx| try self.linkDependencyUnique(entry_idx, inject_idx);
            for (runtime_indices) |runtime_idx| try self.linkDependencyUnique(entry_idx, runtime_idx);
            for (run_before_main_indices) |rbm_idx| try self.linkDependencyUnique(entry_idx, rbm_idx);
        }
    }

    fn linkDependencyUnique(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void {
        if (to.isNone()) return;
        const from_mod = self.getModule(from) orelse return;
        for (from_mod.dependencies.items) |existing| {
            if (existing == to) return;
        }
        try self.linkDependency(from, to);
    }

    pub fn discardResolvedModule(self: *ModuleGraph, resolved: plugin_mod.ResolvedModule) void {
        switch (resolved) {
            .file => |f| self.allocator.free(f.path),
            .disabled => |d| self.allocator.free(d.path),
            .virtual, .dataurl, .external, .custom => {},
        }
    }

    pub fn markRecordLazyResolved(self: *ModuleGraph, mod_idx: usize, rec_i: usize) void {
        if (mod_idx >= self.modules.count()) return;
        const m = self.modules.at(mod_idx);
        if (rec_i >= m.import_records.len) return;
        m.import_records[rec_i].is_lazy_resolved = true;
    }

    /// Phase 2-4: DFS exec_index + ExportsKind 승격 + TLA 전파.
    /// build()와 buildIncremental() 양쪽에서 호출.
    fn finalizeGraph(self: *ModuleGraph, entry_points: []const []const u8) !void {
        var scope = profile.begin(.graph_finalize);
        defer scope.end();

        const count = self.modules.count();
        if (count == 0) return;

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer visited.deinit();
        var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer in_stack.deinit();

        var entry_indices: std.ArrayList(ModuleIndex) = .empty;
        defer entry_indices.deinit(self.allocator);
        for (entry_points) |entry_path| {
            if (self.path_to_module.get(entry_path)) |idx| {
                const ei = @intFromEnum(idx);
                if (ei < self.modules.count()) {
                    self.modules.at(ei).is_entry_point = true;
                }
                try self.dfs(idx, &visited, &in_stack);
                try entry_indices.append(self.allocator, idx);
            }
        }

        // dfs 는 dependencies 만 따라가서 exec_index/TLA 분석 정확. dynamic edge 통한
        // static cycle 멤버 marking 은 별도 pass (#2211).
        try self.markCyclesViaDynamic(entry_indices.items);

        self.promoteExportsKinds();
        self.promoteRunBeforeMainModules();
        self.registerWrapperSymbols();
        self.propagateTopLevelAwait();
        self.checkSelfReExport();
    }

    /// Self-cycle named re-export 진단. alias/onResolve가 source를 자기 자신으로
    /// redirect하면 emit이 `exports_self.X` 자기 참조 getter를 생성해 평가 시 무한
    /// 재귀. rolldown CIRCULAR_REEXPORT처럼 빌드 단계에서 거부. default re-export는
    /// 별도 경로에서 이미 안전 처리되므로 제외.
    fn checkSelfReExport(self: *ModuleGraph) void {
        var it = self.modules.iterator(0);
        var i: usize = 0;
        while (it.next()) |m| : (i += 1) {
            const self_idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
            for (m.export_bindings) |eb| {
                if (eb.kind != .re_export) continue;
                if (std.mem.eql(u8, eb.exported_name, "default")) continue;
                const rec_idx = eb.import_record_index orelse continue;
                if (rec_idx >= m.import_records.len) continue;
                if (m.import_records[rec_idx].resolved != self_idx) continue;
                self.addDiag(
                    .circular_reexport,
                    .@"error",
                    m.path,
                    eb.local_span,
                    .link,
                    "Re-export source resolves to the module itself (self-cycle)",
                    "Check resolver alias / plugin onResolve — the import source must point to a different module.",
                );
            }
        }
    }

    /// 증분 빌드 결과.
    pub const IncrementalBuildResult = struct {
        /// 그래프 구조 또는 내용이 변경되었는지
        graph_changed: bool,
        /// 재파싱된 모듈 인덱스 목록 (graph allocator 소유)
        reparsed_indices: []const types.ModuleIndex,
    };

    /// 증분 그래프 빌드. store에서 캐시 히트된 모듈은 파싱 스킵.
    /// 캐시 미스된 모듈만 parseModule()을 실행한다.
    /// build()와 동일한 Phase 2~4를 실행하여 exec_index, ExportsKind, TLA를 보장.
    pub fn buildIncremental(
        self: *ModuleGraph,
        entry_points: []const []const u8,
        store: *module_store.PersistentModuleStore,
        /// Watcher 가 이번 rebuild 동안 변경됐다고 보고한 절대경로 set.
        /// null → 현재 변경 정보 없음 (initial build / CLI 모드). 전체 모듈 stat.
        /// non-null → set 에 없는 path 는 mtime stat 을 skip 하고 store 의 cached mtime 을 그대로 신뢰.
        /// 새로 그래프에 추가된 모듈 (`store.modules.contains(path) == false`) 은 강제로 stat (Issue #1727 §3).
        changed_files: ?*const std.StringHashMap(void),
    ) !IncrementalBuildResult {
        // #1961: builtin runtime helper plugin prepend (build() 와 동일).
        self.ensureBuiltinPlugins();

        // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용)
        if (self.entry_dir.len == 0 and entry_points.len > 0) {
            self.entry_dir = std.fs.path.dirname(entry_points[0]) orelse "";
        }
        if (self.project_root.len == 0 and self.entry_dir.len > 0) {
            self.project_root = findProjectRoot(self.allocator, self.entry_dir) catch self.entry_dir;
        }

        // --inject 파일을 먼저 모듈 그래프에 추가
        var inject_indices: std.ArrayList(types.ModuleIndex) = .empty;
        defer inject_indices.deinit(self.allocator);
        for (self.inject_files) |inject_path| {
            const idx = try self.addModule(inject_path);
            _ = try self.requestAllExports(idx);
            try inject_indices.append(self.allocator, idx);
        }

        var run_before_main_indices: std.ArrayList(types.ModuleIndex) = .empty;
        defer run_before_main_indices.deinit(self.allocator);
        for (self.run_before_main_files) |rbm_path| {
            const idx = try self.addModule(rbm_path);
            _ = try self.requestAllExports(idx);
            try run_before_main_indices.append(self.allocator, idx);
        }

        for (entry_points) |entry_path| {
            const idx = try self.addModule(entry_path);
            _ = try self.requestAllExports(idx);
        }

        var reparsed: std.ArrayListUnmanaged(types.ModuleIndex) = .empty;
        var graph_changed = false;
        var cache_hit_modules = std.AutoHashMap(u32, void).init(self.allocator);
        defer cache_hit_modules.deinit();

        var discover_scope = profile.begin(.graph_discover);

        // 순차 처리 — 증분 빌드는 캐시 히트가 대부분이므로 스레드 풀 오버헤드보다 효율적.
        var parse_start: usize = 0;
        while (parse_start < self.modules.count()) {
            const parse_end = self.modules.count();
            for (parse_start..parse_end) |i| {
                var mod = self.modules.at(i);
                if (mod.state == .ready) continue; // disabled 모듈 등

                const mod_path = mod.path;

                // Watcher-driven mtime skip (Issue #1727 §3): watcher 가 이 파일을 건드리지
                // 않았다고 보고했고 cache 에도 있으면 stat syscall 을 생략하고 cached mtime 을
                // 그대로 쓴다. 수백 모듈 × ~100us stat 이 주 병목이었음. changed_files 가 null
                // 이거나 cache miss 인 경로는 기존처럼 stat.
                const mtime: i128 = blk: {
                    if (changed_files) |cf| {
                        if (!cf.contains(mod_path)) {
                            if (store.modules.get(mod_path)) |cached_entry| {
                                break :blk cached_entry.mtime;
                            }
                        }
                    }
                    break :blk getMtime(mod_path) catch 0;
                };

                // 캐시 조회
                if (store.getIfFresh(mod_path, mtime)) |cached| {
                    // 캐시 히트: struct assign으로 전체 복원 후 graph-specific 필드만 override.
                    // Module에 새 필드가 추가되어도 누락 없이 복사됨.
                    const saved_index = mod.index;
                    const saved_path = mod.path;
                    const saved_deps = mod.dependencies;
                    const saved_importers = mod.importers;
                    const saved_dynamic = mod.dynamic_imports;
                    const saved_dynamic_importers = mod.dynamic_importers;
                    mod.* = cached.module;
                    mod.index = saved_index;
                    mod.path = saved_path;
                    mod.dependencies = saved_deps;
                    mod.importers = saved_importers;
                    mod.dynamic_imports = saved_dynamic;
                    mod.dynamic_importers = saved_dynamic_importers;
                    mod.mtime = mtime;
                    try cache_hit_modules.put(@intCast(i), {});
                    // parse_arena 소유권 이전: store → graph.
                    cached.module.parse_arena = null;
                    cached.module.import_records = &.{};
                    cached.module.resolved_deps = .empty;
                    // alias_table 도 동일 패턴: 얕은 복사로 인해 backing 이
                    // graph 와 store 에 동시에 잡혀있어 graph.deinit 에서 free 되면
                    // store 쪽 포인터가 dangling — 다음 rebuild 가 그 메모리를
                    // nested_name_sets HashMap backing 으로 재사용하면
                    // setCanonicalName 의 write 가 Header 를 덮어써 deinit 시
                    // malloc abort. ownership 을 graph 로 이전해 graph.deinit
                    // 한 번만 free 되도록 한다.
                    cached.module.alias_table = null;
                    // canonical_name 은 이전 Build 의 Linker 가 소유한 문자열을
                    // 가리키는데, 그 Linker.deinit 이후 이미 freed 상태다.
                    // 다음 Linker 가 conflict 마다 새로 assign 하므로 stale 한
                    // 포인터를 비워 emit 이 freed memory 를 읽지 못하도록 한다.
                    if (mod.semantic) |*sem| {
                        for (sem.symbols.items) |*sym| sym.canonical_name = "";
                    }
                    mod.state = .ready;
                } else {
                    // 캐시 미스: 정상 파싱
                    self.parseModule(@enumFromInt(@as(u32, @intCast(i))));
                    const m_ptr = self.modules.at(i);
                    self.applySideEffectsFromPackageJson(m_ptr);
                    m_ptr.mtime = mtime;
                    m_ptr.state = .ready;
                    try reparsed.append(self.allocator, @enumFromInt(@as(u32, @intCast(i))));
                }
            }

            // resolve + addModule (새 의존성 등록)
            for (parse_start..parse_end) |i| {
                if (cache_hit_modules.contains(@intCast(i))) {
                    try self.replayCachedResolvedDeps(i);
                    try self.resolveDeferredRequestedImportsIfReady(ModuleIndex.fromUsize(i));
                } else {
                    try self.resolveModuleImports(@enumFromInt(@as(u32, @intCast(i))));
                }
            }

            // 새 모듈이 추가되었으면 그래프 변경
            if (self.modules.count() > parse_end) {
                graph_changed = true;
            }
            parse_start = parse_end;
        }

        var runtime_indices: std.ArrayList(types.ModuleIndex) = .empty;
        defer runtime_indices.deinit(self.allocator);
        const before_runtime_count = self.modules.count();
        try self.applyRuntimePolyfills(&runtime_indices);
        if (self.modules.count() > before_runtime_count) graph_changed = true;
        try self.linkExecutionRoots(entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);

        discover_scope.end();

        try self.finalizeGraph(entry_points);

        return .{
            .graph_changed = graph_changed or reparsed.items.len > 0,
            .reparsed_indices = try reparsed.toOwnedSlice(self.allocator),
        };
    }

    /// 파일의 mtime 을 나노초로 반환. virtual module / embedded null byte / overlong
    /// path 는 error 로 폴백해 호출부가 `catch 0` 으로 처리하도록 한다.
    ///
    /// `std.fs.Dir.statFile` 은 내부에서 `toPosixPath` 를 거치는데, 그 함수가
    /// `runtime_safety` (Debug / ReleaseSafe) 빌드에서 path 내 null byte 존재 시
    /// `assert(indexOfScalar == null)` 로 panic (reached unreachable code) 한다.
    /// plugin 이 합성한 virtual path, AssetRegistry 등 에서 실제로 이런 path 가 들어와
    /// HMR rebuild 중 번들러가 통째로 죽던 버그를 막는다.
    pub fn getMtime(path: []const u8) !i128 {
        if (path.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
        if (path.len >= std.fs.max_path_bytes) return error.NameTooLong;
        const stat = try fs.statFile(path);
        return stat.mtime;
    }

    /// 모듈을 그래프에 추가하고 파싱한다.
    /// 이미 존재하면 기존 인덱스를 반환.
    pub fn addModule(self: *ModuleGraph, abs_path: []const u8) !ModuleIndex {
        // 중복 체크
        if (self.path_to_module.get(abs_path)) |existing| {
            return existing;
        }

        // 새 모듈 슬롯 할당
        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.count())));
        const path_owned = try self.allocator.dupe(u8, abs_path);

        var module = Module.init(index, path_owned);
        const ext = std.fs.path.extension(abs_path);
        module.module_type = ModuleType.fromExtension(ext);
        // 로더 결정: --loader 오버라이드 → 확장자 기본값
        const parsed_loader = self.resolveLoader(ext);
        module.loader = parsed_loader.loader;
        module.module_type = parsed_loader.module_type orelse moduleTypeForLoader(module.module_type, module.loader);
        try self.modules.append(self.allocator, module);
        try self.path_to_module.put(path_owned, index);

        // 파싱은 build()의 배치 루프에서 수행
        return index;
    }

    /// platform=browser에서 Node 빌트인 모듈을 빈 CJS 모듈로 등록 (esbuild "(disabled)" 방식).
    /// AST 없이 wrap_kind=.cjs, is_disabled=true로 설정.
    /// DFS가 이 모듈을 방문하여 exec_index를 부여하고, emitter가 빈 __commonJS wrapper를 출력.
    pub fn addDisabledModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
        // 가상 경로: "(disabled):specifier" (esbuild 형식).
        // specifier 기준으로 중복 체크 — 여러 모듈이 같은 빌트인을 require해도 하나만 생성.
        const disabled_path = try std.mem.concat(self.allocator, u8, &.{ "(disabled):", specifier });

        // 중복 체크
        if (self.path_to_module.get(disabled_path)) |existing| {
            self.allocator.free(disabled_path);
            return existing;
        }

        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.count())));
        var module = Module.init(index, disabled_path);
        module.module_type = .js;
        module.exports_kind = .commonjs;
        module.wrap_kind = .cjs;
        module.is_disabled = true;
        module.side_effects = false;
        module.state = .ready;
        try self.modules.append(self.allocator, module);
        try self.path_to_module.put(disabled_path, index);

        return index;
    }

    /// `external` 패턴 매칭된 specifier 를 phantom Module 로 graph 에 등록.
    /// 같은 specifier 의 여러 import 는 한 Module 을 공유 — Rollup `getModuleInfo("react")`
    /// 동일 식별자 의미. AST/source 없음, chunk/emit/tree-shake 에선 별도 가드로 제외.
    pub fn addExternalModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
        if (self.path_to_module.get(specifier)) |existing| return existing;

        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.count())));
        const path_owned = try self.allocator.dupe(u8, specifier);
        var module = Module.init(index, path_owned);
        module.is_external = true;
        module.module_type = .js;
        module.exports_kind = .esm;
        module.side_effects = true;
        module.state = .ready;
        try self.modules.append(self.allocator, module);
        try self.path_to_module.put(path_owned, index);
        return index;
    }

    /// 양방향 의존성 등록. from → to (dependencies) + to → from (importers) 를 동시에 append.
    /// graph 가 양방향 관계 책임을 캡슐화. storage 가 SegmentedList 로 바뀌어도 caller 영향 없음.
    pub fn linkDependency(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void {
        if (to.isNone()) return;
        const from_mod = self.moduleAtMut(from) orelse return;
        const to_mod = self.moduleAtMut(to) orelse return;
        try from_mod.dependencies.append(self.allocator, to);
        try to_mod.importers.append(self.allocator, from);
    }

    /// 양방향 dynamic import 등록. `linkDependency` 의 dynamic 버전.
    pub fn linkDynamicImport(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void {
        if (to.isNone()) return;
        const from_mod = self.moduleAtMut(from) orelse return;
        const to_mod = self.moduleAtMut(to) orelse return;
        try from_mod.dynamic_imports.append(self.allocator, to);
        try to_mod.dynamic_importers.append(self.allocator, from);
    }

    // Import resolution and resolved dependency application — graph/resolve_imports.zig로 위임
    const graph_resolve_imports = @import("graph/resolve_imports.zig");
    const resolveDeferredRequestedImportsIfReady = graph_resolve_imports.resolveDeferredRequestedImportsIfReady;
    const replayCachedResolvedDeps = graph_resolve_imports.replayCachedResolvedDeps;
    pub const applyContextDepResults = graph_resolve_imports.applyContextDepResults;
    pub const applyResolveResult = graph_resolve_imports.applyResolveResult;
    pub const resolveModuleImports = graph_resolve_imports.resolveModuleImports;

    // Discovery scan workers — graph/discovery_scan.zig로 위임
    const graph_discovery_scan = @import("graph/discovery_scan.zig");
    const ResolveOutput = graph_discovery_scan.ResolveOutput;
    const ScanResult = graph_discovery_scan.ScanResult;
    const scanWorker = graph_discovery_scan.scanWorker;
    const scanModuleRangeSequential = graph_discovery_scan.scanModuleRangeSequential;
    pub const applyScanResult = graph_discovery_scan.applyScanResult;
    pub const scanModule = graph_discovery_scan.scanModule;

    // Module parsing pipeline — graph/parse_module.zig로 위임
    const graph_parse_module = @import("graph/parse_module.zig");
    pub const parseModule = graph_parse_module.parseModule;

    // ============================================================
    // Final graph promotion/wrapping passes — graph/finalize.zig로 위임
    // ============================================================
    const graph_finalize = @import("graph/finalize.zig");
    const promoteExportsKinds = graph_finalize.promoteExportsKinds;
    const promoteRunBeforeMainModules = graph_finalize.promoteRunBeforeMainModules;
    const registerWrapperSymbols = graph_finalize.registerWrapperSymbols;
    const propagateTopLevelAwait = graph_finalize.propagateTopLevelAwait;

    // Loader/source helpers — graph/loaders.zig로 위임
    const graph_loaders = @import("graph/loaders.zig");
    pub const parseCssModule = graph_loaders.parseCssModule;
    pub const parseAssetModule = graph_loaders.parseAssetModule;
    pub const readModuleSourceWithMtime = graph_loaders.readModuleSourceWithMtime;
    const graph_json_module = @import("graph/json_module.zig");
    pub const parseJsonModule = graph_json_module.parse;
    const graph_parser_setup = @import("graph/parser_setup.zig");
    pub const initParserForModule = graph_parser_setup.init;

    // Diagnostics helpers — graph/diagnostics.zig로 위임
    const graph_diagnostics = @import("graph/diagnostics.zig");
    pub const addDiag = graph_diagnostics.addDiag;
    pub const addPluginFailureDiag = graph_diagnostics.addPluginFailureDiag;
    const validatePluginSourceMaps = graph_diagnostics.validatePluginSourceMaps;
};

const test_helpers = @import("test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

const PrePassPredicateTestOptions = struct {
    transform_options: TransformOptions = .{},
    plugin_transform_applied: bool = false,
    react_refresh: bool = false,
    styled_components: bool = false,
    emotion: bool = false,
    worklet_transform: bool = false,
    minify_identifiers: bool = false,
};

fn shouldRunPrePassForTest(
    source: []const u8,
    path: []const u8,
    opts: PrePassPredicateTestOptions,
) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const source_copy = try arena_alloc.dupe(u8, source);
    var scanner = try Scanner.init(arena_alloc, source_copy);
    var parser = Parser.init(arena_alloc, &scanner);
    var module = Module.init(@enumFromInt(0), path);
    module.module_type = ModuleType.fromExtension(std.fs.path.extension(path));
    module.loader = .javascript;
    module.source = source_copy;
    ModuleGraph.configureParserForModule(&parser, &module, std.fs.path.extension(path));
    parser.is_module = true;
    scanner.is_module = true;
    parser.enable_scan = true;
    _ = try parser.parse();

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.transform_options_base = opts.transform_options;
    graph.react_refresh = opts.react_refresh;
    graph.styled_components = opts.styled_components;
    graph.emotion = opts.emotion;
    graph.worklet_transform = opts.worklet_transform;
    graph.minify_identifiers = opts.minify_identifiers;

    module.ast = parser.ast;
    return graph.shouldRunTransformerPrePass(&module, opts.plugin_transform_applied);
}

fn expectPrePassDecision(
    expected: bool,
    source: []const u8,
    path: []const u8,
    opts: PrePassPredicateTestOptions,
) !void {
    try std.testing.expectEqual(expected, try shouldRunPrePassForTest(source, path, opts));
}

fn expectAllBuiltModulesSkipPrePass(file_count: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var i: usize = 0;
    while (i < file_count) : (i += 1) {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "m{d}.ts", .{i});
        defer std.testing.allocator.free(file_name);
        const source = if (i + 1 < file_count)
            try std.fmt.allocPrint(std.testing.allocator, "import {{ v as next }} from './m{d}'; export const v: number = next + 1;", .{i + 1})
        else
            try std.fmt.allocPrint(std.testing.allocator, "export const v: number = {d};", .{i});
        defer std.testing.allocator.free(source);
        try writeFile(tmp.dir, file_name, source);
    }

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "m0.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});
    try std.testing.expectEqual(file_count, graph.moduleCount());
    var it = graph.modulesIterator();
    while (it.next()) |module| {
        try std.testing.expect(module.transform_cache == null);
    }
}

test "graph pre-pass predicate: simple ESM and TS strip modules can skip" {
    try expectPrePassDecision(false, "import { value } from './dep'; export const answer: number = value + 1;", "entry.ts", .{});
    try expectPrePassDecision(false, "interface Shape { x: number }\ntype Id<T> = T;\nexport const value: Id<number> = 1;", "types.ts", .{});
    try expectPrePassDecision(false, "import type { User } from './types'; import { value } from './dep'; export type { User }; export { value };", "mixed.ts", .{});
    try expectPrePassDecision(false, "export { value } from './dep'; export * from './other';", "barrel.ts", .{});
    try expectPrePassDecision(false, "export const value: number = 1;", "target-es5-simple.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(false, "export const double = (value: number) => value * 2;", "target-es5-arrow.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
}

test "graph pre-pass predicate: synthetic no-op graphs skip every eligible module" {
    try expectAllBuiltModulesSkipPrePass(50);
    try expectAllBuiltModulesSkipPrePass(200);
}

test "graph pre-pass predicate: syntax and options that mutate graph-visible surface keep pre-pass" {
    try expectPrePassDecision(true, "export const App = () => <div />;", "view.tsx", .{});
    try expectPrePassDecision(true, "@sealed class Foo {}", "decorator.ts", .{ .transform_options = .{ .experimental_decorators = true } });
    try expectPrePassDecision(true, "enum Kind { A, B } export const k = Kind.A;", "enum.ts", .{});
    try expectPrePassDecision(true, "namespace N { export const x = 1 } export const y = N.x;", "namespace.ts", .{});
    try expectPrePassDecision(true, "import Foo = require('foo'); export = Foo;", "import-equals.ts", .{});
    try expectPrePassDecision(true, "export const run = async () => await value;", "downlevel.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export async function* g() { yield 1; await Promise.resolve(); }", "async-generator.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export function* ids() { yield 1; }", "generator.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export const xs = [...items];", "spread.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "for (const item of items) console.log(item);", "for-of.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export class Child extends Parent {}", "class.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "class Foo { #x = 1; field = this.#x; }", "private.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es2021) } });
    try expectPrePassDecision(true, "console.log(__DEV__); debugger;", "minify-define-drop.ts", .{ .transform_options = .{ .minify_syntax = true } });
    try expectPrePassDecision(false, "export const value = 1;", "unused-define.ts", .{ .transform_options = .{ .define = &.{.{ .key = "__DEV__", .value = "false" }} } });
    try expectPrePassDecision(false, "export const env = 'local';", "unused-member-define.ts", .{ .transform_options = .{ .define = &.{.{ .key = "process.env.NODE_ENV", .value = "\"production\"" }} } });
    try expectPrePassDecision(true, "console.log(__DEV__);", "define.ts", .{ .transform_options = .{ .define = &.{.{ .key = "__DEV__", .value = "false" }} } });
    try expectPrePassDecision(true, "console.log(globalThis.process?.env?.NODE_ENV);", "define-optional.ts", .{ .transform_options = .{ .define = &.{.{ .key = "process.env.NODE_ENV", .value = "\"production\"" }} } });
    try expectPrePassDecision(true, "console.log('x'); debugger;", "drop.ts", .{ .transform_options = .{ .drop_console = true, .drop_debugger = true } });
    try expectPrePassDecision(true, "export const value = 1;", "plugin.ts", .{ .plugin_transform_applied = true });
    try expectPrePassDecision(true, "export function App() { return null; }", "refresh.tsx", .{ .react_refresh = true });
    try expectPrePassDecision(true, "import styled from 'styled-components'; export const Box = styled.div``;", "styled.ts", .{ .styled_components = true });
    try expectPrePassDecision(true, "import { css } from '@emotion/react'; export const c = css``;", "emotion.ts", .{ .emotion = true });
    try expectPrePassDecision(true, "export function f() { 'worklet'; return 1; }", "worklet.ts", .{ .worklet_transform = true });
}

// Regression: `toPosixPath` 가 Debug/ReleaseSafe 빌드에서 null byte path 를
// `reached unreachable code` 로 panic 시키던 걸 `getMtime` 이 error 로
// 폴백하도록 만든 가드. plugin 합성 virtual path / AssetRegistry / 빈 경로
// 등이 실제로 putModule loop 을 타고 들어와 서버가 통째로 죽던 사례 (#1682).
test "getMtime: reject null-byte / empty / overlong path" {
    try std.testing.expectError(error.InvalidPath, ModuleGraph.getMtime(""));
    try std.testing.expectError(error.InvalidPath, ModuleGraph.getMtime("/tmp/foo\x00bar"));

    var long_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memset(&long_buf, 'a');
    try std.testing.expectError(error.NameTooLong, ModuleGraph.getMtime(&long_buf));
}
