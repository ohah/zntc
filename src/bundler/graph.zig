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
const ImportKind = types.ImportKind;
const ImportRecord = types.ImportRecord;
const BundlerDiagnostic = types.BundlerDiagnostic;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const CachedResolvedDep = module_mod.CachedResolvedDep;
const runtime_helpers = @import("runtime_helpers.zig");
const runtime_polyfills = @import("runtime_polyfills.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const ResolveCache = resolve_cache_mod.ResolveCache;
const resolver_mod = @import("resolver.zig");
const import_scanner = @import("import_scanner.zig");
const binding_scanner_mod = @import("binding_scanner.zig");
const bundler_symbol = @import("symbol.zig");
const json_to_esm = @import("json_to_esm.zig");
const fs = @import("fs.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const profile = @import("../profile.zig");
const semantic_symbol = @import("../semantic/symbol.zig");
const stmt_info_mod = @import("stmt_info.zig");
const purity = @import("purity.zig");
const Span = @import("../lexer/token.zig").Span;
const pkg_json = @import("package_json.zig");
const plugin_mod = @import("plugin.zig");
const MpscChannel = @import("mpsc_channel.zig").MpscChannel;
const transformer_mod = @import("../transformer/transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const TransformCache = @import("module.zig").TransformCache;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const module_parser = @import("../parser/module.zig");
const runtime_helper_modules = @import("../runtime_helper_modules.zig");
pub const module_store = @import("module_store.zig");
const phase_mod = @import("phase.zig");
pub const ModulePhase = phase_mod.ModulePhase;
pub const ParseAccessor = phase_mod.ParseAccessor;
pub const ResolveAccessor = phase_mod.ResolveAccessor;
pub const LinkAccessor = phase_mod.LinkAccessor;
const graph_assets = @import("graph/assets.zig");
const assetSourceFromBytes = graph_assets.sourceFromBytes;
const moduleReadsSourceForAsset = graph_assets.loaderReadsSource;
const graph_transform_prepass = @import("graph/transform_prepass.zig");
const graph_synthetic_imports = @import("graph/synthetic_imports.zig");
const injectJsxRuntimeImports = graph_synthetic_imports.injectJsxRuntimeImports;
const injectFlowEnumRuntimeImport = graph_synthetic_imports.injectFlowEnumRuntimeImport;
const createJsxImportBindings = graph_synthetic_imports.createJsxImportBindings;
const graph_project_root = @import("graph/project_root.zig");
const findProjectRoot = graph_project_root.findProjectRoot;
const graph_glob = @import("graph/glob.zig");
const expandGlobRecords = graph_glob.expandGlobRecords;
const graph_package_side_effects = @import("graph/package_side_effects.zig");
const graph_parse_helpers = @import("graph/parse_helpers.zig");
const graph_plugins = @import("graph/plugins.zig");
const graph_requested_exports = @import("graph/requested_exports.zig");
const graph_runtime_polyfills = @import("graph/runtime_polyfills.zig");
const graph_state = @import("graph/state.zig");

pub const determineExportsKind = graph_parse_helpers.determineExportsKind;

pub const ModuleGraph = struct {
    pub const matchSideEffectsPatterns = graph_package_side_effects.matchPatterns;
    const configureParserForModule = graph_parse_helpers.configureParserForModule;
    const isFlowPath = graph_parse_helpers.isFlowPath;
    const mergeImportBindings = graph_parse_helpers.mergeImportBindings;
    const mergeImportRecords = graph_parse_helpers.mergeImportRecords;
    const moduleTypeForLoader = graph_parse_helpers.moduleTypeForLoader;
    const projectExportedNames = graph_parse_helpers.projectExportedNames;
    const suppressRuntimeHelperInternalUnresolved = graph_parse_helpers.suppressRuntimeHelperInternalUnresolved;
    const requestAllExports = graph_requested_exports.requestAll;
    const requestNamedExport = graph_requested_exports.requestNamed;
    const shouldLinkResolvedRecordForModule = graph_requested_exports.shouldLinkResolvedRecordForModule;
    const hasDeferredRequestedImports = graph_requested_exports.hasDeferredRequestedImports;
    const requestDependencyExports = graph_requested_exports.requestDependencyExports;
    const shouldRunTransformerPrePass = graph_transform_prepass.shouldRun;
    const runTransformerPrePass = graph_transform_prepass.run;
    pub const resyncModuleMetadataAfterConstMaterialization = graph_transform_prepass.resyncAfterConstMaterialization;
    pub const resyncModuleMetadataAfterAstMutation = graph_transform_prepass.resyncAfterAstMutation;

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
    const pluginRunnerWithBuiltins = graph_plugins.pluginRunnerWithBuiltins;
    const shouldRunResolveId = graph_plugins.shouldRunResolveId;
    const shouldRunLoad = graph_plugins.shouldRunLoad;

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

    /// idx 검증 → modules storage 의 in-range index 반환. read/mut 양쪽 진입점에서 공유.
    inline fn validModuleSlot(self: *const ModuleGraph, idx: ModuleIndex) ?usize {
        if (idx.isNone()) return null;
        const i = idx.toUsize();
        if (i >= self.modules.count()) return null;
        return i;
    }

    /// idx 에 해당하는 module 의 read-only 포인터. 범위 밖이면 null.
    pub inline fn getModule(self: *const ModuleGraph, idx: ModuleIndex) ?*const Module {
        const i = self.validModuleSlot(idx) orelse return null;
        return self.modules.at(i);
    }

    /// 등록된 module 개수. storage 내부 구조 캡슐화 진입점.
    pub inline fn moduleCount(self: *const ModuleGraph) usize {
        return self.modules.count();
    }

    /// path 와 정확히 일치하는 module 의 read-only 포인터. SegmentedList 선형 스캔이라
    /// O(N) — entry/RBM 주입처럼 build 당 호출 횟수가 작은 경로에서만 사용한다.
    pub fn findModuleByPath(self: *const ModuleGraph, path: []const u8) ?*const Module {
        var it = self.modulesIterator();
        while (it.next()) |m| {
            if (std.mem.eql(u8, m.path, path)) return m;
        }
        return null;
    }

    /// **Accessor 전용**. 직접 호출 금지 — `parseAccessor()` 등 phase accessor 의
    /// setter 메서드를 사용하라. 외부 mutable pointer 노출은 worker race 의 root.
    pub inline fn moduleAtMut(self: *ModuleGraph, idx: ModuleIndex) ?*Module {
        const i = self.validModuleSlot(idx) orelse return null;
        return self.modules.at(i);
    }

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

    /// 모든 module 을 순회하는 read-only iterator. SegmentedList 의 chunk 경계를
    /// 투명하게 처리하는 ConstIterator 를 그대로 노출.
    pub inline fn modulesIterator(self: *const ModuleGraph) ModulesIterator {
        return self.modules.constIterator(0);
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

    fn discardResolvedModule(self: *ModuleGraph, resolved: plugin_mod.ResolvedModule) void {
        switch (resolved) {
            .file => |f| self.allocator.free(f.path),
            .disabled => |d| self.allocator.free(d.path),
            .virtual, .dataurl, .external, .custom => {},
        }
    }

    fn markRecordLazyResolved(self: *ModuleGraph, mod_idx: usize, rec_i: usize) void {
        if (mod_idx >= self.modules.count()) return;
        const m = self.modules.at(mod_idx);
        if (rec_i >= m.import_records.len) return;
        m.import_records[rec_i].is_lazy_resolved = true;
    }

    fn resolveDeferredRequestedImportsIfReady(self: *ModuleGraph, idx: ModuleIndex) anyerror!void {
        const mod_idx = self.validModuleSlot(idx) orelse return;
        const m = self.modules.at(mod_idx);
        if (m.state != .ready or m.is_external or m.is_disabled) return;
        if (!self.hasDeferredRequestedImports(mod_idx)) return;
        try self.resolveModuleImports(idx);
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
    fn addModule(self: *ModuleGraph, abs_path: []const u8) !ModuleIndex {
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
    fn addDisabledModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
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
    fn addExternalModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
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

    fn appendResolvedDep(
        self: *ModuleGraph,
        mod_idx: usize,
        dep: CachedResolvedDep,
    ) !void {
        const mod_ptr = self.modules.at(mod_idx);
        const path_owned = try self.allocator.dupe(u8, dep.path);
        errdefer self.allocator.free(path_owned);

        var owned_dep = dep;
        owned_dep.path = path_owned;
        try mod_ptr.resolved_deps.append(self.allocator, owned_dep);
    }

    fn replayCachedResolvedDeps(self: *ModuleGraph, mod_idx: usize) !void {
        std.debug.assert(mod_idx < self.modules.count());
        const mod_index = ModuleIndex.fromUsize(mod_idx);
        const mod_ptr = self.modules.at(mod_idx);

        for (mod_ptr.resolved_deps.items) |dep| {
            switch (dep.target) {
                .file, .virtual => {
                    const dep_idx = try self.addModule(dep.path);
                    if (dep.target_is_module_field or mod_ptr.is_module_field) {
                        self.modules.at(@intFromEnum(dep_idx)).is_module_field = true;
                    }
                    if (dep.is_context_dep) {
                        self.modules.at(@intFromEnum(dep_idx)).is_context_dep = true;
                    }
                    try self.replayLinkResolvedDep(mod_index, mod_idx, dep, dep_idx);
                },
                .disabled => {
                    const dep_idx = try self.addDisabledModule(dep.path);
                    try self.replayLinkResolvedDep(mod_index, mod_idx, dep, dep_idx);
                },
                .external => {
                    const ext_idx = try self.addExternalModule(dep.path);
                    if (dep.record_index) |rec_idx| {
                        if (rec_idx < mod_ptr.import_records.len) {
                            mod_ptr.import_records[rec_idx].is_external = true;
                            _ = try self.requestDependencyExports(mod_idx, rec_idx, mod_ptr.import_records[rec_idx], ext_idx);
                        }
                    }
                    if (dep.kind == .dynamic_import) {
                        try self.linkDynamicImport(mod_index, ext_idx);
                    } else {
                        try self.linkDependency(mod_index, ext_idx);
                    }
                },
                .worker => {
                    const rec_idx = dep.record_index orelse continue;
                    const path_dupe = try self.allocator.dupe(u8, dep.path);
                    try self.worker_entries.append(self.allocator, .{
                        .resolved_path = path_dupe,
                        .source_module = mod_index,
                        .record_index = @intCast(rec_idx),
                    });
                },
            }
        }
    }

    /// `record_index` 가 있으면 record 갱신 + link, 없으면 link 만 수행. file/virtual/disabled
    /// 케이스가 공통으로 사용. external 은 `is_external` flag 기록 후 무조건 link 라 별도.
    fn replayLinkResolvedDep(
        self: *ModuleGraph,
        mod_index: ModuleIndex,
        mod_idx: usize,
        dep: CachedResolvedDep,
        dep_idx: ModuleIndex,
    ) !void {
        if (dep.record_index) |rec_idx| {
            const mod_ptr = self.modules.at(mod_idx);
            if (rec_idx >= mod_ptr.import_records.len) return;
            const request_changed = try self.requestDependencyExports(mod_idx, rec_idx, mod_ptr.import_records[rec_idx], dep_idx);
            try self.recordResolvedDep(mod_index, mod_idx, rec_idx, dep_idx, dep.kind);
            if (request_changed) try self.resolveDeferredRequestedImportsIfReady(dep_idx);
            return;
        }
        _ = try self.requestAllExports(dep_idx);
        if (dep.kind == .dynamic_import) {
            try self.linkDynamicImport(mod_index, dep_idx);
        } else {
            try self.linkDependency(mod_index, dep_idx);
        }
    }

    /// context_expansion_deps 를 resolve 하고 graph 에 module + dependency 로 등록 (#1579 Phase 4).
    /// scanModules receiver / resolveModuleImports 양쪽 경로에서 호출. SegmentedList 로
    /// append 해도 기존 *Module 포인터는 유효 (#1779 INVARIANTS.md).
    fn applyContextDepResults(self: *ModuleGraph, mod_idx: usize) !void {
        const mod_index = ModuleIndex.fromUsize(mod_idx);
        const mod_ptr = self.modules.at(mod_idx);
        const context_deps = mod_ptr.context_expansion_deps;
        if (context_deps.len == 0) return;

        const module_path = mod_ptr.path;
        const source_dir = std.fs.path.dirname(module_path) orelse ".";
        for (context_deps) |dep| {
            const resolved = self.resolve_cache.resolveThreadSafe(source_dir, dep.specifier, dep.kind) catch |err| switch (err) {
                error.ModuleNotFound => {
                    self.addDiag(
                        .unresolved_import,
                        .warning,
                        module_path,
                        dep.span,
                        .resolve,
                        "Cannot resolve require.context match",
                        dep.specifier,
                    );
                    continue;
                },
                else => |e| return e,
            };
            if (resolved) |m| switch (m) {
                .file => |f| {
                    defer self.allocator.free(f.path);
                    const dep_idx = try self.addModule(f.path);
                    _ = try self.requestAllExports(dep_idx);
                    // tree-shaker 가 static import 없이도 이 모듈을 보존하도록 마킹.
                    self.modules.at(@intFromEnum(dep_idx)).is_context_dep = true;
                    try self.appendResolvedDep(mod_idx, .{
                        .kind = dep.kind,
                        .target = .file,
                        .path = f.path,
                        .target_is_module_field = f.is_module_field,
                        .is_context_dep = true,
                    });
                    try self.linkDependency(mod_index, dep_idx);
                },
                // require.context 의 disabled / virtual 등 variant 는 Phase 1 cache 에서 반환되지 않음.
                .disabled => |d| self.allocator.free(d.path),
                .virtual, .dataurl, .external, .custom => unreachable,
            };
        }
    }

    /// 의존성 인덱스를 import_records 에 기록하고 graph 에 link.
    /// dynamic_import 는 별도 link 경로 — 그 외는 일반 dependency.
    /// SegmentedList 는 realloc 없지만 모듈 소유 slice 를 update 하므로 *Module 재조회 안전.
    fn recordResolvedDep(
        self: *ModuleGraph,
        mod_index: ModuleIndex,
        mod_idx: usize,
        rec_i: usize,
        dep_idx: ModuleIndex,
        kind: types.ImportKind,
    ) !void {
        const src_mod = self.modules.at(mod_idx);
        src_mod.import_records[rec_i].resolved = dep_idx;
        src_mod.import_records[rec_i].is_lazy_resolved = false;
        if (kind == .dynamic_import) {
            try self.linkDynamicImport(mod_index, dep_idx);
        } else {
            try self.linkDependency(mod_index, dep_idx);
        }
    }

    /// import_records[rec_i] 가 가리키는 source 의 import_declaration 노드를 source span
    /// 일치로 찾고, 그 안의 모든 named binding 이름이 AST 어디에서도 `identifier_reference`
    /// 로 등장하지 않으면 true (자기 참조 제외).
    ///
    /// implicit type-only — TS type annotation 안에서만 쓰이는 binding — 은 parser 가 type
    /// 노드를 폐기하거나 child_offsets 가 비어있어서 value position 의 identifier_reference
    /// 가 AST 어디에도 안 나타남. babel typescript preset 의 statement elision 과 동등.
    ///
    /// 텍스트 매칭이라 semantic analyzer 의 type-position 추적 한계와 무관. 보수적 — default
    /// / namespace specifier 가 하나라도 있으면 false, 동명 binding 이 다른 import 에서 value
    /// 로 쓰여도 false.
    ///
    /// allocation 실패 시 false (= keep) — resolver 는 기존 hard error 경로 유지.
    fn isImportAllBindingsUnused(self: *ModuleGraph, module: *const Module, record: types.ImportRecord) bool {
        const ast_ptr = if (module.ast) |*a| a else return false;

        var binding_names: std.ArrayList([]const u8) = .empty;
        defer binding_names.deinit(self.allocator);
        // import_specifier 가 자체적으로 imported/local 식별자를 `identifier_reference` 로
        // 보유 (parseIdentifierName) — 이들 NodeIndex 를 따로 수집해서 self-reference 제외.
        var spec_self_nodes: std.ArrayList(NodeIndex) = .empty;
        defer spec_self_nodes.deinit(self.allocator);

        var found_decl = false;
        for (ast_ptr.nodes.items) |n| {
            if (n.tag != .import_declaration) continue;
            const e = n.data.extra;
            if (e + 2 >= ast_ptr.extra_data.items.len) continue;
            const x = module_parser.readImportDeclExtras(ast_ptr, e);
            if (x.source.isNone()) continue;
            const source_node = ast_ptr.getNode(x.source);
            // record.span 이 정확히 source string literal span 이라 start 비교로 unique
            // (`import_scanner.tryExtractImportDecl` 가 동일 span 사용).
            if (source_node.span.start != record.span.start) continue;
            found_decl = true;

            if (x.specs_len == 0) return false; // side-effect import
            if (x.specs_start + x.specs_len > ast_ptr.extra_data.items.len) return false;
            const spec_indices = ast_ptr.extra_data.items[x.specs_start .. x.specs_start + x.specs_len];
            for (spec_indices) |raw_idx| {
                const spec_idx: NodeIndex = @enumFromInt(raw_idx);
                if (spec_idx.isNone()) return false;
                const spec_node = ast_ptr.getNode(spec_idx);
                // default / namespace 는 보수적으로 keep — JSX pragma 등 implicit value use.
                if (spec_node.tag != .import_specifier) return false;
                const left_idx = spec_node.data.binary.left;
                const local_idx = spec_node.data.binary.right;
                const local_node = if (!local_idx.isNone()) ast_ptr.getNode(local_idx) else spec_node;
                binding_names.append(self.allocator, ast_ptr.getText(local_node.span)) catch return false;

                // `import { A as B }` 면 left/right 둘 다 다른 NodeIndex — 모두 self.
                if (!left_idx.isNone()) {
                    spec_self_nodes.append(self.allocator, left_idx) catch return false;
                }
                if (!local_idx.isNone() and @intFromEnum(local_idx) != @intFromEnum(left_idx)) {
                    spec_self_nodes.append(self.allocator, local_idx) catch return false;
                }
            }
            break;
        }
        if (!found_decl or binding_names.items.len == 0) return false;

        for (ast_ptr.nodes.items, 0..) |n, ni| {
            if (n.tag != .identifier_reference) continue;
            const this_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(ni)));
            var is_spec_self = false;
            for (spec_self_nodes.items) |s| {
                if (@intFromEnum(this_idx) == @intFromEnum(s)) {
                    is_spec_self = true;
                    break;
                }
            }
            if (is_spec_self) continue;
            const text = ast_ptr.getText(n.span);
            for (binding_names.items) |name| {
                if (std.mem.eql(u8, text, name)) return false;
            }
        }
        return true;
    }

    fn applyResolveResult(
        self: *ModuleGraph,
        mod_idx: usize,
        rec_i: usize,
        record: types.ImportRecord,
        resolved: ?plugin_mod.ResolvedModule,
        is_error: bool,
    ) !void {
        const mod_index = ModuleIndex.fromUsize(mod_idx);
        if (is_error) {
            // Worker resolve 실패 → 경고만 (메인 빌드 중단하지 않음)
            if (record.kind == .worker) {
                self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Cannot resolve worker module", record.specifier);
                return;
            }
            // ModuleNotFound — browser에서 Node 빌트인은 빈 CJS로 대체
            if (self.resolve_cache.platform.isBrowserLike() and resolve_cache_mod.isNodeBuiltin(record.specifier)) {
                const dep_idx = try self.addDisabledModule(record.specifier);
                try self.appendResolvedDep(mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .disabled,
                    .path = record.specifier,
                });
                try self.recordResolvedDep(mod_index, mod_idx, rec_i, dep_idx, record.kind);
                return;
            }
            // try-block 안의 optional require/import — warning + stub.
            // follow-redirects/debug.js 의 silent-catch 패턴 같이 unresolved 가
            // runtime 에 catch 되는 의도된 케이스를 build hard-fail 시키지 않는다.
            if (record.is_optional) {
                self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Optional dependency not resolved (will throw at runtime if reached)", record.specifier);
                const dep_idx = try self.addDisabledModule(record.specifier);
                try self.appendResolvedDep(mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .disabled,
                    .path = record.specifier,
                });
                try self.recordResolvedDep(mod_index, mod_idx, rec_i, dep_idx, record.kind);
                return;
            }
            // #2466 implicit type-only import — `react-native-screens/types` 처럼 .d.ts 만
            // 있는 subpath 를 `import { X } from '...'` 로 가져와 X 를 type position 에서만
            // 쓰는 패턴. babel typescript preset 은 transform 시 statement 통째 제거하므로
            // Metro 는 resolve 시도조차 안 함. ZNTC 는 parser 가 type annotation 을 폐기
            // 해서 analyzer 가 type-position reference 를 못 보지만, 그게 오히려 도움 —
            // value position 참조가 0 이면 (truly unused 이거나 type-only) 어느 경우든
            // bundle 에서 빠져도 동작 동등. resolve 실패 + binding 전부 value-use 없음 →
            // soft fail (warning + stub).
            if (record.kind == .static_import and self.isImportAllBindingsUnused(self.modules.at(mod_idx), record)) {
                self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Type-only import elided (no value usage)", record.specifier);
                const dep_idx = try self.addDisabledModule(record.specifier);
                try self.appendResolvedDep(mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .disabled,
                    .path = record.specifier,
                });
                try self.recordResolvedDep(mod_index, mod_idx, rec_i, dep_idx, record.kind);
                return;
            }
            const sev: types.BundlerDiagnostic.Severity = if (record.kind == .dynamic_import) .warning else .@"error";
            self.addDiag(.unresolved_import, sev, self.modules.at(mod_idx).path, record.span, .resolve, "Cannot resolve module", record.specifier);
            return;
        }

        if (resolved) |m| {
            // Phase 1 의 cache 와 plugin (fromLegacy 통과) 는 file/disabled variant 만 반환.
            // virtual/dataurl/external/custom 은 PR 5 plugin layer 도입 시 처리.
            switch (m) {
                .file => |f| {
                    defer self.allocator.free(f.path);

                    // Worker: 메인 그래프에 모듈로 추가하지 않고 경로만 수집
                    if (record.kind == .worker) {
                        const path_dupe = try self.allocator.dupe(u8, f.path);
                        try self.worker_entries.append(self.allocator, .{
                            .resolved_path = path_dupe,
                            .source_module = @enumFromInt(mod_idx),
                            .record_index = @intCast(rec_i),
                        });
                        try self.appendResolvedDep(mod_idx, .{
                            .record_index = @intCast(rec_i),
                            .kind = record.kind,
                            .target = .worker,
                            .path = f.path,
                            .target_is_module_field = f.is_module_field,
                        });
                        return;
                    }

                    const dep_idx = try self.addModule(f.path);
                    if (f.is_module_field or self.modules.at(mod_idx).is_module_field) {
                        self.modules.at(@intFromEnum(dep_idx)).is_module_field = true;
                    }
                    const request_changed = try self.requestDependencyExports(mod_idx, rec_i, record, dep_idx);
                    try self.appendResolvedDep(mod_idx, .{
                        .record_index = @intCast(rec_i),
                        .kind = record.kind,
                        .target = .file,
                        .path = f.path,
                        .target_is_module_field = f.is_module_field,
                    });
                    try self.recordResolvedDep(mod_index, mod_idx, rec_i, dep_idx, record.kind);
                    if (request_changed) try self.resolveDeferredRequestedImportsIfReady(dep_idx);
                },
                .disabled => |d| {
                    defer self.allocator.free(d.path);
                    const dep_idx = try self.addDisabledModule(record.specifier);
                    _ = try self.requestDependencyExports(mod_idx, rec_i, record, dep_idx);
                    try self.appendResolvedDep(mod_idx, .{
                        .record_index = @intCast(rec_i),
                        .kind = record.kind,
                        .target = .disabled,
                        .path = record.specifier,
                    });
                    try self.recordResolvedDep(mod_index, mod_idx, rec_i, dep_idx, record.kind);
                },
                .virtual => |v| {
                    // #1961: virtual module 은 plugin 의 load 훅이 source 채움. addModule 이
                    // path 를 dupe 하므로 graph 가 owner. v.path 는 plugin 이 borrow 한
                    // specifier (runtime_helper_modules) 일 수 있어 free 안 함 — plugin 이
                    // alloc 했으면 plugin context lifetime 동안 살아있어야 한다는 규약.
                    const dep_idx = try self.addModule(v.path);
                    const request_changed = try self.requestDependencyExports(mod_idx, rec_i, record, dep_idx);
                    try self.appendResolvedDep(mod_idx, .{
                        .record_index = @intCast(rec_i),
                        .kind = record.kind,
                        .target = .virtual,
                        .path = v.path,
                    });
                    try self.recordResolvedDep(mod_index, mod_idx, rec_i, dep_idx, record.kind);
                    if (request_changed) try self.resolveDeferredRequestedImportsIfReady(dep_idx);
                },
                .dataurl, .external, .custom => unreachable,
            }
        } else {
            // external — phantom Module 로 graph 에 등록 + 양방향 link.
            // 핵심 정책: `record.resolved` 는 `.none` 그대로 둔다. emit/linker 의 기존
            // `rec.resolved.isNone()` 외부 검출 코드를 깨지 않으면서 ModuleInfo /
            // graph traversal 에서만 phantom 노드가 보이도록 분리.
            const ext_idx = try self.addExternalModule(record.specifier);
            const src_mod = self.modules.at(mod_idx);
            src_mod.import_records[rec_i].is_external = true;
            src_mod.import_records[rec_i].is_lazy_resolved = false;
            _ = try self.requestDependencyExports(mod_idx, rec_i, record, ext_idx);
            try self.appendResolvedDep(mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .external,
                .path = record.specifier,
            });
            if (record.kind == .dynamic_import) {
                try self.linkDynamicImport(mod_index, ext_idx);
            } else {
                try self.linkDependency(mod_index, ext_idx);
            }
        }
    }

    /// resolve 결과를 저장하는 구조체. scanWorker가 기록, 메인 스레드가 적용.
    const ResolveOutput = struct {
        resolved: ?plugin_mod.ResolvedModule = null,
        is_error: bool = false,
        skipped: bool = false,
    };

    /// 이벤트 큐 기반 스캔 결과. 워커가 채널로 전송, 메인이 수신.
    const ScanResult = struct {
        module_idx: ModuleIndex,
        resolve_outputs: []ResolveOutput,
    };

    /// Event-queue scan worker: parse and resolve, then send the result to the channel.
    /// It does not mutate graph topology, so the main thread remains the sole writer.
    fn scanWorker(self: *ModuleGraph, idx: ModuleIndex, channel: *MpscChannel(ScanResult)) void {
        channel.send(self.scanModule(idx));
    }

    fn scanModuleRangeSequential(self: *ModuleGraph, start: usize, end: usize) !usize {
        var i = start;
        while (i < end) : (i += 1) {
            const m = self.modules.at(i);
            if (m.state == .ready) continue;
            const result = self.scanModule(.fromUsize(i));
            try self.applyScanResult(result);
        }
        return end;
    }

    fn applyScanResult(self: *ModuleGraph, result: ScanResult) !void {
        var apply_scope = profile.begin(.graph_discover_apply);
        defer apply_scope.end();
        defer if (result.resolve_outputs.len > 0) self.allocator.free(result.resolve_outputs);

        const mod_idx = @intFromEnum(result.module_idx);
        const mod_ptr = self.modules.at(mod_idx);
        self.applySideEffectsFromPackageJson(mod_ptr);
        mod_ptr.state = .ready;

        const records = mod_ptr.import_records;
        const resolves = result.resolve_outputs;

        // SegmentedList (#1779 PR #3) appends do not invalidate existing pointers,
        // so *Module pointers held by inflight workers remain valid. The old
        // ArrayList-era drain/realloc path is no longer needed.
        for (records, 0..) |record, rec_i| {
            if (rec_i < resolves.len) {
                if (resolves[rec_i].skipped and !resolves[rec_i].is_error) {
                    self.markRecordLazyResolved(mod_idx, rec_i);
                    if (resolves[rec_i].resolved) |resolved| self.discardResolvedModule(resolved);
                    continue;
                }
                try self.applyResolveResult(mod_idx, rec_i, record, resolves[rec_i].resolved, resolves[rec_i].is_error);
            }
        }
        if (self.hasDeferredRequestedImports(mod_idx)) {
            try self.resolveModuleImports(result.module_idx);
        }
        // Register require.context matches as graph dependencies (#1579 Phase 4).
        try self.applyContextDepResults(mod_idx);
    }

    fn scanModule(self: *ModuleGraph, idx: ModuleIndex) ScanResult {
        var scope = profile.begin(.graph_discover_scan_worker);
        defer scope.end();

        {
            var parse_scope = profile.begin(.graph_discover_scan_worker_parse);
            defer parse_scope.end();
            self.parseModule(idx);
        }

        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.count()) {
            return .{ .module_idx = idx, .resolve_outputs = &.{} };
        }

        const mod_ptr = self.modules.at(mod_idx);
        self.applySideEffectsFromPackageJson(mod_ptr);
        if (mod_ptr.import_records.len == 0) {
            return .{ .module_idx = idx, .resolve_outputs = &.{} };
        }

        const module_path = mod_ptr.path;
        const source_dir = std.fs.path.dirname(module_path) orelse ".";

        const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

        // import.meta.glob: 워커에서 glob 확장 수행
        expandGlobRecords(self.allocator, mod_ptr.import_records, source_dir);
        // require.context: plugin 으로 matches 주입 + context_expansion_deps 로 수집 (#1579 Phase 4).
        // import_records 는 건드리지 않으므로 len 변화 없음.
        expandRequireContextRecords(self, mod_idx);

        const records = mod_ptr.import_records;
        var results = self.allocator.alloc(ResolveOutput, records.len) catch {
            self.addDiag(.resolve_error, .@"error", module_path, Span.EMPTY, .resolve, "Out of memory allocating resolve results", null);
            return .{ .module_idx = idx, .resolve_outputs = &.{} };
        };
        for (results) |*r| r.* = .{};

        {
            var resolve_scope = profile.begin(.graph_discover_scan_worker_resolve);
            defer resolve_scope.end();

            for (records, 0..) |record, rec_i| {
                if (record.kind == .glob or record.kind == .require_context) {
                    results[rec_i].skipped = true;
                    continue;
                }
                if (record.resolved != .none or record.is_external) {
                    results[rec_i].skipped = true;
                    continue;
                }
                const should_link = self.shouldLinkResolvedRecordForModule(mod_idx, rec_i, record);

                if (plugin_runner) |runner| {
                    if (self.shouldRunResolveId(record.specifier)) {
                        var hook_ctx: plugin_mod.HookContext = .{};
                        const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator, &hook_ctx) catch |err| switch (err) {
                            error.PluginFailed => {
                                self.addPluginFailureDiag(hook_ctx.failure, module_path, record.span, .resolve);
                                results[rec_i] = .{ .is_error = true, .skipped = !should_link };
                                continue;
                            },
                            error.OutOfMemory => {
                                self.addDiag(.resolve_error, .@"error", module_path, record.span, .resolve, "Out of memory during resolve", record.specifier);
                                continue;
                            },
                        };
                        if (resolve_result) |plugin_result| {
                            results[rec_i] = .{ .resolved = plugin_result, .is_error = false, .skipped = !should_link };
                            continue;
                        }
                    }
                }

                const resolved = self.resolve_cache.resolveThreadSafe(
                    source_dir,
                    record.specifier,
                    record.kind,
                ) catch |err| switch (err) {
                    error.ModuleNotFound => {
                        results[rec_i] = .{ .is_error = true, .skipped = !should_link };
                        continue;
                    },
                    error.OutOfMemory => {
                        self.addDiag(.resolve_error, .@"error", module_path, record.span, .resolve, "Out of memory during resolve", record.specifier);
                        continue;
                    },
                };
                results[rec_i] = .{ .resolved = resolved, .skipped = !should_link };
            }
        }

        return .{ .module_idx = idx, .resolve_outputs = results };
    }

    /// 단일 모듈을 파싱하고 import를 추출한다.
    /// 모듈별 Arena로 Scanner/Parser/AST를 할당하여 emitter까지 보존.
    /// import_records는 graph allocator로 별도 할당 (specifier가 source를 참조).
    fn parseModule(self: *ModuleGraph, idx: ModuleIndex) void {
        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.count()) return;

        var module = self.modules.at(mod_idx);
        module.state = .parsing;

        // Plugin runner: parseModule 내에서 load + transform 훅에 공용
        const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

        // Plugin: load 훅 — 모든 module_type 분기 전에 플러그인에게 기회를 줌.
        // 플러그인이 내용을 반환하면 JS 모듈로 전환 (예: .css → JS export).
        var plugin_load_applied = false;
        if (plugin_runner) |runner| {
            if (self.shouldRunLoad(module.path)) {
                // 임시 allocator로 load 결과만 확인 (성공 시 arena를 생성)
                const tmp_arena = module_mod.createParseArena(self.allocator) orelse {
                    module.state = .ready;
                    return;
                };
                var hook_ctx: plugin_mod.HookContext = .{};
                const load_result = runner.runLoad(module.path, tmp_arena.allocator(), &hook_ctx) catch |err| switch (err) {
                    error.PluginFailed => {
                        self.addPluginFailureDiag(hook_ctx.failure, module.path, Span.EMPTY, .resolve);
                        module_mod.destroyParseArena(self.allocator, tmp_arena);
                        module.state = .ready;
                        return;
                    },
                    error.OutOfMemory => {
                        module_mod.destroyParseArena(self.allocator, tmp_arena);
                        module.state = .ready;
                        return;
                    },
                };
                if (load_result) |plugin_result| {
                    plugin_load_applied = true;
                    const load_source_maps = hook_ctx.source_maps orelse &.{};
                    // 플러그인이 내용을 반환. (#2157) `loader` 가 명시되면 raw bytes 를 그 loader 의
                    // 값 표현식으로 변환 (parseAssetModule 와 동일한 assetSourceFromBytes 헬퍼).
                    // asset 변환 성공 시 parseAssetModule 와 동일하게 ast 없이 종료 → emitter 의
                    // emitAssetModule 가 `module.exports = <source>` 로 wrap. JS 파이프라인 진입 시
                    // source 가 단순 표현식 ("text") 이라 default export 없는 빈 모듈로 emit 되어
                    // import binding 이 깨진다.
                    module.parse_arena = tmp_arena;
                    const arena_alloc = tmp_arena.allocator();
                    if (load_source_maps.len > 0) {
                        if (!self.validatePluginSourceMaps(load_source_maps, module.path, Span.EMPTY, .transform, "load")) {
                            module_mod.destroyParseArena(self.allocator, tmp_arena);
                            module.parse_arena = null;
                            module.state = .ready;
                            return;
                        }
                        module.plugin_source_maps = load_source_maps;
                    }
                    if (plugin_result.loader) |loader_override| {
                        module.loader = loader_override;
                        module.module_type = plugin_result.module_type orelse
                            moduleTypeForLoader(ModuleType.fromExtension(std.fs.path.extension(module.path)), loader_override);
                        if (assetSourceFromBytes(arena_alloc, loader_override, plugin_result.contents, module.path, self.transform_options_base.minify_whitespace)) |expr| {
                            module.source = expr;
                            module.module_type = .js;
                            module.exports_kind = .commonjs;
                            module.wrap_kind = .cjs;
                            module.side_effects = false;
                            module.state = .ready;
                            return;
                        }
                        // asset 변환 미지원 loader (file/copy/javascript/json/css/none): raw 그대로 JS 파이프라인.
                        module.source = plugin_result.contents;
                    } else {
                        module.loader = .javascript;
                        module.module_type = .js;
                        module.source = plugin_result.contents;
                    }
                    // module_type 분기를 건너뛰고 JS 파싱 경로로 직접 이동
                    // (아래 "모듈별 Arena" 블록은 parse_arena가 이미 설정되어 있으므로 건너뜀)
                } else {
                    module_mod.destroyParseArena(self.allocator, tmp_arena);
                }
            }
        }

        // compiled_cache key 는 mtime 을 요구한다. 디스크 source 를 읽는 경로는
        // readModuleSourceWithMtime 가 같은 file handle 에서 source+mtime 을 채운다.
        // plugin load 는 플러그인이 생성한 source 일 수 있어 결합할 파일 read 가 없고,
        // empty/none 처럼 source read 가 없는 loader 는 기존처럼 여기서 stat 한다.
        if (module.mtime == 0) {
            const can_read_mtime_with_source = !plugin_load_applied and
                (module.module_type.isJavaScriptLike() or
                    module.module_type == .json or
                    (module.module_type == .css and module.loader == .css) or
                    moduleReadsSourceForAsset(module.loader));
            if (!can_read_mtime_with_source) {
                module.mtime = getMtime(module.path) catch 0;
            }
        }

        // JSON 모듈: ESM AST로 변환 → 일반 JS와 동일한 파이프라인
        // `export default <json_value>;` 형태의 AST를 생성하여
        // semantic → import_scanner → binding_scanner를 공유한다.
        if (module.module_type == .json) {
            module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
                module.state = .ready;
                return;
            };
            const arena_alloc = module.parse_arena.?.allocator();
            module.source = self.readModuleSourceWithMtime(module, arena_alloc, 10 * 1024 * 1024, .parse) orelse return;

            module.ast = json_to_esm.convert(arena_alloc, module.source) catch {
                self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Invalid JSON", null);
                module.state = .ready;
                return;
            };

            // JSON은 항상 ESM, side-effects 없음
            module.exports_kind = .esm;
            module.wrap_kind = .none;
            module.side_effects = false;

            // semantic analysis — export default가 제대로 추적되도록
            var analyzer = SemanticAnalyzer.init(arena_alloc, &(module.ast.?));
            analyzer.is_module = true;
            analyzer.enable_stmt_info = true;
            if (analyzer.analyze()) |_| {
                module.semantic = .{
                    .symbols = analyzer.symbols,
                    .scopes = analyzer.scopes.items,
                    .scope_maps = analyzer.scope_maps.items,
                    .exported_names = analyzer.exported_names,
                    .symbol_ids = analyzer.symbol_ids.items,
                    .unresolved_references = analyzer.unresolved_references,
                    .references = analyzer.references.items,
                    .numeric_const_texts = analyzer.numeric_const_texts,
                };
                if (analyzer.stmt_info_count > 0) {
                    module.prebuilt_stmt_info = stmt_info_mod.buildFromSemantic(
                        arena_alloc,
                        &(module.ast.?),
                        analyzer.symbols.items,
                        analyzer.references.items,
                        if (module.semantic) |*s| &s.unresolved_references else null,
                        false,
                    ) catch null;
                }
            } else |_| {}

            // import/export 스캔 — JSON에는 import가 없지만 export default가 있음
            const scan_result = import_scanner.extractImportsWithCjsDetectionAndDefines(arena_alloc, &(module.ast.?), self.defines) catch {
                module.state = .ready;
                return;
            };
            module.import_records = scan_result.records;
            // specifier 들이 ast.string_table 또는 ast.source 의 borrowed slice 인데, 후속 transform
            // 파스가 string_table 을 grow 시키면 dangling → 0xAA UAF (raw require leak, #raw-require).
            // arena_alloc 은 모듈 lifetime 동안 살아있어 module.import_records 와 동일 lifetime 보장.
            for (module.import_records) |*r| {
                if (arena_alloc.dupe(u8, r.specifier)) |owned| r.specifier = owned else |_| {}
            }
            // OOM 시 silent skip 하면 axios/follow-redirects 같은 optional require 가 hard
            // error 로 회귀해 build 자체가 깨진다. 1108줄 extractImports 와 동일하게 fallback.
            import_scanner.markPostScanFlags(arena_alloc, &(module.ast.?), module.import_records) catch {
                module.state = .ready;
                return;
            };
            module.import_bindings = binding_scanner_mod.extractImportBindings(arena_alloc, &(module.ast.?), scan_result.records) catch &.{};
            binding_scanner_mod.collectNamespaceAccesses(arena_alloc, &(module.ast.?), module.import_bindings) catch {};
            module.export_bindings = binding_scanner_mod.extractExportBindings(arena_alloc, &(module.ast.?), scan_result.records, module.import_bindings) catch &.{};
            module.exported_names = projectExportedNames(arena_alloc, module.export_bindings);

            // Phase 1 (#1328): 합성 심볼 테이블 초기화 + export default 등록.
            module.ensureAliasTable(self.allocator);
            if (module.semantic) |*sem| {
                const scope0: ?std.StringHashMap(usize) =
                    if (sem.scope_maps.len > 0) sem.scope_maps[0] else null;
                binding_scanner_mod.populateSyntheticSymbols(
                    &module.alias_table.?,
                    module.index,
                    module.export_bindings,
                    &sem.symbols,
                    arena_alloc,
                    scope0,
                ) catch {};
            }

            module.state = .parsed;
            return;
        }

        // Asset 로더: 파일을 읽어서 fake JS 모듈로 변환 (rolldown 방식)
        // 플러그인이 이미 소스를 반환한 경우 건너뜀 (플러그인 우선)
        if (module.loader.isAsset() and module.source.len == 0) {
            self.parseAssetModule(module);
            // asset_registry 모드(.file/.copy)에서만 loader를 .javascript로 전환해
            // 일반 JS 파이프라인이 source의 require()를 ImportRecord로 추출하게 한다.
            // (plugin load hook과 동일한 fall-through 신호)
            if (module.loader != .javascript) return;
        }

        // CSS 모듈: @import 추출 → 모듈 그래프에 등록
        if (module.module_type == .css and module.loader == .css) {
            self.parseCssModule(module);
            return;
        }

        if (!module.module_type.isJavaScriptLike()) {
            // loader=.none + 알 수 없는 확장자: 빌드 에러 (esbuild 호환)
            if (module.loader == .none and module.module_type != .css) {
                self.addDiag(.no_loader, .@"error", module.path, Span.EMPTY, .parse, "No loader is configured for this file type", null);
            }
            module.state = .ready;
            return;
        }

        var setup_scope = profile.begin(.graph_discover_pm_setup);

        // 모듈별 Arena: Scanner/Parser/AST 메모리를 소유 (D061)
        // 플러그인 load 훅에서 이미 설정된 경우 건너뜀
        if (module.parse_arena == null) {
            module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
                module.state = .ready;
                return;
            };
        }
        const arena_alloc = module.parse_arena.?.allocator();

        // 파일 시스템에서 읽기 (플러그인이 source를 이미 설정한 경우 건너뜀)
        {
            var read_scope = profile.begin(.graph_discover_pm_setup_read);
            defer read_scope.end();
            if (module.source.len == 0) {
                module.source = self.readModuleSourceWithMtime(module, arena_alloc, 100 * 1024 * 1024, .resolve) orelse return;
            }
        }

        // Plugin: transform 훅 — 소스 읽기 후, 파싱 전에 호출 (Rolldown 호환).
        // 플러그인이 코드를 변환하면 변환된 소스로 파싱한다.
        // Babel 플러그인(예: react-native-reanimated/plugin)이 유저 코드를 변환할 수 있다.
        var plugin_transform_applied = false;
        if (plugin_runner) |runner| {
            if (self.has_transform_plugins) {
                var hook_ctx: plugin_mod.HookContext = .{};
                const transform_result = runner.runTransform(module.source, module.path, arena_alloc, &hook_ctx) catch |err| switch (err) {
                    error.PluginFailed => {
                        self.addPluginFailureDiag(hook_ctx.failure, module.path, Span.EMPTY, .transform);
                        module.state = .ready;
                        return;
                    },
                    error.OutOfMemory => {
                        module.state = .ready;
                        return;
                    },
                };
                if (transform_result) |result| {
                    if (hook_ctx.source_maps) |maps| {
                        if (!self.validatePluginSourceMaps(maps, module.path, Span.EMPTY, .transform, "transform")) {
                            module.state = .ready;
                            return;
                        }
                        if (module.plugin_source_maps.len > 0) {
                            module.plugin_source_maps = std.mem.concat(arena_alloc, []const u8, &.{
                                module.plugin_source_maps,
                                maps,
                            }) catch {
                                module.state = .ready;
                                return;
                            };
                        } else {
                            module.plugin_source_maps = maps;
                        }
                    }
                    module.source = result;
                    plugin_transform_applied = true;
                }
            }
        }

        // Scanner + Parser (arena 할당)
        var scanner: Scanner = undefined;
        var parser: Parser = undefined;
        const ext = std.fs.path.extension(module.path);
        {
            var parser_setup_scope = profile.begin(.graph_discover_pm_setup_parser);
            defer parser_setup_scope.end();

            scanner = Scanner.init(arena_alloc, module.source) catch {
                self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Scanner initialization failed", null);
                module.state = .ready;
                return;
            };

            parser = Parser.init(arena_alloc, &scanner);
            configureParserForModule(&parser, module, ext);

            // Flow 모드: --flow CLI 또는 .js.flow/.jsx.flow 확장자 (pragma는 parse() 내부에서 감지)
            // TS 와 Flow 는 상호 배타 — TS 파일에서는 Flow 무시
            if (parser.source_mode != .ts) {
                if (self.flow) {
                    parser.is_flow = true;
                    scanner.has_flow_pragma = true; // flow comment 활성화
                } else {
                    parser.configureFlowFromPath(module.path);
                }
            }

            // .js 파일에서 JSX 파싱 활성화 (--platform=react-native 프리셋)
            // .ts 파일은 이미 configureForBundler에서 JSX 설정됨 (.tsx만 true)
            // .ts에 강제 jsx=true하면 <T> 제네릭이 JSX로 오파싱됨
            if (self.jsx_in_js and parser.source_mode != .ts) {
                parser.is_jsx = true;
            }

            // 모듈 정의 형식 결정 (Rolldown ModuleDefFormat)
            module.def_format = if (std.mem.eql(u8, ext, ".mjs"))
                .esm_mjs
            else if (std.mem.eql(u8, ext, ".mts"))
                .esm_mts
            else if (std.mem.eql(u8, ext, ".cjs"))
                .cjs
            else if (std.mem.eql(u8, ext, ".cts"))
                .cts
            else if (module.is_module_field or self.isPackageTypeModule(module.path))
                .esm_package_json
            else
                .unknown;

            // .js/.jsx: package.json "type" 또는 Unambiguous 모드로 module/script 결정
            // .mjs/.mts/.ts/.tsx: 이미 확정 module, 변경 없음
            if (!parser.is_module) {
                parser.is_module = true;
                scanner.is_module = true;
                if (module.def_format == .unknown) {
                    parser.is_unambiguous = true;
                }
            }
            // Inline scanning: 파서가 AST를 구축하면서 import/export 레코드를 동시 수집
            parser.enable_scan = true;
            // require.context 등 build-time 정적 평가용 define entries 전달 (#1579 Phase 2.6)
            parser.scan_defines = self.defines;
        }
        setup_scope.end();
        {
            var parse_scope = profile.begin(.graph_discover_pm_parse);
            defer parse_scope.end();
            _ = parser.parse() catch {
                self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Parse failed", null);
                module.state = .ready;
                return;
            };
        }

        if (parser.errors.items.len > 0) {
            // 파싱 에러 기록. recoverable validation 에러(use_strict_non_simple 등)는
            // AST가 정상이고 런타임도 실행하므로 모듈을 스킵하지 않는다 (#1291).
            var has_fatal = false;
            for (parser.errors.items) |err| {
                const msg = if (err.message.len > 0) err.message else "Parse error";
                self.addDiag(.parse_error, .@"error", module.path, err.span, .parse, msg, null);
                const recoverable = if (err.code) |c| c.isRecoverable() else false;
                if (!recoverable) has_fatal = true;
            }
            if (has_fatal) {
                module.state = .ready;
                return;
            }
        }

        // Legal comments 수집 (eof/linked/external 모드용)
        {
            var legal_count: usize = 0;
            for (parser.scanner.comments.items) |c| {
                if (c.is_legal) legal_count += 1;
            }
            if (legal_count > 0) {
                if (arena_alloc.alloc([]const u8, legal_count)) |buf| {
                    var li: usize = 0;
                    for (parser.scanner.comments.items) |c| {
                        if (c.is_legal and c.start < module.source.len and c.end <= module.source.len) {
                            buf[li] = module.source[c.start..c.end];
                            li += 1;
                        }
                    }
                    module.legal_comments = buf[0..li];
                } else |_| {}
            }
        }

        // Semantic analysis — linker에 필요한 스코프/심볼/export 정보.
        // arena_alloc으로 실행: SemanticAnalyzer의 모든 데이터가 parse_arena에 할당.
        // analyzer.deinit()을 의도적으로 호출하지 않음 — arena가 일괄 해제.
        // 주의: 이후에 defer analyzer.deinit()을 추가하면 double-free 발생.
        {
            var semantic_scope = profile.begin(.graph_discover_pm_semantic);
            defer semantic_scope.end();

            if (self.ignore_annotations) {
                purity.clearPureCallFlags(&parser.ast);
            } else {
                purity.markUserPureCalls(&parser.ast, self.pure);
            }

            var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
            analyzer.is_strict_mode = parser.is_strict_mode;
            analyzer.is_module = parser.is_module;
            analyzer.is_ts = parser.source_mode == .ts;
            analyzer.is_flow = parser.is_flow;
            analyzer.enable_stmt_info = true; // tree_shaker가 AST 재순회 없이 StmtInfo 사용
            const analyze_ok = if (analyzer.analyze()) |_| true else |_| false;

            // OOM 시 semantic = null로 유지 (부분 데이터로 linker가 오동작하는 것 방지)
            if (analyze_ok) {
                module.semantic = .{
                    .symbols = analyzer.symbols,
                    .scopes = analyzer.scopes.items,
                    .scope_maps = analyzer.scope_maps.items,
                    .exported_names = analyzer.exported_names,
                    .symbol_ids = analyzer.symbol_ids.items,
                    .unresolved_references = analyzer.unresolved_references,
                    .references = analyzer.references.items,
                    .numeric_const_texts = analyzer.numeric_const_texts,
                };
                // TLA 감지: semantic analyzer가 스코프 체인을 추적하며 정확히 판별
                module.uses_top_level_await = analyzer.has_top_level_await;

                // Semantic Analyzer에서 사전 수집한 stmt↔symbol 매핑으로 StmtInfo 구축.
                // tree_shaker가 AST를 다시 순회하지 않아도 된다 (Phase 2 최적화).
                if (analyzer.stmt_info_count > 0) {
                    module.prebuilt_stmt_info = stmt_info_mod.buildFromSemantic(
                        arena_alloc,
                        &parser.ast,
                        analyzer.symbols.items,
                        analyzer.references.items,
                        if (module.semantic) |*s| &s.unresolved_references else null,
                        false,
                    ) catch null;
                }
            }
        }

        var post_scope = profile.begin(.graph_discover_pm_post);
        defer post_scope.end();

        module.ast = parser.ast;
        module.line_offsets = scanner.line_offsets.items;

        // import/export 추출: inline scan 결과를 bundler 타입으로 변환
        {
            // Parser scan records → bundler ImportRecord
            {
                var records_scope = profile.begin(.graph_discover_pm_post_records);
                defer records_scope.end();

                const scan_records = parser.scan_import_records.items;
                const records = arena_alloc.alloc(ImportRecord, scan_records.len) catch {
                    module.state = .ready;
                    return;
                };
                for (scan_records, 0..) |sr, i| {
                    const ik: ImportKind = @enumFromInt(@intFromEnum(sr.kind));
                    const ctx_mode: types.RequireContextMode = @enumFromInt(@intFromEnum(sr.context_mode));
                    records[i] = .{
                        .specifier = sr.specifier,
                        .kind = ik,
                        .span = sr.span,
                        .url_span = sr.url_span,
                        .glob_eager = sr.glob_eager,
                        .glob_import_name = sr.glob_import_name,
                        .context_recursive = sr.context_recursive,
                        .context_filter = sr.context_filter,
                        .context_filter_flags = sr.context_filter_flags,
                        .context_mode = ctx_mode,
                        .context_invalid_reason = sr.context_invalid_reason,
                    };
                }
                module.import_records = records;

                // Parser scan import bindings → bundler ImportBinding
                const scan_ibindings = parser.scan_import_bindings.items;
                if (arena_alloc.alloc(binding_scanner_mod.ImportBinding, scan_ibindings.len)) |ibindings| {
                    for (scan_ibindings, 0..) |sb, i| {
                        const ib_kind: binding_scanner_mod.ImportBinding.Kind = @enumFromInt(@intFromEnum(sb.kind));
                        ibindings[i] = .{
                            .kind = ib_kind,
                            .local_name = sb.local_name,
                            .imported_name = sb.imported_name,
                            .local_span = sb.local_span,
                            .import_record_index = sb.import_record_index,
                        };
                    }
                    module.import_bindings = ibindings;
                } else |_| {}

                // Parser scan export bindings → bundler ExportBinding
                const scan_ebindings = parser.scan_export_bindings.items;
                if (arena_alloc.alloc(binding_scanner_mod.ExportBinding, scan_ebindings.len)) |ebindings| {
                    for (scan_ebindings, 0..) |sb, i| {
                        const eb_kind: binding_scanner_mod.ExportBinding.Kind = @enumFromInt(@intFromEnum(sb.kind));
                        ebindings[i] = .{
                            .exported_name = sb.exported_name,
                            .local_name = sb.local_name,
                            .local_span = sb.local_span,
                            .kind = eb_kind,
                            .import_record_index = sb.import_record_index,
                        };
                    }
                    module.export_bindings = ebindings;
                    module.exported_names = projectExportedNames(arena_alloc, ebindings);
                } else |_| {}
            }

            // OOM 시 silent skip 하면 optional require 가 hard error 로 회귀하므로 module 을
            // ready 로 끝내고 graph 진행 중단 (1108줄 extractImports 와 동일 패턴).
            {
                var optional_scope = profile.begin(.graph_discover_pm_post_optional_requires);
                defer optional_scope.end();
                import_scanner.markPostScanFlags(arena_alloc, &(module.ast.?), module.import_records) catch {
                    module.state = .ready;
                    return;
                };
            }

            if (parser.ast.has_flow_enum_declaration) {
                module.import_records = injectFlowEnumRuntimeImport(
                    arena_alloc,
                    module.import_records,
                ) catch module.import_records;
            }

            // namespace access 수집은 별도 AST walk 필요
            {
                var namespace_scope = profile.begin(.graph_discover_pm_post_namespace_access);
                defer namespace_scope.end();
                binding_scanner_mod.collectNamespaceAccesses(arena_alloc, &parser.ast, module.import_bindings) catch {};
            }

            // Phase 1-3b (#1328): 합성 심볼 테이블 초기화 + re_export_alias 등록
            // + semantic 공간에 synthetic_default 등록.
            {
                var synthetic_scope = profile.begin(.graph_discover_pm_post_synthetic_symbols);
                defer synthetic_scope.end();
                module.ensureAliasTable(self.allocator);
                if (module.semantic) |*sem| {
                    const scope0: ?std.StringHashMap(usize) =
                        if (sem.scope_maps.len > 0) sem.scope_maps[0] else null;
                    binding_scanner_mod.populateSyntheticSymbols(
                        &module.alias_table.?,
                        module.index,
                        module.export_bindings,
                        &sem.symbols,
                        arena_alloc,
                        scope0,
                    ) catch {};
                }
            }

            // CJS/ESM 감지 — inline scan 결과로 ScanResult 생성
            const scan_result = import_scanner.ScanResult{
                .records = module.import_records,
                .has_esm_syntax = parser.scan_result.has_esm_syntax or parser.has_module_syntax,
                .has_cjs_require = parser.scan_result.has_cjs_require,
                .has_module_exports = parser.scan_result.has_module_exports,
                .has_exports_dot = parser.scan_result.has_exports_dot,
                .has_esmodule_marker = parser.scan_result.has_esmodule_marker,
            };

            // JSX automatic synthetic imports. `react` 는 key-after-spread 일 때만 주입 —
            // 모든 JSX 모듈에 일괄 주입하면 `createElement` 문자열이 노출되어
            // `createElement 미노출` 회귀 테스트를 깬다.
            var jsx_injected = false;
            var react_injected = false;
            var jsx_inject_base: u32 = 0;
            {
                var jsx_scope = profile.begin(.graph_discover_pm_post_jsx_imports);
                defer jsx_scope.end();
                if (self.jsx_runtime != .classic and parser.ast.has_jsx) {
                    if (self.jsx_specifier_cache == null) {
                        const is_dev = self.jsx_runtime == .automatic_dev;
                        self.jsx_specifier_cache = std.fmt.allocPrint(
                            self.allocator,
                            "{s}/{s}",
                            .{ self.jsx_import_source, if (is_dev) "jsx-dev-runtime" else "jsx-runtime" },
                        ) catch null;
                    }
                    if (self.jsx_specifier_cache) |specifier| {
                        var specs_buf: [2][]const u8 = undefined;
                        specs_buf[0] = specifier;
                        var n: usize = 1;
                        if (parser.ast.has_jsx_key_after_spread) {
                            specs_buf[n] = self.jsx_import_source;
                            n += 1;
                        }
                        jsx_inject_base = @intCast(module.import_records.len);
                        module.import_records = injectJsxRuntimeImports(
                            specs_buf[0..n],
                            arena_alloc,
                            module.import_records,
                        ) catch module.import_records;
                        jsx_injected = (module.import_records.len > jsx_inject_base);
                        react_injected = (n == 2) and jsx_injected;
                    }
                }
            }

            module.exports_kind = determineExportsKind(scan_result, module.path);
            module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;
            module.has_cjs_export_signal = scan_result.has_module_exports or scan_result.has_exports_dot;
            module.can_skip_cjs_default_interop = Module.computeCanSkipCjsDefaultInterop(
                module.wrap_kind == .cjs,
                scan_result.has_module_exports,
                scan_result.has_exports_dot,
                scan_result.has_esmodule_marker,
            );

            // JSX synthetic import bindings 추가
            if (jsx_injected) {
                const jsx_record_idx: u32 = jsx_inject_base;
                const react_record_idx: ?u32 = if (react_injected) jsx_record_idx + 1 else null;
                module.import_bindings = createJsxImportBindings(
                    self.jsx_runtime,
                    arena_alloc,
                    module.import_bindings,
                    jsx_record_idx,
                    react_record_idx,
                ) catch module.import_bindings;
            }
        }

        // #1961/#1913: transformer pre-pass. helper module 을 graph 의 1급 모듈로
        // 분배하려면 helper import 가 link 단계 전에 import_records 에 등록되어야 한다.
        // transformer 를 여기서 1회 실행해 final AST 를 module.ast 에 저장하고, 그 AST
        // 기준으로 semantic/import/export/StmtInfo 를 다시 만든다. emitter 는
        // module.transform_cache hit 시 transform skip.
        {
            var prepass_scope = profile.begin(.graph_discover_pm_prepass);
            defer prepass_scope.end();
            const run_prepass = blk: {
                var decision_scope = profile.begin(.graph_discover_pm_prepass_decision);
                defer decision_scope.end();
                break :blk self.shouldRunTransformerPrePass(module, plugin_transform_applied);
            };
            if (run_prepass) {
                var run_scope = profile.begin(.graph_discover_pm_prepass_run);
                defer run_scope.end();
                self.runTransformerPrePass(module, arena_alloc);
            } else {
                module.transform_cache = null;
                suppressRuntimeHelperInternalUnresolved(module);
            }
        }

        module.state = .parsed;
    }

    const findPackageDirPath = resolve_cache_mod.findPackageDirPath;

    /// `pkg_info_cache` 통합 lookup. pkg_dir_path 별 1회만 parsePackageJson,
    /// 이후 호출은 cache hit. is_module 과 side_effects 모두 반환 (#1744).
    ///
    /// Fast path (lock→get→unlock) → Slow path (lock 밖 parse) →
    /// double-check put (race 시 내 값 폐기). patterns 메모리 소유권은
    /// 캐시가 보유하며 Linker deinit 에서 일괄 해제.
    pub fn lookupPkgInfo(self: *ModuleGraph, pkg_dir_path: []const u8) PkgInfo {
        self.pkg_info_cache_mutex.lock();
        const cached = self.pkg_info_cache.get(pkg_dir_path);
        self.pkg_info_cache_mutex.unlock();
        if (cached) |c| return c;

        var info: PkgInfo = .{ .is_module = false, .side_effects = .unknown };
        if (pkg_json.parsePackageJson(self.allocator, pkg_dir_path)) |parsed_val| {
            var parsed = parsed_val;
            info.is_module = parsed.pkg.isModule();
            info.side_effects = parsed.pkg.side_effects;
            // 소유권을 info 로 이전 — parsed.deinit() 에서 이중 free 방지.
            parsed.pkg.side_effects = .unknown;
            parsed.deinit();
        } else |_| {}

        self.pkg_info_cache_mutex.lock();
        defer self.pkg_info_cache_mutex.unlock();
        // Race: 다른 스레드가 먼저 put 했으면 내 info.side_effects 폐기.
        if (self.pkg_info_cache.get(pkg_dir_path)) |raced| {
            info.side_effects.deinit(self.allocator);
            return raced;
        }
        self.pkg_info_cache.put(self.allocator, pkg_dir_path, info) catch {
            // alloc 실패 시 누수 방지
            info.side_effects.deinit(self.allocator);
            return .{ .is_module = info.is_module, .side_effects = .unknown };
        };
        return info;
    }

    /// node_modules 패키지의 package.json sideEffects 필드를 module.side_effects에 반영.
    fn applySideEffectsFromPackageJson(self: *ModuleGraph, module: *Module) void {
        if (self.ignore_annotations) return;
        const pkg_dir_path = findPackageDirPath(module.path) orelse return;
        const info = self.lookupPkgInfo(pkg_dir_path);
        graph_package_side_effects.applyCached(module, pkg_dir_path, info.side_effects);
    }

    /// Phase 1: 모듈의 import들을 resolve하고 의존성 모듈을 등록한다.
    /// modules 배열이 커질 수 있으므로, 포인터가 아닌 인덱스로만 접근.
    fn resolveModuleImports(self: *ModuleGraph, idx: ModuleIndex) !void {
        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.count()) return;

        const mod_ptr = self.modules.at(mod_idx);
        const module_path = mod_ptr.path;
        const source_dir = std.fs.path.dirname(module_path) orelse ".";

        // Plugin: resolveId 훅용 runner를 루프 밖에서 한 번만 생성
        const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

        // import.meta.glob: glob 레코드를 파일 시스템에서 확장
        expandGlobRecords(self.allocator, mod_ptr.import_records, source_dir);
        // require.context: plugin 으로 matches 주입 + context_expansion_deps 로 수집 (#1579 Phase 4).
        expandRequireContextRecords(self, mod_idx);

        const records = mod_ptr.import_records;
        for (records, 0..) |record, rec_i| {
            if (record.kind == .glob) continue;
            if (record.kind == .require_context) continue;
            if (record.resolved != .none or record.is_external) continue;
            const should_link = self.shouldLinkResolvedRecordForModule(mod_idx, rec_i, record);

            // Plugin: resolveId 훅 — 기본 resolver 전에 플러그인에게 경로 해석 기회를 줌
            if (plugin_runner) |runner| {
                if (self.shouldRunResolveId(record.specifier)) {
                    var hook_ctx: plugin_mod.HookContext = .{};
                    const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator, &hook_ctx) catch |err| switch (err) {
                        error.PluginFailed => {
                            self.addPluginFailureDiag(hook_ctx.failure, module_path, record.span, .resolve);
                            return;
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    // non-null이면 플러그인이 resolve 완료 → 기본 resolver 건너뜀
                    if (resolve_result) |plugin_result| {
                        if (should_link) {
                            try self.applyResolveResult(mod_idx, rec_i, record, plugin_result, false);
                        } else {
                            self.markRecordLazyResolved(mod_idx, rec_i);
                            self.discardResolvedModule(plugin_result);
                        }
                        continue;
                    }
                    // null이면 기본 resolver로 fall through
                }
            }

            const resolved = self.resolve_cache.resolve(
                source_dir,
                record.specifier,
                record.kind,
            ) catch |err| switch (err) {
                error.ModuleNotFound => {
                    try self.applyResolveResult(mod_idx, rec_i, record, null, true);
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (should_link) {
                try self.applyResolveResult(mod_idx, rec_i, record, resolved, false);
            } else if (resolved) |resolved_module| {
                self.markRecordLazyResolved(mod_idx, rec_i);
                self.discardResolvedModule(resolved_module);
            }
        }

        // require.context context_expansion_deps 도 resolve + addDep.
        try self.applyContextDepResults(mod_idx);
    }

    /// Phase 2: 반복 DFS 후위 순서 순회. exec_index 부여 + 순환 감지 (D065, D076).
    /// 재귀 대신 명시적 스택 사용 — 깊은 모듈 체인에서도 스택 오버플로 없음.
    fn dfs(self: *ModuleGraph, start_idx: ModuleIndex, visited: *std.DynamicBitSet, in_stack: *std.DynamicBitSet) !void {
        const DfsEntry = struct {
            idx: u32,
            post: bool, // true = 후처리 (exec_index 부여), false = 전처리 (의존성 push)
        };

        var stack: std.ArrayList(DfsEntry) = .empty;
        defer stack.deinit(self.allocator);

        const start = @intFromEnum(start_idx);
        if (start >= self.modules.count()) return;
        if (visited.isSet(start)) return;

        try stack.append(self.allocator, .{ .idx = start, .post = false });

        while (stack.items.len > 0) {
            const entry = stack.pop() orelse break;

            if (entry.post) {
                // 후처리: exec_index 부여 + in_stack 해제
                in_stack.unset(entry.idx);
                visited.set(entry.idx);
                self.modules.at(entry.idx).exec_index = self.exec_counter;
                self.exec_counter += 1;
                continue;
            }

            if (visited.isSet(entry.idx)) continue;

            // 순환 감지 (D065)
            if (in_stack.isSet(entry.idx)) {
                self.cycle_counter += 1;
                const entry_mod = self.modules.at(entry.idx);
                entry_mod.cycle_group = self.cycle_counter;
                // cycle 의 *모든 멤버* 에 같은 cycle_group 부여 (#2198).
                // stack 거꾸로 따라가며 back-edge target (entry.idx) 까지 marking →
                // cycle 안 모듈의 const/let 을 emit 시 var 로 강등 (esbuild 호환,
                // ESM live binding 으로 TDZ 회피). post=true 가 path 상 노드 표식.
                {
                    var k = stack.items.len;
                    while (k > 0) {
                        k -= 1;
                        const e = stack.items[k];
                        if (!e.post) continue;
                        self.modules.at(e.idx).cycle_group = self.cycle_counter;
                        if (e.idx == entry.idx) break;
                    }
                }
                self.addDiag(
                    .circular_dependency,
                    .warning,
                    entry_mod.path,
                    Span.EMPTY,
                    .link,
                    "Circular dependency detected",
                    null,
                );
                continue;
            }

            in_stack.set(entry.idx);

            // 후처리를 먼저 push (LIFO이므로 나중에 실행)
            try stack.append(self.allocator, .{ .idx = entry.idx, .post = true });

            // 의존성을 역순으로 push (원래 순서대로 방문하기 위해).
            // dynamic_imports 는 *exec_index/TLA 전파 분석용 dfs* 에선 따라가지
            // 않는다 (lazy 라 평가 순서/TLA 전파에 무관). cycle marking 은 별도
            // pass `markCyclesViaDynamic` 에서 dynamic edge 도 같이 본다 (#2211).
            const deps = self.modules.at(entry.idx).dependencies.items;
            var j: usize = deps.len;
            while (j > 0) {
                j -= 1;
                const dep = @intFromEnum(deps[j]);
                if (dep < self.modules.count() and !visited.isSet(dep)) {
                    try stack.append(self.allocator, .{ .idx = dep, .post = false });
                }
            }
        }
    }

    /// dynamic edge 도 따라가는 별도 cycle marking pass (#2211).
    /// 기본 dfs 는 `dependencies` 만 follow 해서 exec_index/TLA 전파 분석 정확성을
    /// 유지. 그러나 dynamic target 이 다른 모듈과 *static cycle* 이면 cycle 멤버
    /// marking 이 필요 — `dependencies + dynamic_imports` 양쪽 따라가는 별도 dfs 로
    /// cycle_group 만 부여한다 (exec_index 는 건드리지 않음).
    fn markCyclesViaDynamic(self: *ModuleGraph, entry_indices: []const ModuleIndex) !void {
        const count = self.modules.count();
        if (count == 0) return;

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer visited.deinit();
        var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer in_stack.deinit();

        const DfsEntry = struct { idx: u32, post: bool };
        var stack: std.ArrayList(DfsEntry) = .empty;
        defer stack.deinit(self.allocator);

        for (entry_indices) |entry_idx| {
            const start = @intFromEnum(entry_idx);
            if (start >= count) continue;
            if (visited.isSet(start)) continue;
            try stack.append(self.allocator, .{ .idx = start, .post = false });

            while (stack.items.len > 0) {
                const entry = stack.pop() orelse break;

                if (entry.post) {
                    in_stack.unset(entry.idx);
                    visited.set(entry.idx);
                    continue;
                }

                if (visited.isSet(entry.idx)) continue;

                if (in_stack.isSet(entry.idx)) {
                    // back-edge — cycle 의 모든 stack 멤버에 같은 cycle_group 부여.
                    // 기존 (정적 dfs) 가 부여한 cycle_group 이 있으면 그 위에 덮어쓰지
                    // 않고 새로 dynamic-only cycle 만 카운터 증가.
                    self.cycle_counter += 1;
                    var k = stack.items.len;
                    while (k > 0) {
                        k -= 1;
                        const e = stack.items[k];
                        if (!e.post) continue;
                        if (self.modules.at(e.idx).cycle_group == 0) {
                            self.modules.at(e.idx).cycle_group = self.cycle_counter;
                        }
                        if (e.idx == entry.idx) break;
                    }
                    if (self.modules.at(entry.idx).cycle_group == 0) {
                        self.modules.at(entry.idx).cycle_group = self.cycle_counter;
                    }
                    continue;
                }

                in_stack.set(entry.idx);
                try stack.append(self.allocator, .{ .idx = entry.idx, .post = true });

                const cur_mod = self.modules.at(entry.idx);
                const dep_groups = [_][]const ModuleIndex{ cur_mod.dependencies.items, cur_mod.dynamic_imports.items };
                for (dep_groups) |group| {
                    var j: usize = group.len;
                    while (j > 0) {
                        j -= 1;
                        const dep = @intFromEnum(group[j]);
                        if (dep < count and !visited.isSet(dep)) {
                            try stack.append(self.allocator, .{ .idx = dep, .post = false });
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    // Final graph promotion/wrapping passes — graph/finalize.zig로 위임
    // ============================================================
    const graph_finalize = @import("graph/finalize.zig");
    const promoteExportsKinds = graph_finalize.promoteExportsKinds;
    const promoteRunBeforeMainModules = graph_finalize.promoteRunBeforeMainModules;
    const registerWrapperSymbols = graph_finalize.registerWrapperSymbols;
    const propagateTopLevelAwait = graph_finalize.propagateTopLevelAwait;

    /// 모듈 경로에서 가장 가까운 package.json의 "type" 필드가 "module"인지 확인.
    /// `lookupPkgInfo` 로 캐시 경유 — 같은 pkg 의 side_effects 조회와 pkg.json parse 공유.
    fn isPackageTypeModule(self: *ModuleGraph, module_path: []const u8) bool {
        var scope = profile.begin(.graph_discover_pm_is_pkg_type);
        defer scope.end();
        const pkg_dir_path = findPackageDirPath(module_path) orelse return false;
        return self.lookupPkgInfo(pkg_dir_path).is_module;
    }

    // Loader/source helpers — graph/loaders.zig로 위임
    const graph_loaders = @import("graph/loaders.zig");
    const parseCssModule = graph_loaders.parseCssModule;
    const parseAssetModule = graph_loaders.parseAssetModule;
    const readModuleSourceWithMtime = graph_loaders.readModuleSourceWithMtime;

    // Diagnostics helpers — graph/diagnostics.zig로 위임
    const graph_diagnostics = @import("graph/diagnostics.zig");
    pub const addDiag = graph_diagnostics.addDiag;
    const addPluginFailureDiag = graph_diagnostics.addPluginFailureDiag;
    const validatePluginSourceMaps = graph_diagnostics.validatePluginSourceMaps;
};

/// require.context(...) 레코드의 매칭 파일 목록을 host plugin (resolveContext) 으로 채운다.
/// (#1579 Phase 2). ZNTC 자체 regex executor 가 없어서 host runtime 의 RegExp 위임 (#1771).
///
/// 처리 순서:
///   1. invalid record (`context_invalid_reason != null`) → require_context_invalid error.
///   2. plugin runner 호출 (first non-null wins) → 결과를 record.context_matches 에 저장.
///   3. plugin 미구현 → require_context_no_handler warning (record.context_matches 는 null 유지).
///
/// `self`: ModuleGraph (addDiag, plugins 접근용)
/// `module_path`: 현재 모듈 경로 (importer)
/// `records`: 모듈의 import_records (in-place 수정)
fn expandRequireContextRecords(self: *ModuleGraph, mod_idx: usize) void {
    const module = self.modules.at(mod_idx);

    // scanWorker + resolveModuleImports 양쪽에서 호출됨. 이미 expand 됐으면 즉시 리턴
    // (has_any 루프보다 먼저 체크 — 재진입 시 records 전체 순회 회피).
    if (module.context_expansion_deps.len > 0) return;

    const records = module.import_records;
    var has_any = false;
    for (records) |r| {
        if (r.kind == .require_context) {
            has_any = true;
            break;
        }
    }
    if (!has_any) return;

    const module_path = module.path;
    const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

    // require.context 는 parse 산출물이라 arena 가 항상 존재. 없으면 (disabled/asset 등)
    // expand 자체가 의미 없고, graph allocator fallback 은 module.deinit 에서 free 누락 →
    // leak. 안전하게 early return.
    const arena = if (module.parse_arena) |a| a else return;
    const arena_alloc = arena.allocator();
    var expansion = std.ArrayList(types.ImportRecord).empty;

    for (records) |*record| {
        if (record.kind != .require_context) continue;
        if (record.context_matches != null) continue;

        // Invalid 인자 → diagnostic (Phase 1 의 reason 텍스트 그대로 사용). empty slice 로 마킹.
        if (record.context_invalid_reason) |reason| {
            self.addDiag(.require_context_invalid, .@"error", module_path, record.span, .resolve, reason, null);
            record.context_matches = &.{};
            continue;
        }

        // Plugin 호출
        if (plugin_runner) |runner| {
            var hook_ctx: plugin_mod.HookContext = .{};
            defer hook_ctx.deinit();
            const matches = runner.runResolveContext(
                record.specifier,
                record.context_recursive,
                record.context_filter,
                record.context_filter_flags,
                module_path,
                self.allocator,
                &hook_ctx,
            ) catch null;
            if (matches) |m| {
                record.context_matches = m;
                // 매치별 abs path resolve 결과를 record.context_resolved_paths 에 1:1 저장.
                // codegen 이 webpackContext IIFE 의 module wrapper 호출 (`__zntc_modules[<abs>]`) 에 사용.
                // null 슬롯 = resolve 실패 — codegen 이 throw stub 으로 emit.
                const source_dir = std.fs.path.dirname(module_path) orelse ".";
                const resolved_paths_opt: ?[]?[]const u8 = arena_alloc.alloc(?[]const u8, m.len) catch null;
                for (m, 0..) |match_path, i| {
                    const joined = joinContextPath(arena_alloc, record.specifier, match_path) orelse {
                        if (resolved_paths_opt) |paths| paths[i] = null;
                        continue;
                    };
                    if (resolved_paths_opt) |paths| {
                        // default null — file variant 만 dupe 성공 시 덮어씀.
                        paths[i] = null;
                        if (self.resolve_cache.resolveThreadSafe(source_dir, joined, .require) catch null) |res| switch (res) {
                            // resolve_cache 가 self.allocator 로 path 할당 → arena 로 dupe 후 free.
                            .file => |f| {
                                paths[i] = arena_alloc.dupe(u8, f.path) catch null;
                                self.allocator.free(f.path);
                            },
                            .disabled => |d| self.allocator.free(d.path),
                            .virtual, .dataurl, .external, .custom => {},
                        };
                    }
                    // graph dep 등록은 applyContextDepResults 에서 (cache hit 라 빠름).
                    expansion.append(arena_alloc, .{
                        .specifier = joined,
                        .kind = .require,
                        .span = record.span,
                    }) catch {};
                }
                if (resolved_paths_opt) |paths| record.context_resolved_paths = paths;
                continue;
            }
        }

        // Plugin 미구현 → warning. empty slice 로 마킹 (Phase 3 codegen 이 빈 stub 으로 emit).
        self.addDiag(
            .require_context_no_handler,
            .warning,
            module_path,
            record.span,
            .resolve,
            "require.context requires a host plugin to match files (ZNTC regex executor not yet implemented — see #1771)",
            null,
        );
        record.context_matches = &.{};
    }

    module.context_expansion_deps = expansion.toOwnedSlice(arena_alloc) catch &.{};
}

/// record.specifier (e.g. "./app" 또는 "../foo") 와 match_path (e.g. "./a.tsx") 를 결합.
/// codegen 의 emitJoinedPath 와 동일 로직 — dir trailing `/`, match `./` prefix 정규화.
/// 결과는 모듈 resolver 가 일반 require 처럼 처리할 수 있는 specifier.
fn joinContextPath(alloc: std.mem.Allocator, dir: []const u8, match: []const u8) ?[]u8 {
    const dir_clean = if (dir.len > 0 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
    const match_clean = if (match.len >= 2 and match[0] == '.' and match[1] == '/') match[2..] else match;
    const out = alloc.alloc(u8, dir_clean.len + 1 + match_clean.len) catch return null;
    @memcpy(out[0..dir_clean.len], dir_clean);
    out[dir_clean.len] = '/';
    @memcpy(out[dir_clean.len + 1 ..], match_clean);
    return out;
}

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
