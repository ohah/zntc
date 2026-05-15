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
const plugin_mod = @import("plugin.zig");
const transformer_mod = @import("../transformer/transformer.zig");
const TransformOptions = transformer_mod.TransformOptions;
const runtime_helper_modules = @import("../runtime_helper_modules.zig");
pub const module_store = @import("module_store.zig");
const phase_mod = @import("phase.zig");
pub const ModulePhase = phase_mod.ModulePhase;
pub const ParseAccessor = phase_mod.ParseAccessor;
pub const ResolveAccessor = phase_mod.ResolveAccessor;
pub const LinkAccessor = phase_mod.LinkAccessor;
const graph_transform_prepass = @import("graph/transform_prepass.zig");
const graph_package_side_effects = @import("graph/package_side_effects.zig");
const graph_parse_helpers = @import("graph/parse_helpers.zig");
const graph_plugins = @import("graph/plugins.zig");
const graph_requested_exports = @import("graph/requested_exports.zig");
const graph_state = @import("graph/state.zig");
const graph_parser_metadata = @import("graph/parser_metadata.zig");
const graph_accessors = @import("graph/accessors.zig");

pub const determineExportsKind = graph_parse_helpers.determineExportsKind;

pub const ModuleGraph = struct {
    pub const matchSideEffectsPatterns = graph_package_side_effects.matchPatterns;
    const configureParserForModule = graph_parse_helpers.configureParserForModule;
    const isFlowPath = graph_parse_helpers.isFlowPath;
    const mergeImportRecords = graph_parse_helpers.mergeImportRecords;
    const requestAllExports = graph_requested_exports.requestAll;
    const requestNamedExport = graph_requested_exports.requestNamed;
    pub const shouldLinkResolvedRecordForModule = graph_requested_exports.shouldLinkResolvedRecordForModule;
    pub const hasDeferredRequestedImports = graph_requested_exports.hasDeferredRequestedImports;
    pub const getModule = graph_accessors.getModule;
    pub const moduleCount = graph_accessors.moduleCount;
    pub const findModuleByPath = graph_accessors.findModuleByPath;
    pub const moduleAtMut = graph_accessors.moduleAtMut;
    pub const modulesIterator = graph_accessors.modulesIterator;
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

    /// Incremental rebuild path 여부. bundler 가 `module_store` / `changed_files`
    /// / `compiled_cache` 중 하나라도 주입한 경우 true — `readModuleSourceWithMtime`
    /// 가 fstat 호출로 mtime 을 채워야 cache invalidation 이 동작. fresh build
    /// (CLI / 첫 빌드 외부) 에서는 false — caller 자체가 없어 fstat 불필요.
    /// 5000-module 합성 벤치에서 fstat ~5000 회 절감.
    incremental_mode: bool = false,
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
    /// Worker 엔트리: new Worker(new URL(...)) 패턴에서 수집된 worker 파일 경로.
    /// 메인 그래프에는 모듈로 추가하지 않고, bundler에서 별도 빌드한다.
    worker_entries: std.ArrayList(WorkerEntry) = .empty,
    /// RN AssetRegistry.registerAsset 호출에 emit 된 asset metadata 수집.
    /// loader 가 emit 시점에 push, bundler 가 BundleResult.rn_asset_metadata 로 expose.
    /// strings 는 graph.allocator 소유 (loader arena 가 free 되어도 안전하도록 dupe).
    rn_asset_metadata: std.ArrayListUnmanaged(@import("graph/assets.zig").RnAssetMetadata) = .empty,
    /// rn_asset_metadata 병렬 append 보호 (scanWorker 호출 대응).
    rn_asset_metadata_mutex: std.Thread.Mutex = .{},

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

    // Construction/teardown — graph/lifecycle.zig로 위임
    const graph_lifecycle = @import("graph/lifecycle.zig");
    pub const init = graph_lifecycle.init;
    pub const deinit = graph_lifecycle.deinit;

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

    // Module registry/link helpers — graph/module_registry.zig로 위임
    const graph_module_registry = @import("graph/module_registry.zig");
    pub const discardResolvedModule = graph_module_registry.discardResolvedModule;
    pub const markRecordLazyResolved = graph_module_registry.markRecordLazyResolved;
    pub const addModule = graph_module_registry.addModule;
    pub const addModuleWithResolveDir = graph_module_registry.addModuleWithResolveDir;
    pub const addDisabledModule = graph_module_registry.addDisabledModule;
    pub const addOptionalMissingModule = graph_module_registry.addOptionalMissingModule;
    pub const addExternalModule = graph_module_registry.addExternalModule;
    pub const linkDependency = graph_module_registry.linkDependency;
    pub const linkDynamicImport = graph_module_registry.linkDynamicImport;

    // Build/incremental orchestration — graph/build_flow.zig로 위임
    const graph_build_flow = @import("graph/build_flow.zig");
    pub const build = graph_build_flow.build;

    pub const IncrementalBuildResult = graph_build_flow.IncrementalBuildResult;
    pub const buildIncremental = graph_build_flow.buildIncremental;
    pub const getMtime = graph_build_flow.getMtime;

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
