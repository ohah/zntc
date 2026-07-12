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
    pub const materializeFromCachedAst = graph_transform_prepass.materializeFromCachedAst;
    const graph_package_info = @import("graph/package_info.zig");
    pub const lookupPkgInfo = graph_package_info.lookupPkgInfo;
    pub const applySideEffectsFromPackageJson = graph_package_info.applySideEffectsFromPackageJson;
    const isPackageTypeModule = graph_package_info.isPackageTypeModule;

    allocator: std.mem.Allocator,
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
    const registerWrapperSymbols = graph_finalize.registerWrapperSymbols;
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
    try std.testing.expectError(error.InvalidPath, ModuleGraph.getMtime(std.testing.io, ""));
    try std.testing.expectError(error.InvalidPath, ModuleGraph.getMtime(std.testing.io, "/tmp/foo\x00bar"));

    var long_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memset(&long_buf, 'a');
    try std.testing.expectError(error.NameTooLong, ModuleGraph.getMtime(std.testing.io, &long_buf));
}
