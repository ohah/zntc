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
//!   - D078: 양방향 인접 리스트 (linkDependency 가 유일한 등록 API)
//!   - D079: 파서 inline scan 으로 import 추출 (scan_results → import_scanner)
//!
//! 참고:
//!   - references/rollup/src/utils/executionOrder.ts
//!   - references/rolldown/crates/rolldown/src/module_loader/
//!   - references/bun/src/bundler/LinkerContext.zig

const std = @import("std");
const spin = @import("../util/spin_lock.zig");
const types = @import("types.zig");
const default_asset_inline_limit = types.default_asset_inline_limit;
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
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const plugin_mod = @import("plugin.zig");
const transformer_mod = @import("../transformer/transformer.zig");
const TransformOptions = transformer_mod.TransformOptions;
const runtime_helper_modules = @import("../runtime_helper_modules.zig");
pub const module_store = @import("module_store.zig");
const phase_mod = @import("phase.zig");
pub const ModulePhase = phase_mod.ModulePhase;
const graph_transform_prepass = @import("graph/transform_prepass.zig");
const graph_package_side_effects = @import("graph/package_side_effects.zig");
const graph_parse_helpers = @import("graph/parse_helpers.zig");
const graph_plugins = @import("graph/plugins.zig");
const graph_requested_exports = @import("graph/requested_exports.zig");
const graph_state = @import("graph/state.zig");
const graph_parser_metadata = @import("graph/parser_metadata.zig");
const graph_accessors = @import("graph/accessors.zig");

pub const determineExportsKind = graph_parse_helpers.determineExportsKind;

/// Lazy compilation(PR-3a) 의 미파싱 동적 청크 seed. discovery 가 동적 `import()`
/// 경계에서 정지하며 기록 → BFS 종료 후 materialize. `path`/`resolve_dir` 는
/// path_arena 소유(개별 free 불요).
pub const LazySeed = struct {
    from: ModuleIndex,
    rec_i: u32,
    path: []const u8,
    resolve_dir: ?[]const u8,
};

pub const TlaReadinessAll = struct {
    module_index: types.ModuleIndex,
    export_index: u32,
    symbol_id: @import("../semantic/symbol.zig").SymbolId,
    owner_token: module_mod.SemanticOwnerToken,
};

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
    pub const resyncModuleMetadataAfterConstMaterializationRetainingGraph = graph_transform_prepass.resyncAfterConstMaterializationRetainingGraph;
    pub const resyncModuleMetadataAfterConstMaterializationRetainingMinifiedGraph = graph_transform_prepass.resyncAfterConstMaterializationRetainingMinifiedGraph;
    pub const materializeFromCachedAst = graph_transform_prepass.materializeFromCachedAst;
    const graph_package_info = @import("graph/package_info.zig");
    pub const lookupPkgInfo = graph_package_info.lookupPkgInfo;
    pub const applySideEffectsFromPackageJson = graph_package_info.applySideEffectsFromPackageJson;
    const isPackageTypeModule = graph_package_info.isPackageTypeModule;

    allocator: std.mem.Allocator,
    tla_readiness_all: ?TlaReadinessAll = null,
    /// Actual installed runtime/source domains; refreshed only at graph
    /// handoff or prepared same-graph publication, never by witness capture.
    output_runtime_registry: @import("../semantic/output_runtime_registration.zig").Registry = .{},
    /// PR-Z4: Module path/resolve_dir 전용 arena. M8 측정에서 add_module alloc 의
    /// 69% (3.1ms) 가 path/dir dupe. arena 로 alloc 비용 cheap + graph deinit 시 일괄
    /// 해제 (path_to_module key free loop 회피).
    path_arena: std.heap.ArenaAllocator,
    /// Module storage. SegmentedList 는 append 시에도 기존 포인터를 무효화하지
    /// 않아서 worker race-safety 를 보장한다 (#1779 PR #3). prealloc=0 은 전량
    /// heap chunk — Module 이 수백 바이트라 stack pre-alloc 비효율.
    modules: ModuleList = .{},
    path_to_module: std.StringHashMapUnmanaged(ModuleIndex) = .empty,
    requested_exports: std.AutoHashMapUnmanaged(u32, RequestedExports) = .empty,
    requested_exports_mutex: spin.SpinLock = .{},
    diagnostics: std.ArrayList(BundlerDiagnostic),
    owned_diagnostic_strings: std.ArrayList([]const u8) = .empty,
    resolve_cache: *ResolveCache,
    /// `this.emitFile` (PR5) 수집소 포인터(`emit_store.EmitStore`). bundler 가 bundle() 에서
    /// 단일 store 를 만들어 세팅하며, plugin hook 사이트가 hook_ctx 로 전파한다. null = emitFile
    /// 미연결(예: worker sub-bundle). 메인 스레드 직렬 write 라 동기화 불필요 (#1880 PR5).
    emit_store: ?*anyopaque = null,
    source_read_cache: fs.ReadFileCache = .{},
    /// 병렬 워커에서 diagnostics 접근 보호용 mutex
    diag_mutex: spin.SpinLock = .{},

    /// 패키지 단위 package.json 정보 캐시. pkg_dir_path → (is_module, side_effects).
    /// `type: "module"` 과 `sideEffects` 를 **한 번의 pkg.json parse** 로 추출 (#1744).
    /// 키는 module_path 의 substring (graph 수명 동안 유효) — dupe 불필요.
    /// scanWorker 병렬 호출 대응으로 Mutex 보호 + double-check pattern.
    pkg_info_cache: std.StringHashMapUnmanaged(PkgInfo) = .empty,
    /// pkg_info_cache 병렬 접근 보호.
    pkg_info_cache_mutex: spin.SpinLock = .{},

    // DFS 상태
    exec_counter: u32 = 0,
    cycle_counter: u32 = 0,

    /// `promoteExportsKinds` 가 wrap_kind 확정을 마쳤는지 (#4520).
    ///
    /// wrap_kind 는 "누가 나를 require 하는가 / 내가 dynamic import target 인가 /
    /// RN·dev wrap-all 인가" 같은 **그래프 전역** 정보로 정해진다. 반면
    /// `resyncAfterAstMutation` 은 **단일 모듈 구문 재스캔**이라 그 정보를 복원할 수
    /// 없다. 확정 전(파스 직후 transform prepass / 디스크 캐시 복원)에는 재스캔이
    /// 곧 최초 분류라 그대로 써도 되지만, 확정 후(tree-shaker 의 post-link AST 변형
    /// 등)에 다시 덮어쓰면 `__esm` lazy wrap 이 통째로 날아간다.
    wrap_kinds_finalized: bool = false,

    /// `requestDependencyExports` 의 per-importer 캐시 (record_index → binding 인덱스, CSR).
    /// 과거엔 record 마다 `import_bindings` 전체를 선형 스캔 → mega-entry/대형 barrel(한 모듈이
    /// N개 import)에서 record N개 × binding N개 = **O(N²)**. `resolveModuleImports` 가 한 모듈의
    /// record 를 연속 처리하므로 importer 가 바뀔 때만 1회 O(N) 재구축 → 전체 O(N).
    /// `rdx_offsets[rec]..rdx_offsets[rec+1]` 범위가 `rdx_order` 안의 binding 인덱스(원래 순서 보존).
    /// self.allocator 소유(arena 아님), clearRetainingCapacity 로 재사용, graph deinit 에서 해제.
    /// `rdx_cache_owner` = 캐시가 담은 importer_idx (null = 비어있음/무효).
    rdx_cache_owner: ?usize = null,
    rdx_offsets: std.ArrayListUnmanaged(u32) = .empty,
    rdx_order: std.ArrayListUnmanaged(u32) = .empty,

    /// Incremental rebuild path 여부. bundler 가 `module_store` / `changed_files`
    /// / `compiled_cache` 중 하나라도 주입한 경우 true — `readModuleSourceWithMtime`
    /// 가 fstat 호출로 mtime 을 채워야 cache invalidation 이 동작. fresh build
    /// (CLI / 첫 빌드 외부) 에서는 false — caller 자체가 없어 fstat 불필요.
    /// 5000-module 합성 벤치에서 fstat ~5000 회 절감.
    incremental_mode: bool = false,
    /// #4438 디스크 캐시(parse/semantic 영속화). null 이면 비활성(기본). bundler 가 BundleOptions
    /// 의 store 인스턴스를 주입. parseModule 이 이 store 가 있을 때만 모듈별 키를 계산해
    /// `module.disk_cache_key` 에 캡처한다(store/load 호출은 후속 단계).
    disk_cache: ?*@import("disk_module_store.zig").DiskModuleStore = null,
    /// 디스크 캐시 키의 옵션 dimension(보수 전략 = `computeDiskOptionsHash` — plugin 을 포인터가
    /// 아니라 이름+훅으로 해시해 프로세스 간 안정). bundler 주입.
    disk_options_hash: u64 = 0,
    /// 디스크 캐시 키의 컴파일러-버전 dimension(`build_id.current()`). bundler 주입.
    disk_compiler_build_id: u64 = 0,
    /// #4438 load hit 활성 여부. bundler 가 legal_comments 모드가 load-안전(inline/none)일 때만
    /// true 로 설정. eof/linked/external 은 module.legal_comments 가 출력(banner)에 반영되는데 load
    /// 는 scanner 없이 그걸 재구성 못하므로 load 비활성(store 는 무관하게 계속 — AST 만 저장).
    disk_load_enabled: bool = false,
    /// #4438 디스크 캐시 load hit 카운터(계측/테스트). parseModule 이 worker 에서 병렬 increment 하므로
    /// atomic. hit = parse 를 스킵하고 캐시에서 복원한 모듈 수.
    /// usize: 32-bit 타겟(wasm32/x86-win)은 64-bit atomic 을 지원하지 않으므로 워드 크기 카운터 사용.
    disk_load_hits: std.atomic.Value(usize) = .init(0),
    /// perf/hmr-graph-topology-reuse Phase B — 위상(topology) 보존 모드.
    /// true 면 (1) `transferModulesToStore` 가 비활성(graph 가 parse_arena 단독 owner —
    /// store 로 양도하지 않음), (2) bundler external_graph 훅이 매 빌드 graph 를 전량 clear
    /// (prepareForPreservedRebuild) 하지 않고 `buildIncrementalPreserved` 가 변경 모듈만
    /// 선택적으로 재파싱(edge-reuse short-circuit)한다. 위상 변화(모듈 추가/삭제, specifier/
    /// resolve target 변화)면 안에서 full fallback. enable_persistence(IncrementalBundler) /
    /// RN watch worker 가 set. default false → 기존 경로(Phase A) 영향 0.
    preserve_topology: bool = false,
    /// A graph error can leave a module marked ready after its AST and
    /// transform_cache have already changed. Such a graph must be cleared
    /// before a later preserve-topology build can publish output.
    preserved_graph_invalidated: bool = false,
    /// Phase B 관측용 카운터(누적). edge-reuse short-circuit 가 성공(보존-hit)한 빌드 수와
    /// 위상 변화/불확실로 full fallback 한 빌드 수. ZNTC_DEBUG / 단위 테스트가 "이번 rebuild 가
    /// 실제 보존 경로를 탔는지(전량 fallback 이 아닌지)" 검증하는 데 사용. 빌드 정확성과 무관.
    topology_preserved_hits: usize = 0,
    topology_fallback_count: usize = 0,
    /// PR-B: HMR 위상 보존-hit 시 변경(reparse)된 모듈 path set. emit 이 unchanged 모듈의
    /// 전체 source 해시(computeInputHash)를 skip 하고 직전 compiled_cache 결과를 재사용하게 한다
    /// (eMod 절감). 보존-hit 에서만 non-null(빈 set=변경 0), fallback/full/첫빌드=null →
    /// emit fast-path 자동 비활성. key=path_arena 소유 path(borrow), graph 수명. lifecycle.deinit 해제.
    changed_emit_paths: ?std.StringHashMapUnmanaged(void) = null,
    /// Phase B edge-reuse 내부 플래그 — 변경 모듈 *재resolve* 중에만 일시적으로 true.
    /// true 면 `linkDependency`/`linkDynamicImport` 가 no-op (보존된 edge 리스트를 그대로 두고
    /// import_records[].resolved + resolved_deps 만 재구성하기 위함). 보존 모드에서 변경 모듈의
    /// edge 를 unlink/relink 하면 dep.importers 내 위치가 바뀌어 byte-identical 이 깨지므로,
    /// edge 는 invalidate 전 스냅샷으로 보존하고 link 단계만 억제한다. 재resolve 종료 즉시 false 복구.
    suppress_edge_link: bool = false,
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
    /// 이 크기(byte) 이하의 asset 은 별도 파일 대신 data URL 로 인라인 (#4466).
    /// `--asset-inline-limit`. 0 = 인라인 끔 (항상 파일 방출).
    /// 확장자 기본 테이블로 `.file` 이 된 자산에만 적용 — `--loader:.x=file` 로
    /// 명시 지정한 경우엔 무시된다 (Module.loader_explicit).
    asset_inline_limit: u32 = default_asset_inline_limit,
    /// Metro AssetRegistry 모듈 경로. null이면 URL 문자열, 값이 있으면 registerAsset 래핑.
    asset_registry: ?[]const u8 = null,
    /// 엔트리 포인트 기준 디렉토리. [dir] 패턴 치환에 사용.
    /// entry point들의 공통 부모 디렉토리 (esbuild --outbase에 해당).
    /// 0.16: graph 가 **소유**(build 에서 dupe, deinit 에서 free). 과거엔 caller 의
    /// entry_points 로의 borrow 였으나, 짧게 사는 entry_points(테스트 헬퍼 등)를
    /// 일찍 free 하면 dangling → use-after-free 였다(Linux 에서 발현). graph-owned 로
    /// 모든 caller lifetime 에서 안전.
    entry_dir: []const u8 = "",
    /// Metro `projectRoot` 호환 — asset httpServerLocation 계산의 기준점.
    /// 미설정 시 build() 호출 중 entry_dir에서 위로 올라가며 첫 package.json
    /// 위치를 자동 감지. RN CLI의 기본 동작과 동일.
    project_root: []const u8 = "",
    /// project_root 가 user-set(옵션)이 아니라 entry_dir 에서 **자동 추론**됐는지.
    /// auto 면 entry_dir(=project_root 가 borrow 하는 대상) 재설정 시 함께 무효화해
    /// 재추론(증분 빌드에서 entry_dir free 후 dangling 방지). user-set 은 보존.
    project_root_auto: bool = false,
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
    /// `registerWrapperSymbols` 가 한 번 이상 실행됐는지. 그 전(discovery 워커의 transform
    /// pre-pass)에는 재분석이 떨어뜨릴 wrapper/runtime 행이 없고, 그래프 전체를 고치는
    /// 등록을 워커에서 부르면 다른 모듈의 semantic 과 경합한다 (#5604).
    wrapper_symbols_registered: bool = false,
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
    /// RN AssetRegistry.registerAsset 호출에 emit 된 asset metadata.
    /// loader 가 `module.rn_asset_metadata`(parse_arena 소유)에 저장하고, finalize 의
    /// collectRnAssetMetadata 가 renumber-후 결정적 순서로 이 list 를 borrow 재구성한다.
    /// list 항목은 borrow(실제 owner=module.parse_arena) — bundler 가 BundleResult 로 expose
    /// 할 때만 deep-copy(dupeRnAssetMetadata)로 long-lived 분리. (per-module 저장이라 graph 공유
    /// append 가 없어져 mutex 불요.)
    rn_asset_metadata: std.ArrayListUnmanaged(@import("graph/assets.zig").RnAssetMetadata) = .empty,

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

    /// Lazy compilation (RFC docs/RFC_LAZY_COMPILATION.md, A안). dev 서버 온디맨드
    /// 청크 컴파일 — BFS discovery 가 동적 `import()` 경계에서 멈추고 타겟을 미파싱
    /// seed 로 등록한다(아래 `lazy_seeds`). `false`(기본)면 기존 eager 동작 그대로 →
    /// kill-switch 회귀 0. `dev_mode and code_splitting` 와 함께여야 의미 있음.
    lazy_compilation: bool = false,
    /// PR-3b-ii primitive: lazy_compilation 이어도 이 경로들(resolver resolved 절대경로와
    /// exact match)의 동적 import 타겟은 deferred 하지 않고 즉시 parse(eager). 슬라이스
    /// borrow(BundleOptions 소유). 전체 on-demand 는 shared-off + export-all 까지 필요(RFC).
    lazy_force_parse: []const []const u8 = &.{},
    /// PR-3a: discovery 중 동적 import 경계에서 정지한 타겟. BFS 종료 후 일괄
    /// materialize(`materializeLazySeeds`) — static 으로도 도달했으면 그 파싱 모듈에
    /// link, 아니면 미파싱 seed(`Module.is_lazy_seed`, state=.ready, ast=null)로 등록.
    /// `path` 는 path_arena 소유(개별 free 불요), 리스트 자체만 deinit.
    lazy_seeds: std.ArrayListUnmanaged(LazySeed) = .empty,

    /// transformer pre-pass 의 옵션 base (#1961). bundler 가 init 시 BundleOptions →
    /// TransformOptions 매핑을 1회 채움. parseModule 이 base 를 복사 후 per-module
    /// override (`react_refresh`, `plugins`, `jsx_transform`, `jsx_filename`,
    /// `emit_runtime_helper_imports`) 만 추가하여 transformer.init 호출.
    /// 옵션 추가 시 갱신 site 가 1 곳 (bundler.zig) 으로 좁혀 drift 방지.
    transform_options_base: transformer_mod.TransformOptions = .{},

    /// Runtime helper virtual module plugin (#1961) 의 `SourceOptions`.
    /// graph 가 build() 동안 owner — `Plugin.context` 에서 `*const SourceOptions` 로 참조.
    helper_plugin_opts: runtime_helper_modules.SourceOptions = .{},
    /// Primary-analysis provider used by the single-output interop prelude.
    dynamic_import_ast_provider: ?@import("runtime_dynamic_import_ast.zig").Provider = null,
    interop_ast_provider: ?@import("runtime_interop_ast.zig").Provider = null,
    entry_guard_invocations: std.ArrayListUnmanaged(@import("runtime_entry_guard_calls.zig").Invocation) = .empty,
    entry_guard_ast_provider: ?@import("runtime_entry_guard_ast.zig").Provider = null,
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
    /// PR-3: 빌드 호출자(RN preset 등)가 "이 빌드의 모든 user plugin 이 결정적·모듈별 순수
    /// (전역 상태/lifecycle 출력 영향 없음)"를 보장하는 opt-in 신호. 기본 false(보수적).
    /// HMR 위상 보존(canPreserveTopology)이 plugin 게이트를 이 신호로 완화한다.
    preserve_safe_plugins: bool = false,
    /// PR-3: preserve-safe 가 아닌(=보존 불가) user plugin hook 보유 여부. canPreserveTopology
    /// 게이트가 has_user_* 대신 이걸 본다. `ensureBuiltinPlugins` 가 채움(codegen 은 native·
    /// 결정적이라 unsafe transform 에 불포함).
    has_unsafe_resolve_id_plugins: bool = false,
    has_unsafe_load_plugins: bool = false,
    has_unsafe_transform_plugins: bool = false,

    /// Graph-local, non-serialized authority for completed self namespace AST.
    self_namespace_holders: std.AutoHashMapUnmanaged(u32, @import("self_namespace_ast.zig").Completed) = .empty,
    /// Provider source authority was consumed; keep it out of ModuleStore
    /// even after its importer plan is invalidated. Graph-local, never serialized.
    namespace_source_consumed_providers: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub const PkgInfo = graph_state.PkgInfo;
    pub const WorkerEntry = graph_state.WorkerEntry;
    const RequestedExports = graph_state.RequestedExports;

    // Construction/teardown — graph/lifecycle.zig로 위임
    const graph_lifecycle = @import("graph/lifecycle.zig");
    pub const init = graph_lifecycle.init;
    pub const deinit = graph_lifecycle.deinit;
    /// RFC_GRAPH_PERSISTENCE Sub-PR-B.1 — graph-global state reset (modules 보존).
    /// 호출자 없음 (Sub-PR-B.3 에서 wire-up).
    pub const reset = graph_lifecycle.reset;
    /// RFC_GRAPH_PERSISTENCE Sub-PR-B.1 — 단일 모듈 invalidate (path 보존).
    /// 호출자 없음 (Sub-PR-B.3 에서 wire-up).
    pub const invalidateModule = graph_lifecycle.invalidateModule;
    /// perf/hmr-graph-topology-reuse Phase A — persistent_graph 재사용 빌드 직전 reset.
    /// 현재는 fresh 와 byte-identical(모듈 전량 clear). bundler.zig external_graph 훅이 호출.
    pub const prepareForPreservedRebuild = graph_lifecycle.prepareForPreservedRebuild;

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
    // - mutate 는 graph/*.zig 내부 메서드가 `moduleAtMut` 로 수행 (storage owner 전용).
    //   외부 파일은 read(getModule/iterator) + `linkDependency`/`setDevId` 만 사용.
    //   phase 경계 규약은 docs/INVARIANTS.md.
    // ============================================================

    /// dev mode 모듈 ID write. link phase 에서 emit 직전 한 번만 설정한다.
    /// (과거 LinkAccessor.setDevId — accessor 계층 제거 후 graph 메서드로 흡수.)
    pub inline fn setDevId(self: *ModuleGraph, idx: ModuleIndex, dev_id: []const u8) void {
        if (self.moduleAtMut(idx)) |m| m.dev_id = dev_id;
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
    /// perf/hmr-graph-topology-reuse Phase B — 위상 보존 증분 빌드(edge-reuse short-circuit).
    /// `preserve_topology=true` 일 때 bundler 가 buildIncremental 대신 호출.
    pub const buildIncrementalPreserved = graph_build_flow.buildIncrementalPreserved;
    pub const getMtime = graph_build_flow.getMtime;
    pub const transferModulesToStore = graph_build_flow.transferModulesToStore;

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
    pub const registerWrapperSymbols = graph_finalize.registerWrapperSymbols;
    const propagateTopLevelAwait = graph_finalize.propagateTopLevelAwait;

    // Loader/source helpers — graph/loaders.zig로 위임
    const graph_loaders = @import("graph/loaders.zig");
    pub const parseCssModule = graph_loaders.parseCssModule;
    pub const parseAssetModule = graph_loaders.parseAssetModule;
    pub const parseWorkerWrapperModule = graph_loaders.parseWorkerWrapperModule;
    pub const readModuleSourceWithMtime = graph_loaders.readModuleSourceWithMtime;
    const graph_json_module = @import("graph/json_module.zig");
    pub const parseJsonModule = graph_json_module.parse;
    const graph_parser_setup = @import("graph/parser_setup.zig");
    pub const initParserForModule = graph_parser_setup.init;

    // Diagnostics helpers — graph/diagnostics.zig로 위임
    const graph_diagnostics = @import("graph/diagnostics.zig");
    pub const addDiag = graph_diagnostics.addDiag;
    pub const addOwnedDiag = graph_diagnostics.addOwnedDiag;
    pub const addOwnedDiagnostic = graph_diagnostics.addOwnedDiagnostic;
    pub const addPluginFailureDiag = graph_diagnostics.addPluginFailureDiag;
    const validatePluginSourceMaps = graph_diagnostics.validatePluginSourceMaps;
};

const test_helpers = @import("test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

const PrePassPredicateTestOptions = struct {
    ast_plugin: enum { none, ordinary, on_function, visitor_program, visitor_object, visitor_call, visitor_class, auto_worklet } = .none,
    transform_options: TransformOptions = .{},
    plugin_transform_applied: bool = false,
    react_refresh: bool = false,
    styled_components: bool = false,
    styled_components_top_level_import_paths: []const []const u8 = &.{},
    emotion: bool = false,
    emotion_extra_css_sources: []const []const u8 = &.{},
    emotion_extra_styled_sources: []const []const u8 = &.{},
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
    var module = Module.init(@fromBackingInt(@intCast(0)), path);
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
    const ast_test_plugins: []const plugin_mod.Plugin = switch (opts.ast_plugin) {
        .none => &[_]plugin_mod.Plugin{},
        .ordinary => &[_]plugin_mod.Plugin{.{ .name = "ordinary", .transform = noopPrePassTestTransform }},
        .on_function => &[_]plugin_mod.Plugin{.{ .name = "on-function", .onFunction = noopPrePassTestFunction }},
        .visitor_program => &[_]plugin_mod.Plugin{.{ .name = "visitor", .visitor = .{ .on_program = noopPrePassTestVisitor } }},
        .visitor_object => &[_]plugin_mod.Plugin{.{ .name = "visitor", .visitor = .{ .on_object_expression = noopPrePassTestVisitor } }},
        .visitor_call => &[_]plugin_mod.Plugin{.{ .name = "visitor", .visitor = .{ .on_call_expression = noopPrePassTestVisitor } }},
        .visitor_class => &[_]plugin_mod.Plugin{.{ .name = "visitor", .visitor = .{ .on_class_expression = noopPrePassTestVisitor } }},
        .auto_worklet => &[_]plugin_mod.Plugin{.{
            .name = "auto-worklet",
            .autoWorkletCallees = &.{.{ .name = "useWorklet" }},
        }},
    };
    graph.plugins = ast_test_plugins;
    graph.react_refresh = opts.react_refresh;
    graph.styled_components = opts.styled_components;
    graph.styled_components_top_level_import_paths = opts.styled_components_top_level_import_paths;
    graph.emotion = opts.emotion;
    graph.emotion_extra_css_sources = opts.emotion_extra_css_sources;
    graph.emotion_extra_styled_sources = opts.emotion_extra_styled_sources;
    graph.worklet_transform = opts.worklet_transform;
    graph.minify_identifiers = opts.minify_identifiers;

    module.ast = parser.ast;
    return graph.shouldRunTransformerPrePass(&module, opts.plugin_transform_applied);
}

fn noopPrePassTestTransform(
    _: ?*anyopaque,
    _: []const u8,
    _: []const u8,
    _: std.mem.Allocator,
    _: *plugin_mod.HookContext,
) plugin_mod.PluginError!?[]const u8 {
    return null;
}

fn noopPrePassTestFunction(
    _: ?*anyopaque,
    _: *plugin_mod.AstTransformCtx,
    _: plugin_mod.FunctionInfo,
) plugin_mod.PluginError!void {}

fn noopPrePassTestVisitor(
    _: ?*anyopaque,
    _: *plugin_mod.AstTransformCtx,
    _: @import("../parser/ast.zig").NodeIndex,
) plugin_mod.PluginError!?@import("../parser/ast.zig").NodeIndex {
    return null;
}

const ColdParseVisitorKind = enum {
    program,
    object_expression,
    call_expression,
    class_declaration,
    class_expression,
};

const ColdParseVisitorState = struct {
    calls: usize = 0,
    observed_tag: ?@import("../parser/ast.zig").Node.Tag = null,
};

const IdentityRetainingVisitorMutationState = struct {
    calls: usize = 0,
    observed_tag: ?ast_mod.Node.Tag = null,
    did_mutate: bool = false,
};

fn identityRetainingVisitorMutationHook(
    ctx: ?*anyopaque,
    api: *plugin_mod.AstTransformCtx,
    node_idx: ast_mod.NodeIndex,
) plugin_mod.PluginError!?ast_mod.NodeIndex {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *IdentityRetainingVisitorMutationState = @ptrCast(@alignCast(state_ptr));
    state.calls += 1;
    state.observed_tag = api.transformer.ast.getNode(node_idx).tag;
    if (state.did_mutate) return null;

    const ast = api.transformer.ast;
    const owner_span = ast.getNode(node_idx).span;
    var first_numeric: ?usize = null;
    var replacement_span: ?@import("../lexer/token.zig").Span = null;
    for (ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .numeric_literal or !owner_span.contains(node.span)) continue;
        if (first_numeric == null) {
            first_numeric = raw;
        } else {
            replacement_span = node.span;
            break;
        }
    }
    const first = first_numeric orelse return error.PluginFailed;
    const replacement = replacement_span orelse return error.PluginFailed;
    ast.nodes.items[first].span = replacement;
    state.did_mutate = true;
    return null;
}

fn identityRetainingVisitorFor(kind: ColdParseVisitorKind) plugin_mod.Visitor {
    return switch (kind) {
        .program => .{ .on_program = identityRetainingVisitorMutationHook },
        .object_expression => .{ .on_object_expression = identityRetainingVisitorMutationHook },
        .call_expression => .{ .on_call_expression = identityRetainingVisitorMutationHook },
        .class_declaration => .{ .on_class_declaration = identityRetainingVisitorMutationHook },
        .class_expression => .{ .on_class_expression = identityRetainingVisitorMutationHook },
    };
}

const TransformedNumericLiteralCount = struct {
    ast: *const ast_mod.Ast,
    text: []const u8,
    count: usize = 0,

    fn visit(self: *@This(), _: ast_mod.NodeIndex, node: ast_mod.Node) ast_walk.WalkAction {
        if (node.tag == .numeric_literal and std.mem.eql(u8, self.ast.getText(node.span), self.text))
            self.count += 1;
        return .descend;
    }
};

fn expectMutatedVisitorGraph(
    graph: *const ModuleGraph,
    entry: []const u8,
    kind: ColdParseVisitorKind,
    state: IdentityRetainingVisitorMutationState,
) !void {
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(coldParseVisitorNodeTag(kind), state.observed_tag.?);
    try std.testing.expect(state.did_mutate);
    try expectVisitorGraphReady(graph, entry);

    const module = graph.findModuleByPath(entry).?;
    const ast = &module.ast.?;
    const root = ast.transformed_root.?;
    var original_value_count = TransformedNumericLiteralCount{ .ast = ast, .text = "1" };
    try ast_walk.walkPreorderIterative(
        std.testing.allocator,
        ast,
        root,
        &original_value_count,
        TransformedNumericLiteralCount.visit,
    );
    var rewritten_value_count = TransformedNumericLiteralCount{ .ast = ast, .text = "2" };
    try ast_walk.walkPreorderIterative(
        std.testing.allocator,
        ast,
        root,
        &rewritten_value_count,
        TransformedNumericLiteralCount.visit,
    );
    try std.testing.expectEqual(@as(usize, 0), original_value_count.count);
    try std.testing.expectEqual(@as(usize, 2), rewritten_value_count.count);
}

fn expectColdAndCachedVisitorMutationRetainsGraph(kind: ColdParseVisitorKind, source: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_state: IdentityRetainingVisitorMutationState = .{};
    const cold_plugins = [_]plugin_mod.Plugin{.{
        .name = "identity-retaining-visitor-edit",
        .context = @ptrCast(&cold_state),
        .visitor = identityRetainingVisitorFor(kind),
        .ast_graph_contract = .identity_preserving_visitor_edits,
    }};
    {
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x5678;
        graph.disk_compiler_build_id = 0xEF01;
        graph.max_threads = 1;
        graph.plugins = &cold_plugins;

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(@as(usize, 0), graph.disk_load_hits.load(.monotonic));
        try expectMutatedVisitorGraph(&graph, entry, kind, cold_state);
    }

    var warm_state: IdentityRetainingVisitorMutationState = .{};
    const warm_plugins = [_]plugin_mod.Plugin{.{
        .name = "identity-retaining-visitor-edit",
        .context = @ptrCast(&warm_state),
        .visitor = identityRetainingVisitorFor(kind),
        .ast_graph_contract = .identity_preserving_visitor_edits,
    }};
    var warm_cache = ResolveCache.init(std.testing.allocator, .{});
    defer warm_cache.deinit();
    var warm_graph = ModuleGraph.init(std.testing.allocator, &warm_cache);
    defer warm_graph.deinit();
    warm_graph.disk_cache = &disk;
    warm_graph.disk_load_enabled = true;
    warm_graph.disk_options_hash = 0x5678;
    warm_graph.disk_compiler_build_id = 0xEF01;
    warm_graph.max_threads = 1;
    warm_graph.plugins = &warm_plugins;

    try warm_graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), warm_graph.disk_load_hits.load(.monotonic));
    try expectMutatedVisitorGraph(&warm_graph, entry, kind, warm_state);
}

const TrackedDirectEvalGraphHookState = struct {
    calls: usize = 0,
    did_inject: bool = false,
    insertion_scope: ScopeId = .none,
    initial_scope_has_direct_eval: ?bool = null,
    edited_scope_has_direct_eval: ?bool = null,
};

fn trackedDirectEvalGraphHook(
    ctx: ?*anyopaque,
    api: *plugin_mod.AstTransformCtx,
    info: @import("../transformer/ast_plugin.zig").FunctionInfo,
) plugin_mod.PluginError!void {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *TrackedDirectEvalGraphHookState = @ptrCast(@alignCast(state_ptr));
    state.calls += 1;
    if (info.node_tag != .function_declaration) return;

    const scope = api.insertion_scope;
    if (scope.isNone()) return error.PluginFailed;
    const scope_index = scope.toIndex();
    state.insertion_scope = scope;
    if (scope_index >= api.transformer.scopes.len) return error.PluginFailed;
    state.initial_scope_has_direct_eval = api.transformer.scopes[scope_index].subtree_has_direct_eval;

    const injected = try api.parseAndInjectStatements("eval('secret');");
    defer api.getAllocator().free(injected);
    for (injected) |statement| try api.addTrailingStatement(statement);
    if (api.transformer.semantic_editor) |*editor| {
        if (scope_index >= editor.scopes.items.len) return error.PluginFailed;
        state.edited_scope_has_direct_eval = editor.scopes.items[scope_index].subtree_has_direct_eval;
    } else {
        return error.PluginFailed;
    }
    state.did_inject = true;
}

const TransformedDirectEvalCallCount = struct {
    ast: *const ast_mod.Ast,
    count: usize = 0,

    fn visit(self: *@This(), _: ast_mod.NodeIndex, node: ast_mod.Node) ast_walk.WalkAction {
        if (node.tag != .call_expression) return .descend;
        const callee = self.ast.readExtraNode(node.data.extra, 0);
        if (callee.isNone()) return .descend;
        const callee_node = self.ast.getNode(callee);
        if (callee_node.tag == .identifier_reference and
            Scanner.identifierNamesEqual(self.ast.identifierNameText(callee_node), "eval"))
        {
            self.count += 1;
        }
        return .descend;
    }
};

fn expectTrackedDirectEvalGraph(
    graph: *const ModuleGraph,
    entry: []const u8,
    state: TrackedDirectEvalGraphHookState,
) !void {
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.did_inject);
    try std.testing.expect(!state.insertion_scope.isNone());
    try std.testing.expectEqual(false, state.initial_scope_has_direct_eval.?);
    try std.testing.expectEqual(true, state.edited_scope_has_direct_eval.?);
    try expectVisitorGraphReady(graph, entry);

    const module = graph.findModuleByPath(entry).?;
    const semantic = &module.semantic.?;
    const scope_index = state.insertion_scope.toIndex();
    try std.testing.expect(scope_index < semantic.scopes.len);
    try std.testing.expect(semantic.scopes[scope_index].subtree_has_direct_eval);

    const ast = &module.ast.?;
    var eval_calls = TransformedDirectEvalCallCount{ .ast = ast };
    try ast_walk.walkPreorderIterative(
        std.testing.allocator,
        ast,
        ast.transformed_root.?,
        &eval_calls,
        TransformedDirectEvalCallCount.visit,
    );
    try std.testing.expectEqual(@as(usize, 1), eval_calls.count);
}

fn expectColdAndCachedTrackedDirectEvalGraph() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "function read() { let secret = 1; }";
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_state: TrackedDirectEvalGraphHookState = .{};
    const cold_plugins = [_]plugin_mod.Plugin{.{
        .name = "tracked-direct-eval-function-hook",
        .context = @ptrCast(&cold_state),
        .onFunction = trackedDirectEvalGraphHook,
        .ast_graph_contract = .tracked_function_edits,
    }};
    {
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x9234;
        graph.disk_compiler_build_id = 0xABFE;
        graph.max_threads = 1;
        graph.plugins = &cold_plugins;

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(@as(usize, 0), graph.disk_load_hits.load(.monotonic));
        try expectTrackedDirectEvalGraph(&graph, entry, cold_state);
    }

    var warm_state: TrackedDirectEvalGraphHookState = .{};
    const warm_plugins = [_]plugin_mod.Plugin{.{
        .name = "tracked-direct-eval-function-hook",
        .context = @ptrCast(&warm_state),
        .onFunction = trackedDirectEvalGraphHook,
        .ast_graph_contract = .tracked_function_edits,
    }};
    var warm_cache = ResolveCache.init(std.testing.allocator, .{});
    defer warm_cache.deinit();
    var warm_graph = ModuleGraph.init(std.testing.allocator, &warm_cache);
    defer warm_graph.deinit();
    warm_graph.disk_cache = &disk;
    warm_graph.disk_load_enabled = true;
    warm_graph.disk_options_hash = 0x9234;
    warm_graph.disk_compiler_build_id = 0xABFE;
    warm_graph.max_threads = 1;
    warm_graph.plugins = &warm_plugins;

    try warm_graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), warm_graph.disk_load_hits.load(.monotonic));
    try expectTrackedDirectEvalGraph(&warm_graph, entry, warm_state);
}

const TrackedInjectedBindingGraphState = struct {
    callbacks: usize = 0,
    target_calls: usize = 0,
    method_calls: usize = 0,
    did_inject: bool = false,
    insertion_scope: ScopeId = .none,
    source_binding: ast_mod.NodeIndex = .none,
    source_reference: ast_mod.NodeIndex = .none,
    decoy_binding: ast_mod.NodeIndex = .none,
    injected_binding: ast_mod.NodeIndex = .none,
    injected_reference: ast_mod.NodeIndex = .none,
};

fn trackedInjectedBindingGraphHook(
    ctx: ?*anyopaque,
    api: *plugin_mod.AstTransformCtx,
    info: @import("../transformer/ast_plugin.zig").FunctionInfo,
) plugin_mod.PluginError!void {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *TrackedInjectedBindingGraphState = @ptrCast(@alignCast(state_ptr));
    state.callbacks += 1;
    const ast = api.transformer.ast;
    if (state.decoy_binding.isNone() or state.source_binding.isNone()) {
        for (ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier) continue;
            const name = ast.getText(node.data.string_ref);
            if (state.decoy_binding.isNone() and Scanner.identifierNamesEqual(name, "injectedValue"))
                state.decoy_binding = @fromBackingInt(@intCast(raw));
            if (state.source_binding.isNone() and Scanner.identifierNamesEqual(name, "secret"))
                state.source_binding = @fromBackingInt(@intCast(raw));
        }
    }
    const function_name = info.name orelse "";
    if (info.node_tag == .method_definition and std.mem.eql(u8, function_name, "run")) {
        state.method_calls += 1;
        return;
    }
    if (!std.mem.eql(u8, function_name, "read") and
        info.node_tag != .arrow_function_expression and info.node_tag != .function_expression) return;
    state.target_calls += 1;
    if (state.target_calls != 1 or state.source_binding.isNone() or state.decoy_binding.isNone()) return error.PluginFailed;

    state.insertion_scope = api.insertion_scope;
    if (!Scanner.identifierNamesEqual(ast.getText(ast.getNode(state.source_binding).data.string_ref), "secret")) return error.PluginFailed;

    const injected = try api.parseAndInjectStatements("const injectedValue = secret; injectedValue;");
    defer api.getAllocator().free(injected);
    for (injected) |statement| {
        const node = api.getNode(statement);
        switch (node.tag) {
            .variable_declaration => {
                const start = ast.extra_data.items[node.data.extra + 1];
                const declarator_raw = ast.extra_data.items[start];
                const declarator = ast.nodes.items[declarator_raw];
                state.injected_binding = ast.readExtraNode(declarator.data.extra, 0);
                state.source_reference = ast.readExtraNode(declarator.data.extra, 2);
            },
            .expression_statement => state.injected_reference = node.data.unary.operand,
            else => return error.PluginFailed,
        }
        try api.addTrailingStatement(statement);
    }
    if (state.injected_binding.isNone() or state.source_reference.isNone() or state.injected_reference.isNone())
        return error.PluginFailed;
    state.did_inject = true;
}

fn expectTrackedInjectedBindingGraph(
    graph: *const ModuleGraph,
    entry: []const u8,
    state: TrackedInjectedBindingGraphState,
    expected_method_calls: usize,
) !void {
    try std.testing.expect(state.callbacks >= 1);
    try std.testing.expectEqual(@as(usize, 1), state.target_calls);
    try std.testing.expectEqual(expected_method_calls, state.method_calls);
    try std.testing.expect(state.did_inject);
    try std.testing.expect(!state.insertion_scope.isNone());
    try expectVisitorGraphReady(graph, entry);

    const module = graph.findModuleByPath(entry).?;
    const semantic = &module.semantic.?;
    const ast = &module.ast.?;
    const binding_raw: usize = @intCast(@backingInt(state.injected_binding));
    const source_binding_raw: usize = @intCast(@backingInt(state.source_binding));
    const decoy_binding_raw: usize = @intCast(@backingInt(state.decoy_binding));
    const source_reference_raw: usize = @intCast(@backingInt(state.source_reference));
    const injected_reference_raw: usize = @intCast(@backingInt(state.injected_reference));
    try std.testing.expect(binding_raw < semantic.symbol_ids.len);
    try std.testing.expect(source_binding_raw < semantic.symbol_ids.len);
    try std.testing.expect(decoy_binding_raw < semantic.symbol_ids.len);
    try std.testing.expect(source_reference_raw < semantic.symbol_ids.len);
    try std.testing.expect(injected_reference_raw < semantic.symbol_ids.len);
    const injected_symbol = semantic.symbol_ids[binding_raw] orelse return error.TestUnexpectedResult;
    const source_symbol = semantic.symbol_ids[source_binding_raw] orelse return error.TestUnexpectedResult;
    const decoy_symbol = semantic.symbol_ids[decoy_binding_raw] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(source_symbol, semantic.symbol_ids[source_reference_raw].?);
    try std.testing.expectEqual(injected_symbol, semantic.symbol_ids[injected_reference_raw].?);
    try std.testing.expect(injected_symbol != source_symbol);
    try std.testing.expect(injected_symbol != decoy_symbol);
    try std.testing.expectEqual(.variable_const, semantic.symbols.items[injected_symbol].kind);

    const scope_index = state.insertion_scope.toIndex();
    try std.testing.expect(scope_index < semantic.scopes.len);
    try std.testing.expectEqual(state.insertion_scope, semantic.symbols.items[injected_symbol].scope_id);
    try std.testing.expectEqual(@as(usize, injected_symbol), semantic.scope_maps[scope_index].get("injectedValue").?);
    const decoy_scope = semantic.symbols.items[decoy_symbol].scope_id;
    try std.testing.expect(decoy_scope != state.insertion_scope);
    try std.testing.expectEqual(@as(usize, decoy_symbol), semantic.scope_maps[decoy_scope.toIndex()].get("injectedValue").?);

    var declaration_rows: usize = 0;
    var source_reference_rows: usize = 0;
    var injected_reference_rows: usize = 0;
    for (semantic.references) |reference| {
        if (reference.flags.declare and reference.declaration_node_index == state.injected_binding) {
            try std.testing.expectEqual(injected_symbol, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(state.insertion_scope, reference.scope_id);
            declaration_rows += 1;
        }
        if (reference.node_index == state.source_reference) {
            try std.testing.expectEqual(source_symbol, @backingInt(reference.symbol_id));
            source_reference_rows += 1;
        }
        if (reference.node_index == state.injected_reference) {
            try std.testing.expectEqual(injected_symbol, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(state.insertion_scope, reference.scope_id);
            injected_reference_rows += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), declaration_rows);
    try std.testing.expectEqual(@as(usize, 1), source_reference_rows);
    try std.testing.expectEqual(@as(usize, 1), injected_reference_rows);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, ast.transformed_root.?);
    defer std.testing.allocator.free(reachable);
    for ([_]ast_mod.NodeIndex{ state.injected_binding, state.source_reference, state.injected_reference }) |node| {
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(node)) != null);
    }
}

fn expectColdAndCachedTrackedInjectedBindingGraph(source: []const u8, expected_method_calls: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_state: TrackedInjectedBindingGraphState = .{};
    const cold_plugins = [_]plugin_mod.Plugin{.{
        .name = "tracked-injected-binding-function-hook",
        .context = @ptrCast(&cold_state),
        .onFunction = trackedInjectedBindingGraphHook,
        .ast_graph_contract = .tracked_function_edits,
    }};
    {
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0xB17D;
        graph.disk_compiler_build_id = 0xCACE;
        graph.max_threads = 1;
        graph.plugins = &cold_plugins;
        graph.transform_options_base.minify_syntax = true;
        graph.minify_identifiers = true;

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(@as(usize, 0), graph.disk_load_hits.load(.monotonic));
        try expectTrackedInjectedBindingGraph(&graph, entry, cold_state, expected_method_calls);
    }

    var warm_state: TrackedInjectedBindingGraphState = .{};
    const warm_plugins = [_]plugin_mod.Plugin{.{
        .name = "tracked-injected-binding-function-hook",
        .context = @ptrCast(&warm_state),
        .onFunction = trackedInjectedBindingGraphHook,
        .ast_graph_contract = .tracked_function_edits,
    }};
    var warm_cache = ResolveCache.init(std.testing.allocator, .{});
    defer warm_cache.deinit();
    var warm_graph = ModuleGraph.init(std.testing.allocator, &warm_cache);
    defer warm_graph.deinit();
    warm_graph.disk_cache = &disk;
    warm_graph.disk_load_enabled = true;
    warm_graph.disk_options_hash = 0xB17D;
    warm_graph.disk_compiler_build_id = 0xCACE;
    warm_graph.max_threads = 1;
    warm_graph.plugins = &warm_plugins;
    warm_graph.transform_options_base.minify_syntax = true;
    warm_graph.minify_identifiers = true;

    try warm_graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), warm_graph.disk_load_hits.load(.monotonic));
    try expectTrackedInjectedBindingGraph(&warm_graph, entry, warm_state, expected_method_calls);
}

const UntrackedEvalGraphMutationState = struct {
    mutations: usize = 0,
};

fn untrackedEvalGraphMutationHook(
    ctx: ?*anyopaque,
    api: *plugin_mod.AstTransformCtx,
    info: @import("../transformer/ast_plugin.zig").FunctionInfo,
) plugin_mod.PluginError!void {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *UntrackedEvalGraphMutationState = @ptrCast(@alignCast(state_ptr));
    const ast = api.transformer.ast;
    const body = ast.getNode(info.body_idx);
    if (body.tag != .block_statement) return;
    const body_items = ast.extra_data.items[body.data.list.start .. body.data.list.start + body.data.list.len];
    for (body_items) |raw| {
        const statement: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        const statement_node = ast.getNode(statement);
        if (statement_node.tag != .expression_statement) continue;
        const expression_idx = statement_node.data.unary.operand;
        const expression = ast.getNode(expression_idx);
        if (expression.tag != .identifier_reference or
            !Scanner.identifierNamesEqual(ast.identifierNameText(expression), "eval")) continue;

        const arguments = try ast.addNodeList(&.{});
        const extra = try ast.addExtras(&.{ @backingInt(expression_idx), arguments.start, arguments.len, 0 });
        const call = try ast.addExtraNode(.call_expression, expression.span, extra);
        ast.nodes.items[@backingInt(statement)].data.unary.operand = call;
        state.mutations += 1;
        return;
    }
}

fn expectUntrackedEvalGraphMutationRejected(source: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);

    var mutation: UntrackedEvalGraphMutationState = .{};
    const plugins = [_]plugin_mod.Plugin{.{
        .name = "tracked-contract-bypass-eval-function-hook",
        .context = @ptrCast(&mutation),
        .onFunction = untrackedEvalGraphMutationHook,
        .ast_graph_contract = .tracked_function_edits,
    }};
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.max_threads = 1;
    graph.plugins = &plugins;
    graph.transform_options_base.minify_syntax = true;
    graph.minify_identifiers = true;

    try graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
    try std.testing.expectEqual(@as(usize, 1), mutation.mutations);
    const module = graph.findModuleByPath(entry).?;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expect(module.semantic != null);
    try std.testing.expect(module.semantic.?.owner_token != .unassigned);
    try std.testing.expect(module.ast != null);
    try std.testing.expectEqualStrings(source, module.ast.?.source);
    try std.testing.expect(module.ast.?.transformed_root == null);
    try std.testing.expect(module.transform_cache == null);

    var error_diagnostics: usize = 0;
    for (graph.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") error_diagnostics += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), error_diagnostics);
}

const TrackedNoopFunctionHookState = struct { calls: usize = 0 };

fn trackedNoopFunctionHook(
    ctx: ?*anyopaque,
    _: *plugin_mod.AstTransformCtx,
    _: @import("../transformer/ast_plugin.zig").FunctionInfo,
) plugin_mod.PluginError!void {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *TrackedNoopFunctionHookState = @ptrCast(@alignCast(state_ptr));
    state.calls += 1;
}

test "graph function-hook caller: syntax minification publishes when the tracked candidate stays exact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "export function read() { return 1 + 2; }";
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);

    var hook_state: TrackedNoopFunctionHookState = .{};
    const plugins = [_]plugin_mod.Plugin{.{
        .name = "tracked-noop-function-hook",
        .context = @ptrCast(&hook_state),
        .onFunction = trackedNoopFunctionHook,
        .ast_graph_contract = .tracked_function_edits,
    }};
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.max_threads = 1;
    graph.plugins = &plugins;
    graph.transform_options_base.minify_syntax = true;
    graph.minify_identifiers = true;

    try graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), hook_state.calls);
    try expectVisitorGraphReady(&graph, entry);
    const ast = &graph.findModuleByPath(entry).?.ast.?;
    const root = ast.transformed_root.?;
    var folded = TransformedNumericLiteralCount{ .ast = ast, .text = "3" };
    try ast_walk.walkPreorderIterative(std.testing.allocator, ast, root, &folded, TransformedNumericLiteralCount.visit);
    try std.testing.expectEqual(@as(usize, 1), folded.count);
    for ([_][]const u8{ "1", "2" }) |text| {
        var stale = TransformedNumericLiteralCount{ .ast = ast, .text = text };
        try ast_walk.walkPreorderIterative(std.testing.allocator, ast, root, &stale, TransformedNumericLiteralCount.visit);
        try std.testing.expectEqual(@as(usize, 0), stale.count);
    }
}

fn coldParseVisitorHook(
    ctx: ?*anyopaque,
    api: *plugin_mod.AstTransformCtx,
    node_idx: @import("../parser/ast.zig").NodeIndex,
) plugin_mod.PluginError!?@import("../parser/ast.zig").NodeIndex {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *ColdParseVisitorState = @ptrCast(@alignCast(state_ptr));
    state.calls += 1;
    state.observed_tag = api.transformer.ast.getNode(node_idx).tag;
    return null;
}

fn coldParseVisitorFor(kind: ColdParseVisitorKind) plugin_mod.Visitor {
    return switch (kind) {
        .program => .{ .on_program = coldParseVisitorHook },
        .object_expression => .{ .on_object_expression = coldParseVisitorHook },
        .call_expression => .{ .on_call_expression = coldParseVisitorHook },
        .class_declaration => .{ .on_class_declaration = coldParseVisitorHook },
        .class_expression => .{ .on_class_expression = coldParseVisitorHook },
    };
}

fn coldParseVisitorPlugin(kind: ColdParseVisitorKind, state: *ColdParseVisitorState) plugin_mod.Plugin {
    return .{
        .name = "cold-parse-visitor",
        .context = @ptrCast(state),
        .visitor = coldParseVisitorFor(kind),
        .ast_graph_contract = .identity_preserving_visitor_edits,
    };
}

fn coldParseVisitorNodeTag(kind: ColdParseVisitorKind) @import("../parser/ast.zig").Node.Tag {
    return switch (kind) {
        .program => .program,
        .object_expression => .object_expression,
        .call_expression => .call_expression,
        .class_declaration => .class_declaration,
        .class_expression => .class_expression,
    };
}

fn expectColdParseVisitorInvoked(kind: ColdParseVisitorKind, state: ColdParseVisitorState) !void {
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.observed_tag != null);
    try std.testing.expectEqual(coldParseVisitorNodeTag(kind), state.observed_tag.?);
}

fn expectVisitorGraphReady(graph: *const ModuleGraph, entry: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
    const module_option = graph.findModuleByPath(entry);
    try std.testing.expect(module_option != null);
    const module = module_option.?;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expect(module.semantic != null);
    try std.testing.expect(module.ast != null);
    try std.testing.expect(module.ast.?.transformed_root != null);
    try std.testing.expect(module.transform_cache != null);
    try std.testing.expectEqualSlices(?u32, module.semantic.?.symbol_ids, module.transform_cache.?.symbol_ids);
    for (graph.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.severity != .@"error");
    }
}

fn expectVisitorGraphSkipped(graph: *const ModuleGraph, entry: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
    const module_option = graph.findModuleByPath(entry);
    try std.testing.expect(module_option != null);
    const module = module_option.?;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expect(module.semantic != null);
    try std.testing.expect(module.ast != null);
    try std.testing.expect(module.transform_cache == null);
    for (graph.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.severity != .@"error");
    }
}

fn expectAutomaticJsxGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
    required_runtime_helper_hint: ?[]const u8,
) !void {
    const module = graph.findModuleByPath(entry) orelse return error.MissingAutomaticJsxGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    const ast = &(module.ast orelse return error.MissingAutomaticJsxGraphAst);
    const semantic = &(module.semantic orelse return error.MissingAutomaticJsxGraphSemantic);
    const transform_cache = module.transform_cache orelse return error.MissingAutomaticJsxGraphTransform;
    const root = ast.transformed_root orelse return error.MissingAutomaticJsxGraphRoot;
    // The graph's edited semantic map is authoritative for the final AST;
    // TransformCache.symbol_ids can be a shorter transformer-side overlay.
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);

    var jsx_nodes: usize = 0;
    var call_expressions: usize = 0;
    var import_declarations: usize = 0;
    var props_symbol: ?u32 = null;
    var props_references: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .jsx_element, .jsx_opening_element, .jsx_closing_element, .jsx_fragment, .jsx_opening_fragment, .jsx_closing_fragment => jsx_nodes += 1,
            .call_expression => call_expressions += 1,
            .import_declaration => import_declarations += 1,
            .binding_identifier => if (std.mem.eql(u8, ast.getText(node.data.string_ref), "props")) {
                props_symbol = semantic.symbol_ids[raw];
            },
            .identifier_reference => if (std.mem.eql(u8, ast.getText(node.data.string_ref), "props")) {
                try std.testing.expectEqual(props_symbol orelse return error.MissingAutomaticJsxPropsBinding, semantic.symbol_ids[raw] orelse return error.MissingAutomaticJsxPropsReference);
                props_references += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), jsx_nodes);
    try std.testing.expect(call_expressions > 0);
    try std.testing.expect(import_declarations > 0);
    try std.testing.expect(props_references > 0);

    const helper_bindings = transform_cache.runtime_helper_import_output_bindings;
    try std.testing.expect(helper_bindings.len > 0);
    var found_required_runtime_helper = required_runtime_helper_hint == null;
    for (helper_bindings) |binding| {
        const raw: usize = binding.node_index;
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, binding.node_index) != null);
        try std.testing.expect(raw < semantic.symbol_ids.len);
        const local = ast.nodes.items[raw];
        try std.testing.expect(local.tag == .identifier_reference or local.tag == .import_default_specifier);
        try std.testing.expectEqualStrings(binding.output_name_hint, ast.getText(local.data.string_ref));
        const symbol_id = semantic.symbol_ids[raw] orelse return error.MissingAutomaticJsxHelperSymbol;
        try std.testing.expect(symbol_id < semantic.symbols.items.len);
        const symbol = semantic.symbols.items[symbol_id];
        try std.testing.expectEqual(@as(?@import("../semantic/symbol.zig").SyntheticKind, .runtime_helper_import), symbol.synthetic_kind);
        try std.testing.expectEqualStrings(binding.output_name_hint, symbol.output_name_hint);
        if (required_runtime_helper_hint) |required| {
            if (std.mem.eql(u8, binding.output_name_hint, required)) found_required_runtime_helper = true;
        }

        var exact_reference_nodes: usize = 0;
        for (reachable) |reference_raw| {
            const reference = ast.nodes.items[reference_raw];
            if (reference.tag != .identifier_reference or reference_raw >= semantic.symbol_ids.len) continue;
            if (semantic.symbol_ids[reference_raw] == symbol_id) exact_reference_nodes += 1;
        }
        // One exact identifier is the import local; at least one more must be
        // the JSX-generated call site, both owned by this module's graph.
        try std.testing.expect(exact_reference_nodes >= 2);
    }
    try std.testing.expect(found_required_runtime_helper);
}

fn expectClassicJsxGraphModule(graph: *const ModuleGraph, entry: []const u8) !void {
    const module = graph.findModuleByPath(entry) orelse return error.MissingClassicJsxGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    const ast = &(module.ast orelse return error.MissingClassicJsxGraphAst);
    const semantic = &(module.semantic orelse return error.MissingClassicJsxGraphSemantic);
    const transform_cache = module.transform_cache orelse return error.MissingClassicJsxGraphTransform;
    const root = ast.transformed_root orelse return error.MissingClassicJsxGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqual(@as(usize, 0), transform_cache.runtime_helper_import_output_bindings.len);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);

    var react_symbol: ?u32 = null;
    var props_symbol: ?u32 = null;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        const name = switch (node.tag) {
            .binding_identifier, .import_default_specifier, .identifier_reference => ast.getText(node.data.string_ref),
            else => continue,
        };
        if (node.tag == .import_default_specifier and std.mem.eql(u8, name, "React")) {
            react_symbol = semantic.symbol_ids[raw];
        } else if (node.tag == .binding_identifier and std.mem.eql(u8, name, "props")) {
            props_symbol = semantic.symbol_ids[raw];
        }
    }
    const expected_react_symbol = react_symbol orelse return error.MissingClassicJsxFactoryImportSymbol;
    const expected_props_symbol = props_symbol orelse return error.MissingClassicJsxPropsBinding;
    try std.testing.expect(expected_react_symbol < semantic.symbols.items.len);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.import_binding, semantic.symbols.items[expected_react_symbol].kind);

    var jsx_nodes: usize = 0;
    var call_expressions: usize = 0;
    var react_references: usize = 0;
    var props_references: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        switch (node.tag) {
            .jsx_element, .jsx_opening_element, .jsx_closing_element, .jsx_fragment, .jsx_opening_fragment, .jsx_closing_fragment => jsx_nodes += 1,
            .call_expression => call_expressions += 1,
            .identifier_reference => {
                const name = ast.getText(node.data.string_ref);
                if (std.mem.eql(u8, name, "React")) {
                    try std.testing.expectEqual(expected_react_symbol, semantic.symbol_ids[raw] orelse return error.MissingClassicJsxFactoryReference);
                    react_references += 1;
                } else if (std.mem.eql(u8, name, "props")) {
                    try std.testing.expectEqual(expected_props_symbol, semantic.symbol_ids[raw] orelse return error.MissingClassicJsxPropsReference);
                    props_references += 1;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), jsx_nodes);
    try std.testing.expect(call_expressions > 0);
    try std.testing.expect(react_references > 0);
    try std.testing.expect(props_references > 0);

    var found_external_factory_import = false;
    for (module.import_records) |record| {
        if (record.kind == .static_import and std.mem.eql(u8, record.specifier, "react")) found_external_factory_import = true;
    }
    try std.testing.expect(found_external_factory_import);
}

fn expectTypeScriptEnumGraphModule(graph: *const ModuleGraph, entry: []const u8, enum_name: []const u8) !void {
    const module = graph.findModuleByPath(entry) orelse return error.MissingTypeScriptEnumGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    const ast = &(module.ast orelse return error.MissingTypeScriptEnumGraphAst);
    const semantic = &(module.semantic orelse return error.MissingTypeScriptEnumGraphSemantic);
    _ = module.transform_cache orelse return error.MissingTypeScriptEnumGraphTransform;
    const root = ast.transformed_root orelse return error.MissingTypeScriptEnumGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(
        std.testing.allocator,
        ast,
        root,
    );
    defer std.testing.allocator.free(runtime_references);
    var runtime_reference_nodes = std.AutoHashMapUnmanaged(u32, void).empty;
    defer runtime_reference_nodes.deinit(std.testing.allocator);
    for (runtime_references) |reference| try runtime_reference_nodes.put(std.testing.allocator, @backingInt(reference), {});

    var enum_declarations: usize = 0;
    var enum_binding_nodes = std.AutoHashMapUnmanaged(u32, void).empty;
    defer enum_binding_nodes.deinit(std.testing.allocator);
    var binding_symbols = std.AutoHashMapUnmanaged(u32, void).empty;
    defer binding_symbols.deinit(std.testing.allocator);
    var enum_references: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_enum_declaration) {
            enum_declarations += 1;
            const enum_name_node = ast.readExtraNode(node.data.extra, ast_mod.EnumExtra.name);
            if (!enum_name_node.isNone() and @backingInt(enum_name_node) < ast.nodes.items.len) {
                const enum_name_raw = @backingInt(enum_name_node);
                if (std.mem.eql(u8, ast.identifierNameText(ast.nodes.items[enum_name_raw]), enum_name)) {
                    const symbol_id = semantic.symbol_ids[enum_name_raw] orelse return error.MissingTypeScriptEnumIifeParameterSymbol;
                    try std.testing.expect(symbol_id < semantic.symbols.items.len);
                    try std.testing.expectEqualStrings(enum_name, semantic.symbols.items[symbol_id].nameText(ast.source));
                    try enum_binding_nodes.put(std.testing.allocator, enum_name_raw, {});
                    try binding_symbols.put(std.testing.allocator, symbol_id, {});
                }
            }
            if (semantic.scope_owner_map.get(@intCast(raw))) |enum_scope| {
                for (semantic.symbols.items, 0..) |symbol, symbol_id| {
                    if (symbol.synthetic_kind != .enum_iife_parameter or @backingInt(symbol.scope_id) != enum_scope or
                        !std.mem.eql(u8, symbol.nameText(ast.source), enum_name)) continue;
                    try binding_symbols.put(std.testing.allocator, @intCast(symbol_id), {});
                }
            }
        }
        const is_enum_binding = node.tag == .binding_identifier or enum_binding_nodes.contains(@intCast(raw));
        const is_enum_name = switch (node.tag) {
            .binding_identifier => std.mem.eql(u8, ast.getText(node.data.string_ref), enum_name),
            .assignment_target_identifier => enum_binding_nodes.contains(@intCast(raw)) and
                std.mem.eql(u8, ast.identifierNameText(node), enum_name),
            .identifier_reference => runtime_reference_nodes.contains(@intCast(raw)) and
                std.mem.eql(u8, ast.getText(node.data.string_ref), enum_name),
            else => false,
        };
        if (!is_enum_name) continue;

        const symbol_id = semantic.symbol_ids[raw] orelse return error.MissingTypeScriptEnumSymbolId;
        try std.testing.expect(symbol_id < semantic.symbols.items.len);
        try std.testing.expectEqualStrings(enum_name, semantic.symbols.items[symbol_id].nameText(ast.source));
        if (is_enum_binding) {
            var found_declaration = false;
            for (semantic.references) |reference| {
                if (!reference.flags.declare or reference.declaration_node_index.isNone()) continue;
                if (@backingInt(reference.declaration_node_index) != raw) continue;
                try std.testing.expectEqual(symbol_id, @backingInt(reference.symbol_id));
                found_declaration = true;
            }
            if (node.tag == .binding_identifier) try std.testing.expect(found_declaration);
            try binding_symbols.put(std.testing.allocator, symbol_id, {});
        } else {
            var found_reference = false;
            for (semantic.references) |reference| {
                if (reference.node_index.isNone() or @backingInt(reference.node_index) != raw) continue;
                try std.testing.expect(!reference.flags.declare);
                try std.testing.expectEqual(symbol_id, @backingInt(reference.symbol_id));
                found_reference = true;
            }
            try std.testing.expect(found_reference);
            enum_references += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), enum_declarations);
    try std.testing.expect(binding_symbols.count() > 0);
    try std.testing.expect(enum_references > 0);
    for (semantic.references) |reference| {
        if (reference.node_index.isNone()) continue;
        const raw = @backingInt(reference.node_index);
        if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference) continue;
        if (!runtime_reference_nodes.contains(raw)) continue;
        if (!std.mem.eql(u8, ast.getText(ast.nodes.items[raw].data.string_ref), enum_name)) continue;
        const reference_symbol = @backingInt(reference.symbol_id);
        try std.testing.expect(binding_symbols.contains(reference_symbol));
    }
}

fn expectTypeScriptEnumModuleGraph(
    entries: []const []const u8,
    enum_names: []const []const u8,
    disk: *@import("disk_module_store.zig").DiskModuleStore,
    expected_load_hits: usize,
) !void {
    const profile = @import("../profile.zig");
    profile.resetForTest();
    defer profile.resetForTest();
    profile.setIoForTest(std.testing.io);
    profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = disk;
    graph.disk_load_enabled = true;
    graph.disk_options_hash = 0x6193_4819;
    graph.disk_compiler_build_id = 0x4819;
    graph.max_threads = 1;

    try graph.build(std.testing.io, entries);

    try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
    try std.testing.expect(graph.moduleCount() >= entries.len);
    try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    try std.testing.expectEqual(entries.len, enum_names.len);
    for (entries, enum_names) |entry, enum_name| try expectTypeScriptEnumGraphModule(&graph, entry, enum_name);
    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
}

const TypeScriptNamespaceGraphIdentity = struct {
    namespace_symbol: u32,
    member_a_symbol: u32,
    member_b_symbol: u32,
    destructuring_temp_symbol: u32,
    first_namespace_scope: u32,
    second_namespace_scope: u32,
};

fn expectMergedTypeScriptNamespaceGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
) !TypeScriptNamespaceGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingTypeScriptNamespaceGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    const ast = &(module.ast orelse return error.MissingTypeScriptNamespaceGraphAst);
    const semantic = &(module.semantic orelse return error.MissingTypeScriptNamespaceGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingTypeScriptNamespaceGraphTransform;
    const root = ast.transformed_root orelse return error.MissingTypeScriptNamespaceGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var namespace_symbols: [2]u32 = undefined;
    var namespace_scopes: [2]u32 = undefined;
    var namespace_parameter_symbols: [2]u32 = undefined;
    var namespace_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .ts_module_declaration or node.data.binary.flags != 0) continue;
        const name_node = node.data.binary.left;
        if (name_node.isNone() or @backingInt(name_node) >= ast.nodes.items.len) continue;
        if (!std.mem.eql(u8, ast.identifierNameText(ast.getNode(name_node)), "N")) continue;
        try std.testing.expect(namespace_count < namespace_symbols.len);
        const symbol_id = semantic.symbol_ids[@backingInt(name_node)] orelse return error.MissingTypeScriptNamespaceSymbol;
        try std.testing.expect(symbol_id < semantic.symbols.items.len);
        try std.testing.expectEqualStrings("N", semantic.symbols.items[symbol_id].nameText(ast.source));
        namespace_symbols[namespace_count] = symbol_id;
        namespace_scopes[namespace_count] = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingTypeScriptNamespaceScope;

        var iife_parameters: usize = 0;
        for (semantic.symbols.items, 0..) |symbol, symbol_index| {
            if (symbol.scope_id != @as(ScopeId, @fromBackingInt(namespace_scopes[namespace_count])) or
                symbol.synthetic_kind != .namespace_iife_parameter) continue;
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, symbol.kind);
            namespace_parameter_symbols[namespace_count] = @intCast(symbol_index);
            iife_parameters += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), iife_parameters);
        namespace_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), namespace_count);
    try std.testing.expectEqual(namespace_symbols[0], namespace_symbols[1]);
    // The merged output nodes share one source owner and therefore one
    // canonical declaration row, whose anchor may differ from either emitted
    // node's name index.
    var canonical_namespace_declarations: usize = 0;
    for (semantic.references) |reference| {
        if (!reference.flags.declare or @backingInt(reference.symbol_id) != namespace_symbols[0]) continue;
        const anchor = reference.declaration_node_index;
        if (anchor.isNone() or @backingInt(anchor) >= ast.nodes.items.len) return error.MissingCanonicalTypeScriptNamespaceBinding;
        const anchor_raw = @backingInt(anchor);
        const anchor_node = ast.nodes.items[anchor_raw];
        try std.testing.expectEqual(.binding_identifier, anchor_node.tag);
        try std.testing.expectEqual(namespace_symbols[0], semantic.symbol_ids[anchor_raw] orelse return error.MissingCanonicalTypeScriptNamespaceBindingSymbol);
        try std.testing.expectEqualStrings("N", ast.identifierNameText(anchor_node));
        canonical_namespace_declarations += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), canonical_namespace_declarations);

    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(
        std.testing.allocator,
        ast,
        root,
    );
    defer std.testing.allocator.free(runtime_references);
    var member_a_symbol: ?u32 = null;
    var member_b_symbol: ?u32 = null;
    var members = semantic.namespace_member_owners.iterator();
    while (members.next()) |entry_pair| {
        if (entry_pair.value_ptr.* != namespace_symbols[0]) continue;
        const symbol_id = entry_pair.key_ptr.*;
        try std.testing.expect(symbol_id < semantic.symbols.items.len);
        const name = semantic.symbols.items[symbol_id].nameText(ast.source);
        if (std.mem.eql(u8, name, "a")) member_a_symbol = symbol_id;
        if (std.mem.eql(u8, name, "b")) member_b_symbol = symbol_id;
    }
    const member_a = member_a_symbol orelse return error.MissingTypeScriptNamespaceMemberA;
    const member_b = member_b_symbol orelse return error.MissingTypeScriptNamespaceMemberB;

    // These are namespace export proxies, not source declaration rows. Their
    // owner and source spelling are the retained identity witnesses.
    for ([_]struct { symbol_id: u32, name: []const u8 }{
        .{ .symbol_id = member_a, .name = "a" },
        .{ .symbol_id = member_b, .name = "b" },
    }) |member| {
        const proxy = semantic.symbols.items[member.symbol_id];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, proxy.kind);
        try std.testing.expect(proxy.decl_flags.is_exported);
        try std.testing.expectEqualStrings(member.name, proxy.nameText(ast.source));
    }

    var second_namespace_parameter_reads: usize = 0;
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference) continue;
        const sid = semantic.symbol_ids[raw] orelse continue;
        var exact_rows: usize = 0;
        for (semantic.references) |reference| {
            if (reference.node_index != reference_node) continue;
            try std.testing.expect(!reference.flags.declare);
            try std.testing.expectEqual(sid, @backingInt(reference.symbol_id));
            exact_rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_rows);
        if (sid == member_a) return error.NamespaceProxyReferenceSurvivedLowering;
        if (sid == namespace_parameter_symbols[1]) second_namespace_parameter_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), second_namespace_parameter_reads);

    // Export reads lower from `a` to `N.a`; the object reference is owned by
    // the second IIFE parameter while `b` remains an external namespace read.
    var member_a_accesses: usize = 0;
    var namespace_owner_member_b_reads: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .static_member_expression or node.data.extra + 1 >= ast.extra_data.items.len) continue;
        const object_raw = ast.extra_data.items[node.data.extra];
        const property_raw = ast.extra_data.items[node.data.extra + 1];
        if (property_raw >= ast.nodes.items.len) continue;
        const property_name = ast.getText(ast.nodes.items[property_raw].span);
        if (object_raw < semantic.symbol_ids.len and semantic.symbol_ids[object_raw] == namespace_parameter_symbols[1] and
            std.mem.eql(u8, property_name, "a")) member_a_accesses += 1;
        if (object_raw < semantic.symbol_ids.len and semantic.symbol_ids[object_raw] == namespace_symbols[0] and
            std.mem.eql(u8, property_name, "b")) namespace_owner_member_b_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), member_a_accesses);
    try std.testing.expectEqual(@as(usize, 1), namespace_owner_member_b_reads);

    try std.testing.expectEqual(@as(usize, 1), transformed.destructuring_temp_bindings.count());
    var temp_keys = transformed.destructuring_temp_bindings.keyIterator();
    const temp_raw = temp_keys.next().?.*;
    try std.testing.expect(temp_keys.next() == null);
    try std.testing.expect(temp_raw < ast.nodes.items.len);
    var temp_is_reachable = false;
    for (reachable) |raw| if (raw == temp_raw) {
        temp_is_reachable = true;
        break;
    };
    try std.testing.expect(temp_is_reachable);
    const temp_node = ast.nodes.items[temp_raw];
    try std.testing.expectEqual(.binding_identifier, temp_node.tag);
    try std.testing.expect((temp_node.span.start & ast_mod.Ast.STRING_TABLE_BIT) != 0);
    const temp_symbol = semantic.symbol_ids[temp_raw] orelse return error.MissingTypeScriptNamespaceTempSymbol;
    try std.testing.expect(temp_symbol < semantic.symbols.items.len);
    try std.testing.expect(semantic.symbols.items[temp_symbol].scope_id == @as(ScopeId, @fromBackingInt(namespace_scopes[0])));
    var temp_declaration_rows: usize = 0;
    for (semantic.references) |reference| {
        if (!reference.flags.declare or reference.declaration_node_index != @as(ast_mod.NodeIndex, @fromBackingInt(temp_raw))) continue;
        try std.testing.expectEqual(temp_symbol, @backingInt(reference.symbol_id));
        temp_declaration_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), temp_declaration_rows);

    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    return .{
        .namespace_symbol = namespace_symbols[0],
        .member_a_symbol = member_a,
        .member_b_symbol = member_b,
        .destructuring_temp_symbol = temp_symbol,
        .first_namespace_scope = namespace_scopes[0],
        .second_namespace_scope = namespace_scopes[1],
    };
}

const TypeScriptImportEqualsGraphIdentity = struct {
    namespace_symbol: u32,
    alias_symbol: u32,
    namespace_scope: u32,
    alias_scope: u32,
};

fn expectImportEqualsReferenceRow(semantic: anytype, node: ast_mod.NodeIndex, symbol_id: u32) !void {
    var rows: usize = 0;
    for (semantic.references) |reference| {
        if (reference.node_index != node) continue;
        try std.testing.expect(!reference.flags.declare);
        try std.testing.expectEqual(symbol_id, @backingInt(reference.symbol_id));
        rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rows);
}

fn expectLocalImportEqualsGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
) !TypeScriptImportEqualsGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingImportEqualsGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(@as(usize, 0), module.import_records.len);
    const ast = &(module.ast orelse return error.MissingImportEqualsGraphAst);
    const semantic = &(module.semantic orelse return error.MissingImportEqualsGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingImportEqualsGraphTransform;
    const root = ast.transformed_root orelse return error.MissingImportEqualsGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    var source_local: ast_mod.NodeIndex = .none;
    var source_value: ast_mod.NodeIndex = .none;
    var source_import_span: @import("../lexer/token.zig").Span = .EMPTY;
    var source_imports: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag != .ts_import_equals_declaration) continue;
        source_imports += 1;
        source_import_span = node.span;
        source_local = node.data.binary.left;
        source_value = node.data.binary.right;
    }
    try std.testing.expectEqual(@as(usize, 1), source_imports);
    try std.testing.expect(!source_local.isNone() and @backingInt(source_local) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_local).tag);
    try std.testing.expectEqualStrings("Alias", ast.identifierNameText(ast.getNode(source_local)));
    const alias_symbol = semantic.symbol_ids[@backingInt(source_local)] orelse return error.MissingImportEqualsAliasSymbol;
    try std.testing.expect(alias_symbol < semantic.symbols.items.len);
    const alias_symbol_data = semantic.symbols.items[alias_symbol];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, alias_symbol_data.kind);
    try std.testing.expectEqualStrings("Alias", alias_symbol_data.nameText(ast.source));
    try std.testing.expect(std.meta.eql(ast.getNode(source_local).span, alias_symbol_data.name));
    try std.testing.expect(std.meta.eql(source_import_span, alias_symbol_data.declaration_span));
    try std.testing.expect(!alias_symbol_data.scope_id.isNone());
    try std.testing.expect(!source_value.isNone() and @backingInt(source_value) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_value).tag);
    try std.testing.expectEqualStrings("Source", ast.identifierNameText(ast.getNode(source_value)));

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var namespace_symbol: ?u32 = null;
    var namespace_scope: ?u32 = null;
    var namespace_count: usize = 0;
    var alias_binding: ast_mod.NodeIndex = .none;
    var alias_binding_count: usize = 0;
    var alias_initializer: ast_mod.NodeIndex = .none;
    var alias_declarator_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_import_equals_declaration) return error.ImportEqualsSurvivedLowering;
        if (node.tag == .ts_module_declaration and node.data.binary.flags == 0) {
            const name = node.data.binary.left;
            if (!name.isNone() and @backingInt(name) < ast.nodes.items.len and
                ast.getNode(name).tag == .binding_identifier and
                std.mem.eql(u8, ast.identifierNameText(ast.getNode(name)), "Source"))
            {
                namespace_symbol = semantic.symbol_ids[@backingInt(name)] orelse return error.MissingImportEqualsNamespaceSymbol;
                namespace_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingImportEqualsNamespaceScope;
                namespace_count += 1;
            }
        }
        if (node.tag == .binding_identifier and std.mem.eql(u8, ast.identifierNameText(node), "Alias")) {
            if (semantic.symbol_ids[raw] == alias_symbol) {
                alias_binding = @fromBackingInt(@intCast(raw));
                alias_binding_count += 1;
            }
        }
        if (node.tag != .variable_declarator or !ast.hasExtra(node.data.extra, 2)) continue;
        const binding = ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(binding)), "Alias") or semantic.symbol_ids[@backingInt(binding)] != alias_symbol) continue;
        alias_initializer = ast.readExtraNode(node.data.extra, 2);
        alias_declarator_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), namespace_count);
    try std.testing.expectEqual(@as(usize, 1), alias_binding_count);
    try std.testing.expectEqual(@as(usize, 1), alias_declarator_count);
    const source_namespace_symbol = namespace_symbol orelse return error.MissingImportEqualsNamespaceSymbol;
    const source_namespace_scope = namespace_scope orelse return error.MissingImportEqualsNamespaceScope;
    try std.testing.expect(source_namespace_symbol != alias_symbol);
    try std.testing.expect(!alias_binding.isNone());
    try std.testing.expect(std.meta.eql(ast.getNode(alias_binding).span, ast.getNode(source_local).span));
    try std.testing.expectEqual(source_namespace_symbol, semantic.symbol_ids[@backingInt(source_value)] orelse return error.MissingImportEqualsSourceNamespaceSymbol);

    const alias_scope = @backingInt(semantic.symbols.items[alias_symbol].scope_id);
    try std.testing.expect(alias_scope < semantic.scope_maps.len);
    try std.testing.expectEqual(@as(?usize, alias_symbol), semantic.scope_maps[alias_scope].get("Alias"));

    try std.testing.expect(!alias_initializer.isNone() and @backingInt(alias_initializer) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(alias_initializer).tag);
    try std.testing.expectEqualStrings("Source", ast.identifierNameText(ast.getNode(alias_initializer)));
    try std.testing.expect(std.meta.eql(ast.getNode(alias_initializer).span, ast.getNode(source_value).span));
    try std.testing.expectEqual(source_namespace_symbol, semantic.symbol_ids[@backingInt(alias_initializer)] orelse return error.MissingImportEqualsSourceReferenceSymbol);
    try expectImportEqualsReferenceRow(semantic, alias_initializer, source_namespace_symbol);

    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(
        std.testing.allocator,
        ast,
        root,
    );
    defer std.testing.allocator.free(runtime_references);
    var alias_runtime_references: usize = 0;
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference or
            !std.mem.eql(u8, ast.identifierNameText(ast.nodes.items[raw]), "Alias")) continue;
        try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[raw] orelse return error.MissingImportEqualsOutputReferenceSymbol);
        try expectImportEqualsReferenceRow(semantic, reference_node, alias_symbol);
        alias_runtime_references += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_runtime_references);

    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    return .{
        .namespace_symbol = source_namespace_symbol,
        .alias_symbol = alias_symbol,
        .namespace_scope = source_namespace_scope,
        .alias_scope = alias_scope,
    };
}

const TypeScriptExternalImportEqualsGraphIdentity = struct {
    alias_symbol: u32,
    alias_scope: u32,
};

fn expectStaticRequireExpression(ast: *const ast_mod.Ast, expression: ast_mod.NodeIndex, specifier: []const u8) !void {
    try std.testing.expect(!expression.isNone() and @backingInt(expression) < ast.nodes.items.len);
    const call = ast.getNode(expression);
    try std.testing.expectEqual(.call_expression, call.tag);
    try std.testing.expect(ast.hasExtra(call.data.extra, 3));
    const callee = ast.readExtraNode(call.data.extra, 0);
    try std.testing.expect(!callee.isNone() and @backingInt(callee) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(callee).tag);
    try std.testing.expectEqualStrings("require", ast.identifierNameText(ast.getNode(callee)));
    try std.testing.expectEqual(@as(u32, 1), ast.readExtra(call.data.extra, 2));
    const args_start = ast.readExtra(call.data.extra, 1);
    try std.testing.expect(args_start < ast.extra_data.items.len);
    const argument: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    try std.testing.expect(!argument.isNone() and @backingInt(argument) < ast.nodes.items.len);
    const argument_node = ast.getNode(argument);
    try std.testing.expectEqual(.string_literal, argument_node.tag);
    const text = @import("import_scanner.zig").stripQuotes(ast.getText(argument_node.span)) orelse return error.InvalidImportEqualsRequireSpecifier;
    try std.testing.expectEqualStrings(specifier, text);
}

fn expectExternalImportEqualsGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
    specifier: []const u8,
) !TypeScriptExternalImportEqualsGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingExternalImportEqualsGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(types.ExportsKind.commonjs, module.exports_kind);
    try std.testing.expectEqual(types.WrapKind.cjs, module.wrap_kind);
    try std.testing.expect(module.has_cjs_export_signal);
    try std.testing.expectEqual(@as(usize, 1), module.import_records.len);
    const record = module.import_records[0];
    try std.testing.expectEqual(types.ImportKind.require, record.kind);
    try std.testing.expectEqualStrings(specifier, record.specifier);
    try std.testing.expect(record.is_external);
    try std.testing.expect(record.resolved.isNone());
    try std.testing.expect(!record.resolve_failed);

    const ast = &(module.ast orelse return error.MissingExternalImportEqualsGraphAst);
    const semantic = &(module.semantic orelse return error.MissingExternalImportEqualsGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingExternalImportEqualsGraphTransform;
    const root = ast.transformed_root orelse return error.MissingExternalImportEqualsGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    var source_local: ast_mod.NodeIndex = .none;
    var source_value: ast_mod.NodeIndex = .none;
    var source_export_local: ast_mod.NodeIndex = .none;
    var source_import_span: @import("../lexer/token.zig").Span = .EMPTY;
    var source_import_count: usize = 0;
    var source_export_count: usize = 0;
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .ts_import_equals_declaration => {
                source_import_count += 1;
                source_import_span = node.span;
                source_local = node.data.binary.left;
                source_value = node.data.binary.right;
            },
            .ts_export_assignment => {
                source_export_count += 1;
                source_export_local = node.data.unary.operand;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), source_import_count);
    try std.testing.expectEqual(@as(usize, 1), source_export_count);
    try std.testing.expect(!source_local.isNone() and @backingInt(source_local) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_local).tag);
    try std.testing.expectEqualStrings("Assert", ast.identifierNameText(ast.getNode(source_local)));
    try expectStaticRequireExpression(ast, source_value, specifier);

    const alias_symbol = semantic.symbol_ids[@backingInt(source_local)] orelse return error.MissingExternalImportEqualsAliasSymbol;
    try std.testing.expect(alias_symbol < semantic.symbols.items.len);
    const alias_symbol_data = semantic.symbols.items[alias_symbol];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, alias_symbol_data.kind);
    try std.testing.expectEqualStrings("Assert", alias_symbol_data.nameText(ast.source));
    try std.testing.expect(std.meta.eql(ast.getNode(source_local).span, alias_symbol_data.name));
    try std.testing.expect(std.meta.eql(source_import_span, alias_symbol_data.declaration_span));
    try std.testing.expect(!alias_symbol_data.scope_id.isNone());
    try std.testing.expect(!source_export_local.isNone() and @backingInt(source_export_local) < ast.nodes.items.len);
    const alias_scope = @backingInt(alias_symbol_data.scope_id);
    try std.testing.expect(alias_scope < semantic.scope_maps.len);
    try std.testing.expectEqual(@as(?usize, alias_symbol), semantic.scope_maps[alias_scope].get("Assert"));
    try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[@backingInt(source_export_local)] orelse return error.MissingExternalImportEqualsExportSymbol);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var alias_binding: ast_mod.NodeIndex = .none;
    var alias_binding_count: usize = 0;
    var alias_initializer: ast_mod.NodeIndex = .none;
    var alias_declarator_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_import_equals_declaration or node.tag == .ts_export_assignment)
            return error.ImportEqualsOrExportAssignmentSurvivedLowering;
        if (node.tag == .binding_identifier and std.mem.eql(u8, ast.identifierNameText(node), "Assert") and
            semantic.symbol_ids[raw] == alias_symbol)
        {
            alias_binding = @fromBackingInt(@intCast(raw));
            alias_binding_count += 1;
        }
        if (node.tag != .variable_declarator or !ast.hasExtra(node.data.extra, 2)) continue;
        const binding = ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(binding)), "Assert") or semantic.symbol_ids[@backingInt(binding)] != alias_symbol) continue;
        alias_initializer = ast.readExtraNode(node.data.extra, 2);
        alias_declarator_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_binding_count);
    try std.testing.expectEqual(@as(usize, 1), alias_declarator_count);
    try std.testing.expect(!alias_binding.isNone());
    try std.testing.expect(std.meta.eql(ast.getNode(alias_binding).span, ast.getNode(source_local).span));
    try expectStaticRequireExpression(ast, alias_initializer, specifier);
    try std.testing.expect(std.meta.eql(ast.getNode(alias_initializer).span, ast.getNode(source_value).span));

    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(
        std.testing.allocator,
        ast,
        root,
    );
    defer std.testing.allocator.free(runtime_references);
    var alias_runtime_references: usize = 0;
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference or
            !std.mem.eql(u8, ast.identifierNameText(ast.nodes.items[raw]), "Assert")) continue;
        try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[raw] orelse return error.MissingExternalImportEqualsOutputReferenceSymbol);
        try expectImportEqualsReferenceRow(semantic, reference_node, alias_symbol);
        alias_runtime_references += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_runtime_references);

    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    return .{ .alias_symbol = alias_symbol, .alias_scope = alias_scope };
}

fn expectSourceNamespaceMemberExpression(
    ast: *const ast_mod.Ast,
    expression: ast_mod.NodeIndex,
) !ast_mod.NodeIndex {
    try std.testing.expect(!expression.isNone() and @backingInt(expression) < ast.nodes.items.len);
    const member = ast.getNode(expression);
    try std.testing.expectEqual(.static_member_expression, member.tag);
    try std.testing.expect(ast.hasExtra(member.data.extra, 2));
    const object = ast.readExtraNode(member.data.extra, 0);
    const property = ast.readExtraNode(member.data.extra, 1);
    try std.testing.expect(!object.isNone() and @backingInt(object) < ast.nodes.items.len);
    try std.testing.expect(!property.isNone() and @backingInt(property) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(object).tag);
    try std.testing.expectEqualStrings("Source", ast.identifierNameText(ast.getNode(object)));
    try std.testing.expectEqualStrings("Inner", ast.getText(ast.getNode(property).span));
    return object;
}

fn expectQualifiedLocalImportEqualsGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
) !TypeScriptImportEqualsGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingQualifiedImportEqualsGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(@as(usize, 0), module.import_records.len);
    const ast = &(module.ast orelse return error.MissingQualifiedImportEqualsGraphAst);
    const semantic = &(module.semantic orelse return error.MissingQualifiedImportEqualsGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingQualifiedImportEqualsGraphTransform;
    const root = ast.transformed_root orelse return error.MissingQualifiedImportEqualsGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    var source_local: ast_mod.NodeIndex = .none;
    var source_value: ast_mod.NodeIndex = .none;
    var source_import_span: @import("../lexer/token.zig").Span = .EMPTY;
    var source_import_count: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag != .ts_import_equals_declaration) continue;
        source_import_count += 1;
        source_import_span = node.span;
        source_local = node.data.binary.left;
        source_value = node.data.binary.right;
    }
    try std.testing.expectEqual(@as(usize, 1), source_import_count);
    try std.testing.expect(!source_local.isNone() and @backingInt(source_local) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_local).tag);
    try std.testing.expectEqualStrings("DeepAlias", ast.identifierNameText(ast.getNode(source_local)));
    const alias_symbol = semantic.symbol_ids[@backingInt(source_local)] orelse return error.MissingQualifiedImportEqualsAliasSymbol;
    try std.testing.expect(alias_symbol < semantic.symbols.items.len);
    const alias_symbol_data = semantic.symbols.items[alias_symbol];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, alias_symbol_data.kind);
    try std.testing.expectEqualStrings("DeepAlias", alias_symbol_data.nameText(ast.source));
    try std.testing.expect(std.meta.eql(ast.getNode(source_local).span, alias_symbol_data.name));
    try std.testing.expect(std.meta.eql(source_import_span, alias_symbol_data.declaration_span));
    try std.testing.expect(!alias_symbol_data.scope_id.isNone());
    const alias_scope = @backingInt(alias_symbol_data.scope_id);
    try std.testing.expect(alias_scope < semantic.scope_maps.len);
    try std.testing.expectEqual(@as(?usize, alias_symbol), semantic.scope_maps[alias_scope].get("DeepAlias"));

    const source_namespace_reference = try expectSourceNamespaceMemberExpression(ast, source_value);
    const source_namespace_symbol = semantic.symbol_ids[@backingInt(source_namespace_reference)] orelse return error.MissingQualifiedImportEqualsNamespaceReferenceSymbol;
    try std.testing.expect(source_namespace_symbol != alias_symbol);
    try expectImportEqualsReferenceRow(semantic, source_namespace_reference, source_namespace_symbol);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var namespace_symbol: ?u32 = null;
    var namespace_scope: ?u32 = null;
    var namespace_count: usize = 0;
    var alias_binding: ast_mod.NodeIndex = .none;
    var alias_binding_count: usize = 0;
    var alias_initializer: ast_mod.NodeIndex = .none;
    var alias_declarator_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_import_equals_declaration) return error.QualifiedImportEqualsSurvivedLowering;
        if (node.tag == .ts_module_declaration and node.data.binary.flags == 0) {
            const name = node.data.binary.left;
            if (!name.isNone() and @backingInt(name) < ast.nodes.items.len and
                ast.getNode(name).tag == .binding_identifier and
                std.mem.eql(u8, ast.identifierNameText(ast.getNode(name)), "Source"))
            {
                namespace_symbol = semantic.symbol_ids[@backingInt(name)] orelse return error.MissingQualifiedImportEqualsNamespaceSymbol;
                namespace_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingQualifiedImportEqualsNamespaceScope;
                namespace_count += 1;
            }
        }
        if (node.tag == .binding_identifier and std.mem.eql(u8, ast.identifierNameText(node), "DeepAlias") and
            semantic.symbol_ids[raw] == alias_symbol)
        {
            alias_binding = @fromBackingInt(@intCast(raw));
            alias_binding_count += 1;
        }
        if (node.tag != .variable_declarator or !ast.hasExtra(node.data.extra, 2)) continue;
        const binding = ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(binding)), "DeepAlias") or semantic.symbol_ids[@backingInt(binding)] != alias_symbol) continue;
        alias_initializer = ast.readExtraNode(node.data.extra, 2);
        alias_declarator_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), namespace_count);
    try std.testing.expectEqual(@as(usize, 1), alias_binding_count);
    try std.testing.expectEqual(@as(usize, 1), alias_declarator_count);
    const emitted_namespace_symbol = namespace_symbol orelse return error.MissingQualifiedImportEqualsNamespaceSymbol;
    const emitted_namespace_scope = namespace_scope orelse return error.MissingQualifiedImportEqualsNamespaceScope;
    try std.testing.expectEqual(source_namespace_symbol, emitted_namespace_symbol);
    try std.testing.expect(!alias_binding.isNone());
    try std.testing.expect(std.meta.eql(ast.getNode(alias_binding).span, ast.getNode(source_local).span));
    const output_namespace_reference = try expectSourceNamespaceMemberExpression(ast, alias_initializer);
    try std.testing.expect(std.meta.eql(ast.getNode(alias_initializer).span, ast.getNode(source_value).span));
    try std.testing.expectEqual(source_namespace_symbol, semantic.symbol_ids[@backingInt(output_namespace_reference)] orelse return error.MissingQualifiedImportEqualsOutputNamespaceSymbol);
    try expectImportEqualsReferenceRow(semantic, output_namespace_reference, source_namespace_symbol);

    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(
        std.testing.allocator,
        ast,
        root,
    );
    defer std.testing.allocator.free(runtime_references);
    var alias_runtime_references: usize = 0;
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference or
            !std.mem.eql(u8, ast.identifierNameText(ast.nodes.items[raw]), "DeepAlias")) continue;
        try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[raw] orelse return error.MissingQualifiedImportEqualsOutputReferenceSymbol);
        try expectImportEqualsReferenceRow(semantic, reference_node, alias_symbol);
        alias_runtime_references += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_runtime_references);

    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    return .{
        .namespace_symbol = emitted_namespace_symbol,
        .alias_symbol = alias_symbol,
        .namespace_scope = emitted_namespace_scope,
        .alias_scope = alias_scope,
    };
}

const TypeScriptNestedImportEqualsGraphIdentity = struct {
    alias_symbol: u32,
    nested_symbol: u32,
    container_scope: u32,
    nested_scope: u32,
    alias_scope: u32,
    capture_scope: u32,
};

fn semanticScopeContains(semantic: anytype, ancestor: ScopeId, descendant: ScopeId) bool {
    if (ancestor.isNone() or descendant.isNone()) return false;
    var current = descendant;
    for (0..semantic.scopes.len) |_| {
        if (current == ancestor) return true;
        if (current.isNone() or @backingInt(current) >= semantic.scopes.len) return false;
        current = semantic.scopes[@backingInt(current)].parent;
    }
    return false;
}

fn expectNestedImportEqualsGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
    expect_exported_alias: bool,
) !TypeScriptNestedImportEqualsGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingNestedImportEqualsGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(@as(usize, 0), module.import_records.len);
    const ast = &(module.ast orelse return error.MissingNestedImportEqualsGraphAst);
    const semantic = &(module.semantic orelse return error.MissingNestedImportEqualsGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingNestedImportEqualsGraphTransform;
    const root = ast.transformed_root orelse return error.MissingNestedImportEqualsGraphRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    var source_local: ast_mod.NodeIndex = .none;
    var source_value: ast_mod.NodeIndex = .none;
    var source_import_span: @import("../lexer/token.zig").Span = .EMPTY;
    var source_import_count: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag != .ts_import_equals_declaration) continue;
        source_import_count += 1;
        source_import_span = node.span;
        source_local = node.data.binary.left;
        source_value = node.data.binary.right;
    }
    try std.testing.expectEqual(@as(usize, 1), source_import_count);
    try std.testing.expect(!source_local.isNone() and @backingInt(source_local) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_local).tag);
    try std.testing.expectEqualStrings("NestedAlias", ast.identifierNameText(ast.getNode(source_local)));
    try std.testing.expect(!source_value.isNone() and @backingInt(source_value) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_value).tag);
    try std.testing.expectEqualStrings("Nested", ast.identifierNameText(ast.getNode(source_value)));

    const alias_symbol = semantic.symbol_ids[@backingInt(source_local)] orelse return error.MissingNestedImportEqualsAliasSymbol;
    try std.testing.expect(alias_symbol < semantic.symbols.items.len);
    const alias_symbol_data = semantic.symbols.items[alias_symbol];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, alias_symbol_data.kind);
    try std.testing.expectEqualStrings("NestedAlias", alias_symbol_data.nameText(ast.source));
    try std.testing.expect(std.meta.eql(ast.getNode(source_local).span, alias_symbol_data.name));
    try std.testing.expect(std.meta.eql(source_import_span, alias_symbol_data.declaration_span));
    try std.testing.expect(!alias_symbol_data.scope_id.isNone());

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var container_scope: ?u32 = null;
    var container_count: usize = 0;
    var nested_symbol: ?u32 = null;
    var nested_scope: ?u32 = null;
    var nested_count: usize = 0;
    var alias_binding: ast_mod.NodeIndex = .none;
    var alias_binding_count: usize = 0;
    var alias_initializer: ast_mod.NodeIndex = .none;
    var alias_declarator_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_import_equals_declaration) return error.NestedImportEqualsSurvivedLowering;
        if (node.tag == .ts_module_declaration and node.data.binary.flags == 0) {
            const name = node.data.binary.left;
            if (!name.isNone() and @backingInt(name) < ast.nodes.items.len and
                ast.getNode(name).tag == .binding_identifier)
            {
                const name_text = ast.identifierNameText(ast.getNode(name));
                if (std.mem.eql(u8, name_text, "Container")) {
                    container_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingNestedImportEqualsContainerScope;
                    container_count += 1;
                } else if (std.mem.eql(u8, name_text, "Nested")) {
                    nested_symbol = semantic.symbol_ids[@backingInt(name)] orelse return error.MissingNestedImportEqualsNamespaceSymbol;
                    nested_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingNestedImportEqualsNamespaceScope;
                    nested_count += 1;
                }
            }
        }
        if (node.tag == .binding_identifier and std.mem.eql(u8, ast.identifierNameText(node), "NestedAlias") and
            semantic.symbol_ids[raw] == alias_symbol)
        {
            alias_binding = @fromBackingInt(@intCast(raw));
            alias_binding_count += 1;
        }
        if (node.tag != .variable_declarator or !ast.hasExtra(node.data.extra, 2)) continue;
        const binding = ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(binding)), "NestedAlias") or semantic.symbol_ids[@backingInt(binding)] != alias_symbol) continue;
        alias_initializer = ast.readExtraNode(node.data.extra, 2);
        alias_declarator_count += 1;
    }
    var alias_export_declaration_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .export_named_declaration or !ast.hasExtra(node.data.extra, 1)) continue;
        const declaration_idx = ast.readExtraNode(node.data.extra, 0);
        if (declaration_idx.isNone() or @backingInt(declaration_idx) >= ast.nodes.items.len) continue;
        const declaration = ast.getNode(declaration_idx);
        if (declaration.tag != .variable_declaration) continue;
        const declaration_extra: usize = declaration.data.extra;
        if (declaration_extra > ast.extra_data.items.len or ast.extra_data.items.len - declaration_extra <= 2) continue;
        const declarators_start = ast.extra_data.items[declaration_extra + 1];
        const declarators_len = ast.extra_data.items[declaration_extra + 2];
        if (declarators_start > ast.extra_data.items.len or declarators_len > ast.extra_data.items.len - declarators_start) continue;
        for (ast.extra_data.items[declarators_start .. declarators_start + declarators_len]) |raw_declarator| {
            const declarator_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_declarator));
            if (declarator_idx.isNone() or @backingInt(declarator_idx) >= ast.nodes.items.len) continue;
            const declarator = ast.getNode(declarator_idx);
            if (declarator.tag != .variable_declarator or !ast.hasExtra(declarator.data.extra, 1)) continue;
            const binding = ast.readExtraNode(declarator.data.extra, 0);
            if (!binding.isNone() and @backingInt(binding) < ast.nodes.items.len and
                semantic.symbol_ids[@backingInt(binding)] == alias_symbol)
            {
                alias_export_declaration_count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), container_count);
    try std.testing.expectEqual(@as(usize, 1), nested_count);
    try std.testing.expectEqual(@as(usize, 1), alias_binding_count);
    try std.testing.expectEqual(@as(usize, 1), alias_declarator_count);
    try std.testing.expectEqual(if (expect_exported_alias) @as(usize, 1) else 0, alias_export_declaration_count);
    const container_owner_scope = container_scope orelse return error.MissingNestedImportEqualsContainerScope;
    const nested_owner_scope = nested_scope orelse return error.MissingNestedImportEqualsNamespaceScope;
    const nested_namespace_symbol = nested_symbol orelse return error.MissingNestedImportEqualsNamespaceSymbol;
    const alias_scope = @backingInt(alias_symbol_data.scope_id);
    try std.testing.expectEqual(container_owner_scope, alias_scope);
    try std.testing.expect(alias_scope < semantic.scope_maps.len);
    try std.testing.expectEqual(nested_namespace_symbol, semantic.symbol_ids[@backingInt(source_value)] orelse return error.MissingNestedImportEqualsSourceSymbol);
    try std.testing.expectEqual(@as(?usize, alias_symbol), semantic.scope_maps[alias_scope].get("NestedAlias"));
    try std.testing.expect(!alias_binding.isNone());
    try std.testing.expect(std.meta.eql(ast.getNode(alias_binding).span, ast.getNode(source_local).span));

    try std.testing.expect(!alias_initializer.isNone() and @backingInt(alias_initializer) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(alias_initializer).tag);
    try std.testing.expectEqualStrings("Nested", ast.identifierNameText(ast.getNode(alias_initializer)));
    try std.testing.expect(std.meta.eql(ast.getNode(alias_initializer).span, ast.getNode(source_value).span));
    try std.testing.expectEqual(nested_namespace_symbol, semantic.symbol_ids[@backingInt(alias_initializer)] orelse return error.MissingNestedImportEqualsOutputSymbol);
    try expectImportEqualsReferenceRow(semantic, source_value, nested_namespace_symbol);
    try expectImportEqualsReferenceRow(semantic, alias_initializer, nested_namespace_symbol);

    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(
        std.testing.allocator,
        ast,
        root,
    );
    defer std.testing.allocator.free(runtime_references);
    var alias_runtime_references: usize = 0;
    var exported_alias_accesses: usize = 0;
    var capture_scope: ?u32 = null;
    var container_parameter_symbol: ?u32 = null;
    var container_parameter_count: usize = 0;
    if (expect_exported_alias) {
        for (semantic.symbols.items, 0..) |symbol, index| {
            if (symbol.synthetic_kind != .namespace_iife_parameter or @backingInt(symbol.scope_id) != container_owner_scope) continue;
            container_parameter_symbol = @intCast(index);
            container_parameter_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), container_parameter_count);
    }
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len) continue;
        const reference_node_data = ast.nodes.items[raw];
        if (reference_node_data.tag == .identifier_reference and
            std.mem.eql(u8, ast.identifierNameText(reference_node_data), "NestedAlias"))
        {
            try std.testing.expect(!expect_exported_alias);
            try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[raw] orelse return error.MissingNestedImportEqualsOutputReferenceSymbol);
            var reference_rows: usize = 0;
            for (semantic.references) |reference| {
                if (reference.node_index != reference_node) continue;
                try std.testing.expect(!reference.flags.declare);
                try std.testing.expectEqual(alias_symbol, @backingInt(reference.symbol_id));
                try std.testing.expect(semanticScopeContains(semantic, @as(ScopeId, @fromBackingInt(alias_scope)), reference.scope_id));
                try std.testing.expect(reference.scope_id != @as(ScopeId, @fromBackingInt(alias_scope)));
                capture_scope = @backingInt(reference.scope_id);
                reference_rows += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), reference_rows);
            alias_runtime_references += 1;
        }
    }
    if (expect_exported_alias) for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .static_member_expression or !ast.hasExtra(node.data.extra, 2)) continue;
        const property = ast.readExtraNode(node.data.extra, 1);
        if (property.isNone() or @backingInt(property) >= ast.nodes.items.len or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(property)), "NestedAlias")) continue;
        const object = ast.readExtraNode(node.data.extra, 0);
        try std.testing.expect(!object.isNone() and @backingInt(object) < ast.nodes.items.len);
        try std.testing.expectEqual(.identifier_reference, ast.getNode(object).tag);
        const parameter_symbol = container_parameter_symbol orelse return error.MissingNestedImportEqualsContainerParameter;
        try std.testing.expectEqual(parameter_symbol, semantic.symbol_ids[@backingInt(object)] orelse return error.MissingNestedImportEqualsContainerParameterReference);
        var reference_rows: usize = 0;
        for (semantic.references) |reference| {
            if (reference.node_index != object) continue;
            try std.testing.expect(!reference.flags.declare);
            try std.testing.expectEqual(parameter_symbol, @backingInt(reference.symbol_id));
            try std.testing.expect(semanticScopeContains(semantic, @as(ScopeId, @fromBackingInt(alias_scope)), reference.scope_id));
            try std.testing.expect(reference.scope_id != @as(ScopeId, @fromBackingInt(alias_scope)));
            capture_scope = @backingInt(reference.scope_id);
            reference_rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), reference_rows);
        exported_alias_accesses += 1;
    };
    try std.testing.expectEqual(if (expect_exported_alias) @as(usize, 0) else 1, alias_runtime_references);
    try std.testing.expectEqual(if (expect_exported_alias) @as(usize, 1) else 0, exported_alias_accesses);
    try std.testing.expect(capture_scope != null);
    try std.testing.expect(nested_owner_scope != container_owner_scope);

    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    return .{
        .alias_symbol = alias_symbol,
        .nested_symbol = nested_namespace_symbol,
        .container_scope = container_owner_scope,
        .nested_scope = nested_owner_scope,
        .alias_scope = alias_scope,
        .capture_scope = capture_scope.?,
    };
}

fn expectNestedImportEqualsGraphColdAndCached(
    source: []const u8,
    expect_exported_alias: bool,
) !TypeScriptNestedImportEqualsGraphIdentity {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    defer profile.resetForTest();
    var cold_identity: ?TypeScriptNestedImportEqualsGraphIdentity = null;
    for ([_]usize{ 0, 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819;
        graph.max_threads = 1;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const identity = try expectNestedImportEqualsGraphModule(&graph, entry, expect_exported_alias);
        if (cold_identity) |cold| {
            try std.testing.expectEqual(cold.alias_symbol, identity.alias_symbol);
            try std.testing.expectEqual(cold.nested_symbol, identity.nested_symbol);
            try std.testing.expectEqual(cold.container_scope, identity.container_scope);
            try std.testing.expectEqual(cold.nested_scope, identity.nested_scope);
            try std.testing.expectEqual(cold.alias_scope, identity.alias_scope);
            try std.testing.expectEqual(cold.capture_scope, identity.capture_scope);
        } else {
            cold_identity = identity;
        }
    }
    return cold_identity orelse error.MissingNestedImportEqualsColdIdentity;
}

const TypeScriptNamespaceExternalImportEqualsGraphIdentity = struct {
    alias_symbol: u32,
    namespace_symbol: u32,
    namespace_parameter_symbol: u32,
    namespace_scope: u32,
    alias_scope: u32,
    capture_scope: u32,
};

fn expectNamespaceExternalImportEqualsGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
    specifier: []const u8,
) !TypeScriptNamespaceExternalImportEqualsGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingNamespaceExternalImportEqualsModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(@as(usize, 1), module.import_records.len);
    const record = module.import_records[0];
    try std.testing.expectEqual(types.ImportKind.require, record.kind);
    try std.testing.expectEqualStrings(specifier, record.specifier);
    try std.testing.expect(record.is_external);
    try std.testing.expect(record.resolved.isNone());
    try std.testing.expect(!record.resolve_failed);

    const ast = &(module.ast orelse return error.MissingNamespaceExternalImportEqualsAst);
    const semantic = &(module.semantic orelse return error.MissingNamespaceExternalImportEqualsSemantic);
    const transformed = module.transform_cache orelse return error.MissingNamespaceExternalImportEqualsTransform;
    const root = ast.transformed_root orelse return error.MissingNamespaceExternalImportEqualsRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    var source_local: ast_mod.NodeIndex = .none;
    var source_value: ast_mod.NodeIndex = .none;
    var source_import_span: @import("../lexer/token.zig").Span = .EMPTY;
    var source_import_count: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag != .ts_import_equals_declaration) continue;
        source_import_count += 1;
        source_import_span = node.span;
        source_local = node.data.binary.left;
        source_value = node.data.binary.right;
    }
    try std.testing.expectEqual(@as(usize, 1), source_import_count);
    try std.testing.expect(!source_local.isNone() and @backingInt(source_local) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_local).tag);
    try std.testing.expectEqualStrings("Assert", ast.identifierNameText(ast.getNode(source_local)));
    try expectStaticRequireExpression(ast, source_value, specifier);

    const alias_symbol = semantic.symbol_ids[@backingInt(source_local)] orelse return error.MissingNamespaceExternalImportEqualsAliasSymbol;
    try std.testing.expect(alias_symbol < semantic.symbols.items.len);
    const alias_data = semantic.symbols.items[alias_symbol];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, alias_data.kind);
    try std.testing.expectEqualStrings("Assert", alias_data.nameText(ast.source));
    try std.testing.expect(std.meta.eql(ast.getNode(source_local).span, alias_data.name));
    try std.testing.expect(std.meta.eql(source_import_span, alias_data.declaration_span));

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var namespace_symbol: ?u32 = null;
    var namespace_scope: ?u32 = null;
    var alias_binding_count: usize = 0;
    var alias_export_count: usize = 0;
    var alias_initializer: ast_mod.NodeIndex = .none;
    var alias_declarator_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_import_equals_declaration) return error.NamespaceExternalImportEqualsSurvivedLowering;
        if (node.tag == .ts_module_declaration and node.data.binary.flags == 0) {
            const name = node.data.binary.left;
            if (!name.isNone() and @backingInt(name) < ast.nodes.items.len and ast.getNode(name).tag == .binding_identifier and
                std.mem.eql(u8, ast.identifierNameText(ast.getNode(name)), "Container"))
            {
                namespace_symbol = semantic.symbol_ids[@backingInt(name)] orelse return error.MissingNamespaceExternalImportEqualsNamespaceSymbol;
                namespace_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingNamespaceExternalImportEqualsNamespaceScope;
            }
        }
        if (node.tag == .binding_identifier and std.mem.eql(u8, ast.identifierNameText(node), "Assert") and
            semantic.symbol_ids[raw] == alias_symbol)
        {
            alias_binding_count += 1;
        }
        if (node.tag != .variable_declarator or !ast.hasExtra(node.data.extra, 2)) continue;
        const binding = ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(binding)), "Assert") or semantic.symbol_ids[@backingInt(binding)] != alias_symbol) continue;
        alias_initializer = ast.readExtraNode(node.data.extra, 2);
        alias_declarator_count += 1;
    }
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .export_named_declaration or !ast.hasExtra(node.data.extra, 1)) continue;
        const declaration_idx = ast.readExtraNode(node.data.extra, 0);
        if (declaration_idx.isNone() or @backingInt(declaration_idx) >= ast.nodes.items.len) continue;
        const declaration = ast.getNode(declaration_idx);
        if (declaration.tag != .variable_declaration) continue;
        const extra: usize = declaration.data.extra;
        if (extra > ast.extra_data.items.len or ast.extra_data.items.len - extra <= 2) continue;
        const start = ast.extra_data.items[extra + 1];
        const len = ast.extra_data.items[extra + 2];
        if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) continue;
        for (ast.extra_data.items[start .. start + len]) |raw_declarator| {
            const declarator_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw_declarator));
            if (declarator_idx.isNone() or @backingInt(declarator_idx) >= ast.nodes.items.len) continue;
            const declarator = ast.getNode(declarator_idx);
            if (declarator.tag != .variable_declarator or !ast.hasExtra(declarator.data.extra, 1)) continue;
            const binding = ast.readExtraNode(declarator.data.extra, 0);
            if (!binding.isNone() and @backingInt(binding) < ast.nodes.items.len and
                semantic.symbol_ids[@backingInt(binding)] == alias_symbol)
            {
                alias_export_count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), alias_binding_count);
    try std.testing.expectEqual(@as(usize, 1), alias_export_count);
    try std.testing.expectEqual(@as(usize, 1), alias_declarator_count);
    const emitted_namespace_symbol = namespace_symbol orelse return error.MissingNamespaceExternalImportEqualsNamespaceSymbol;
    const emitted_namespace_scope = namespace_scope orelse return error.MissingNamespaceExternalImportEqualsNamespaceScope;
    try std.testing.expect(!alias_initializer.isNone());
    try expectStaticRequireExpression(ast, alias_initializer, specifier);
    try std.testing.expect(std.meta.eql(ast.getNode(alias_initializer).span, ast.getNode(source_value).span));

    const alias_scope = @backingInt(alias_data.scope_id);
    try std.testing.expectEqual(emitted_namespace_scope, alias_scope);
    try std.testing.expect(alias_scope < semantic.scope_maps.len);
    try std.testing.expectEqual(@as(?usize, alias_symbol), semantic.scope_maps[alias_scope].get("Assert"));

    var namespace_parameter_symbol: ?u32 = null;
    var namespace_parameter_count: usize = 0;
    for (semantic.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != .namespace_iife_parameter or @backingInt(symbol.scope_id) != emitted_namespace_scope) continue;
        namespace_parameter_symbol = @intCast(index);
        namespace_parameter_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), namespace_parameter_count);
    const expected_parameter = namespace_parameter_symbol orelse return error.MissingNamespaceExternalImportEqualsParameter;

    var alias_identifier_references: usize = 0;
    var namespace_member_accesses: usize = 0;
    var capture_scope: ?u32 = null;
    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(runtime_references);
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw < ast.nodes.items.len and ast.nodes.items[raw].tag == .identifier_reference and
            std.mem.eql(u8, ast.identifierNameText(ast.nodes.items[raw]), "Assert"))
        {
            try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[raw] orelse return error.MissingNamespaceExternalImportEqualsAliasReference);
            alias_identifier_references += 1;
        }
    }
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .static_member_expression or !ast.hasExtra(node.data.extra, 2)) continue;
        const property = ast.readExtraNode(node.data.extra, 1);
        if (property.isNone() or @backingInt(property) >= ast.nodes.items.len or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(property)), "Assert")) continue;
        const object = ast.readExtraNode(node.data.extra, 0);
        try std.testing.expect(!object.isNone() and @backingInt(object) < ast.nodes.items.len);
        try std.testing.expectEqual(.identifier_reference, ast.getNode(object).tag);
        try std.testing.expectEqual(expected_parameter, semantic.symbol_ids[@backingInt(object)] orelse return error.MissingNamespaceExternalImportEqualsParameterReference);
        var rows: usize = 0;
        for (semantic.references) |reference| {
            if (reference.node_index != object) continue;
            try std.testing.expect(!reference.flags.declare);
            try std.testing.expectEqual(expected_parameter, @backingInt(reference.symbol_id));
            try std.testing.expect(semanticScopeContains(semantic, @as(ScopeId, @fromBackingInt(alias_scope)), reference.scope_id));
            try std.testing.expect(reference.scope_id != @as(ScopeId, @fromBackingInt(alias_scope)));
            capture_scope = @backingInt(reference.scope_id);
            rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), rows);
        namespace_member_accesses += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), alias_identifier_references);
    try std.testing.expectEqual(@as(usize, 1), namespace_member_accesses);
    try std.testing.expect(capture_scope != null);
    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");

    return .{
        .alias_symbol = alias_symbol,
        .namespace_symbol = emitted_namespace_symbol,
        .namespace_parameter_symbol = expected_parameter,
        .namespace_scope = emitted_namespace_scope,
        .alias_scope = alias_scope,
        .capture_scope = capture_scope.?,
    };
}

const TypeScriptNamespaceLocalExternalImportEqualsGraphIdentity = struct {
    alias_symbol: u32,
    namespace_symbol: u32,
    namespace_parameter_symbol: u32,
    namespace_scope: u32,
    alias_scope: u32,
    reference_scope: u32,
};

fn expectNamespaceLocalExternalImportEqualsGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
    specifier: []const u8,
) !TypeScriptNamespaceLocalExternalImportEqualsGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingNamespaceLocalExternalImportEqualsModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(@as(usize, 1), module.import_records.len);
    const record = module.import_records[0];
    try std.testing.expectEqual(types.ImportKind.require, record.kind);
    try std.testing.expectEqualStrings(specifier, record.specifier);
    try std.testing.expect(record.is_external);
    try std.testing.expect(record.resolved.isNone());
    try std.testing.expect(!record.resolve_failed);

    const ast = &(module.ast orelse return error.MissingNamespaceLocalExternalImportEqualsAst);
    const semantic = &(module.semantic orelse return error.MissingNamespaceLocalExternalImportEqualsSemantic);
    const transformed = module.transform_cache orelse return error.MissingNamespaceLocalExternalImportEqualsTransform;
    const root = ast.transformed_root orelse return error.MissingNamespaceLocalExternalImportEqualsRoot;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    var source_local: ast_mod.NodeIndex = .none;
    var source_value: ast_mod.NodeIndex = .none;
    var source_import_span: @import("../lexer/token.zig").Span = .EMPTY;
    var source_import_count: usize = 0;
    for (ast.nodes.items) |node| {
        if (node.tag != .ts_import_equals_declaration) continue;
        source_import_count += 1;
        source_import_span = node.span;
        source_local = node.data.binary.left;
        source_value = node.data.binary.right;
    }
    try std.testing.expectEqual(@as(usize, 1), source_import_count);
    try std.testing.expect(!source_local.isNone() and @backingInt(source_local) < ast.nodes.items.len);
    try std.testing.expectEqual(.identifier_reference, ast.getNode(source_local).tag);
    try std.testing.expectEqualStrings("Assert", ast.identifierNameText(ast.getNode(source_local)));
    try expectStaticRequireExpression(ast, source_value, specifier);

    const alias_symbol = semantic.symbol_ids[@backingInt(source_local)] orelse return error.MissingNamespaceLocalExternalImportEqualsAliasSymbol;
    try std.testing.expect(alias_symbol < semantic.symbols.items.len);
    const alias_data = semantic.symbols.items[alias_symbol];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_const, alias_data.kind);
    try std.testing.expectEqualStrings("Assert", alias_data.nameText(ast.source));
    try std.testing.expect(std.meta.eql(ast.getNode(source_local).span, alias_data.name));
    try std.testing.expect(std.meta.eql(source_import_span, alias_data.declaration_span));

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var namespace_symbol: ?u32 = null;
    var namespace_scope: ?u32 = null;
    var namespace_count: usize = 0;
    var alias_binding_count: usize = 0;
    var alias_declarator_count: usize = 0;
    var alias_initializer: ast_mod.NodeIndex = .none;
    var namespace_member_accesses: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_import_equals_declaration) return error.NamespaceLocalExternalImportEqualsSurvivedLowering;
        if (node.tag == .ts_module_declaration and node.data.binary.flags == 0) {
            const name = node.data.binary.left;
            if (!name.isNone() and @backingInt(name) < ast.nodes.items.len and ast.getNode(name).tag == .binding_identifier and
                std.mem.eql(u8, ast.identifierNameText(ast.getNode(name)), "Container"))
            {
                namespace_symbol = semantic.symbol_ids[@backingInt(name)] orelse return error.MissingNamespaceLocalExternalImportEqualsNamespaceSymbol;
                namespace_scope = semantic.scope_owner_map.get(@intCast(raw)) orelse return error.MissingNamespaceLocalExternalImportEqualsNamespaceScope;
                namespace_count += 1;
            }
        }
        if (node.tag == .binding_identifier and std.mem.eql(u8, ast.identifierNameText(node), "Assert") and
            semantic.symbol_ids[raw] == alias_symbol)
        {
            alias_binding_count += 1;
        }
        if (node.tag == .static_member_expression and ast.hasExtra(node.data.extra, 2)) {
            const property = ast.readExtraNode(node.data.extra, 1);
            if (!property.isNone() and @backingInt(property) < ast.nodes.items.len and
                std.mem.eql(u8, ast.identifierNameText(ast.getNode(property)), "Assert"))
            {
                namespace_member_accesses += 1;
            }
        }
        if (node.tag != .variable_declarator or !ast.hasExtra(node.data.extra, 2)) continue;
        const binding = ast.readExtraNode(node.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier or
            !std.mem.eql(u8, ast.identifierNameText(ast.getNode(binding)), "Assert") or semantic.symbol_ids[@backingInt(binding)] != alias_symbol) continue;
        alias_initializer = ast.readExtraNode(node.data.extra, 2);
        alias_declarator_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), namespace_count);
    try std.testing.expectEqual(@as(usize, 1), alias_binding_count);
    try std.testing.expectEqual(@as(usize, 1), alias_declarator_count);
    try std.testing.expectEqual(@as(usize, 0), namespace_member_accesses);
    const emitted_namespace_symbol = namespace_symbol orelse return error.MissingNamespaceLocalExternalImportEqualsNamespaceSymbol;
    const emitted_namespace_scope = namespace_scope orelse return error.MissingNamespaceLocalExternalImportEqualsNamespaceScope;
    try std.testing.expect(!alias_initializer.isNone());
    try expectStaticRequireExpression(ast, alias_initializer, specifier);
    try std.testing.expect(std.meta.eql(ast.getNode(alias_initializer).span, ast.getNode(source_value).span));

    const alias_scope = @backingInt(alias_data.scope_id);
    try std.testing.expectEqual(emitted_namespace_scope, alias_scope);
    try std.testing.expect(alias_scope < semantic.scope_maps.len);
    try std.testing.expectEqual(@as(?usize, alias_symbol), semantic.scope_maps[alias_scope].get("Assert"));

    var namespace_parameter_symbol: ?u32 = null;
    var namespace_parameter_count: usize = 0;
    for (semantic.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != .namespace_iife_parameter or @backingInt(symbol.scope_id) != emitted_namespace_scope) continue;
        namespace_parameter_symbol = @intCast(index);
        namespace_parameter_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), namespace_parameter_count);
    const expected_parameter = namespace_parameter_symbol orelse return error.MissingNamespaceLocalExternalImportEqualsParameter;

    const runtime_references = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(runtime_references);
    var alias_reference_count: usize = 0;
    var reference_scope: ?u32 = null;
    for (runtime_references) |reference_node| {
        const raw = @backingInt(reference_node);
        if (raw >= ast.nodes.items.len or ast.nodes.items[raw].tag != .identifier_reference or
            !std.mem.eql(u8, ast.identifierNameText(ast.nodes.items[raw]), "Assert")) continue;
        try std.testing.expectEqual(alias_symbol, semantic.symbol_ids[raw] orelse return error.MissingNamespaceLocalExternalImportEqualsAliasReference);
        var rows: usize = 0;
        for (semantic.references) |reference| {
            if (reference.node_index != reference_node) continue;
            try std.testing.expect(!reference.flags.declare);
            try std.testing.expectEqual(alias_symbol, @backingInt(reference.symbol_id));
            try std.testing.expect(semanticScopeContains(semantic, @as(ScopeId, @fromBackingInt(alias_scope)), reference.scope_id));
            try std.testing.expect(reference.scope_id != @as(ScopeId, @fromBackingInt(alias_scope)));
            try std.testing.expect(@backingInt(reference.symbol_id) != expected_parameter);
            reference_scope = @backingInt(reference.scope_id);
            rows += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), rows);
        alias_reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_reference_count);
    try std.testing.expect(reference_scope != null);
    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");

    return .{
        .alias_symbol = alias_symbol,
        .namespace_symbol = emitted_namespace_symbol,
        .namespace_parameter_symbol = expected_parameter,
        .namespace_scope = emitted_namespace_scope,
        .alias_scope = alias_scope,
        .reference_scope = reference_scope.?,
    };
}

fn expectAutomaticJsxModuleGraph(
    entries: []const []const u8,
    jsx_entries: []const []const u8,
    no_jsx_entry: []const u8,
    runtime: @import("../codegen/codegen.zig").JsxRuntime,
    required_runtime_helper_hint: ?[]const u8,
    disk: *@import("disk_module_store.zig").DiskModuleStore,
    expected_load_hits: usize,
) !void {
    const profile = @import("../profile.zig");
    profile.resetForTest();
    defer profile.resetForTest();
    profile.setIoForTest(std.testing.io);
    profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");

    const external_patterns = [_][]const u8{
        "react",
        "react/jsx-runtime",
        "react/jsx-dev-runtime",
        "preact/jsx-runtime",
        "preact/jsx-dev-runtime",
    };
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &external_patterns });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = disk;
    graph.disk_load_enabled = true;
    graph.disk_options_hash = 0x6193_4819;
    graph.disk_compiler_build_id = 0x4819;
    graph.max_threads = 1;
    graph.jsx_runtime = runtime;
    graph.jsx_import_source = "react";
    graph.transform_options_base.jsx_runtime = runtime;
    graph.transform_options_base.jsx_import_source = "react";

    try graph.build(std.testing.io, entries);

    try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
    // External imports still have graph module records, including the runtime
    // import edges introduced by JSX lowering.
    try std.testing.expect(graph.moduleCount() >= entries.len);
    try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    for (jsx_entries) |entry| try expectAutomaticJsxGraphModule(&graph, entry, required_runtime_helper_hint);

    const no_jsx = graph.findModuleByPath(no_jsx_entry) orelse return error.MissingNoJsxGraphModule;
    try std.testing.expectEqual(Module.State.ready, no_jsx.state);
    try std.testing.expect(no_jsx.semantic != null);
    try std.testing.expect(no_jsx.ast != null);
    try std.testing.expect(no_jsx.transform_cache == null);
    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
}

fn expectClassicJsxModuleGraph(
    entries: []const []const u8,
    jsx_entries: []const []const u8,
    no_jsx_entry: []const u8,
    disk: *@import("disk_module_store.zig").DiskModuleStore,
    expected_load_hits: usize,
) !void {
    const profile = @import("../profile.zig");
    profile.resetForTest();
    defer profile.resetForTest();
    profile.setIoForTest(std.testing.io);
    profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");

    const external_patterns = [_][]const u8{"react"};
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &external_patterns });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = disk;
    graph.disk_load_enabled = true;
    graph.disk_options_hash = 0x6193_4819;
    graph.disk_compiler_build_id = 0x4819;
    graph.max_threads = 1;
    graph.jsx_runtime = .classic;
    graph.transform_options_base.jsx_runtime = .classic;

    try graph.build(std.testing.io, entries);

    try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
    try std.testing.expect(graph.moduleCount() >= entries.len);
    try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    for (jsx_entries) |entry| try expectClassicJsxGraphModule(&graph, entry);

    const no_jsx = graph.findModuleByPath(no_jsx_entry) orelse return error.MissingNoClassicJsxModule;
    try std.testing.expectEqual(Module.State.ready, no_jsx.state);
    try std.testing.expect(no_jsx.semantic != null);
    try std.testing.expect(no_jsx.ast != null);
    try std.testing.expect(no_jsx.transform_cache == null);
    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
}

const BuiltInTransformGraphExpectation = struct {
    expect_prepass: bool,
    removed_identifier: ?[]const u8 = null,
    removed_node_tag: ?ast_mod.Node.Tag = null,
    retained_symbol_name: ?[]const u8 = null,
    expected_reference_count: ?u32 = null,
    expected_boolean_value: ?bool = null,
    expected_numeric_literal: ?[]const u8 = null,
    expected_numeric_literal_count: ?usize = null,
};

fn expectBuiltInTransformGraph(
    entry: []const u8,
    disk: *@import("disk_module_store.zig").DiskModuleStore,
    expected_load_hits: usize,
    options: TransformOptions,
    expectation: BuiltInTransformGraphExpectation,
) !void {
    const profile = @import("../profile.zig");
    profile.resetForTest();
    defer profile.resetForTest();
    profile.setIoForTest(std.testing.io);
    profile.addFromCsv("graph.resync_semantic");

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = disk;
    graph.disk_load_enabled = true;
    graph.disk_options_hash = 0x6193;
    graph.disk_compiler_build_id = 0x4819;
    graph.transform_options_base = options;
    graph.max_threads = 1;

    try graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    if (!expectation.expect_prepass) {
        try expectVisitorGraphSkipped(&graph, entry);
        return;
    }

    try expectVisitorGraphReady(&graph, entry);
    const module = graph.findModuleByPath(entry).?;
    const ast = &module.ast.?;
    const root = ast.transformed_root.?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var found_boolean_value = false;
    var found_removed_node_tag = false;
    var found_numeric_literal = false;
    var numeric_literal_count: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .identifier_reference) {
            if (expectation.removed_identifier) |removed_identifier| {
                try std.testing.expect(!Scanner.identifierNamesEqual(ast.getText(node.span), removed_identifier));
            }
        } else if (node.tag == .boolean_literal) {
            if (expectation.expected_boolean_value) |expected| {
                const expected_text = if (expected) "true" else "false";
                if (std.mem.eql(u8, ast.getText(node.span), expected_text)) found_boolean_value = true;
            }
        } else if (node.tag == .numeric_literal) {
            numeric_literal_count += 1;
            if (expectation.expected_numeric_literal) |expected| {
                if (std.mem.eql(u8, ast.getText(node.span), expected)) found_numeric_literal = true;
            }
        }
        if (expectation.removed_node_tag == node.tag) found_removed_node_tag = true;
    }
    if (expectation.expected_boolean_value != null) try std.testing.expect(found_boolean_value);
    if (expectation.removed_node_tag != null) try std.testing.expect(!found_removed_node_tag);
    if (expectation.expected_numeric_literal != null) try std.testing.expect(found_numeric_literal);
    if (expectation.expected_numeric_literal_count) |expected| try std.testing.expectEqual(expected, numeric_literal_count);

    if (expectation.retained_symbol_name) |retained_symbol_name| {
        const expected_reference_count = expectation.expected_reference_count orelse return error.TestUnexpectedResult;
        const semantic = &module.semantic.?;
        var found_retained = false;
        for (semantic.symbols.items) |symbol| {
            if (!std.mem.eql(u8, symbol.nameText(ast.source), retained_symbol_name)) continue;
            found_retained = true;
            try std.testing.expectEqual(expected_reference_count, symbol.reference_count);
        }
        try std.testing.expect(found_retained);
    }
}

const FlowGraphIdentity = struct {
    symbol_id: u32,
    scope_id: u32,
    reference_count: u32,
};

const FlowEnumGraphIdentity = struct {
    symbol_id: u32,
    scope_id: u32,
    reference_count: u32,
};

const GraphSourceSymbolIdentity = struct {
    symbol_id: u32,
    scope_id: u32,
    reference_count: u32,
    write_count: u32,
};

const expected_flow_enum_runtime_specifier = "flow-enums-runtime";

const FlowGeneratedRole = enum {
    match_parameter,
    ref_component_helper,
};

fn flowScopeContains(scopes: []const @import("../semantic/scope.zig").Scope, ancestor: ScopeId, child: ScopeId) bool {
    if (ancestor.isNone() or child.isNone() or ancestor.toIndex() >= scopes.len or child.toIndex() >= scopes.len) return false;
    var current = child;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current == ancestor) return true;
        if (current.toIndex() >= scopes.len) return false;
        current = scopes[current.toIndex()].parent;
    }
    return false;
}

fn expectFlowSourceBindingIdentity(module: *const Module, reachable: []const u32, name: []const u8) !u32 {
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    var binding: ?u32 = null;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, ast.getText(node.data.string_ref), name)) continue;
        try std.testing.expect(binding == null);
        binding = semantic.symbol_ids[raw] orelse return error.MissingFlowSourceBindingSymbol;
    }
    const symbol_id = binding orelse return error.MissingFlowSourceBinding;
    try std.testing.expect(symbol_id < semantic.symbols.items.len);
    var reference_count: u32 = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(node.data.string_ref), name)) continue;
        try std.testing.expectEqual(symbol_id, semantic.symbol_ids[raw] orelse return error.MissingFlowSourceReferenceSymbol);
        var found_row = false;
        for (semantic.references) |reference| {
            if (reference.node_index != @as(ast_mod.NodeIndex, @fromBackingInt(raw))) continue;
            try std.testing.expectEqual(@as(u32, symbol_id), @as(u32, @intCast(@backingInt(reference.symbol_id))));
            try std.testing.expect(reference.flags.read or reference.flags.write);
            found_row = true;
            reference_count += 1;
            break;
        }
        try std.testing.expect(found_row);
    }
    try std.testing.expect(reference_count > 0);
    try std.testing.expectEqual(reference_count, semantic.symbols.items[symbol_id].reference_count);
    return symbol_id;
}

fn expectGraphSourceSymbolIdentity(
    module: *const Module,
    reachable: []const u32,
    name: []const u8,
) !GraphSourceSymbolIdentity {
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    var symbol_id: ?u32 = null;
    for (semantic.symbols.items, 0..) |symbol, raw| {
        if (!std.mem.eql(u8, symbol.nameText(ast.source), name)) continue;
        try std.testing.expect(symbol_id == null);
        symbol_id = @intCast(raw);
    }
    const sid = symbol_id orelse return error.MissingGraphSourceSymbol;
    const symbol = semantic.symbols.items[sid];
    try std.testing.expect(!symbol.scope_id.isNone());
    try std.testing.expect(symbol.scope_id.toIndex() < semantic.scopes.len);

    var declaration_count: usize = 0;
    var reference_count: u32 = 0;
    var write_count: u32 = 0;
    for (reachable) |raw| {
        if (raw >= semantic.symbol_ids.len or semantic.symbol_ids[raw] != sid) continue;
        const node = ast.nodes.items[raw];
        const node_index: ast_mod.NodeIndex = @fromBackingInt(raw);
        var is_declaration = false;
        if (node.tag == .binding_identifier or node.tag == .assignment_target_identifier) {
            for (semantic.references) |reference| {
                if (!reference.flags.declare or reference.declaration_node_index != node_index) continue;
                try std.testing.expectEqual(sid, @as(u32, @intCast(@backingInt(reference.symbol_id))));
                is_declaration = true;
                break;
            }
        }
        if (is_declaration) {
            declaration_count += 1;
            continue;
        }
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;

        var found_reference = false;
        for (semantic.references) |reference| {
            if (reference.node_index != node_index) continue;
            try std.testing.expectEqual(sid, @as(u32, @intCast(@backingInt(reference.symbol_id))));
            try std.testing.expect(reference.flags.read or reference.flags.write);
            try std.testing.expect(!found_reference);
            found_reference = true;
            reference_count += 1;
            if (reference.flags.write) write_count += 1;
        }
        try std.testing.expect(found_reference);
    }
    try std.testing.expect(declaration_count > 0);
    try std.testing.expect(reference_count > 0);
    try std.testing.expectEqual(reference_count, symbol.reference_count);
    try std.testing.expectEqual(write_count, symbol.write_count);
    return .{
        .symbol_id = sid,
        .scope_id = @backingInt(symbol.scope_id),
        .reference_count = reference_count,
        .write_count = write_count,
    };
}

fn expectFlowEnumGraphModule(
    graph: *const ModuleGraph,
    entry: []const u8,
    enum_name: []const u8,
    has_explicit_runtime_import: bool,
) !FlowEnumGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingFlowEnumGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    const ast = &(module.ast orelse return error.MissingFlowEnumGraphAst);
    const semantic = &(module.semantic orelse return error.MissingFlowEnumGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingFlowEnumGraphTransform;
    try std.testing.expect(ast.has_flow_enum_declaration);
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    const root = ast.transformed_root orelse return error.MissingFlowEnumGraphRoot;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    const symbol_id = try expectFlowSourceBindingIdentity(module, reachable, enum_name);
    const symbol = semantic.symbols.items[symbol_id];
    try std.testing.expect(!symbol.scope_id.isNone());
    try std.testing.expect(symbol.scope_id.toIndex() < semantic.scopes.len);

    var enum_declarations: usize = 0;
    var enum_members: usize = 0;
    for (reachable) |raw| {
        const tag = ast.nodes.items[raw].tag;
        if (tag == .flow_enum_declaration) enum_declarations += 1;
        if (tag == .flow_enum_member) enum_members += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), enum_declarations);
    try std.testing.expect(enum_members >= 2);

    var runtime_records: usize = 0;
    for (module.import_records) |record| {
        if (!std.mem.eql(u8, record.specifier, expected_flow_enum_runtime_specifier)) continue;
        runtime_records += 1;
        try std.testing.expect(record.is_external);
        if (has_explicit_runtime_import) {
            try std.testing.expectEqual(@as(@TypeOf(record.kind), .static_import), record.kind);
            try std.testing.expect(!record.source_node.isNone());
            try std.testing.expect(record.span.end > record.span.start);
        } else {
            try std.testing.expectEqual(@as(@TypeOf(record.kind), .require), record.kind);
            try std.testing.expect(record.source_node.isNone());
            try std.testing.expectEqual(@as(u32, 0), record.span.start);
            try std.testing.expectEqual(@as(u32, 0), record.span.end);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), runtime_records);

    return .{
        .symbol_id = symbol_id,
        .scope_id = @backingInt(symbol.scope_id),
        .reference_count = semantic.symbols.items[symbol_id].reference_count,
    };
}

fn expectFlowEnumRuntimeModuleLink(
    graph: *const ModuleGraph,
    entry: []const u8,
    runtime_path: []const u8,
    enum_name: []const u8,
    expected_kind: types.ImportKind,
) !FlowEnumGraphIdentity {
    const module = graph.findModuleByPath(entry) orelse return error.MissingLinkedFlowEnumGraphModule;
    const runtime_module = graph.findModuleByPath(runtime_path) orelse return error.MissingFlowEnumRuntimeModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expectEqual(Module.State.ready, runtime_module.state);
    const ast = &(module.ast orelse return error.MissingLinkedFlowEnumGraphAst);
    const semantic = &(module.semantic orelse return error.MissingLinkedFlowEnumGraphSemantic);
    const transformed = module.transform_cache orelse return error.MissingLinkedFlowEnumGraphTransform;
    try std.testing.expect(ast.has_flow_enum_declaration);
    try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transformed.symbol_ids);

    const root = ast.transformed_root orelse return error.MissingLinkedFlowEnumGraphRoot;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    const symbol_id = try expectFlowSourceBindingIdentity(module, reachable, enum_name);
    const symbol = semantic.symbols.items[symbol_id];
    try std.testing.expect(!symbol.scope_id.isNone());
    try std.testing.expect(symbol.scope_id.toIndex() < semantic.scopes.len);

    var dependency_edge_count: usize = 0;
    for (module.dependencies.items) |dependency| {
        if (dependency == runtime_module.index) dependency_edge_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dependency_edge_count);
    var importer_edge_count: usize = 0;
    for (runtime_module.importers.items) |importer| {
        if (importer == module.index) importer_edge_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), importer_edge_count);

    var runtime_records: usize = 0;
    for (module.import_records) |record| {
        if (!std.mem.eql(u8, record.specifier, expected_flow_enum_runtime_specifier)) continue;
        runtime_records += 1;
        try std.testing.expect(!record.is_external);
        try std.testing.expectEqual(expected_kind, record.kind);
        try std.testing.expectEqual(runtime_module.index, record.resolved);
        try std.testing.expect(std.mem.indexOfScalar(types.ModuleIndex, module.dependencies.items, runtime_module.index) != null);
        if (expected_kind == .require) {
            try std.testing.expect(record.source_node.isNone());
            try std.testing.expectEqual(@as(u32, 0), record.span.start);
            try std.testing.expectEqual(@as(u32, 0), record.span.end);
        } else {
            try std.testing.expect(!record.source_node.isNone());
            try std.testing.expect(record.span.end > record.span.start);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), runtime_records);

    return .{
        .symbol_id = symbol_id,
        .scope_id = @backingInt(symbol.scope_id),
        .reference_count = semantic.symbols.items[symbol_id].reference_count,
    };
}

fn expectFlowSourceSymbolIdentity(module: *const Module, reachable: []const u32, source_name: []const u8) !u32 {
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    var found_symbol: ?u32 = null;
    for (semantic.symbols.items, 0..) |symbol, raw| {
        if (symbol.synthetic_kind != null or !std.mem.eql(u8, symbol.nameText(ast.source), source_name)) continue;
        try std.testing.expect(found_symbol == null);
        found_symbol = @intCast(raw);
    }
    const symbol_id = found_symbol orelse return error.MissingFlowSourceSymbol;
    var has_exact_export = false;
    for (module.export_bindings) |binding| {
        if (binding.kind != .local or !std.mem.eql(u8, binding.exported_name, source_name)) continue;
        if (module.exportBindingSemanticIndex(binding) == symbol_id) has_exact_export = true;
    }
    try std.testing.expect(has_exact_export);
    var binding_count: usize = 0;
    var live_reference_count: u32 = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (raw < semantic.symbol_ids.len and semantic.symbol_ids[raw] == symbol_id) {
            if (node.tag == .binding_identifier) binding_count += 1;
            if (node.tag == .identifier_reference) live_reference_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);

    var semantic_reference_count: u32 = 0;
    for (semantic.references) |reference| {
        if (@backingInt(reference.symbol_id) != symbol_id or reference.flags.declare) continue;
        try std.testing.expect(!reference.node_index.isNone());
        const raw: u32 = @intCast(@backingInt(reference.node_index));
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, raw) != null);
        try std.testing.expect(raw < semantic.symbol_ids.len and semantic.symbol_ids[raw] == symbol_id);
        try std.testing.expect(reference.flags.read or reference.flags.write);
        semantic_reference_count += 1;
    }
    try std.testing.expectEqual(live_reference_count, semantic_reference_count);
    try std.testing.expectEqual(live_reference_count, semantic.symbols.items[symbol_id].reference_count);
    return symbol_id;
}

fn expectFlowGeneratedIdentityForSymbol(
    module: *const Module,
    reachable: []const u32,
    symbol_id: u32,
    role: FlowGeneratedRole,
) !FlowGraphIdentity {
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    const symbol = semantic.symbols.items[symbol_id];
    try std.testing.expect(!symbol.scope_id.isNone());
    try std.testing.expect(symbol.scope_id.toIndex() < semantic.scopes.len);
    try std.testing.expect(symbol.scope_id.toIndex() < semantic.scope_maps.len);

    var binding_count: usize = 0;
    var ast_reference_count: u32 = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag == .flow_match_expression or node.tag == .flow_component_wrapper)
            return error.UnloweredFlowRuntimeNode;
        if (node.tag == .binding_identifier and raw < semantic.symbol_ids.len and semantic.symbol_ids[raw] == symbol_id) {
            binding_count += 1;
            try std.testing.expectEqual(symbol_id, semantic.symbol_ids[raw].?);
            const name = ast.getText(node.data.string_ref);
            try std.testing.expectEqual(@as(?usize, @intCast(symbol_id)), semantic.scope_maps[symbol.scope_id.toIndex()].get(name));
        }
        if (node.tag == .identifier_reference and raw < semantic.symbol_ids.len and semantic.symbol_ids[raw] == symbol_id)
            ast_reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);

    var semantic_reference_count: u32 = 0;
    var semantic_read_count: u32 = 0;
    var semantic_write_count: u32 = 0;
    for (semantic.references) |reference| {
        if (@backingInt(reference.symbol_id) != symbol_id or reference.flags.declare) continue;
        if (reference.node_index.isNone() or @backingInt(reference.node_index) >= ast.nodes.items.len)
            return error.FlowGeneratedReferenceLostNode;
        const raw: u32 = @intCast(@backingInt(reference.node_index));
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, raw) != null);
        const node = ast.nodes.items[raw];
        try std.testing.expect(node.tag == .identifier_reference or node.tag == .assignment_target_identifier);
        try std.testing.expectEqual(symbol_id, semantic.symbol_ids[raw] orelse return error.FlowGeneratedReferenceLostSymbol);
        try std.testing.expect(flowScopeContains(semantic.scopes, symbol.scope_id, reference.scope_id));
        semantic_reference_count += 1;
        if (reference.flags.read) semantic_read_count += 1;
        if (reference.flags.write) semantic_write_count += 1;
    }
    try std.testing.expect(semantic_reference_count > 0);
    try std.testing.expectEqual(ast_reference_count, semantic_read_count);
    try std.testing.expectEqual(symbol.reference_count, semantic_read_count);
    try std.testing.expectEqual(symbol.write_count, semantic_write_count);

    if (role == .match_parameter) {
        var exact_function_owners: usize = 0;
        var owners = semantic.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            const raw = entry.key_ptr.*;
            if (raw >= ast.nodes.items.len or entry.value_ptr.* != @backingInt(symbol.scope_id)) continue;
            if (ast.nodes.items[raw].tag == .function_expression) exact_function_owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_function_owners);
    }

    return .{
        .symbol_id = symbol_id,
        .scope_id = @backingInt(symbol.scope_id),
        .reference_count = semantic_read_count,
    };
}

fn isFlowMatchParameter(module: *const Module, reachable: []const u32, symbol_id: u32) bool {
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    const symbol = semantic.symbols.items[symbol_id];
    if (symbol.kind != .parameter or symbol.synthetic_name.len == 0) return false;

    for (reachable) |raw| {
        const call = ast.nodes.items[raw];
        if (call.tag != .call_expression) continue;
        const callee_idx = ast.readExtraNode(call.data.extra, 0);
        if (callee_idx.isNone()) continue;
        const callee = ast.getNode(callee_idx);
        if (callee.tag != .function_expression) continue;
        const params = ast.functionParamsList(callee);
        if (params.len != 1) continue;
        const parameter: ast_mod.NodeIndex = @fromBackingInt(ast.extra_data.items[params.start]);
        const parameter_raw: u32 = @intCast(@backingInt(parameter));
        if (parameter_raw < semantic.symbol_ids.len and semantic.symbol_ids[parameter_raw] == symbol_id) return true;
    }
    return false;
}

fn expectFlowGeneratedIdentities(module: *const Module, role: FlowGeneratedRole) ![]FlowGraphIdentity {
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    const root = ast.transformed_root orelse return error.MissingFlowTransformedRoot;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);

    var identities: std.ArrayList(FlowGraphIdentity) = .empty;
    for (semantic.symbols.items, 0..) |symbol, raw| {
        const matches_role = switch (role) {
            .match_parameter => isFlowMatchParameter(module, reachable, @intCast(raw)),
            .ref_component_helper => symbol.kind == .function_decl and std.mem.startsWith(u8, symbol.synthetic_name, "Card_withRef"),
        };
        if (!matches_role) continue;
        try identities.append(std.testing.allocator, try expectFlowGeneratedIdentityForSymbol(module, reachable, @intCast(raw), role));
    }
    if (identities.items.len == 0) return error.MissingFlowGeneratedSymbol;
    return identities.toOwnedSlice(std.testing.allocator);
}

fn expectFlowGeneratedIdentity(module: *const Module, role: FlowGeneratedRole) !FlowGraphIdentity {
    const identities = try expectFlowGeneratedIdentities(module, role);
    defer std.testing.allocator.free(identities);
    try std.testing.expectEqual(@as(usize, 1), identities.len);
    return identities[0];
}

fn expectFlowQuotedPropertyComputed(module: *const Module, key_text: []const u8) !void {
    const ast = &module.ast.?;
    const root = ast.transformed_root orelse return error.MissingFlowTransformedRoot;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);

    var matching_keys: usize = 0;
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .computed_member_expression) continue;
        const property_idx = ast.readExtraNode(node.data.extra, 1);
        if (property_idx.isNone()) continue;
        const property = ast.getNode(property_idx);
        if (property.tag != .string_literal or !std.mem.eql(u8, ast.getText(property.span), key_text)) continue;
        try std.testing.expect(std.mem.eql(u8, ast.getText(property.data.string_ref), key_text));
        matching_keys += 1;
    }
    try std.testing.expect(matching_keys > 0);
}

fn expectColdParseVisitorRetainsGraph(kind: ColdParseVisitorKind, source: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);

    var hook_state: ColdParseVisitorState = .{};
    const plugins = [_]plugin_mod.Plugin{coldParseVisitorPlugin(kind, &hook_state)};

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.max_threads = 1;
    graph.plugins = &plugins;

    try graph.build(std.testing.io, &.{entry});

    try expectColdParseVisitorInvoked(kind, hook_state);
    try expectVisitorGraphReady(&graph, entry);
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

    try graph.build(std.testing.io, &.{entry});
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
    try expectPrePassDecision(true, "function square(value) { return value ** 2; }", "target-es5-exponentiation.mjs", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "function square(value) { value **= 2; }", "target-es5-exponentiation-assignment.mjs", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(false, "function square(value) { return value ** 2; }", "target-es2016-exponentiation.mjs", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) } });
}

test "graph pre-pass predicate: synthetic no-op graphs skip every eligible module" {
    try expectAllBuiltModulesSkipPrePass(50);
    try expectAllBuiltModulesSkipPrePass(200);
}

test "graph built-in caller: drop-console retains its graph on cold/cache and skips a no-match module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "drop.js", "const retained = 42; console.log(retained);");
    try writeFile(tmp.dir, "plain.js", "const untouched = 42;");

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const drop_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "drop.js" });
    defer std.testing.allocator.free(drop_entry);
    const plain_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "plain.js" });
    defer std.testing.allocator.free(plain_entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    const options: TransformOptions = .{ .drop_console = true };
    try expectBuiltInTransformGraph(drop_entry, &disk, 0, options, .{ .expect_prepass = true, .removed_identifier = "console", .retained_symbol_name = "retained", .expected_reference_count = 0 });
    try expectBuiltInTransformGraph(drop_entry, &disk, 1, options, .{ .expect_prepass = true, .removed_identifier = "console", .retained_symbol_name = "retained", .expected_reference_count = 0 });
    try expectBuiltInTransformGraph(plain_entry, &disk, 0, options, .{ .expect_prepass = false, .retained_symbol_name = "untouched", .expected_reference_count = 1 });
    try expectBuiltInTransformGraph(plain_entry, &disk, 1, options, .{ .expect_prepass = false, .retained_symbol_name = "untouched", .expected_reference_count = 1 });
}

test "graph built-in caller: define retains its graph on cold/cache and skips a no-match module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "define.js", "const retained = 42; console.log(retained, __DEV__);");
    try writeFile(tmp.dir, "plain.js", "const untouched = 42; console.log(untouched);");

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const define_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "define.js" });
    defer std.testing.allocator.free(define_entry);
    const plain_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "plain.js" });
    defer std.testing.allocator.free(plain_entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    const defines = [_]@import("../parser/scan_results.zig").DefineEntry{.{ .key = "__DEV__", .value = "false" }};
    const options: TransformOptions = .{ .define = &defines };
    try expectBuiltInTransformGraph(define_entry, &disk, 0, options, .{ .expect_prepass = true, .removed_identifier = "__DEV__", .retained_symbol_name = "retained", .expected_reference_count = 1, .expected_boolean_value = false });
    try expectBuiltInTransformGraph(define_entry, &disk, 1, options, .{ .expect_prepass = true, .removed_identifier = "__DEV__", .retained_symbol_name = "retained", .expected_reference_count = 1, .expected_boolean_value = false });
    try expectBuiltInTransformGraph(plain_entry, &disk, 0, options, .{ .expect_prepass = false, .retained_symbol_name = "untouched", .expected_reference_count = 1 });
    try expectBuiltInTransformGraph(plain_entry, &disk, 1, options, .{ .expect_prepass = false, .retained_symbol_name = "untouched", .expected_reference_count = 1 });
}

test "graph built-in caller: debugger and label drops retain graphs on cold/cache and skip no-match modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "debugger.js", "function read(value) { debugger; return value; }");
    try writeFile(tmp.dir, "plain-debugger.js", "function read(value) { return value; }");
    try writeFile(tmp.dir, "label.js", "function read(value) { DEV: { console.log(value); } return value; }");
    try writeFile(tmp.dir, "plain-label.js", "function read(value) { TEST: { console.log(value); } return value; }");

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const debugger_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "debugger.js" });
    defer std.testing.allocator.free(debugger_entry);
    const plain_debugger_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "plain-debugger.js" });
    defer std.testing.allocator.free(plain_debugger_entry);
    const label_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "label.js" });
    defer std.testing.allocator.free(label_entry);
    const plain_label_entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "plain-label.js" });
    defer std.testing.allocator.free(plain_label_entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    const debugger_options: TransformOptions = .{ .drop_debugger = true };
    try expectBuiltInTransformGraph(debugger_entry, &disk, 0, debugger_options, .{
        .expect_prepass = true,
        .removed_node_tag = .debugger_statement,
        .retained_symbol_name = "value",
        .expected_reference_count = 1,
    });
    try expectBuiltInTransformGraph(debugger_entry, &disk, 1, debugger_options, .{
        .expect_prepass = true,
        .removed_node_tag = .debugger_statement,
        .retained_symbol_name = "value",
        .expected_reference_count = 1,
    });
    try expectBuiltInTransformGraph(plain_debugger_entry, &disk, 0, debugger_options, .{ .expect_prepass = false });
    try expectBuiltInTransformGraph(plain_debugger_entry, &disk, 1, debugger_options, .{ .expect_prepass = false });

    const labels = [_][]const u8{"DEV"};
    const label_options: TransformOptions = .{ .drop_labels = &labels };
    try expectBuiltInTransformGraph(label_entry, &disk, 0, label_options, .{
        .expect_prepass = true,
        .removed_identifier = "console",
        .removed_node_tag = .labeled_statement,
        .retained_symbol_name = "value",
        .expected_reference_count = 1,
    });
    try expectBuiltInTransformGraph(label_entry, &disk, 1, label_options, .{
        .expect_prepass = true,
        .removed_identifier = "console",
        .removed_node_tag = .labeled_statement,
        .retained_symbol_name = "value",
        .expected_reference_count = 1,
    });
    try expectBuiltInTransformGraph(plain_label_entry, &disk, 0, label_options, .{ .expect_prepass = false });
    try expectBuiltInTransformGraph(plain_label_entry, &disk, 1, label_options, .{ .expect_prepass = false });
}

test "graph built-in caller: syntax minification retains its edited graph on cold/cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "function read(value) { return value + (2 * 3); }");

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    const options: TransformOptions = .{ .minify_syntax = true };
    try expectBuiltInTransformGraph(entry, &disk, 0, options, .{
        .expect_prepass = true,
        .retained_symbol_name = "value",
        .expected_reference_count = 1,
        .expected_numeric_literal = "6",
        .expected_numeric_literal_count = 1,
    });
    try expectBuiltInTransformGraph(entry, &disk, 1, options, .{
        .expect_prepass = true,
        .retained_symbol_name = "value",
        .expected_reference_count = 1,
        .expected_numeric_literal = "6",
        .expected_numeric_literal_count = 1,
    });
}

test "graph JSX caller: automatic runtime keeps source and generated identities on cold/cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "export function App(props) { return <div>{props.value}</div>; }",
        "export function App(props) { return <div><span>{props.value}</span><b /></div>; }",
        "export function App(props) { return <>{props.value}<span /></>; }",
        "export function App(props) { return <Card {...props} />; }",
        "export function App(props) { return <Card key={props.id} {...props} />; }",
        "export function App(props) { return <Card {...props} key={props.id} />; }",
        "export function App(props) { return <UI.Card value={props.value} />; }",
        "/** @jsxImportSource preact */ export function App(props) { return <div>{props.value}</div>; }",
        "const _jsx = 'user'; const _jsxs = 'user-many'; export function App(props) { return <div>{props.value}</div>; }",
        "export function App(props) { return <div>{...props.items}</div>; }",
        "export function App(props) { return <div title={props.title}>{props.children}<span>{props.value}</span></div>; }",
    };
    var jsx_entries: [sources.len][]const u8 = undefined;
    var entries: [sources.len + 1][]const u8 = undefined;
    for (sources, 0..) |source, index| {
        const basename = try std.fmt.allocPrint(std.testing.allocator, "entry-{d}.tsx", .{index});
        defer std.testing.allocator.free(basename);
        try writeFile(tmp.dir, basename, source);
        entries[index] = try absPath(&tmp, basename);
    }
    try writeFile(tmp.dir, "plain.tsx", "export function App(props) { return props.value; }");
    entries[sources.len] = try absPath(&tmp, "plain.tsx");
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
    }
    @memcpy(jsx_entries[0..], entries[0..sources.len]);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    try expectAutomaticJsxModuleGraph(&entries, &jsx_entries, entries[sources.len], .automatic, null, &disk, 0);
    try expectAutomaticJsxModuleGraph(&entries, &jsx_entries, entries[sources.len], .automatic, null, &disk, entries.len);
}

test "graph JSX caller: automatic-dev runtime keeps jsxDEV identity on cold/cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "export function App(props) { return <div title={props.title} />; }",
        "export function App(props) { return <div>{props.child}</div>; }",
        "export function App(props) { return <div><span>{props.value}</span><b /></div>; }",
        "export function App(props) { return <>{props.value}<span /></>; }",
        "export function App(props) { return <UI.Card value={props.value} />; }",
        "export function App(props) { return <Card {...props} />; }",
        "export function App(props) { return <Card key={props.id} {...props} />; }",
        "export function App(props) { return <Card key={props.id} title={props.title} />; }",
        "/** @jsxImportSource preact */ export function App(props) { return <div>{props.value}</div>; }",
        "export function App(props) { return <div>{...props.items}</div>; }",
    };
    var jsx_entries: [sources.len][]const u8 = undefined;
    var entries: [sources.len + 1][]const u8 = undefined;
    for (sources, 0..) |source, index| {
        const basename = try std.fmt.allocPrint(std.testing.allocator, "dev-entry-{d}.tsx", .{index});
        defer std.testing.allocator.free(basename);
        try writeFile(tmp.dir, basename, source);
        entries[index] = try absPath(&tmp, basename);
    }
    try writeFile(tmp.dir, "dev-plain.tsx", "export function App(props) { return props.value; }");
    entries[sources.len] = try absPath(&tmp, "dev-plain.tsx");
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
    }
    @memcpy(jsx_entries[0..], entries[0..sources.len]);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    try expectAutomaticJsxModuleGraph(&entries, &jsx_entries, entries[sources.len], .automatic_dev, "_jsxDEV", &disk, 0);
    try expectAutomaticJsxModuleGraph(&entries, &jsx_entries, entries[sources.len], .automatic_dev, "_jsxDEV", &disk, entries.len);
}

test "graph JSX caller: classic runtime binds factory references to source import on cold/cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "import React from 'react'; export function App(props) { return <div>{props.value}</div>; }",
        "import React from 'react'; export function App(props) { return <div><span>{props.value}</span><b /></div>; }",
        "import React from 'react'; export function App(props) { return <>{props.value}<span /></>; }",
        "import React from 'react'; export function App(props) { return <Card title={props.title} />; }",
        "import React from 'react'; export function App(props) { return <UI.Card value={props.value} />; }",
        "import React from 'react'; export function App(props) { return <div {...props} />; }",
        "import React from 'react'; export function App(props) { return <div>{...props.children}</div>; }",
        "import React from 'react'; export function App(props) { return <Card {...props} key={props.id} />; }",
        "import React from 'react'; export function App(props) { function Label() { return <span>{props.label}</span>; } return <div><Label /></div>; }",
        "import React from 'react'; export function App(props) { return <section title={props.title}><span>{props.value}</span><span>{props.other}</span></section>; }",
    };
    var jsx_entries: [sources.len][]const u8 = undefined;
    var entries: [sources.len + 1][]const u8 = undefined;
    for (sources, 0..) |source, index| {
        const basename = try std.fmt.allocPrint(std.testing.allocator, "classic-entry-{d}.tsx", .{index});
        defer std.testing.allocator.free(basename);
        try writeFile(tmp.dir, basename, source);
        entries[index] = try absPath(&tmp, basename);
    }
    try writeFile(tmp.dir, "classic-plain.tsx", "import React from 'react'; export function App(props) { return props.value; }");
    entries[sources.len] = try absPath(&tmp, "classic-plain.tsx");
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
    }
    @memcpy(jsx_entries[0..], entries[0..sources.len]);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    try expectClassicJsxModuleGraph(&entries, &jsx_entries, entries[sources.len], &disk, 0);
    try expectClassicJsxModuleGraph(&entries, &jsx_entries, entries[sources.len], &disk, entries.len);
}

test "graph TypeScript caller: runtime enums keep exact symbol references on cold/cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "enum Kind0 { North, South } export const value0 = Kind0.South;",
        "export enum Kind1 { North = 3, South } export const value1 = Kind1.South;",
        "enum Kind2 { North = 'n', South = 's' } export const value2 = Kind2.South;",
        "enum Kind3 { North = 1 + 2, South = Kind3.North * 2 } export const value3 = Kind3.South;",
        "function read4() { enum Kind4 { North, South } return Kind4.South; } export const value4 = read4();",
        "enum Kind5 { North, South = 7 } function read(Kind5: number) { return Kind5; } export const value5 = Kind5.South + read(0);",
        "function outer6() { enum Kind6 { North, South } return () => Kind6.South; } export const value6 = outer6()();",
        "enum Kind7 { North, South } export const record7 = { [Kind7.North]: Kind7.South };",
        "enum Kind8 { North, South } export function read8(input: number) { switch (input) { case Kind8.North: return Kind8.South; default: return Kind8.North; } }",
        "enum Kind9 { North = 0x10, South = 0b10, West = 0o7 } const lookup9 = { [Kind9.North]: Kind9.South }; export const value9 = lookup9[Kind9.North];",
    };
    var enum_names: [sources.len][]const u8 = undefined;
    var entries: [sources.len][]const u8 = undefined;
    for (sources, 0..) |source, index| {
        const basename = try std.fmt.allocPrint(std.testing.allocator, "enum-entry-{d}.ts", .{index});
        defer std.testing.allocator.free(basename);
        try writeFile(tmp.dir, basename, source);
        entries[index] = try absPath(&tmp, basename);
        enum_names[index] = try std.fmt.allocPrint(std.testing.allocator, "Kind{d}", .{index});
    }
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
        for (enum_names) |enum_name| std.testing.allocator.free(enum_name);
    }

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    try expectTypeScriptEnumModuleGraph(&entries, &enum_names, &disk, 0);
    try expectTypeScriptEnumModuleGraph(&entries, &enum_names, &disk, entries.len);
}

test "graph TypeScript caller: merged namespace keeps exact identities on cold/cache" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "namespace N{export const {a}={a:1}}namespace N{export const b=a}console.log(N.b);";
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    defer profile.resetForTest();
    var cold_identity: ?TypeScriptNamespaceGraphIdentity = null;
    for ([_]usize{ 0, 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819;
        graph.max_threads = 1;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const identity = try expectMergedTypeScriptNamespaceGraphModule(&graph, entry);
        if (cold_identity) |cold| {
            try std.testing.expectEqual(cold.namespace_symbol, identity.namespace_symbol);
            try std.testing.expectEqual(cold.member_a_symbol, identity.member_a_symbol);
            try std.testing.expectEqual(cold.member_b_symbol, identity.member_b_symbol);
            try std.testing.expectEqual(cold.destructuring_temp_symbol, identity.destructuring_temp_symbol);
            try std.testing.expectEqual(cold.first_namespace_scope, identity.first_namespace_scope);
            try std.testing.expectEqual(cold.second_namespace_scope, identity.second_namespace_scope);
        } else {
            cold_identity = identity;
        }
    }
}

test "graph TypeScript caller: local import-equals keeps exact identities on cold/cache" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "namespace Source { export const value = 42; } import Alias = Source; export const result = Alias.value;";
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    defer profile.resetForTest();
    var cold_identity: ?TypeScriptImportEqualsGraphIdentity = null;
    for ([_]usize{ 0, 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819;
        graph.max_threads = 1;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const identity = try expectLocalImportEqualsGraphModule(&graph, entry);
        if (cold_identity) |cold| {
            try std.testing.expectEqual(cold.namespace_symbol, identity.namespace_symbol);
            try std.testing.expectEqual(cold.alias_symbol, identity.alias_symbol);
            try std.testing.expectEqual(cold.namespace_scope, identity.namespace_scope);
            try std.testing.expectEqual(cold.alias_scope, identity.alias_scope);
        } else {
            cold_identity = identity;
        }
    }
}

test "graph TypeScript caller: external require import-equals preserves CJS graph on cold/cache" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const specifier = "node:assert/strict";
    const source = "import Assert = require('node:assert/strict'); export = Assert;";
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    defer profile.resetForTest();
    var cold_identity: ?TypeScriptExternalImportEqualsGraphIdentity = null;
    for ([_]usize{ 0, 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819;
        graph.max_threads = 1;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
        const external = graph.findModuleByPath(specifier) orelse return error.MissingExternalImportEqualsPhantomModule;
        try std.testing.expect(external.is_external);
        try std.testing.expectEqual(Module.State.ready, external.state);
        const importer = graph.findModuleByPath(entry) orelse return error.MissingExternalImportEqualsImporter;
        try std.testing.expectEqual(@as(usize, 1), importer.dependencies.items.len);
        try std.testing.expectEqual(external.index, importer.dependencies.items[0]);
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const identity = try expectExternalImportEqualsGraphModule(&graph, entry, specifier);
        if (cold_identity) |cold| {
            try std.testing.expectEqual(cold.alias_symbol, identity.alias_symbol);
            try std.testing.expectEqual(cold.alias_scope, identity.alias_scope);
        } else {
            cold_identity = identity;
        }
    }
}

test "graph TypeScript caller: qualified local import-equals keeps exact identities on cold/cache" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "namespace Source { export namespace Inner { export const value = 42; } } import DeepAlias = Source.Inner; export const result = DeepAlias.value;";
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    defer profile.resetForTest();
    var cold_identity: ?TypeScriptImportEqualsGraphIdentity = null;
    for ([_]usize{ 0, 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819;
        graph.max_threads = 1;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const identity = try expectQualifiedLocalImportEqualsGraphModule(&graph, entry);
        if (cold_identity) |cold| {
            try std.testing.expectEqual(cold.namespace_symbol, identity.namespace_symbol);
            try std.testing.expectEqual(cold.alias_symbol, identity.alias_symbol);
            try std.testing.expectEqual(cold.namespace_scope, identity.namespace_scope);
            try std.testing.expectEqual(cold.alias_scope, identity.alias_scope);
        } else {
            cold_identity = identity;
        }
    }
}

test "graph TypeScript caller: nested import-equals alias keeps its capture scope on cold/cache" {
    const source = "namespace Container { export namespace Nested { export const value = 43; } import NestedAlias = Nested; export function read() { return NestedAlias.value; } } export const result = Container.read();";
    _ = try expectNestedImportEqualsGraphColdAndCached(source, false);
}

test "graph TypeScript caller: exported namespace import-equals keeps its export identity on cold/cache" {
    const source = "namespace Container { export namespace Nested { export const value = 43; } export import NestedAlias = Nested; export function read() { return NestedAlias.value; } } export const result = Container.read();";
    _ = try expectNestedImportEqualsGraphColdAndCached(source, true);
}

test "graph TypeScript caller: exported namespace require import-equals keeps identities on cold/cache" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const specifier = "node:assert/strict";
    const source = "namespace Container { export import Assert = require('node:assert/strict'); export function read() { return Assert.equal(40 + 2, 42); } } console.log(Container.read());";
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    defer profile.resetForTest();
    var cold_identity: ?TypeScriptNamespaceExternalImportEqualsGraphIdentity = null;
    for ([_]usize{ 0, 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819;
        graph.max_threads = 1;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
        const external = graph.findModuleByPath(specifier) orelse return error.MissingNamespaceExternalImportEqualsPhantomModule;
        try std.testing.expect(external.is_external);
        try std.testing.expectEqual(Module.State.ready, external.state);
        const importer = graph.findModuleByPath(entry) orelse return error.MissingNamespaceExternalImportEqualsImporter;
        try std.testing.expectEqual(@as(usize, 1), importer.dependencies.items.len);
        try std.testing.expectEqual(external.index, importer.dependencies.items[0]);
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const identity = try expectNamespaceExternalImportEqualsGraphModule(&graph, entry, specifier);
        if (cold_identity) |cold| {
            try std.testing.expectEqual(cold.alias_symbol, identity.alias_symbol);
            try std.testing.expectEqual(cold.namespace_symbol, identity.namespace_symbol);
            try std.testing.expectEqual(cold.namespace_parameter_symbol, identity.namespace_parameter_symbol);
            try std.testing.expectEqual(cold.namespace_scope, identity.namespace_scope);
            try std.testing.expectEqual(cold.alias_scope, identity.alias_scope);
            try std.testing.expectEqual(cold.capture_scope, identity.capture_scope);
        } else {
            cold_identity = identity;
        }
    }
}

test "graph TypeScript caller: namespace local require import-equals keeps capture identity on cold/cache" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const specifier = "node:assert/strict";
    const source = "namespace Container { import Assert = require('node:assert/strict'); export function read() { const invoke = () => Assert.equal(40 + 2, 42); return invoke(); } } console.log(Container.read());";
    try writeFile(tmp.dir, "entry.ts", source);
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    defer profile.resetForTest();
    const targets = [_]@import("../transformer/compat.zig").ESTarget{
        .es5,    .es2015, .es2016, .es2017, .es2018, .es2019, .es2020,
        .es2021, .es2022, .es2023, .es2024, .es2025, .esnext,
    };
    const expected_targets = [_]@import("../transformer/compat.zig").ESTarget{
        .es5,    .es2015, .es2016, .es2017, .es2018, .es2019, .es2020,
        .es2021, .es2022, .es2023, .es2024, .es2025, .esnext,
    };
    try std.testing.expectEqualSlices(@TypeOf(targets[0]), &expected_targets, &targets);
    const MinifyMode = struct {
        name: []const u8,
        whitespace: bool,
        syntax: bool,
        identifiers: bool,
    };
    const minify_modes = [_]MinifyMode{
        .{ .name = "plain", .whitespace = false, .syntax = false, .identifiers = false },
        .{ .name = "whitespace", .whitespace = true, .syntax = false, .identifiers = false },
        .{ .name = "syntax", .whitespace = false, .syntax = true, .identifiers = false },
        .{ .name = "syntax-whitespace", .whitespace = true, .syntax = true, .identifiers = false },
        .{ .name = "identifiers", .whitespace = false, .syntax = false, .identifiers = true },
        .{ .name = "identifiers-whitespace", .whitespace = true, .syntax = false, .identifiers = true },
        .{ .name = "syntax-identifiers", .whitespace = false, .syntax = true, .identifiers = true },
        .{ .name = "full", .whitespace = true, .syntax = true, .identifiers = true },
    };
    var minify_mode_mask: u8 = 0;
    for (minify_modes) |mode| {
        const mode_index: u3 = (@as(u3, @intFromBool(mode.whitespace)) << 2) |
            (@as(u3, @intFromBool(mode.syntax)) << 1) |
            @as(u3, @intFromBool(mode.identifiers));
        minify_mode_mask |= @as(u8, 1) << mode_index;
    }
    try std.testing.expectEqual(@as(u8, 0b1111_1111), minify_mode_mask);
    var matrix_cases: usize = 0;
    for (targets, 0..) |target, target_index| {
        for (minify_modes, 0..) |mode, mode_index| {
            const cache_component = try std.fmt.allocPrint(
                std.testing.allocator,
                "cache-{s}-{s}",
                .{ @tagName(target), mode.name },
            );
            defer std.testing.allocator.free(cache_component);
            const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, cache_component });
            defer std.testing.allocator.free(cache_root);
            var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
            defer disk.deinit();

            var cold_identity: ?TypeScriptNamespaceLocalExternalImportEqualsGraphIdentity = null;
            for ([_]usize{ 0, 1 }) |expected_load_hits| {
                profile.resetForTest();
                profile.setIoForTest(std.testing.io);
                profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");
                var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
                defer cache.deinit();
                var graph = ModuleGraph.init(std.testing.allocator, &cache);
                defer graph.deinit();
                graph.disk_cache = &disk;
                graph.disk_load_enabled = true;
                graph.disk_options_hash = 0x6193_4819 ^ (@as(u64, @intCast(target_index)) << 8) ^ @as(u64, @intCast(mode_index));
                graph.disk_compiler_build_id = 0x4819;
                graph.max_threads = 1;
                graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(target);
                graph.transform_options_base.minify_whitespace = mode.whitespace;
                graph.transform_options_base.minify_syntax = mode.syntax;
                graph.minify_identifiers = mode.identifiers;

                try graph.build(std.testing.io, &.{entry});

                try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
                try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
                const external = graph.findModuleByPath(specifier) orelse return error.MissingNamespaceLocalExternalImportEqualsPhantomModule;
                try std.testing.expect(external.is_external);
                try std.testing.expectEqual(Module.State.ready, external.state);
                const importer = graph.findModuleByPath(entry) orelse return error.MissingNamespaceLocalExternalImportEqualsImporter;
                try std.testing.expectEqual(@as(usize, 1), importer.dependencies.items.len);
                try std.testing.expectEqual(external.index, importer.dependencies.items[0]);
                try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
                const identity = try expectNamespaceLocalExternalImportEqualsGraphModule(&graph, entry, specifier);
                const importer_ast = &(importer.ast orelse return error.MissingNamespaceLocalExternalImportEqualsAst);
                const transformed_root = importer_ast.transformed_root orelse return error.MissingNamespaceLocalExternalImportEqualsRoot;
                const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, importer_ast, transformed_root);
                defer std.testing.allocator.free(reachable);
                var arrow_count: usize = 0;
                for (reachable) |raw| {
                    if (importer_ast.nodes.items[raw].tag == .arrow_function_expression) arrow_count += 1;
                }
                const expected_arrow_count: usize = if (target == .es5) 0 else 1;
                try std.testing.expectEqual(expected_arrow_count, arrow_count);
                if (cold_identity) |cold| {
                    try std.testing.expectEqual(cold.alias_symbol, identity.alias_symbol);
                    try std.testing.expectEqual(cold.namespace_symbol, identity.namespace_symbol);
                    try std.testing.expectEqual(cold.namespace_parameter_symbol, identity.namespace_parameter_symbol);
                    try std.testing.expectEqual(cold.namespace_scope, identity.namespace_scope);
                    try std.testing.expectEqual(cold.alias_scope, identity.alias_scope);
                    try std.testing.expectEqual(cold.reference_scope, identity.reference_scope);
                } else {
                    cold_identity = identity;
                }
            }
            matrix_cases += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 104), matrix_cases);
}

test "graph visitor caller: cold parse runs every hook and retains its semantic graph" {
    const cases = [_]struct {
        kind: ColdParseVisitorKind,
        source: []const u8,
    }{
        .{ .kind = .program, .source = "export const value = 1;" },
        .{ .kind = .object_expression, .source = "export const value = { amount: 1 };" },
        .{ .kind = .call_expression, .source = "function read(value) { return value; } export const result = read(1);" },
        .{ .kind = .class_declaration, .source = "export class Value {}" },
        .{ .kind = .class_expression, .source = "export const Value = class {};" },
    };

    for (cases) |case| try expectColdParseVisitorRetainsGraph(case.kind, case.source);
}

test "graph visitor caller: identity-retaining edits keep the graph on cold and cached ASTs" {
    const cases = [_]struct {
        kind: ColdParseVisitorKind,
        source: []const u8,
    }{
        .{ .kind = .program, .source = "export const value = 1 + 2;" },
        .{ .kind = .object_expression, .source = "export const value = { amount: 1 + 2 };" },
        .{ .kind = .call_expression, .source = "function read(value) { return value; } export const result = read(1 + 2);" },
        .{ .kind = .class_declaration, .source = "export class Value { method() { return 1 + 2; } }" },
        .{ .kind = .class_expression, .source = "export const Value = class { method() { return 1 + 2; } };" },
    };

    for (cases) |case| try expectColdAndCachedVisitorMutationRetainsGraph(case.kind, case.source);
}

fn expectVisitorMinifyGraphBuild(
    entry: []const u8,
    disk: *@import("disk_module_store.zig").DiskModuleStore,
    expected_load_hits: usize,
    cold_parameter_symbol: *?u32,
    cold_parameter_scope: *?u32,
    source_index: usize,
    es5_target: bool,
) !usize {
    const profile = @import("../profile.zig");
    profile.resetForTest();
    profile.setIoForTest(std.testing.io);
    profile.addFromCsv("graph.resync.semantic");
    var state: IdentityRetainingVisitorMutationState = .{};
    const plugins = [_]plugin_mod.Plugin{.{
        .name = "identity-retaining-visitor-minify-edit",
        .context = @ptrCast(&state),
        .visitor = identityRetainingVisitorFor(.program),
        .ast_graph_contract = .identity_preserving_visitor_edits,
    }};
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = disk;
    graph.disk_load_enabled = true;
    graph.disk_options_hash = 0x6193_6878 ^ @as(u64, @intFromBool(es5_target));
    graph.disk_compiler_build_id = 0x4819;
    graph.max_threads = 1;
    graph.plugins = &plugins;
    graph.transform_options_base.minify_syntax = true;
    if (es5_target) graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
    graph.minify_identifiers = true;

    try graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
    try std.testing.expect(graph.moduleCount() >= 1);
    try std.testing.expect(state.calls >= 1);
    try std.testing.expect(state.did_mutate);
    const module = graph.findModuleByPath(entry) orelse return error.MissingVisitorMinifyGraphModule;
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expect(module.transform_cache != null);
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    const root = ast.transformed_root orelse return error.MissingVisitorMinifyGraphRoot;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
    defer std.testing.allocator.free(reachable);
    var arrow_count: usize = 0;
    for (reachable) |raw| {
        if (ast.nodes.items[raw].tag == .arrow_function_expression) arrow_count += 1;
    }
    const source_has_arrow = source_index == 2 or source_index == 9;
    const expected_arrow_count: usize = if (source_has_arrow and !es5_target) 1 else 0;
    try std.testing.expectEqual(expected_arrow_count, arrow_count);

    var parameter_symbol: ?u32 = null;
    for (semantic.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind != .parameter or !std.mem.eql(u8, symbol.nameText(ast.source), "value")) continue;
        try std.testing.expect(parameter_symbol == null);
        parameter_symbol = @intCast(raw);
    }
    const sid = parameter_symbol orelse return error.MissingVisitorParameterSymbol;
    const scope_id = @backingInt(semantic.symbols.items[sid].scope_id);
    try std.testing.expect(scope_id < semantic.scopes.len);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, semantic.scopes[scope_id].kind);

    var declaration_count: usize = 0;
    var reference_count: u32 = 0;
    for (reachable) |raw| {
        if (raw >= semantic.symbol_ids.len or semantic.symbol_ids[raw] != sid) continue;
        switch (ast.nodes.items[raw].tag) {
            .binding_identifier, .assignment_target_identifier => declaration_count += 1,
            .identifier_reference => reference_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), declaration_count);
    try std.testing.expectEqual(@as(u32, 1), reference_count);
    try std.testing.expectEqual(reference_count, semantic.symbols.items[sid].reference_count);
    var exact_declaration_rows: usize = 0;
    var exact_reference_rows: usize = 0;
    var exact_reference_stmt: ?u32 = null;
    for (semantic.references) |reference| {
        if (@backingInt(reference.symbol_id) != sid) continue;
        if (reference.flags.declare) {
            try std.testing.expect(reference.node_index.isNone());
            try std.testing.expect(!reference.declaration_node_index.isNone());
            const raw: u32 = @intCast(@backingInt(reference.declaration_node_index));
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, raw) != null);
            try std.testing.expectEqual(sid, semantic.symbol_ids[raw] orelse return error.MissingVisitorParameterDeclarationSymbol);
            try std.testing.expect(ast.nodes.items[raw].tag == .binding_identifier or ast.nodes.items[raw].tag == .assignment_target_identifier);
            exact_declaration_rows += 1;
            continue;
        }
        try std.testing.expect(!reference.node_index.isNone());
        const raw: u32 = @intCast(@backingInt(reference.node_index));
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, raw) != null);
        try std.testing.expectEqual(sid, semantic.symbol_ids[raw] orelse return error.MissingVisitorParameterReferenceSymbol);
        try std.testing.expect(ast.nodes.items[raw].tag == .identifier_reference);
        try std.testing.expect(reference.flags.read and !reference.flags.write);
        try std.testing.expect(reference.stmt_idx != @import("../semantic/symbol.zig").Reference.NO_STMT);
        exact_reference_stmt = reference.stmt_idx;
        exact_reference_rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), exact_declaration_rows);
    try std.testing.expectEqual(@as(usize, 1), exact_reference_rows);
    const stmt_infos = module.prebuilt_stmt_info orelse return error.MissingVisitorMinifyStmtInfo;
    const referencing_stmts = stmt_infos.referencingStmts(sid);
    try std.testing.expectEqual(@as(usize, 1), referencing_stmts.len);
    try std.testing.expectEqual(exact_reference_stmt.?, referencing_stmts[0]);
    try std.testing.expect(referencing_stmts[0] < stmt_infos.stmts.len);
    try std.testing.expect(std.mem.indexOfScalar(u32, stmt_infos.stmts[referencing_stmts[0]].referenced_symbols, sid) != null);

    var folded = TransformedNumericLiteralCount{ .ast = ast, .text = "4" };
    try ast_walk.walkPreorderIterative(std.testing.allocator, ast, root, &folded, TransformedNumericLiteralCount.visit);
    try std.testing.expectEqual(@as(usize, 1), folded.count);
    for ([_][]const u8{ "1", "2" }) |text| {
        var stale = TransformedNumericLiteralCount{ .ast = ast, .text = text };
        try ast_walk.walkPreorderIterative(std.testing.allocator, ast, root, &stale, TransformedNumericLiteralCount.visit);
        try std.testing.expectEqual(@as(usize, 0), stale.count);
    }

    if (cold_parameter_symbol.*) |cold_sid| {
        try std.testing.expectEqual(cold_sid, sid);
        try std.testing.expectEqual(cold_parameter_scope.*.?, scope_id);
    } else {
        cold_parameter_symbol.* = sid;
        cold_parameter_scope.* = scope_id;
    }
    for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    return graph.moduleCount();
}

test "graph visitor caller: identity edits compose with ES5, syntax and identifier minification" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "export function read(value) { return value + (1 + 2); }",
        "export const read = function(value) { return value + (1 + 2); };",
        "export const read = (value) => value + (1 + 2);",
        "const box = { read(value) { return value + (1 + 2); } }; export { box };",
        "class Box { read(value) { return value + (1 + 2); } } export { Box };",
        "export default function read(value) { return value + (1 + 2); }",
        "function read(value) { return value + (1 + 2); } export const result = read;",
        "export const box = { read: function(value) { return value + (1 + 2); } };",
        "export function outer() { return function read(value) { return value + (1 + 2); }; }",
        "export const box = { read: (value) => value + (1 + 2) };",
    };
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    defer profile.resetForTest();
    for ([_]bool{ false, true }) |es5_target| {
        for (sources, 0..) |source, source_index| {
            const file_name = try std.fmt.allocPrint(std.testing.allocator, "entry-{d}.js", .{source_index});
            defer std.testing.allocator.free(file_name);
            try writeFile(tmp.dir, file_name, source);
            const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, file_name });
            defer std.testing.allocator.free(entry);
            const cache_component = try std.fmt.allocPrint(std.testing.allocator, "cache-{d}-{s}", .{ source_index, if (es5_target) "es5" else "esnext" });
            defer std.testing.allocator.free(cache_component);
            const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, cache_component });
            defer std.testing.allocator.free(cache_root);
            var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
            defer disk.deinit();
            var cold_parameter_symbol: ?u32 = null;
            var cold_parameter_scope: ?u32 = null;
            var expected_load_hits: usize = 0;
            for (0..2) |build_index| {
                expected_load_hits = try expectVisitorMinifyGraphBuild(
                    entry,
                    &disk,
                    expected_load_hits,
                    &cold_parameter_symbol,
                    &cold_parameter_scope,
                    source_index,
                    es5_target,
                );
                if (build_index == 1) try std.testing.expect(expected_load_hits > 0);
            }
        }
    }
}

test "graph function-hook caller: tracked direct eval injection retains its exact graph on cold and cached ASTs" {
    try expectColdAndCachedTrackedDirectEvalGraph();
}

const RejectedTrailingCodeGraphState = struct {
    target_calls: usize = 0,
    parse_rejections: usize = 0,
    binding_rejections: usize = 0,
    append_rejections: usize = 0,
};

fn rejectNonStatementTrailingCodeGraphHook(
    ctx: ?*anyopaque,
    api: *plugin_mod.AstTransformCtx,
    info: @import("../transformer/ast_plugin.zig").FunctionInfo,
) plugin_mod.PluginError!void {
    const state_ptr = ctx orelse return error.PluginFailed;
    const state: *RejectedTrailingCodeGraphState = @ptrCast(@alignCast(state_ptr));
    const is_target = info.node_tag != .function_declaration;
    if (!is_target) return;
    state.target_calls += 1;

    if (api.parseAndInjectStatements("const injectedValue = secret; injectedValue;")) |statements| {
        defer api.getAllocator().free(statements);
        for (statements) |statement| try api.addTrailingStatement(statement);
    } else |err| {
        if (err == error.PluginFailed) {
            state.parse_rejections += 1;
        } else {
            return err;
        }
    }

    const binding_name = try api.addString("syntheticBinding");
    const binding = try api.addNode(.{
        .tag = .binding_identifier,
        .span = binding_name,
        .data = .{ .string_ref = binding_name },
    });
    if (api.registerSyntheticBinding(binding, .variable_const)) |symbol| {
        _ = symbol;
    } else |err| {
        if (err == error.PluginFailed) {
            state.binding_rejections += 1;
        } else {
            return err;
        }
    }

    const statement = try api.addNode(.{
        .tag = .empty_statement,
        .span = api.getNode(info.node_idx).span,
        .data = .{ .none = 0 },
    });
    api.addTrailingStatement(statement) catch |err| {
        if (err == error.PluginFailed) {
            state.append_rejections += 1;
        } else {
            return err;
        }
    };
}

fn expectRejectedTrailingCodeGraph(source: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);

    var state: RejectedTrailingCodeGraphState = .{};
    const plugins = [_]plugin_mod.Plugin{.{
        .name = "reject-non-statement-trailing-code",
        .context = @ptrCast(&state),
        .onFunction = rejectNonStatementTrailingCodeGraphHook,
    }};
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.max_threads = 1;
    graph.plugins = &plugins;

    try graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), state.target_calls);
    try std.testing.expectEqual(@as(usize, 1), state.parse_rejections);
    try std.testing.expectEqual(@as(usize, 1), state.binding_rejections);
    try std.testing.expectEqual(@as(usize, 1), state.append_rejections);
    const module = graph.findModuleByPath(entry).?;
    // A callback catching an insertion error cannot publish a partially
    // transformed candidate. The installed source graph remains available,
    // while the sticky plugin diagnostic prevents output publication.
    try std.testing.expectEqual(Module.State.ready, module.state);
    try std.testing.expect(module.ast != null and module.semantic != null);
    try std.testing.expect(module.ast.?.transformed_root == null);
    try std.testing.expect(module.transform_cache == null);
    try std.testing.expectEqualStrings(source, module.source);
    var rejected: usize = 0;
    for (graph.diagnostics.items) |diagnostic| {
        if (diagnostic.severity != .@"error") continue;
        try std.testing.expectEqual(@import("types.zig").BundlerDiagnostic.ErrorCode.plugin_error, diagnostic.code);
        try std.testing.expectEqualStrings(entry, diagnostic.file_path);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "generated code was rejected") != null);
        rejected += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), rejected);
    const ast = &module.ast.?;
    const semantic = &module.semantic.?;
    try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
    var decoy_bindings: usize = 0;
    var forbidden_references: usize = 0;
    for (semantic.symbols.items) |*symbol| {
        if (std.mem.eql(u8, symbol.nameText(ast.source), "injectedValue")) decoy_bindings += 1;
        if (std.mem.eql(u8, symbol.nameText(ast.source), "syntheticBinding")) return error.UnexpectedSyntheticSymbol;
    }
    for (ast.nodes.items) |node| {
        if (node.tag == .binding_identifier and Scanner.identifierNamesEqual(ast.getText(node.data.string_ref), "syntheticBinding"))
            return error.UnpublishedBindingNodeLeaked;
        if (node.tag != .identifier_reference) continue;
        if (Scanner.identifierNamesEqual(ast.getText(node.data.string_ref), "secret")) forbidden_references += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), decoy_bindings);
    try std.testing.expectEqual(@as(usize, 0), forbidden_references);
}

test "graph function-hook caller: caught trailing injection errors leave the installed source unchanged" {
    const sources = [_][]const u8{
        "const secret=1; function decoy(){const injectedValue=99;} const holder={read(){}};",
        "const secret=1; function decoy(){const injectedValue=99;} class Holder{read(){}}",
        "const secret=1; function decoy(){const injectedValue=99;} class Holder{static read(){}}",
        "const secret=1; function decoy(){const injectedValue=99;} const read=function read(){};",
        "const secret=1; function decoy(){const injectedValue=99;} const read=()=>{};",
        "const secret=1; function decoy(){const injectedValue=99;} const holder={get read(){}};",
        "const secret=1; function decoy(){const injectedValue=99;} const holder={set read(value){}};",
        "const secret=1; function decoy(){const injectedValue=99;} const holder={[\"read\"](){}};",
        "const secret=1; function decoy(){const injectedValue=99;} class Holder{async read(){}}",
        "const secret=1; function decoy(){const injectedValue=99;} class Holder{*read(){}}",
    };
    for (sources) |source| try expectRejectedTrailingCodeGraph(source);
}

test "graph function-hook caller: injected identities survive syntax and identifier minification on cold and cached ASTs" {
    const cases = [_]struct { source: []const u8, method_calls: usize }{
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} function read(){}", .method_calls = 0 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} function read(ignored=0){}", .method_calls = 0 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} async function read(){}", .method_calls = 0 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} function* read(){}", .method_calls = 0 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} const holder={run(){function read(){}}};", .method_calls = 1 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} class Holder{run(){function read(){}}}", .method_calls = 1 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} class Holder{static run(){function read(){}}}", .method_calls = 1 },
        .{ .source = "const secret=1; function decoy(){const injectedValue=99;} function outer(){function read(){}}", .method_calls = 0 },
        .{ .source = "\"use strict\"; const secret=1; function decoy(){const injectedValue=99;} {function read(){}}", .method_calls = 0 },
    };

    for (cases) |case| try expectColdAndCachedTrackedInjectedBindingGraph(case.source, case.method_calls);
}

test "graph function-hook caller: ten untracked direct eval edits fail closed" {
    const sources = [_][]const u8{
        "function sibling(){eval('retained');}function read(){let secret=1;eval;} ",
        "function sibling(){eval('retained');}async function read(){let secret=1;eval;} ",
        "function sibling(){eval('retained');}function* read(){let secret=1;eval;} ",
        "function sibling(){eval('retained');}const read=function read(){let secret=1;eval;};",
        "function sibling(){eval('retained');}const read=()=>{let secret=1;eval;};",
        "function sibling(){eval('retained');}const holder={read(){let secret=1;eval;}};",
        "function sibling(){eval('retained');}class Holder{read(){let secret=1;eval;}}",
        "function sibling(){eval('retained');}class Holder{static read(){let secret=1;eval;}}",
        "function sibling(){eval('retained');}function outer(){function read(){let secret=1;eval;}}",
        "function sibling(){eval('retained');}{function read(){let secret=1;eval;}}",
    };

    for (sources) |source| try expectUntrackedEvalGraphMutationRejected(source);
}

test "graph visitor caller: cached AST load reruns every hook on the restored graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "export const object = { amount: 1 }; function read(value) { return value; } export const result = read(object.amount); export class Decl {} export const Expr = class {};";
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    const kinds = [_]ColdParseVisitorKind{
        .program,
        .object_expression,
        .call_expression,
        .class_declaration,
        .class_expression,
    };

    var cold_states: [5]ColdParseVisitorState = .{ .{}, .{}, .{}, .{}, .{} };
    var cold_plugins: [5]plugin_mod.Plugin = undefined;
    for (kinds, 0..) |kind, index| {
        cold_plugins[index] = coldParseVisitorPlugin(kind, &cold_states[index]);
    }
    {
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x1234;
        graph.disk_compiler_build_id = 0xABCD;
        graph.max_threads = 1;
        graph.plugins = &cold_plugins;

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(@as(usize, 0), graph.disk_load_hits.load(.monotonic));
        for (kinds, cold_states) |kind, state| try expectColdParseVisitorInvoked(kind, state);
        try expectVisitorGraphReady(&graph, entry);
    }

    var warm_states: [5]ColdParseVisitorState = .{ .{}, .{}, .{}, .{}, .{} };
    var warm_plugins: [5]plugin_mod.Plugin = undefined;
    for (kinds, 0..) |kind, index| {
        warm_plugins[index] = coldParseVisitorPlugin(kind, &warm_states[index]);
    }
    var warm_cache = ResolveCache.init(std.testing.allocator, .{});
    defer warm_cache.deinit();
    var warm_graph = ModuleGraph.init(std.testing.allocator, &warm_cache);
    defer warm_graph.deinit();
    warm_graph.disk_cache = &disk;
    warm_graph.disk_load_enabled = true;
    warm_graph.disk_options_hash = 0x1234;
    warm_graph.disk_compiler_build_id = 0xABCD;
    warm_graph.max_threads = 1;
    warm_graph.plugins = &warm_plugins;

    try warm_graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), warm_graph.disk_load_hits.load(.monotonic));
    for (kinds, warm_states) |kind, state| try expectColdParseVisitorInvoked(kind, state);
    try expectVisitorGraphReady(&warm_graph, entry);
}

fn expectCachedAstVisitorDoesNotMatch(kind: ColdParseVisitorKind, source: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", source);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_state: ColdParseVisitorState = .{};
    const cold_plugins = [_]plugin_mod.Plugin{coldParseVisitorPlugin(kind, &cold_state)};
    {
        var cache = ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x1234;
        graph.disk_compiler_build_id = 0xABCD;
        graph.max_threads = 1;
        graph.plugins = &cold_plugins;

        try graph.build(std.testing.io, &.{entry});

        try std.testing.expectEqual(@as(usize, 0), graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), cold_state.calls);
        try std.testing.expect(cold_state.observed_tag == null);
        try expectVisitorGraphSkipped(&graph, entry);
    }

    var warm_state: ColdParseVisitorState = .{};
    const warm_plugins = [_]plugin_mod.Plugin{coldParseVisitorPlugin(kind, &warm_state)};
    var warm_cache = ResolveCache.init(std.testing.allocator, .{});
    defer warm_cache.deinit();
    var warm_graph = ModuleGraph.init(std.testing.allocator, &warm_cache);
    defer warm_graph.deinit();
    warm_graph.disk_cache = &disk;
    warm_graph.disk_load_enabled = true;
    warm_graph.disk_options_hash = 0x1234;
    warm_graph.disk_compiler_build_id = 0xABCD;
    warm_graph.max_threads = 1;
    warm_graph.plugins = &warm_plugins;

    try warm_graph.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 1), warm_graph.disk_load_hits.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), warm_state.calls);
    try std.testing.expect(warm_state.observed_tag == null);
    try expectVisitorGraphSkipped(&warm_graph, entry);
}

test "graph visitor caller: ten nonmatching syntax cases skip pre-pass" {
    const cases = [_]struct {
        kind: ColdParseVisitorKind,
        source: []const u8,
    }{
        .{ .kind = .object_expression, .source = "read();" },
        .{ .kind = .object_expression, .source = "class Decl {}" },
        .{ .kind = .call_expression, .source = "const object = {};" },
        .{ .kind = .call_expression, .source = "const Expr = class {};" },
        .{ .kind = .call_expression, .source = "class Decl {}" },
        .{ .kind = .class_declaration, .source = "const object = {};" },
        .{ .kind = .class_declaration, .source = "read();" },
        .{ .kind = .class_declaration, .source = "const Expr = class {};" },
        .{ .kind = .class_expression, .source = "const object = {};" },
        .{ .kind = .class_expression, .source = "read();" },
    };

    for (cases) |case| try expectCachedAstVisitorDoesNotMatch(case.kind, case.source);
}

test "graph pre-pass predicate: syntax and options that mutate graph-visible surface keep pre-pass" {
    try expectPrePassDecision(true, "export const App = () => <div />;", "view.tsx", .{});
    try expectPrePassDecision(true, "@sealed class Foo {}", "decorator.ts", .{ .transform_options = .{ .experimental_decorators = true } });
    try expectPrePassDecision(true, "enum Kind { A, B } export const k = Kind.A;", "enum.ts", .{});
    try expectPrePassDecision(true, "namespace N { export const x = 1 } export const y = N.x;", "namespace.ts", .{});
    try expectPrePassDecision(true, "import Foo = require('foo'); export = Foo;", "import-equals.ts", .{});
    try expectPrePassDecision(true, "export const run = async () => await value;", "downlevel.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export class Box { accessor value = 41; }", "auto-accessor.js", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es2022) } });
    try expectPrePassDecision(false, "export class Box { accessor value = 41; }", "native-auto-accessor.js", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.esnext) } });
    try expectPrePassDecision(true, "export async function* g() { yield 1; await Promise.resolve(); }", "async-generator.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export function* ids() { yield 1; }", "generator.ts", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export function read(value = fallback) { return value; }", "function-default-params.js", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
    try expectPrePassDecision(true, "export const read = (value = fallback) => value;", "arrow-default-params.js", .{ .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) } });
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
    try expectPrePassDecision(false, "export const value = 1;", "drop-console-unused.ts", .{ .transform_options = .{ .drop_console = true } });
    try expectPrePassDecision(true, "export const value = 1;", "plugin.ts", .{ .plugin_transform_applied = true });
    try expectPrePassDecision(false, "export const value = 1;", "unused-plugin.js", .{ .ast_plugin = .ordinary });
    try expectPrePassDecision(false, "export const value = 1;", "ast-function-plugin-no-function.js", .{ .ast_plugin = .on_function });
    try expectPrePassDecision(true, "function outer() { let shared = 100; function nestedMarker() {} }", "ast-function-plugin.js", .{ .ast_plugin = .on_function });
    try expectPrePassDecision(true, "const marker = () => 1;", "ast-arrow-plugin.js", .{ .ast_plugin = .on_function });
    try expectPrePassDecision(true, "const value = { marker() {} };", "ast-method-plugin.js", .{ .ast_plugin = .on_function });
    try expectPrePassDecision(true, "export const value = 1;", "ast-program-visitor-plugin.js", .{ .ast_plugin = .visitor_program });
    try expectPrePassDecision(false, "export const value = 1;", "ast-object-visitor-no-object.js", .{ .ast_plugin = .visitor_object });
    try expectPrePassDecision(true, "const value = {};", "ast-object-visitor.js", .{ .ast_plugin = .visitor_object });
    try expectPrePassDecision(false, "export const value = 1;", "ast-call-visitor-plugin-no-call.js", .{ .ast_plugin = .visitor_call });
    try expectPrePassDecision(true, "useWorklet();", "ast-call-visitor-plugin.js", .{ .ast_plugin = .visitor_call });
    try expectPrePassDecision(false, "export const value = 1;", "ast-class-visitor-no-class.js", .{ .ast_plugin = .visitor_class });
    try expectPrePassDecision(true, "const value = class {};", "ast-class-visitor.js", .{ .ast_plugin = .visitor_class });
    try expectPrePassDecision(false, "export const value = 1;", "ast-auto-worklet-plugin-no-call.js", .{ .ast_plugin = .auto_worklet });
    try expectPrePassDecision(true, "useWorklet(() => {});", "ast-auto-worklet-plugin.js", .{ .ast_plugin = .auto_worklet });
    try expectPrePassDecision(true, "export function App() { return null; }", "refresh.tsx", .{ .react_refresh = true });
    try expectPrePassDecision(false, "export function App() { return null; }", "refresh.cjs", .{ .react_refresh = true });
    try expectPrePassDecision(true, "export function App() { return null; }", "refresh.mjs", .{ .react_refresh = true });
    try expectPrePassDecision(true, "import styled from 'styled-components'; export const Box = styled.div``;", "styled.ts", .{ .styled_components = true });
    try expectPrePassDecision(true, "import { css } from '@emotion/react'; export const c = css``;", "emotion.ts", .{ .emotion = true });
    try expectPrePassDecision(false, "export const value = 42;", "styled-unused.ts", .{ .styled_components = true });
    try expectPrePassDecision(false, "import styled from 'other-package'; export const value = 42;", "styled-unmatched.ts", .{ .styled_components = true });
    try expectPrePassDecision(true, "import styled from '@acme/styled'; export const Box = styled.div``;", "styled-custom.ts", .{
        .styled_components = true,
        .styled_components_top_level_import_paths = &.{"@acme/*"},
    });
    try expectPrePassDecision(false, "export const value = 42;", "emotion-unused.ts", .{ .emotion = true });
    try expectPrePassDecision(false, "import { css } from 'other-package'; export const value = 42;", "emotion-unmatched.ts", .{ .emotion = true });
    try expectPrePassDecision(false, "import type { Emotion } from '@emotion/react'; export const value = 42;", "emotion-type-only.ts", .{ .emotion = true });
    try expectPrePassDecision(true, "import { css } from '@acme/emotion'; export const value = 42;", "emotion-custom.ts", .{
        .emotion = true,
        .emotion_extra_css_sources = &.{"@acme/emotion"},
    });
    try expectPrePassDecision(true, "import styled from '@acme/emotion-styled'; export const value = 42;", "emotion-custom-styled.ts", .{
        .emotion = true,
        .emotion_extra_styled_sources = &.{"@acme/emotion-styled"},
    });
    try expectPrePassDecision(true, "export function f() { 'worklet'; return 1; }", "worklet.ts", .{ .worklet_transform = true });
}

test "graph pre-pass predicate: ES5 arrow cover defaults trigger graph ownership" {
    const es5: PrePassPredicateTestOptions = .{
        .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    };
    const sources = [_][]const u8{
        "export const read = (value = 42) => value;",
        "export const read = (value = null) => value;",
        "export const read = (value = true) => value;",
        "export const read = (value = 'fallback') => value;",
        "export const read = (left, value = 42) => left + value;",
        "export const read = (left = 1, value = 42) => left + value;",
        "export const read = (value = 42, tail) => value + tail;",
        "export const read = (value = fallback) => value;",
        "export const read = (value = getFallback()) => value;",
        "export const read = async (value = 42) => value;",
        "export const factory = () => (value = 42) => value;",
        "export const read = ({ value } = { value: 42 }) => value;",
        "export const read = ([value] = [42]) => value;",
    };
    for (sources) |source| try expectPrePassDecision(true, source, "arrow-default.js", es5);

    const body_assignments = [_][]const u8{
        "export const read = (value) => value = 42;",
        "export const read = (value) => { value = 42; return value; };",
        "export const read = (value) => value + 42;",
    };
    for (body_assignments) |source| try expectPrePassDecision(false, source, "arrow-body-assignment.js", es5);
    try expectPrePassDecision(false, sources[0], "native-arrow-default.js", .{});

    var arrow_without_default_lowering = TransformOptions.compat.fromESTarget(.es5);
    arrow_without_default_lowering.default_params = false;
    try expectPrePassDecision(false, sources[0], "arrow-default-params-native.js", .{
        .transform_options = .{ .unsupported = arrow_without_default_lowering },
    });
}

test "graph pre-pass predicate: ES2022 auto-accessors trigger graph ownership" {
    const es2022: PrePassPredicateTestOptions = .{
        .transform_options = .{ .unsupported = TransformOptions.compat.fromESTarget(.es2022) },
    };
    const sources = [_][]const u8{
        "export class Box { accessor value = 41; }",
        "export class Box { accessor value; }",
        "export class Box { static accessor value = 41; }",
        "export class Box { accessor ['value'] = 41; }",
        "const key = 'value'; export class Box { accessor [key] = 41; }",
        "export class Box { accessor left = 20; accessor right = 22; }",
        "export const Box = class { accessor value = 41; };",
        "export function create() { return class { accessor value = 41; }; }",
        "class Base {} export class Box extends Base { accessor value = 41; }",
        "export default class Box { accessor value = 41; }",
    };
    for (sources) |source| try expectPrePassDecision(true, source, "auto-accessor-forms.js", es2022);

    try expectPrePassDecision(false, "export class Box { value = 41; }", "class-field.js", es2022);
    try expectPrePassDecision(false, sources[0], "native-auto-accessor.js", .{});
}

test "graph pre-pass predicate: Flow enums trigger graph ownership" {
    const sources = [_][]const u8{
        "// @flow\nenum Color { Red, Blue }",
        "// @flow\nenum Color of string { Red = 'red', Blue = 'blue' }",
        "// @flow\nenum Level of number { Low = 1, High = 10 }",
        "// @flow\nenum Toggle of boolean { On = true, Off = false }",
        "// @flow\nenum Token of symbol { Read, Write }",
        "// @flow\nenum Count of bigint { One = 1n, Two = 2n }",
        "// @flow\nenum Status { Active, ... }",
        "// @flow\nenum Color { 'red-color', Blue }",
        "// @flow\nenum First { A }\nenum Second of string { B = 'b' }",
        "// @flow\n'use strict';\nenum Mode { Fast, Safe }",
    };
    for (sources) |source| try expectPrePassDecision(true, source, "flow-enum.js", .{});

    try expectPrePassDecision(false, "// @flow\nexport const value = 42;", "flow-no-enum.js", .{});
    try expectPrePassDecision(false, "export const value = 42;", "plain-js.js", .{});
}

test "graph pre-pass predicate: Flow match lowering triggers graph ownership" {
    const sources = [_][]const u8{
        "// @flow\nconst result = match (value) { 1 => 'one', _ => 'other' };",
        "// @flow\nfunction read(mode: number) { return match (mode) { 0 => 'a', 1 => 'b', _ => 'c' }; }",
        "// @flow\nconst result = match (value) { { type: 'a', value: const item } => item, _ => null };",
        "// @flow\nconst result = match (value) { [const head, ...const tail] => tail, _ => []; }",
        "// @flow\nconst result = match (value) { { type: 'a', ...const rest } if (rest.ok) => rest, _ => null };",
        "// @flow\nconst result = match (value) { 1 | 2 | 3 => 'small', _ => 'other' };",
        "// @flow\nconst result = match (value) { const item if (item > 0) => item, _ => 0 };",
        "// @flow\nconst result = match (value) { Status.Ready => 1, Status.Done => 2, _ => 0 };",
        "// @flow\nfunction read(value) { return match (value) { 1 => value + 1, _ => 0 }; }",
        "// @flow\nfunction read(value) { return match (value) { 1 => match (2) { 2 => value, _ => 0 }, _ => 0 }; }",
    };
    for (sources) |source| try expectPrePassDecision(true, source, "flow-match.js", .{});

    try expectPrePassDecision(false, "// @flow\nconst value = 42;", "flow-match-unused.js", .{});
    try expectPrePassDecision(false, "const value = match(input);", "plain-match-call.js", .{});
}

test "graph pre-pass predicate: Flow ref components trigger graph ownership" {
    const sources = [_][]const u8{
        "// @flow\ncomponent Card(ref?: mixed, ...props: any) { return props; }",
        "// @flow\ncomponent Card(ref?: mixed, label: string, ...props: { extra?: boolean }) { return label; }",
        "// @flow\ncomponent Card<T>(ref?: mixed, value: T, ...props: any) { return value; }",
        "// @flow\nfunction make() { component Card(ref?: mixed, ...props: any) { return props; } return Card; }",
        "// @flow\nexport component Card(ref?: mixed, ...props: any) { return props; }",
        "// @flow\ncomponent First(ref?: mixed) { return ref; } component Second(ref?: mixed) { return ref; }",
        "// @flow\ncomponent Card(label: string, ref?: mixed) { return label; }",
        "// @flow\ncomponent Card(ref?: mixed = null, ...props: any) { return props; }",
        "// @flow\ncomponent Card(ref?: mixed, 'data-value' as value: string, ...props: any) renders React.Node { return value; }",
        "// @flow\nfunction outer() { const label = 'outer'; component Card(ref?: mixed, ...props: any) { return label; } return Card; }",
    };
    for (sources) |source| try expectPrePassDecision(true, source, "flow-component.js", .{});

    try expectPrePassDecision(false, "// @flow\ncomponent Card(label: string) { return label; }", "flow-component-no-ref.js", .{});
    try expectPrePassDecision(false, "// @flow\nexport const value = 42;", "flow-component-unused.js", .{});
}

test "graph Flow caller: match and ref-component identities survive cold and cached ASTs" {
    const quoted_component_keys = [_][]const u8{
        "'data-value'",
        "\"plain\"",
        "'space key'",
        "'dot.key'",
        "'0'",
        "'quote\"inside'",
        "\"apostrophe'key\"",
        "'escaped\\u0061'",
        "'unicode-雪'",
        "'line\\nkey'",
    };
    const match_expressions = [_][]const u8{
        "match (value) { 1 => 'one', _ => fallback }",
        "match (value) { { type: 'a', value: const item } => item, _ => fallback }",
        "match (value) { [const head, ...const tail] => tail, _ => fallback }",
        "match (value) { { type: 'a', ...const rest } if (rest.ok) => rest, _ => fallback }",
        "match (value) { 1 | 2 | 3 => 'small', _ => fallback }",
        "match (value) { const item if (item > 0) => item, _ => fallback }",
        "match (value) { (1 | 2) as item => item, _ => fallback }",
        "match (value) { Status.Ready => 1, Status.Done => 2, _ => fallback }",
        "match (value) { 1 => value + 1, _ => fallback }",
        "match (value) { 1 => match (2) { 2 => value, _ => 0 }, _ => fallback }",
        "match (value) { [1, 2] => 'pair', _ => fallback }",
    };
    const match_parameter_counts = [_]usize{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1 };
    const component_declarations = [_][]const u8{
        "component Card(ref?: mixed, ...props: any) { return props; }",
        "component Card(ref?: mixed, label: string, ...props: { extra?: boolean }) { return label; }",
        "component Card<T>(ref?: mixed, value: T, ...props: any) { return value; }",
        "function make() { const label = 'outer'; component Card(ref?: mixed, ...props: any) { return label; } return Card; }",
        "export component Card(ref?: mixed, ...props: any) { return props; }",
        "component Card(label: string, ref?: mixed, ...props: any) { return label; }",
        "component Card(ref?: mixed = null, ...props: any) { return props; }",
        "component Card(ref?: mixed, 'data-value' as value: string, ...props: any) { return value; }",
        "component Card<T>(ref?: mixed, value: T, ...props: { extra?: boolean }) renders React.Node { return value; }",
        "function outer() { const label = 'outer'; component Card(ref?: mixed, ...props: any) { return label; } return Card; }",
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const component_count = component_declarations.len + quoted_component_keys.len;
    const entry_count = match_expressions.len + component_count + 1;
    var entries: [entry_count][]const u8 = undefined;
    var match_entries: [match_expressions.len][]const u8 = undefined;
    var component_entries: [component_count][]const u8 = undefined;
    for (match_expressions, 0..) |match_expression, index| {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "match-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "// @flow\nconst fallback = 'outer'; const _a = 'user-a'; const _b = 'user-b';\nexport function read(value) {{ return {s}; }}\nexport const keep = _a + _b;",
            .{match_expression},
        );
        defer std.testing.allocator.free(source);
        try writeFile(tmp.dir, file_name, source);
        match_entries[index] = try absPath(&tmp, file_name);
        entries[index] = match_entries[index];
    }
    for (component_declarations, 0..) |component, index| {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "component-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        const invocation = if (index == 3 or index == 9) "" else "export const result = Card({ label: 'ok' });";
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "// @flow\nconst Card_withRef = 'user-helper'; export const userHelper = Card_withRef;\n{s}\n{s}",
            .{ component, invocation },
        );
        defer std.testing.allocator.free(source);
        try writeFile(tmp.dir, file_name, source);
        component_entries[index] = try absPath(&tmp, file_name);
        entries[match_expressions.len + index] = component_entries[index];
    }
    for (quoted_component_keys, 0..) |key, key_index| {
        const index = component_declarations.len + key_index;
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "component-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        const component = try std.fmt.allocPrint(
            std.testing.allocator,
            "component Card(ref?: mixed, {s} as value: string, ...props: any) {{ return value; }}",
            .{key},
        );
        defer std.testing.allocator.free(component);
        const invocation = try std.fmt.allocPrint(std.testing.allocator, "export const result = Card({{ {s}: 'ok' }});", .{key});
        defer std.testing.allocator.free(invocation);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "// @flow\nconst Card_withRef = 'user-helper'; export const userHelper = Card_withRef;\n{s}\n{s}",
            .{ component, invocation },
        );
        defer std.testing.allocator.free(source);
        try writeFile(tmp.dir, file_name, source);
        component_entries[index] = try absPath(&tmp, file_name);
        entries[match_expressions.len + index] = component_entries[index];
    }
    try writeFile(tmp.dir, "flow-types-only.js", "// @flow\ntype Shape = { value: number }; export const value = 42;");
    entries[entry_count - 1] = try absPath(&tmp, "flow-types-only.js");
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
    }

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_match_identities: [match_expressions.len][]FlowGraphIdentity = undefined;
    for (&cold_match_identities) |*identities| identities.* = &.{};
    defer {
        for (cold_match_identities) |identities| {
            if (identities.len > 0) std.testing.allocator.free(identities);
        }
    }
    var cold_component_identities: [component_count]FlowGraphIdentity = undefined;
    const profile = @import("../profile.zig");
    defer profile.resetForTest();
    const expected_graph_module_count = entry_count + 1; // shared ES5 object-rest runtime module
    for ([_]usize{ 0, expected_graph_module_count }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");

        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x4819_6193;
        graph.disk_compiler_build_id = 0x4819_6876;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
        graph.max_threads = 1;

        try graph.build(std.testing.io, &entries);

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(expected_graph_module_count, graph.moduleCount());
        var runtime_module_count: usize = 0;
        var graph_modules = graph.modulesIterator();
        while (graph_modules.next()) |graph_module| {
            var is_source_entry = false;
            for (entries) |entry| {
                if (std.mem.eql(u8, graph_module.path, entry)) {
                    is_source_entry = true;
                    break;
                }
            }
            if (is_source_entry) continue;
            try std.testing.expect(std.mem.startsWith(u8, graph_module.path, "\x00zntc:runtime/"));
            runtime_module_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), runtime_module_count);
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));

        for (match_entries, 0..) |entry, index| {
            const module = graph.findModuleByPath(entry) orelse return error.MissingFlowMatchGraphModule;
            try std.testing.expectEqual(Module.State.ready, module.state);
            try std.testing.expect(module.ast.?.has_flow_runtime_transform);
            try std.testing.expect(module.transform_cache != null);
            try std.testing.expect(module.semantic != null);
            const identities = try expectFlowGeneratedIdentities(module, .match_parameter);
            defer std.testing.allocator.free(identities);
            try std.testing.expectEqual(match_parameter_counts[index], identities.len);
            const root = module.ast.?.transformed_root orelse return error.MissingFlowMatchGraphRoot;
            const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, &module.ast.?, root);
            defer std.testing.allocator.free(reachable);
            _ = try expectFlowSourceBindingIdentity(module, reachable, "fallback");
            _ = try expectFlowSourceBindingIdentity(module, reachable, "_a");
            _ = try expectFlowSourceBindingIdentity(module, reachable, "_b");
            if (expected_load_hits == 0) {
                cold_match_identities[index] = try std.testing.allocator.dupe(FlowGraphIdentity, identities);
            } else {
                try std.testing.expectEqual(cold_match_identities[index].len, identities.len);
                for (cold_match_identities[index], identities) |cold, warm| {
                    try std.testing.expectEqual(cold.symbol_id, warm.symbol_id);
                    try std.testing.expectEqual(cold.scope_id, warm.scope_id);
                    try std.testing.expectEqual(cold.reference_count, warm.reference_count);
                }
            }
        }
        for (component_entries, 0..) |entry, index| {
            const module = graph.findModuleByPath(entry) orelse return error.MissingFlowComponentGraphModule;
            try std.testing.expectEqual(Module.State.ready, module.state);
            try std.testing.expect(module.ast.?.has_flow_runtime_transform);
            try std.testing.expect(module.transform_cache != null);
            try std.testing.expect(module.semantic != null);
            const identity = try expectFlowGeneratedIdentity(module, .ref_component_helper);
            const root = module.ast.?.transformed_root orelse return error.MissingFlowComponentGraphRoot;
            const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, &module.ast.?, root);
            defer std.testing.allocator.free(reachable);
            _ = try expectFlowSourceBindingIdentity(module, reachable, "Card");
            _ = try expectFlowSourceBindingIdentity(module, reachable, "Card_withRef");
            if (index == 7) try expectFlowQuotedPropertyComputed(module, "'data-value'");
            if (index >= component_declarations.len) {
                try expectFlowQuotedPropertyComputed(module, quoted_component_keys[index - component_declarations.len]);
            }
            if (expected_load_hits == 0) {
                cold_component_identities[index] = identity;
            } else {
                try std.testing.expectEqual(cold_component_identities[index].symbol_id, identity.symbol_id);
                try std.testing.expectEqual(cold_component_identities[index].scope_id, identity.scope_id);
                try std.testing.expectEqual(cold_component_identities[index].reference_count, identity.reference_count);
            }
        }

        const type_only = graph.findModuleByPath(entries[entry_count - 1]) orelse return error.MissingFlowTypeOnlyGraphModule;
        try std.testing.expectEqual(Module.State.ready, type_only.state);
        try std.testing.expect(!type_only.ast.?.has_flow_runtime_transform);
        try std.testing.expect(type_only.transform_cache == null);
        for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    }
}

test "graph Flow caller: enum identities and runtime import survive cold and cached ASTs" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "// @flow\nexport enum LongColor { Red, Blue }\nexport const selectedColor = LongColor.Blue;",
        "// @flow\nimport flowEnums from 'flow-enums-runtime';\nexport enum LongShape of string { Circle = 'circle', Square = 'square' }\nexport const selectedShape = LongShape.Square;\nexport const runtimeType = typeof flowEnums;",
        "// @flow\nexport const untouched = 42;",
    };
    const enum_names = [_][]const u8{ "LongColor", "LongShape" };
    var entries: [sources.len][]const u8 = undefined;
    for (sources, 0..) |source, index| {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "flow-enum-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        try writeFile(tmp.dir, file_name, source);
        entries[index] = try absPath(&tmp, file_name);
    }
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
    }

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    const external_patterns = [_][]const u8{expected_flow_enum_runtime_specifier};
    var cold_identities: [sources.len]FlowEnumGraphIdentity = undefined;
    defer profile.resetForTest();
    for ([_]usize{ 0, entries.len }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");

        var resolve_cache = ResolveCache.init(std.testing.allocator, .{
            .external_patterns = &external_patterns,
            .platform = .node,
        });
        defer resolve_cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &resolve_cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819_6925;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
        graph.minify_identifiers = true;
        graph.max_threads = 1;

        try graph.build(std.testing.io, &entries);

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expect(graph.moduleCount() >= entries.len);
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        for (enum_names, 0..) |enum_name, index| {
            const entry = entries[index];
            const identity = try expectFlowEnumGraphModule(&graph, entry, enum_name, index == 1);
            if (expected_load_hits == 0) {
                cold_identities[index] = identity;
            } else {
                try std.testing.expectEqual(cold_identities[index].symbol_id, identity.symbol_id);
                try std.testing.expectEqual(cold_identities[index].scope_id, identity.scope_id);
                try std.testing.expectEqual(cold_identities[index].reference_count, identity.reference_count);
            }
        }
        const plain = graph.findModuleByPath(entries[2]) orelse return error.MissingPlainFlowGraphModule;
        try std.testing.expect(!plain.ast.?.has_flow_enum_declaration);
        var plain_runtime_records: usize = 0;
        for (plain.import_records) |record| {
            if (std.mem.eql(u8, record.specifier, expected_flow_enum_runtime_specifier)) {
                plain_runtime_records += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 0), plain_runtime_records);
        for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    }
}

test "graph Flow caller: enum runtime links one package module on cold and cached ASTs" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sources = [_][]const u8{
        "// @flow\nexport enum LongColor { Red, Blue }\nexport const selectedColor = LongColor.Blue;",
        "// @flow\nimport flowEnums from 'flow-enums-runtime';\nexport enum LongShape of string { Circle = 'circle', Square = 'square' }\nexport const selectedShape = LongShape.Square;\nexport const runtimeType = typeof flowEnums;",
        "// @flow\nexport const untouched = 42;",
    };
    const enum_names = [_][]const u8{ "LongColor", "LongShape" };
    const runtime_source = "module.exports = { Mirrored(names) { return Object.fromEntries(names.map((name) => [name, name])); } };";
    try writeFile(tmp.dir, "node_modules/flow-enums-runtime/package.json", "{\"name\":\"flow-enums-runtime\",\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "node_modules/flow-enums-runtime/index.js", runtime_source);

    var entries: [sources.len][]const u8 = undefined;
    for (sources, 0..) |source, index| {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "flow-enum-link-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        try writeFile(tmp.dir, file_name, source);
        entries[index] = try absPath(&tmp, file_name);
    }
    defer {
        for (entries) |entry| std.testing.allocator.free(entry);
    }
    const runtime_path = try absPath(&tmp, "node_modules/flow-enums-runtime/index.js");
    defer std.testing.allocator.free(runtime_path);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_identities: [enum_names.len]FlowEnumGraphIdentity = undefined;
    var cold_runtime_index: ?ModuleIndex = null;
    defer profile.resetForTest();
    for ([_]usize{ 0, entries.len + 1 }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");

        var resolve_cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer resolve_cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &resolve_cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819;
        graph.disk_compiler_build_id = 0x4819_6928;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
        graph.minify_identifiers = true;
        graph.max_threads = 1;

        try graph.build(std.testing.io, &entries);

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(entries.len + 1, graph.moduleCount());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        const runtime_module = graph.findModuleByPath(runtime_path) orelse return error.MissingFlowEnumRuntimeModule;
        if (cold_runtime_index) |index| {
            try std.testing.expectEqual(index, runtime_module.index);
        } else {
            cold_runtime_index = runtime_module.index;
        }
        for (enum_names, 0..) |enum_name, index| {
            const expected_kind: types.ImportKind = if (index == 0) .require else .static_import;
            const identity = try expectFlowEnumRuntimeModuleLink(&graph, entries[index], runtime_path, enum_name, expected_kind);
            if (expected_load_hits == 0) {
                cold_identities[index] = identity;
            } else {
                try std.testing.expectEqual(cold_identities[index].symbol_id, identity.symbol_id);
                try std.testing.expectEqual(cold_identities[index].scope_id, identity.scope_id);
                try std.testing.expectEqual(cold_identities[index].reference_count, identity.reference_count);
            }
        }
        const plain = graph.findModuleByPath(entries[2]) orelse return error.MissingPlainFlowGraphModule;
        try std.testing.expect(!plain.ast.?.has_flow_enum_declaration);
        for (plain.import_records) |record| {
            try std.testing.expect(!std.mem.eql(u8, record.specifier, expected_flow_enum_runtime_specifier));
        }
        for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
    }
}

test "graph ES5 arrow-default caller: parameter identities survive cold and cached ASTs" {
    const profile = @import("../profile.zig");
    const sources = [_]struct {
        source: []const u8,
        fallback_name: ?[]const u8 = null,
    }{
        .{ .source = "export const readA = (value = 1) => value; export const resultA = readA();" },
        .{ .source = "export const readB = (first, value = 'text', last = null) => value; export const resultB = readB(undefined);" },
        .{ .source = "export const readC = (value = true) => /./.test(value); export const resultC = readC();" },
        .{
            .source = "const fallback = 41; export const readD = (value = fallback) => value + 1; export const resultD = readD();",
            .fallback_name = "fallback",
        },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var entries: [sources.len][]const u8 = undefined;
    for (sources, 0..) |case, index| {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "arrow-default-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        try writeFile(tmp.dir, file_name, case.source);
        entries[index] = try absPath(&tmp, file_name);
    }
    defer for (entries) |entry| std.testing.allocator.free(entry);

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_parameter_identities: [sources.len]GraphSourceSymbolIdentity = undefined;
    var cold_fallback_identity: ?GraphSourceSymbolIdentity = null;
    defer profile.resetForTest();
    for ([_]usize{ 0, entries.len }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.discover.pm.semantic,graph.resync.semantic");

        var resolve_cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer resolve_cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &resolve_cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x6193_4819 ^ 0xA770_0001;
        graph.disk_compiler_build_id = 0x4819_6930;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
        graph.transform_options_base.minify_syntax = true;
        graph.minify_identifiers = true;
        graph.max_threads = 1;

        try graph.build(std.testing.io, &entries);

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expectEqual(entries.len, graph.moduleCount());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        for (entries, 0..) |entry, index| {
            const module = graph.findModuleByPath(entry) orelse return error.MissingArrowDefaultGraphModule;
            try std.testing.expectEqual(Module.State.ready, module.state);
            const ast = &(module.ast orelse return error.MissingArrowDefaultGraphAst);
            const semantic = &(module.semantic orelse return error.MissingArrowDefaultGraphSemantic);
            const transform_cache = module.transform_cache orelse return error.MissingArrowDefaultGraphTransform;
            try std.testing.expectEqual(ast.nodes.items.len, semantic.symbol_ids.len);
            try std.testing.expectEqualSlices(?u32, semantic.symbol_ids, transform_cache.symbol_ids);

            const root = ast.transformed_root orelse return error.MissingArrowDefaultGraphRoot;
            const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, ast, root);
            defer std.testing.allocator.free(reachable);
            var arrow_count: usize = 0;
            var function_count: usize = 0;
            for (reachable) |raw| {
                switch (ast.nodes.items[raw].tag) {
                    .arrow_function_expression => arrow_count += 1,
                    .function_expression => function_count += 1,
                    .assignment_pattern => return error.ES5ArrowDefaultParameterWasNotLowered,
                    else => {},
                }
            }
            try std.testing.expectEqual(@as(usize, 0), arrow_count);
            try std.testing.expect(function_count > 0);

            const parameter_identity = try expectGraphSourceSymbolIdentity(module, reachable, "value");
            if (expected_load_hits == 0) {
                cold_parameter_identities[index] = parameter_identity;
            } else {
                try std.testing.expectEqual(cold_parameter_identities[index].symbol_id, parameter_identity.symbol_id);
                try std.testing.expectEqual(cold_parameter_identities[index].scope_id, parameter_identity.scope_id);
                try std.testing.expectEqual(cold_parameter_identities[index].reference_count, parameter_identity.reference_count);
                try std.testing.expectEqual(cold_parameter_identities[index].write_count, parameter_identity.write_count);
            }

            if (sources[index].fallback_name) |fallback_name| {
                const fallback_identity = try expectGraphSourceSymbolIdentity(module, reachable, fallback_name);
                try std.testing.expectEqual(@as(u32, 0), fallback_identity.write_count);
                if (expected_load_hits == 0) {
                    cold_fallback_identity = fallback_identity;
                } else {
                    const cold = cold_fallback_identity orelse return error.MissingColdArrowDefaultFallbackIdentity;
                    try std.testing.expectEqual(cold.symbol_id, fallback_identity.symbol_id);
                    try std.testing.expectEqual(cold.scope_id, fallback_identity.scope_id);
                    try std.testing.expectEqual(cold.reference_count, fallback_identity.reference_count);
                    try std.testing.expectEqual(cold.write_count, fallback_identity.write_count);
                }
            }
            for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
        }
    }
}

test "Flow ref-component identity survives minify modes on cold and cached ASTs" {
    const profile = @import("../profile.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "// @flow\nexport let Card_withRef = 'user-helper'; component Card(ref?: mixed, 'data-value' as value: string, ...props: any) { return value; } export const result = Card({ 'data-value': 'ok' });";
    try writeFile(tmp.dir, "entry.js", source);
    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);

    const MinifyMode = struct {
        name: []const u8,
        whitespace: bool,
        syntax: bool,
        identifiers: bool,
    };
    const modes = [_]MinifyMode{
        .{ .name = "plain", .whitespace = false, .syntax = false, .identifiers = false },
        .{ .name = "whitespace", .whitespace = true, .syntax = false, .identifiers = false },
        .{ .name = "syntax", .whitespace = false, .syntax = true, .identifiers = false },
        .{ .name = "syntax-whitespace", .whitespace = true, .syntax = true, .identifiers = false },
        .{ .name = "identifiers", .whitespace = false, .syntax = false, .identifiers = true },
        .{ .name = "identifiers-whitespace", .whitespace = true, .syntax = false, .identifiers = true },
        .{ .name = "syntax-identifiers", .whitespace = false, .syntax = true, .identifiers = true },
        .{ .name = "full", .whitespace = true, .syntax = true, .identifiers = true },
    };

    defer profile.resetForTest();
    for (modes, 0..) |mode, mode_index| {
        const cache_component = try std.fmt.allocPrint(
            std.testing.allocator,
            "cache-{s}",
            .{mode.name},
        );
        defer std.testing.allocator.free(cache_component);
        const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, cache_component });
        defer std.testing.allocator.free(cache_root);
        var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
        defer disk.deinit();

        var cold_identity: ?FlowGraphIdentity = null;
        var cold_source_symbol_id: ?u32 = null;
        for ([_]usize{ 0, 2 }) |expected_load_hits| {
            profile.resetForTest();
            profile.setIoForTest(std.testing.io);
            profile.addFromCsv("graph.resync.semantic");
            var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
            defer cache.deinit();
            var graph = ModuleGraph.init(std.testing.allocator, &cache);
            defer graph.deinit();
            graph.disk_cache = &disk;
            graph.disk_load_enabled = true;
            graph.disk_options_hash = 0x4819_6877 ^ (@as(u64, @intCast(mode_index)) << 8);
            graph.disk_compiler_build_id = 0x4819;
            graph.max_threads = 1;
            graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
            graph.transform_options_base.minify_whitespace = mode.whitespace;
            graph.transform_options_base.minify_syntax = mode.syntax;
            graph.minify_identifiers = mode.identifiers;

            try graph.build(std.testing.io, &.{entry});

            try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
            try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
            try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
            const module = graph.findModuleByPath(entry) orelse return error.MissingFlowMinifyGraphModule;
            try std.testing.expectEqual(Module.State.ready, module.state);
            try std.testing.expect(module.ast.?.has_flow_runtime_transform);
            try std.testing.expect(module.transform_cache != null);
            try std.testing.expect(module.semantic != null);
            const identity = try expectFlowGeneratedIdentity(module, .ref_component_helper);
            try std.testing.expectEqual(@as(usize, 1), module.dependencies.items.len);
            const root = module.ast.?.transformed_root orelse return error.MissingFlowMinifyGraphRoot;
            const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, &module.ast.?, root);
            defer std.testing.allocator.free(reachable);
            const source_symbol_id = try expectFlowSourceSymbolIdentity(module, reachable, "Card_withRef");
            try expectFlowQuotedPropertyComputed(module, "'data-value'");
            if (cold_identity) |cold| {
                try std.testing.expectEqual(cold.symbol_id, identity.symbol_id);
                try std.testing.expectEqual(cold.scope_id, identity.scope_id);
                try std.testing.expectEqual(cold.reference_count, identity.reference_count);
                try std.testing.expectEqual(cold_source_symbol_id.?, source_symbol_id);
            } else {
                cold_identity = identity;
                cold_source_symbol_id = source_symbol_id;
            }
            try std.testing.expect(identity.symbol_id != source_symbol_id);
            for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
        }
    }
}

test "Flow match identities survive ES5 lowering and syntax minification on cold and cached ASTs" {
    const match_expressions = [_][]const u8{
        "match (value) { 1 => 'one', _ => fallback }",
        "match (value) { { type: 'a', value: const item } => item, _ => fallback }",
        "match (value) { [const head, ...const tail] => tail, _ => fallback }",
        "match (value) { { type: 'a', ...const rest } if (rest.ok) => rest, _ => fallback }",
        "match (value) { 1 | 2 | 3 => 'small', _ => fallback }",
        "match (value) { const item if (item > 0) => item, _ => fallback }",
        "match (value) { (1 | 2) as item => item, _ => fallback }",
        "match (value) { Status.Ready => 1, Status.Done => 2, _ => fallback }",
        "match (value) { 1 => value + 1, _ => fallback }",
        "match (value) { 1 => match (2) { 2 => value, _ => 0 }, _ => fallback }",
        "match (value) { [1, 2] => 'pair', _ => fallback }",
    };
    const match_parameter_counts = [_]usize{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1 };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var entries: [match_expressions.len][]const u8 = undefined;
    var initialized_entries: usize = 0;
    defer for (entries[0..initialized_entries]) |entry| std.testing.allocator.free(entry);
    for (match_expressions, 0..) |match_expression, index| {
        const file_name = try std.fmt.allocPrint(std.testing.allocator, "flow-match-minify-{d}.js", .{index});
        defer std.testing.allocator.free(file_name);
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "// @flow\nconst fallback = 'outer'; export function read(value = fallback) {{ const unused = 2 * 3; return {s}; }}",
            .{match_expression},
        );
        defer std.testing.allocator.free(source);
        try writeFile(tmp.dir, file_name, source);
        entries[index] = try absPath(&tmp, file_name);
        initialized_entries += 1;
    }

    const dp = try absPath(&tmp, ".");
    defer std.testing.allocator.free(dp);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);
    var disk = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer disk.deinit();

    var cold_identities: [match_expressions.len][]FlowGraphIdentity = undefined;
    for (&cold_identities) |*identities| identities.* = &.{};
    defer for (cold_identities) |identities| {
        if (identities.len > 0) std.testing.allocator.free(identities);
    };

    const profile = @import("../profile.zig");
    defer profile.resetForTest();
    for ([_]usize{ 0, entries.len }) |expected_load_hits| {
        profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");

        var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.disk_cache = &disk;
        graph.disk_load_enabled = true;
        graph.disk_options_hash = 0x4819_6923;
        graph.disk_compiler_build_id = 0x4819_6924;
        graph.transform_options_base.unsupported = @import("../transformer/compat.zig").fromESTarget(.es5);
        graph.transform_options_base.minify_syntax = true;
        graph.minify_identifiers = true;
        graph.max_threads = 1;

        try graph.build(std.testing.io, &entries);

        try std.testing.expectEqual(expected_load_hits, graph.disk_load_hits.load(.monotonic));
        try std.testing.expect(graph.moduleCount() >= entries.len);
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        for (entries, 0..) |entry, index| {
            const module = graph.findModuleByPath(entry) orelse return error.MissingFlowMatchMinifyModule;
            try std.testing.expectEqual(Module.State.ready, module.state);
            try std.testing.expect(module.ast.?.has_flow_runtime_transform);
            try std.testing.expect(module.transform_cache != null);
            try std.testing.expect(module.semantic != null);
            const identities = try expectFlowGeneratedIdentities(module, .match_parameter);
            defer std.testing.allocator.free(identities);
            try std.testing.expectEqual(match_parameter_counts[index], identities.len);
            const root = module.ast.?.transformed_root orelse return error.MissingFlowMatchMinifyRoot;
            const reachable = try ast_walk.collectReachableNodeIndicesFrom(std.testing.allocator, &module.ast.?, root);
            defer std.testing.allocator.free(reachable);
            _ = try expectFlowSourceBindingIdentity(module, reachable, "fallback");
            for (reachable) |raw| {
                const node = module.ast.?.nodes.items[raw];
                if (node.tag == .assignment_pattern) return error.ES5DefaultParameterWasNotLowered;
                if (node.tag == .binding_identifier and std.mem.eql(u8, module.ast.?.getText(node.data.string_ref), "unused"))
                    return error.SyntaxMinifyKeptUnusedBinding;
            }
            if (expected_load_hits == 0) {
                cold_identities[index] = try std.testing.allocator.dupe(FlowGraphIdentity, identities);
            } else {
                try std.testing.expectEqual(cold_identities[index].len, identities.len);
                for (cold_identities[index], identities) |cold, warm| {
                    try std.testing.expectEqual(cold.symbol_id, warm.symbol_id);
                    try std.testing.expectEqual(cold.scope_id, warm.scope_id);
                    try std.testing.expectEqual(cold.reference_count, warm.reference_count);
                }
            }
            for (graph.diagnostics.items) |diagnostic| try std.testing.expect(diagnostic.severity != .@"error");
        }
    }
}

test "graph pre-pass predicate: worklet transforms stay gated by conservative AST signals" {
    const worklet: PrePassPredicateTestOptions = .{ .worklet_transform = true };
    try expectPrePassDecision(false, "export const answer = 42;", "worklet-noop.ts", worklet);
    try expectPrePassDecision(true, "export function f() { 'worklet'; return 1; }", "worklet-function.ts", worklet);
    try expectPrePassDecision(true, "'worklet'; export function f() { return 1; }", "worklet-file.ts", worklet);
    try expectPrePassDecision(true, "runOnUI(() => 1);", "worklet-auto.ts", worklet);
    try expectPrePassDecision(true, "const context = { __workletContextObject: true };", "worklet-context.ts", worklet);
    try expectPrePassDecision(true, "class Context { __workletClass = true; }", "worklet-class.ts", worklet);
    try expectPrePassDecision(false, "class Plain { value = true; }", "worklet-class-noop.ts", worklet);
    try expectPrePassDecision(false, "isWeb();", "worklet-web-check-disabled.ts", worklet);
    try expectPrePassDecision(true, "isWeb();", "worklet-web-check.ts", .{
        .worklet_transform = true,
        .transform_options = .{ .substitute_web_platform_checks = true },
    });
    try expectPrePassDecision(false, "function f() { 'worklet'; return 1; }", "/repo/node_modules/react-native/index.js", worklet);
    try expectPrePassDecision(true, "function f() { 'worklet'; return 1; }", "/repo/node_modules/react-native-reanimated/worklet.js", worklet);
}

// Regression: `toPosixPath` 가 debug/safe 빌드에서 null byte path 를
// `reached unreachable code` 로 panic 시키던 걸 `getMtime` 이 error 로
// 폴백하도록 만든 가드. plugin 합성 virtual path / AssetRegistry / 빈 경로
// 등이 실제로 putModule loop 을 타고 들어와 서버가 통째로 죽던 사례 (#1682).
test "getMtime: reject null-byte / empty / overlong path" {
    try std.testing.expectError(error.InvalidPath, ModuleGraph.getMtime(std.testing.io, ""));
    try std.testing.expectError(error.InvalidPath, ModuleGraph.getMtime(std.testing.io, "/tmp/foo\x00bar"));

    var long_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memset(&long_buf, 'a');
    try std.testing.expectError(error.NameTooLong, ModuleGraph.getMtime(std.testing.io, &long_buf));
}
