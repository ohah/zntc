//! ZTS Bundler — Module Graph
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
const wyhash = @import("../util/wyhash.zig");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const ImportKind = types.ImportKind;
const ImportRecord = types.ImportRecord;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("module.zig").Module;
const runtime_helpers = @import("runtime_helpers.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const ResolveCache = resolve_cache_mod.ResolveCache;
const resolver_mod = @import("resolver.zig");
const import_scanner = @import("import_scanner.zig");
const binding_scanner_mod = @import("binding_scanner.zig");
const json_to_esm = @import("json_to_esm.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const profile = @import("../profile.zig");
const semantic_symbol = @import("../semantic/symbol.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const stmt_info_mod = @import("stmt_info.zig");
const Span = @import("../lexer/token.zig").Span;
const pkg_json = @import("package_json.zig");
const mime = @import("../server/mime.zig");
const plugin_mod = @import("plugin.zig");
const MpscChannel = @import("mpsc_channel.zig").MpscChannel;
pub const module_store = @import("module_store.zig");
const phase_mod = @import("phase.zig");
pub const ModulePhase = phase_mod.ModulePhase;
pub const ParseAccessor = phase_mod.ParseAccessor;
pub const ResolveAccessor = phase_mod.ResolveAccessor;
pub const LinkAccessor = phase_mod.LinkAccessor;

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(Module),
    path_to_module: std.StringHashMap(ModuleIndex),
    diagnostics: std.ArrayList(BundlerDiagnostic),
    resolve_cache: *ResolveCache,
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
    /// build-time 정적 평가 entries. parser inline scan (require.context 등 #1579 Phase 2.6) 활용.
    /// bundler 가 BundleOptions.define 으로 설정. transformer 의 define 치환과 동일 entries.
    defines: []const @import("../parser/scan_results.zig").DefineEntry = &.{},
    /// #1621: binary loader 가 생성하는 `__toBinary(...)` 소스에서 축약 이름 사용.
    /// bundler 에서 self.options.minify_whitespace 를 주입.
    minify_whitespace: bool = false,
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

    pub const PkgInfo = struct {
        is_module: bool,
        side_effects: pkg_json.PackageJson.SideEffects,
    };

    pub const WorkerEntry = struct {
        /// resolve된 worker 파일 절대 경로
        resolved_path: []const u8,
        /// worker를 참조하는 모듈 인덱스
        source_module: ModuleIndex,
        /// 해당 모듈의 import_records 내 인덱스
        record_index: u32,
    };

    pub fn init(allocator: std.mem.Allocator, resolve_cache: *ResolveCache) ModuleGraph {
        return .{
            .allocator = allocator,
            .modules = .empty,
            .path_to_module = std.StringHashMap(ModuleIndex).init(allocator),
            .diagnostics = .empty,
            .resolve_cache = resolve_cache,
        };
    }

    pub fn deinit(self: *ModuleGraph) void {
        for (self.modules.items) |*m| {
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
        var pi_it = self.pkg_info_cache.valueIterator();
        while (pi_it.next()) |info| info.side_effects.deinit(self.allocator);
        self.pkg_info_cache.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        for (self.worker_entries.items) |we| {
            self.allocator.free(we.resolved_path);
        }
        self.worker_entries.deinit(self.allocator);
        if (self.jsx_specifier_cache) |s| self.allocator.free(s);
    }

    // ============================================================
    // Module accessor API (#1779 PR #1a)
    //
    // 외부 코드는 `self.modules.items[idx]` 직접 접근 대신 아래 메서드 사용.
    // worker race-safety 와 향후 SegmentedList storage 교체 (#1779 PR #3) 를
    // 위해 storage 접근을 단일 진입점으로 모은다.
    //
    // - read 는 누구나: `getModule(idx)` → `?*const Module`
    // - mutate 는 phase-tagged accessor 경유: `parseAccessor()` / `resolveAccessor()` /
    //   `linkAccessor()` (정의는 phase.zig)
    // - `moduleAtMut` 는 accessor 내부 전용. 다른 호출자는 phase accessor 를 쓸 것.
    // ============================================================

    /// idx 검증 → modules slice 의 in-range index 반환. read/mut 양쪽 진입점에서 공유.
    inline fn validModuleSlot(self: *const ModuleGraph, idx: ModuleIndex) ?usize {
        if (idx.isNone()) return null;
        const i = idx.toUsize();
        if (i >= self.modules.items.len) return null;
        return i;
    }

    /// idx 에 해당하는 module 의 read-only 포인터. 범위 밖이면 null.
    pub inline fn getModule(self: *const ModuleGraph, idx: ModuleIndex) ?*const Module {
        const i = self.validModuleSlot(idx) orelse return null;
        return &self.modules.items[i];
    }

    /// 등록된 module 개수. `self.modules.items.len` 의 캡슐화 진입점.
    pub inline fn moduleCount(self: *const ModuleGraph) usize {
        return self.modules.items.len;
    }

    /// **Accessor 전용**. 직접 호출 금지 — `parseAccessor()` 등 phase accessor 의
    /// setter 메서드를 사용하라. 외부 mutable pointer 노출은 worker race 의 root.
    /// SegmentedList 교체 (#1779 PR #3) 시 내부 구현만 변경된다.
    pub inline fn moduleAtMut(self: *ModuleGraph, idx: ModuleIndex) ?*Module {
        const i = self.validModuleSlot(idx) orelse return null;
        return &self.modules.items[i];
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

    /// 모든 module 을 순회하는 read-only iterator. `for (graph.modules.items) |m|`
    /// 의 캡슐화 진입점. SegmentedList 교체 (#1779 PR #3) 시 chunk 경계를 처리.
    pub inline fn modulesIterator(self: *const ModuleGraph) ModulesIterator {
        return .{ .graph = self, .index = 0 };
    }

    pub const ModulesIterator = struct {
        graph: *const ModuleGraph,
        index: usize,

        pub fn next(self: *ModulesIterator) ?*const Module {
            if (self.index >= self.graph.modules.items.len) return null;
            const m = &self.graph.modules.items[self.index];
            self.index += 1;
            return m;
        }
    };

    /// 확장자에 대한 로더를 결정한다.
    /// --loader 오버라이드가 있으면 우선 사용, 없으면 확장자 기본값.
    fn resolveLoader(self: *const ModuleGraph, ext: []const u8) types.Loader {
        for (self.loader_overrides) |override| {
            if (std.mem.eql(u8, override.ext, ext)) return override.loader;
        }
        return types.Loader.fromExtension(ext);
    }

    /// 진입점들로부터 모듈 그래프를 구축한다.
    /// Phase 1: 모든 모듈 등록 + 파싱 + import resolve (BFS)
    /// Phase 2: DFS로 exec_index + 순환 감지
    pub fn build(self: *ModuleGraph, entry_points: []const []const u8) !void {
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
            try inject_indices.append(self.allocator, idx);
        }

        // Phase 1: 이벤트 큐 기반 스캔 (esbuild 스타일).
        // 워커: parseModule + resolve → 채널 send (그래프 변형 없음)
        // 메인: 채널 recv → 결과 적용 + addModule → 즉시 새 워커 스폰
        // 배치 경계 없이 모듈 발견 즉시 파싱 시작 → CPU 유휴 시간 최소화.
        var discover_scope = profile.begin(.graph_discover);
        for (entry_points) |entry_path| {
            _ = try self.addModule(entry_path);
        }

        var pool: std.Thread.Pool = undefined;
        const pool_opts: std.Thread.Pool.Options = if (self.max_threads > 0)
            .{ .allocator = self.allocator, .n_jobs = self.max_threads }
        else
            .{ .allocator = self.allocator };
        const pool_ok = if (pool.init(pool_opts)) |_| true else |_| false;
        defer if (pool_ok) pool.deinit();

        if (pool_ok) {
            var channel = MpscChannel(ScanResult).init(self.allocator);
            defer channel.deinit();

            var inflight: usize = 0;
            var spawned_up_to: usize = 0;

            // 초기 모듈(엔트리 + inject) 스폰
            while (spawned_up_to < self.modules.items.len) : (spawned_up_to += 1) {
                const m = &self.modules.items[spawned_up_to];
                if (m.state == .ready) continue; // disabled 모듈은 스킵
                const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                pool.spawn(scanWorker, .{ self, idx, &channel }) catch {
                    // 스레드 풀 스폰 실패 시 메인에서 직접 실행
                    scanWorker(self, idx, &channel);
                };
                inflight += 1;
            }

            // 이벤트 루프: 워커 결과 수신 → 적용 → 새 모듈 즉시 스폰
            while (inflight > 0) {
                const result = channel.recv();
                inflight -= 1;

                var apply_scope = profile.begin(.graph_discover_apply);
                defer apply_scope.end();

                const mod_idx = @intFromEnum(result.module_idx);
                self.applySideEffectsFromPackageJson(&self.modules.items[mod_idx]);
                self.modules.items[mod_idx].state = .ready;

                const records = self.modules.items[mod_idx].import_records;
                const resolves = result.resolve_outputs;

                // 포인터 안전: applyResolveResult → addModule → realloc 가능.
                // 워커가 실행 중이면 realloc은 댕글링 포인터를 만듦.
                // → capacity가 부족하면 inflight 워커를 전부 drain한 후 재할당.
                const needed = self.modules.items.len + records.len;
                if (needed > self.modules.capacity and inflight > 0) {
                    // 결과를 버퍼에 모아두고 drain 후 일괄 적용
                    var pending = std.ArrayListUnmanaged(ScanResult).initBuffer(
                        self.allocator.alloc(ScanResult, inflight) catch &.{},
                    );
                    defer if (pending.capacity > 0) self.allocator.free(pending.allocatedSlice());
                    while (inflight > 0) {
                        pending.appendAssumeCapacity(channel.recv());
                        inflight -= 1;
                    }
                    // 워커가 모두 종료됨 → 안전하게 realloc
                    try self.modules.ensureTotalCapacity(self.allocator, needed * 2);

                    // 버퍼에 모아둔 결과 적용
                    for (pending.items) |pending_result| {
                        const p_idx = @intFromEnum(pending_result.module_idx);
                        self.applySideEffectsFromPackageJson(&self.modules.items[p_idx]);
                        self.modules.items[p_idx].state = .ready;
                        const p_records = self.modules.items[p_idx].import_records;
                        const p_resolves = pending_result.resolve_outputs;
                        for (p_records, 0..) |rec, ri| {
                            if (ri < p_resolves.len) {
                                try self.applyResolveResult(p_idx, ri, rec, p_resolves[ri].resolved, p_resolves[ri].is_error);
                            }
                        }
                        if (p_resolves.len > 0) self.allocator.free(p_resolves);
                    }
                }

                // resolve 결과 적용 (capacity 충분 보장됨)
                for (records, 0..) |record, rec_i| {
                    if (rec_i < resolves.len) {
                        try self.applyResolveResult(mod_idx, rec_i, record, resolves[rec_i].resolved, resolves[rec_i].is_error);
                    }
                }
                if (resolves.len > 0) self.allocator.free(resolves);

                // 새로 발견된 모듈 즉시 워커에 디스패치
                while (spawned_up_to < self.modules.items.len) : (spawned_up_to += 1) {
                    const m = &self.modules.items[spawned_up_to];
                    if (m.state == .ready) continue;
                    const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                    pool.spawn(scanWorker, .{ self, idx, &channel }) catch {
                        scanWorker(self, idx, &channel);
                    };
                    inflight += 1;
                }
            }
        } else {
            // 순차 폴백 (스레드 풀 없음)
            var parse_start: usize = 0;
            while (parse_start < self.modules.items.len) {
                const parse_end = self.modules.items.len;
                for (parse_start..parse_end) |j| {
                    self.parseModule(@enumFromInt(@as(u32, @intCast(j))));
                }
                for (parse_start..parse_end) |i| {
                    self.applySideEffectsFromPackageJson(&self.modules.items[i]);
                    self.modules.items[i].state = .ready;
                }
                for (parse_start..parse_end) |i| {
                    try self.resolveModuleImports(@enumFromInt(@as(u32, @intCast(i))));
                }
                parse_start = parse_end;
            }
        }

        // --inject: inject 파일을 각 엔트리 모듈의 의존성으로 추가.
        // DFS에서 inject 모듈이 먼저 방문되어 exec_index가 낮아지고, 번들 상단에 출력.
        if (inject_indices.items.len > 0) {
            for (entry_points) |entry_path| {
                if (self.path_to_module.get(entry_path)) |entry_idx| {
                    const ei = @intFromEnum(entry_idx);
                    if (ei < self.modules.items.len) {
                        for (inject_indices.items) |inject_idx| {
                            try self.modules.items[ei].addDependency(self.allocator, inject_idx, self.modules.items);
                        }
                    }
                }
            }
        }
        discover_scope.end();

        try self.finalizeGraph(entry_points);
    }

    /// Phase 2-4: DFS exec_index + ExportsKind 승격 + TLA 전파.
    /// build()와 buildIncremental() 양쪽에서 호출.
    fn finalizeGraph(self: *ModuleGraph, entry_points: []const []const u8) !void {
        var scope = profile.begin(.graph_finalize);
        defer scope.end();

        const count = self.modules.items.len;
        if (count == 0) return;

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer visited.deinit();
        var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer in_stack.deinit();

        for (entry_points) |entry_path| {
            if (self.path_to_module.get(entry_path)) |idx| {
                const ei = @intFromEnum(idx);
                if (ei < self.modules.items.len) {
                    self.modules.items[ei].is_entry_point = true;
                }
                try self.dfs(idx, &visited, &in_stack);
            }
        }

        self.promoteExportsKinds();
        self.registerWrapperSymbols();
        self.propagateTopLevelAwait();
        self.checkSelfReExport();
    }

    /// Self-cycle named re-export 진단. alias/onResolve가 source를 자기 자신으로
    /// redirect하면 emit이 `exports_self.X` 자기 참조 getter를 생성해 평가 시 무한
    /// 재귀. rolldown CIRCULAR_REEXPORT처럼 빌드 단계에서 거부. default re-export는
    /// 별도 경로에서 이미 안전 처리되므로 제외.
    fn checkSelfReExport(self: *ModuleGraph) void {
        for (self.modules.items, 0..) |*m, i| {
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
            try inject_indices.append(self.allocator, idx);
        }

        for (entry_points) |entry_path| {
            _ = try self.addModule(entry_path);
        }

        var reparsed: std.ArrayListUnmanaged(types.ModuleIndex) = .empty;
        var graph_changed = false;

        var discover_scope = profile.begin(.graph_discover);

        // 순차 처리 — 증분 빌드는 캐시 히트가 대부분이므로 스레드 풀 오버헤드보다 효율적.
        var parse_start: usize = 0;
        while (parse_start < self.modules.items.len) {
            const parse_end = self.modules.items.len;
            for (parse_start..parse_end) |i| {
                var mod = &self.modules.items[i];
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
                    mod.* = cached.module;
                    mod.index = saved_index;
                    mod.path = saved_path;
                    mod.dependencies = saved_deps;
                    mod.importers = saved_importers;
                    mod.dynamic_imports = saved_dynamic;
                    mod.mtime = mtime;
                    // parse_arena 소유권 이전: store → graph.
                    cached.module.parse_arena = null;
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
                    self.applySideEffectsFromPackageJson(&self.modules.items[i]);
                    self.modules.items[i].mtime = mtime;
                    self.modules.items[i].state = .ready;
                    try reparsed.append(self.allocator, @enumFromInt(@as(u32, @intCast(i))));
                }
            }

            // resolve + addModule (새 의존성 등록)
            for (parse_start..parse_end) |i| {
                try self.resolveModuleImports(@enumFromInt(@as(u32, @intCast(i))));
            }

            // 새 모듈이 추가되었으면 그래프 변경
            if (self.modules.items.len > parse_end) {
                graph_changed = true;
            }
            parse_start = parse_end;
        }

        // --inject: inject 파일을 각 엔트리 모듈의 의존성으로 추가
        if (inject_indices.items.len > 0) {
            for (entry_points) |entry_path| {
                if (self.path_to_module.get(entry_path)) |entry_idx| {
                    const ei = @intFromEnum(entry_idx);
                    if (ei < self.modules.items.len) {
                        for (inject_indices.items) |inject_idx| {
                            try self.modules.items[ei].addDependency(self.allocator, inject_idx, self.modules.items);
                        }
                    }
                }
            }
        }

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
        const stat = try std.fs.cwd().statFile(path);
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
        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.items.len)));
        const path_owned = try self.allocator.dupe(u8, abs_path);

        var module = Module.init(index, path_owned);
        const ext = std.fs.path.extension(abs_path);
        module.module_type = ModuleType.fromExtension(ext);
        // 로더 결정: --loader 오버라이드 → 확장자 기본값
        module.loader = self.resolveLoader(ext);
        // asset 로더가 설정되면 module_type도 .asset으로 업데이트
        if (module.loader.isAsset()) {
            module.module_type = .asset;
        }
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

        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.items.len)));
        var module = Module.init(index, disabled_path);
        module.module_type = .javascript;
        module.exports_kind = .commonjs;
        module.wrap_kind = .cjs;
        module.is_disabled = true;
        module.side_effects = false;
        module.state = .ready;
        try self.modules.append(self.allocator, module);
        try self.path_to_module.put(disabled_path, index);

        return index;
    }

    /// resolve 결과를 모듈 그래프에 적용한다 (addModule, addDependency 등).
    /// resolveModuleImports와 resolveModuleImportsBatchParallel 공통.
    fn applyResolveResult(
        self: *ModuleGraph,
        mod_idx: usize,
        rec_i: usize,
        record: types.ImportRecord,
        resolved: ?resolver_mod.ResolveResult,
        is_error: bool,
    ) !void {
        if (is_error) {
            // Worker resolve 실패 → 경고만 (메인 빌드 중단하지 않음)
            if (record.kind == .worker) {
                self.addDiag(.unresolved_import, .warning, self.modules.items[mod_idx].path, record.span, .resolve, "Cannot resolve worker module", record.specifier);
                return;
            }
            // ModuleNotFound — browser에서 Node 빌트인은 빈 CJS로 대체
            if (self.resolve_cache.platform.isBrowserLike() and resolve_cache_mod.isNodeBuiltin(record.specifier)) {
                const dep_idx = try self.addDisabledModule(record.specifier);
                self.modules.items[mod_idx].import_records[rec_i].resolved = dep_idx;
                if (record.kind == .dynamic_import) {
                    try self.modules.items[mod_idx].addDynamicImport(self.allocator, dep_idx);
                } else {
                    try self.modules.items[mod_idx].addDependency(self.allocator, dep_idx, self.modules.items);
                }
            } else {
                const sev: types.BundlerDiagnostic.Severity = if (record.kind == .dynamic_import) .warning else .@"error";
                self.addDiag(.unresolved_import, sev, self.modules.items[mod_idx].path, record.span, .resolve, "Cannot resolve module", record.specifier);
            }
            return;
        }

        if (resolved) |r| {
            defer self.allocator.free(r.path);

            // Worker: 메인 그래프에 모듈로 추가하지 않고 경로만 수집
            if (record.kind == .worker) {
                const path_dupe = try self.allocator.dupe(u8, r.path);
                try self.worker_entries.append(self.allocator, .{
                    .resolved_path = path_dupe,
                    .source_module = @enumFromInt(mod_idx),
                    .record_index = @intCast(rec_i),
                });
                return;
            }

            if (r.disabled) {
                const dep_idx = try self.addDisabledModule(record.specifier);
                self.modules.items[mod_idx].import_records[rec_i].resolved = dep_idx;
                if (record.kind == .dynamic_import) {
                    try self.modules.items[mod_idx].addDynamicImport(self.allocator, dep_idx);
                } else {
                    try self.modules.items[mod_idx].addDependency(self.allocator, dep_idx, self.modules.items);
                }
                return;
            }

            const dep_idx = try self.addModule(r.path);

            if (r.is_module_field or self.modules.items[mod_idx].is_module_field) {
                self.modules.items[@intFromEnum(dep_idx)].is_module_field = true;
            }

            self.modules.items[mod_idx].import_records[rec_i].resolved = dep_idx;

            if (record.kind == .dynamic_import) {
                try self.modules.items[mod_idx].addDynamicImport(self.allocator, dep_idx);
            } else {
                try self.modules.items[mod_idx].addDependency(self.allocator, dep_idx, self.modules.items);
            }
        } else {
            self.modules.items[mod_idx].import_records[rec_i].is_external = true;
        }
    }

    /// resolve 결과를 저장하는 구조체. scanWorker가 기록, 메인 스레드가 적용.
    const ResolveOutput = struct {
        resolved: ?resolver_mod.ResolveResult = null,
        is_error: bool = false,
    };

    /// 이벤트 큐 기반 스캔 결과. 워커가 채널로 전송, 메인이 수신.
    const ScanResult = struct {
        module_idx: ModuleIndex,
        resolve_outputs: []ResolveOutput,
    };

    /// 이벤트 큐 스캔 워커: parse + resolve 후 결과를 채널로 전송.
    /// 그래프 변형(addModule 등)은 하지 않으므로 메인 스레드의 sole writer 보장.
    fn scanWorker(self: *ModuleGraph, idx: ModuleIndex, channel: *MpscChannel(ScanResult)) void {
        var scope = profile.begin(.graph_discover_scan_worker);
        defer scope.end();

        self.parseModule(idx);

        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.items.len) {
            channel.send(.{ .module_idx = idx, .resolve_outputs = &.{} });
            return;
        }

        const records = self.modules.items[mod_idx].import_records;
        if (records.len == 0) {
            channel.send(.{ .module_idx = idx, .resolve_outputs = &.{} });
            return;
        }

        var results = self.allocator.alloc(ResolveOutput, records.len) catch {
            self.addDiag(.resolve_error, .@"error", self.modules.items[mod_idx].path, Span.EMPTY, .resolve, "Out of memory allocating resolve results", null);
            channel.send(.{ .module_idx = idx, .resolve_outputs = &.{} });
            return;
        };
        for (results) |*r| r.* = .{};

        const module_path = self.modules.items[mod_idx].path;
        const source_dir = std.fs.path.dirname(module_path) orelse ".";

        const plugin_runner: ?plugin_mod.PluginRunner = if (self.plugins.len > 0)
            plugin_mod.PluginRunner.init(self.plugins)
        else
            null;

        // import.meta.glob: 워커에서 glob 확장 수행
        expandGlobRecords(self.allocator, self.modules.items[mod_idx].import_records, source_dir);
        // require.context: host plugin 으로 매칭 결과 주입 (#1579 Phase 2)
        expandRequireContextRecords(self, module_path, self.modules.items[mod_idx].import_records);

        for (records, 0..) |record, rec_i| {
            if (record.kind == .glob) continue;
            if (record.kind == .require_context) continue;

            if (plugin_runner) |runner| {
                const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator) catch |err| switch (err) {
                    error.PluginFailed => null,
                    error.OutOfMemory => {
                        self.addDiag(.resolve_error, .@"error", module_path, record.span, .resolve, "Out of memory during resolve", record.specifier);
                        continue;
                    },
                };
                if (resolve_result) |plugin_result| {
                    results[rec_i] = .{ .resolved = plugin_result, .is_error = false };
                    continue;
                }
            }

            const resolved = self.resolve_cache.resolveThreadSafe(
                source_dir,
                record.specifier,
                record.kind,
            ) catch |err| switch (err) {
                error.ModuleNotFound => {
                    results[rec_i] = .{ .is_error = true };
                    continue;
                },
                error.OutOfMemory => {
                    self.addDiag(.resolve_error, .@"error", module_path, record.span, .resolve, "Out of memory during resolve", record.specifier);
                    continue;
                },
            };
            results[rec_i] = .{ .resolved = resolved };
        }

        channel.send(.{ .module_idx = idx, .resolve_outputs = results });
    }

    /// 단일 모듈을 파싱하고 import를 추출한다.
    /// 모듈별 Arena로 Scanner/Parser/AST를 할당하여 emitter까지 보존.
    /// import_records는 graph allocator로 별도 할당 (specifier가 source를 참조).
    fn parseModule(self: *ModuleGraph, idx: ModuleIndex) void {
        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.items.len) return;

        var module = &self.modules.items[mod_idx];
        module.state = .parsing;
        // compiled_cache key 는 mtime 을 요구한다. first build 경로는 여기서 처음 계산,
        // rebuild 경로는 cache lookup 시 이미 설정됐으므로 fsStat 재호출 없이 통과.
        if (module.mtime == 0) module.mtime = getMtime(module.path) catch 0;

        // Plugin runner: parseModule 내에서 load + transform 훅에 공용
        const plugin_runner: ?plugin_mod.PluginRunner = if (self.plugins.len > 0)
            plugin_mod.PluginRunner.init(self.plugins)
        else
            null;

        // Plugin: load 훅 — 모든 module_type 분기 전에 플러그인에게 기회를 줌.
        // 플러그인이 내용을 반환하면 JS 모듈로 전환 (예: .css → JS export).
        if (plugin_runner) |runner| {
            // 임시 allocator로 load 결과만 확인 (성공 시 arena를 생성)
            var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
            const load_result = runner.runLoad(module.path, tmp_arena.allocator()) catch |err| switch (err) {
                error.PluginFailed => null,
                error.OutOfMemory => {
                    tmp_arena.deinit();
                    module.state = .ready;
                    return;
                },
            };
            if (load_result) |plugin_source| {
                // 플러그인이 내용을 반환 → JS 모듈로 전환하여 아래 파싱 경로를 탐
                module.module_type = .javascript;
                module.loader = .javascript;
                module.parse_arena = tmp_arena;
                module.source = plugin_source;
                // module_type 분기를 건너뛰고 JS 파싱 경로로 직접 이동
                // (아래 "모듈별 Arena" 블록은 parse_arena가 이미 설정되어 있으므로 건너뜀)
            } else {
                tmp_arena.deinit();
            }
        }

        // JSON 모듈: ESM AST로 변환 → 일반 JS와 동일한 파이프라인
        // `export default <json_value>;` 형태의 AST를 생성하여
        // semantic → import_scanner → binding_scanner를 공유한다.
        if (module.module_type == .json) {
            module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
            const arena_alloc = module.parse_arena.?.allocator();
            module.source = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 10 * 1024 * 1024) catch "";

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
                };
                if (analyzer.stmt_info_count > 0) {
                    module.prebuilt_stmt_info = stmt_info_mod.buildFromSemantic(
                        arena_alloc,
                        &(module.ast.?),
                        analyzer.symbols.items,
                        analyzer.references.items,
                        if (module.semantic) |*s| &s.unresolved_references else null,
                    ) catch null;
                }
            } else |_| {}

            // import/export 스캔 — JSON에는 import가 없지만 export default가 있음
            const scan_result = import_scanner.extractImportsWithCjsDetection(arena_alloc, &(module.ast.?)) catch {
                module.state = .ready;
                return;
            };
            module.import_records = scan_result.records;
            module.import_bindings = binding_scanner_mod.extractImportBindings(arena_alloc, &(module.ast.?), scan_result.records) catch &.{};
            binding_scanner_mod.collectNamespaceAccesses(arena_alloc, &(module.ast.?), module.import_bindings) catch {};
            module.export_bindings = binding_scanner_mod.extractExportBindings(arena_alloc, &(module.ast.?), scan_result.records, module.import_bindings) catch &.{};

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

        if (module.module_type != .javascript) {
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
            module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        }
        const arena_alloc = module.parse_arena.?.allocator();

        // 파일 시스템에서 읽기 (플러그인이 source를 이미 설정한 경우 건너뜀)
        if (module.source.len == 0) {
            const source = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
                self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .resolve, "Cannot read file", null);
                module.state = .ready;
                return;
            };
            module.source = source;
        }

        // Plugin: transform 훅 — 소스 읽기 후, 파싱 전에 호출 (Rolldown 호환).
        // 플러그인이 코드를 변환하면 변환된 소스로 파싱한다.
        // Babel 플러그인(예: react-native-reanimated/plugin)이 유저 코드를 변환할 수 있다.
        if (plugin_runner) |runner| {
            const transform_result = runner.runTransform(module.source, module.path, arena_alloc) catch |err| switch (err) {
                error.PluginFailed => null,
                error.OutOfMemory => {
                    module.state = .ready;
                    return;
                },
            };
            if (transform_result) |result| {
                module.source = result;
            }
        }

        // Scanner + Parser (arena 할당)
        var scanner = Scanner.init(arena_alloc, module.source) catch {
            self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Scanner initialization failed", null);
            module.state = .ready;
            return;
        };

        var parser = Parser.init(arena_alloc, &scanner);
        const ext = std.fs.path.extension(module.path);
        parser.configureForBundler(ext);

        // Flow 모드: --flow CLI 또는 .js.flow/.jsx.flow 확장자 (pragma는 parse() 내부에서 감지)
        // is_ts와 is_flow는 상호 배타 — TS 파일에서는 Flow 무시
        if (!parser.is_ts) {
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
        if (self.jsx_in_js and !parser.is_ts) {
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
        setup_scope.end();
        _ = parser.parse() catch {
            self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Parse failed", null);
            module.state = .ready;
            return;
        };

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
        var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = parser.is_ts;
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
                ) catch null;
            }
        }

        var post_scope = profile.begin(.graph_discover_pm_post);
        defer post_scope.end();

        module.ast = parser.ast;
        module.line_offsets = scanner.line_offsets.items;

        // import/export 추출: inline scan 결과를 bundler 타입으로 변환
        {
            // Parser scan records → bundler ImportRecord
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
            } else |_| {}

            // Worker 패턴 보완: new Worker(new URL(...)) 는 inline scan에서 감지하지 않으므로
            // 별도의 AST walk로 worker records를 추출하여 병합한다.
            const worker_records = import_scanner.extractWorkerRecords(arena_alloc, &parser.ast) catch &[_]ImportRecord{};
            if (worker_records.len > 0) {
                if (arena_alloc.alloc(ImportRecord, records.len + worker_records.len)) |merged| {
                    @memcpy(merged[0..records.len], records);
                    @memcpy(merged[records.len..], worker_records);
                    module.import_records = merged;
                } else |_| {}
            }

            // namespace access 수집은 별도 AST walk 필요
            binding_scanner_mod.collectNamespaceAccesses(arena_alloc, &parser.ast, module.import_bindings) catch {};

            // Phase 1-3b (#1328): 합성 심볼 테이블 초기화 + re_export_alias 등록
            // + semantic 공간에 synthetic_default 등록.
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

            // CJS/ESM 감지 — inline scan 결과로 ScanResult 생성
            const scan_result = import_scanner.ScanResult{
                .records = module.import_records,
                .has_esm_syntax = parser.scan_result.has_esm_syntax or parser.has_module_syntax,
                .has_cjs_require = parser.scan_result.has_cjs_require,
                .has_module_exports = parser.scan_result.has_module_exports,
                .has_exports_dot = parser.scan_result.has_exports_dot,
            };

            // JSX automatic: AST에 JSX가 있으면 synthetic import를 추가한다.
            var jsx_injected = false;
            if (self.jsx_runtime != .classic) {
                if (parser.ast.has_jsx) {
                    if (self.jsx_specifier_cache == null) {
                        const is_dev = self.jsx_runtime == .automatic_dev;
                        self.jsx_specifier_cache = std.fmt.allocPrint(
                            self.allocator,
                            "{s}/{s}",
                            .{ self.jsx_import_source, if (is_dev) "jsx-dev-runtime" else "jsx-runtime" },
                        ) catch null;
                    }
                    if (self.jsx_specifier_cache) |specifier| {
                        module.import_records = injectJsxRuntimeImport(
                            specifier,
                            arena_alloc,
                            records,
                        ) catch records;
                        jsx_injected = (module.import_records.len > records.len);
                    }
                }
            }

            module.exports_kind = determineExportsKind(scan_result, module.path);
            module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;

            // JSX synthetic import bindings 추가
            if (jsx_injected) {
                const jsx_record_idx: u32 = @intCast(records.len);
                module.import_bindings = createJsxImportBindings(
                    self.jsx_runtime,
                    arena_alloc,
                    module.import_bindings,
                    jsx_record_idx,
                ) catch module.import_bindings;
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
        if (std.fs.cwd().openDir(pkg_dir_path, .{})) |dir_val| {
            var pkg_dir = dir_val;
            defer pkg_dir.close();
            if (pkg_json.parsePackageJson(self.allocator, pkg_dir)) |parsed_val| {
                var parsed = parsed_val;
                info.is_module = parsed.pkg.isModule();
                info.side_effects = parsed.pkg.side_effects;
                // 소유권을 info 로 이전 — parsed.deinit() 에서 이중 free 방지.
                parsed.pkg.side_effects = .unknown;
                parsed.deinit();
            } else |_| {}
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
        const pkg_dir_path = findPackageDirPath(module.path) orelse return;
        const info = self.lookupPkgInfo(pkg_dir_path);
        applyCachedSideEffects(module, pkg_dir_path, info.side_effects);
    }

    /// package.json sideEffects 값을 모듈에 적용.
    /// `.all`/`.patterns` 케이스는 tree-shaker가 auto-purity로 덮어쓰지 못하도록 user_defined lock 설정.
    /// `.unknown` (필드 없음)은 기본 동작(conservative: side_effects=true 유지) 그대로.
    fn applyCachedSideEffects(module: *Module, pkg_dir_path: []const u8, se: pkg_json.PackageJson.SideEffects) void {
        switch (se) {
            .all => |val| {
                module.side_effects = val;
                module.side_effects_user_defined = true;
            },
            .patterns => |patterns| {
                module.side_effects = matchSideEffectsPatterns(module.path, pkg_dir_path, patterns);
                module.side_effects_user_defined = true;
            },
            .unknown => {},
        }
    }

    /// sideEffects 글롭 패턴 매칭.
    /// 모듈의 패키지 내 상대 경로를 각 패턴과 비교하여,
    /// 하나라도 매칭되면 side_effects=true (해당 파일은 제거하면 안 됨).
    /// 아무 패턴도 매칭되지 않으면 side_effects=false (순수 모듈, 제거 가능).
    pub fn matchSideEffectsPatterns(module_path: []const u8, pkg_dir_path: []const u8, patterns: []const []const u8) bool {
        const matchGlob = @import("resolve_cache.zig").matchGlob;

        // 패키지 디렉토리 기준 상대 경로 추출: /abs/node_modules/pkg/src/foo.js → src/foo.js
        const relative = if (module_path.len > pkg_dir_path.len + 1)
            module_path[pkg_dir_path.len + 1 ..] // +1 for separator
        else
            module_path;

        // Windows 경로 정규화: \ → / (패턴은 항상 / 사용)
        var rel_buf: [4096]u8 = undefined;
        const rel_normalized = normalizeSep(relative, &rel_buf);
        const base = std.fs.path.basename(rel_normalized);

        for (patterns) |pattern| {
            // "./" 접두사 제거: "./src/polyfill.js" → "src/polyfill.js"
            const normalized = if (std.mem.startsWith(u8, pattern, "./"))
                pattern[2..]
            else
                pattern;

            if (matchGlob(normalized, rel_normalized)) return true;
            // basename 폴백: "*.css"는 "src/style.css"도 매칭해야 함
            if (base.len != rel_normalized.len) {
                if (matchGlob(normalized, base)) return true;
            }
        }
        return false;
    }

    /// 경로의 \ 구분자를 /로 정규화 (Windows 호환).
    fn normalizeSep(path: []const u8, buf: *[4096]u8) []const u8 {
        if (comptime @import("builtin").os.tag == .windows) {
            const len = @min(path.len, buf.len);
            for (path[0..len], 0..) |c, i| {
                buf[i] = if (c == '\\') '/' else c;
            }
            return buf[0..len];
        }
        return path;
    }

    /// Phase 1: 모듈의 import들을 resolve하고 의존성 모듈을 등록한다.
    /// modules 배열이 커질 수 있으므로, 포인터가 아닌 인덱스로만 접근.
    fn resolveModuleImports(self: *ModuleGraph, idx: ModuleIndex) !void {
        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.items.len) return;

        const module_path = self.modules.items[mod_idx].path;
        const source_dir = std.fs.path.dirname(module_path) orelse ".";
        const records = self.modules.items[mod_idx].import_records;

        // Plugin: resolveId 훅용 runner를 루프 밖에서 한 번만 생성
        const plugin_runner: ?plugin_mod.PluginRunner = if (self.plugins.len > 0)
            plugin_mod.PluginRunner.init(self.plugins)
        else
            null;

        // import.meta.glob: glob 레코드를 파일 시스템에서 확장
        expandGlobRecords(self.allocator, self.modules.items[mod_idx].import_records, source_dir);
        // require.context: host plugin 으로 매칭 결과 주입 (#1579 Phase 2)
        expandRequireContextRecords(self, module_path, self.modules.items[mod_idx].import_records);

        for (records, 0..) |record, rec_i| {
            if (record.kind == .glob) continue;
            if (record.kind == .require_context) continue;

            // Plugin: resolveId 훅 — 기본 resolver 전에 플러그인에게 경로 해석 기회를 줌
            if (plugin_runner) |runner| {
                const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator) catch |err| switch (err) {
                    error.PluginFailed => null,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                // non-null이면 플러그인이 resolve 완료 → 기본 resolver 건너뜀
                if (resolve_result) |plugin_result| {
                    try self.applyResolveResult(mod_idx, rec_i, record, plugin_result, false);
                    continue;
                }
                // null이면 기본 resolver로 fall through
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
            try self.applyResolveResult(mod_idx, rec_i, record, resolved, false);
        }
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
        if (start >= self.modules.items.len) return;
        if (visited.isSet(start)) return;

        try stack.append(self.allocator, .{ .idx = start, .post = false });

        while (stack.items.len > 0) {
            const entry = stack.pop() orelse break;

            if (entry.post) {
                // 후처리: exec_index 부여 + in_stack 해제
                in_stack.unset(entry.idx);
                visited.set(entry.idx);
                self.modules.items[entry.idx].exec_index = self.exec_counter;
                self.exec_counter += 1;
                continue;
            }

            if (visited.isSet(entry.idx)) continue;

            // 순환 감지 (D065)
            if (in_stack.isSet(entry.idx)) {
                self.cycle_counter += 1;
                self.modules.items[entry.idx].cycle_group = self.cycle_counter;
                self.addDiag(
                    .circular_dependency,
                    .warning,
                    self.modules.items[entry.idx].path,
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

            // 의존성을 역순으로 push (원래 순서대로 방문하기 위해)
            const deps = self.modules.items[entry.idx].dependencies.items;
            var j: usize = deps.len;
            while (j > 0) {
                j -= 1;
                const dep = @intFromEnum(deps[j]);
                if (dep < self.modules.items.len and !visited.isSet(dep)) {
                    try stack.append(self.allocator, .{ .idx = dep, .post = false });
                }
            }
        }
    }

    /// 모듈의 exports_kind와 wrap_kind를 소비자에 따라 결정한다. (esbuild 모델)
    /// 2-pass: require()를 먼저 처리하여 래핑을 결정하고, import는 나중에 처리.
    /// - ESM 모듈 + require 소비 → WrapKind.esm (__esm 래퍼)
    /// - CJS/none 모듈 + require 소비 → WrapKind.cjs (__commonJS 래퍼)
    /// - .none 모듈 + import 소비 → .esm 승격 (래핑된 모듈은 변경하지 않음)
    fn promoteExportsKinds(self: *ModuleGraph) void {
        // Pass 1: require() 소비 처리 (래핑 결정)
        // 모든 모듈의 require를 먼저 처리해야 함 — 다른 모듈의 import가
        // 같은 타겟을 ESM으로 승격시키기 전에 wrap_kind가 결정되어야 한다.
        for (self.modules.items) |m| {
            for (m.import_records) |rec| {
                if (rec.kind != .require) continue;
                if (rec.resolved.isNone()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= self.modules.items.len) continue;

                var target = &self.modules.items[target_idx];

                if (target.module_type == .json) {
                    target.exports_kind = .commonjs;
                    target.wrap_kind = .cjs;
                } else if (target.exports_kind == .esm or target.exports_kind == .esm_with_dynamic_fallback) {
                    target.wrap_kind = .esm;
                } else {
                    target.exports_kind = .commonjs;
                    target.wrap_kind = .cjs;
                }
            }
        }

        // Pass 2: import 소비 처리 (래핑 안 된 .none 모듈만 승격)
        for (self.modules.items) |m| {
            for (m.import_records) |rec| {
                if (rec.kind != .static_import and rec.kind != .side_effect and rec.kind != .re_export) continue;
                if (rec.resolved.isNone()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= self.modules.items.len) continue;

                var target = &self.modules.items[target_idx];

                // 이미 래핑된 모듈은 건드리지 않음
                if (target.wrap_kind != .none) continue;

                if (target.exports_kind == .none) {
                    if (self.isImplicitCjs(target)) {
                        target.exports_kind = .commonjs;
                        target.wrap_kind = .cjs;
                    } else {
                        target.exports_kind = .esm;
                    }
                }
            }
        }

        // Pass 2.5: 래핑된 모듈의 re_export source는 lazy 체인 보존을 위해
        // __esm 래핑 (#1340). barrel `export { default as X } from './m'` 패턴에서
        // m이 scope-hoist되면 barrel의 init body가 비고 `_default = ...` 할당이
        // 누락된다. re_export만 cascade — static_import는 binding rewrite로 해결됨.
        // wrap_kind 변경이 또 다른 모듈을 promote할 수 있어 iterative 수행.
        {
            var changed = true;
            while (changed) {
                changed = false;
                for (self.modules.items) |m| {
                    if (m.wrap_kind == .none) continue;
                    for (m.export_bindings) |eb| {
                        if (!eb.kind.isAnyReExport()) continue;
                        const rec_idx = eb.import_record_index orelse continue;
                        const target = self.resolveImportTarget(m, rec_idx) orelse continue;
                        if (promoteToEsmWrap(target)) changed = true;
                    }
                }
            }
        }

        // Pass 3: 모든 ESM 모듈을 __esm 래핑 (RN + dev mode).
        // - RN: circular dep 체인에서 초기화 순서 보장 (Rolldown 호환 lazy loading)
        // - dev mode: HMR을 위해 모든 모듈이 개별 팩토리 함수로 래핑되어야 함
        //   (scope-hoisted flat 모듈은 개별 교체 불가)
        if (self.resolve_cache.platform == .react_native or self.dev_mode) {
            for (self.modules.items) |*m| {
                if (m.wrap_kind == .none and (m.exports_kind == .esm or m.exports_kind == .esm_with_dynamic_fallback)) {
                    m.wrap_kind = .esm;
                }
            }
        }
    }

    /// wrap_kind 확정 후 모든 래핑 모듈에 `init_<path>` + `exports_<path>` 합성
    /// 심볼을 semantic 공간에 등록한다. Emitter/linker가 Module.getInitName/
    /// getExportsName으로 이름을 조회해 중복 할당을 피한다.
    /// OOM/semantic 없음 → 조용히 skip, fallback 경로가 기존 동작 유지.
    fn registerWrapperSymbols(self: *ModuleGraph) void {
        for (self.modules.items) |*m| {
            if (m.wrap_kind == .none) continue;
            // incremental rebuild: 이미 등록된 모듈은 skip.
            if (m.init_symbol != null or m.exports_symbol != null) continue;
            const sem_ptr = if (m.semantic) |*s| s else continue;
            const arena = if (m.parse_arena) |*a| a.allocator() else continue;

            const init_name = types.makeInitVarName(arena, m.path) catch continue;
            const exports_name = types.makeExportsVarName(arena, m.path) catch continue;

            m.init_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .function_decl,
                .esm_init,
                init_name,
                Span.EMPTY,
            ) catch null;

            m.exports_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .variable_var,
                .cjs_exports,
                exports_name,
                Span.EMPTY,
            ) catch null;
        }
    }

    /// `m.import_records[rec_idx].resolved`를 따라 target Module 포인터를 얻는다.
    /// bounds/none 체크 실패 시 null. wrap_kind 결정 패스들의 공통 진입점.
    fn resolveImportTarget(self: *ModuleGraph, m: anytype, rec_idx: usize) ?*Module {
        if (rec_idx >= m.import_records.len) return null;
        const target_mod_idx = m.import_records[rec_idx].resolved;
        if (target_mod_idx.isNone()) return null;
        const target_idx = @intFromEnum(target_mod_idx);
        if (target_idx >= self.modules.items.len) return null;
        return &self.modules.items[target_idx];
    }

    /// `.none` 상태의 ESM 모듈을 `.esm`으로 promote. 이미 래핑됐거나 ESM이 아니면
    /// no-op. 변경 발생 시 true (Pass 2.5 fixpoint loop의 changed 플래그용).
    fn promoteToEsmWrap(target: *Module) bool {
        if (target.wrap_kind != .none) return false;
        if (target.exports_kind != .esm and target.exports_kind != .esm_with_dynamic_fallback) return false;
        target.wrap_kind = .esm;
        return true;
    }

    /// node_modules 내 .js 파일이 ESM/CJS 신호 없으면 CJS로 간주.
    /// Node.js 규칙: package.json "type": "module"이 없으면 .js는 CJS.
    fn isImplicitCjs(_: *ModuleGraph, module: *const Module) bool {
        // node_modules 밖이면 ESM으로 간주 (사용자 코드)
        const nm = "node_modules" ++ std.fs.path.sep_str;
        if (std.mem.indexOf(u8, module.path, nm) == null) return false;
        // def_format이 파싱 시점에 이미 결정됨 — 디스크 I/O 불필요
        return switch (module.def_format) {
            .cjs, .cts, .cjs_package_json => true,
            .esm_mjs, .esm_mts, .esm_package_json => false,
            .unknown => true, // node_modules 내 .js는 기본 CJS
        };
    }

    /// 모듈 경로에서 가장 가까운 package.json의 "type" 필드가 "module"인지 확인.
    /// `lookupPkgInfo` 로 캐시 경유 — 같은 pkg 의 side_effects 조회와 pkg.json parse 공유.
    fn isPackageTypeModule(self: *ModuleGraph, module_path: []const u8) bool {
        var scope = profile.begin(.graph_discover_pm_is_pkg_type);
        defer scope.end();
        const pkg_dir_path = findPackageDirPath(module_path) orelse return false;
        return self.lookupPkgInfo(pkg_dir_path).is_module;
    }

    /// TLA 전이적 전파: TLA 모듈을 static import하는 모듈도 TLA로 표시.
    /// await가 포함된 모듈의 실행이 완료되기 전에 이를 import하는 모듈이
    /// 실행될 수 없으므로, import하는 쪽도 TLA로 간주해야 한다.
    /// 동적 import는 비동기이므로 전파하지 않는다.
    ///
    /// 역방향 BFS O(n + edges): 역의존성 맵을 빌드한 뒤,
    /// TLA 모듈에서 시작하여 importers를 따라 전파한다.
    fn propagateTopLevelAwait(self: *ModuleGraph) void {
        const count = self.modules.items.len;
        if (count == 0) return;

        // Fast path: TLA 모듈이 없으면 전파할 것도 없다.
        var has_tla = false;
        for (self.modules.items) |m| {
            if (m.uses_top_level_await) {
                has_tla = true;
                break;
            }
        }
        if (!has_tla) return;

        // 역의존성 맵 빌드: reverse_deps[target] = [importers...]
        var reverse_deps = self.allocator.alloc(std.ArrayListUnmanaged(u32), count) catch return;
        defer {
            for (reverse_deps) |*list| list.deinit(self.allocator);
            self.allocator.free(reverse_deps);
        }
        for (reverse_deps) |*list| list.* = .empty;

        for (self.modules.items, 0..) |m, src_idx| {
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                if (rec.kind != .static_import and rec.kind != .side_effect and rec.kind != .re_export) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= count) continue;
                reverse_deps[target_idx].append(self.allocator, @intCast(src_idx)) catch return;
            }
        }

        // BFS: TLA 모듈 → importers 전파
        var visited = std.DynamicBitSet.initEmpty(self.allocator, count) catch return;
        defer visited.deinit();
        var queue: std.ArrayListUnmanaged(u32) = .empty;
        defer queue.deinit(self.allocator);

        for (self.modules.items, 0..) |m, idx| {
            if (m.uses_top_level_await) {
                visited.set(idx);
                queue.append(self.allocator, @intCast(idx)) catch return;
            }
        }

        var head: usize = 0;
        while (head < queue.items.len) {
            const tla_idx = queue.items[head];
            head += 1;
            for (reverse_deps[tla_idx].items) |importer_idx| {
                if (visited.isSet(importer_idx)) continue;
                visited.set(importer_idx);
                self.modules.items[importer_idx].uses_top_level_await = true;
                queue.append(self.allocator, importer_idx) catch return;
            }
        }
    }

    /// CSS 모듈을 파싱한다.
    /// 파일을 읽어서 @import 규칙을 추출하고, import_records에 등록한다.
    /// CSS 소스는 module.source에 보존하여 css_emitter에서 사용한다.
    fn parseCssModule(self: *ModuleGraph, module: *Module) void {
        const css_scanner_mod = @import("css_scanner.zig");

        module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_alloc = module.parse_arena.?.allocator();

        // 파일 읽기
        if (module.source.len == 0) {
            module.source = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
                self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .parse, "Cannot read file", null);
                module.state = .ready;
                return;
            };
        }

        // @import 규칙 추출 (arena에 할당)
        const raw_imports = css_scanner_mod.extractCssImports(arena_alloc, module.source);
        const import_count: u32 = @intCast(raw_imports.len);

        if (import_count > 0) {
            // import_records 생성
            const records = arena_alloc.alloc(types.ImportRecord, import_count) catch {
                module.state = .ready;
                return;
            };
            for (raw_imports, 0..) |imp, i| {
                records[i] = .{
                    .specifier = imp.specifier,
                    .kind = .side_effect,
                    .span = imp.span,
                };
            }
            module.import_records = records;
        }

        const strip_end: u32 = if (import_count > 0) raw_imports[import_count - 1].span.end else 0;
        module.css_data = .{ .import_count = import_count, .strip_end = strip_end };
        module.exports_kind = .esm; // CSS는 ESM side-effect import로 처리
        module.side_effects = true; // CSS는 항상 side-effect
        module.state = .parsed;
    }

    /// Asset 로더 모듈을 파싱한다.
    /// 파일을 읽어서 로더 타입에 따라 fake JS 소스를 생성하고,
    /// module_type을 .javascript로 바꿔서 기존 파이프라인을 그대로 탄다.
    ///
    /// asset_registry 모드의 .file/.copy는 loader를 .javascript로 바꿔 fall-through
    /// 신호를 보내고, 호출자가 일반 JS 파이프라인을 이어 실행한다.
    fn parseAssetModule(self: *ModuleGraph, module: *Module) void {
        module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_alloc = module.parse_arena.?.allocator();

        switch (module.loader) {
            .text => {
                // UTF-8 문자열로 읽어서 JS 문자열 리터럴 생성
                const content = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
                    self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .parse, "Cannot read file", null);
                    module.state = .ready;
                    return;
                };
                const escaped = escapeJsString(arena_alloc, content) catch {
                    module.state = .ready;
                    return;
                };
                // source에는 값 표현식만 저장 (JSON 모듈과 동일 패턴)
                // emitter에서 var asset_X = <source>; 형태로 출력
                module.source = std.fmt.allocPrint(arena_alloc, "\"{s}\"", .{escaped}) catch {
                    module.state = .ready;
                    return;
                };
            },
            .dataurl => {
                // 바이너리 읽기 → base64 인코딩 → data URL 문자열
                const raw = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
                    self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .parse, "Cannot read file", null);
                    module.state = .ready;
                    return;
                };
                const encoded = base64Encode(arena_alloc, raw) catch {
                    module.state = .ready;
                    return;
                };
                const full_mime = mime.fromExtension(module.path);
                const mime_type = if (std.mem.indexOf(u8, full_mime, ";")) |semi|
                    full_mime[0..semi]
                else
                    full_mime;

                module.source = std.fmt.allocPrint(arena_alloc, "\"data:{s};base64,{s}\"", .{ mime_type, encoded }) catch {
                    module.state = .ready;
                    return;
                };
            },
            .binary => {
                // 바이너리 읽기 → base64 인코딩 → __toBinary("...") 호출 표현식
                const raw = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
                    self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .parse, "Cannot read file", null);
                    module.state = .ready;
                    return;
                };
                const encoded = base64Encode(arena_alloc, raw) catch {
                    module.state = .ready;
                    return;
                };
                // #1621: minify 시 $tb 축약.
                const to_bin_name = runtime_helpers.helperName("__toBinary", self.minify_whitespace);
                module.source = std.fmt.allocPrint(arena_alloc, "{s}(\"{s}\")", .{ to_bin_name, encoded }) catch {
                    module.state = .ready;
                    return;
                };
            },
            .file, .copy => {
                // 파일 읽기 → content hash → 출력 경로 생성 → URL 문자열
                const raw = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
                    self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .parse, "Cannot read file", null);
                    module.state = .ready;
                    return;
                };
                const hash = contentHash(raw);
                const ext = std.fs.path.extension(module.path);
                const basename = std.fs.path.basename(module.path);
                const name_without_ext = if (ext.len > 0 and basename.len > ext.len)
                    basename[0 .. basename.len - ext.len]
                else
                    basename;

                // [dir]: entry_dir 기준 상대 디렉토리 경로
                const dir = computeAssetDir(module.path, self.entry_dir);

                const output_name = applyAssetNamingPattern(arena_alloc, self.asset_names, name_without_ext, &hash, ext, dir) catch {
                    module.state = .ready;
                    return;
                };

                // RN scale variants (@2x, @3x): asset_registry 활성화 시에만 스캔.
                // 기본 URL 출력 모드에서는 variant가 의미 없음 (런타임이 해석 안 함).
                const scales_result = if (self.asset_registry != null)
                    collectScaleVariants(arena_alloc, module.path, name_without_ext, ext, self.asset_names, dir) catch ScaleCollection{ .scales = &.{1}, .variants = &.{} }
                else
                    ScaleCollection{ .scales = &.{1}, .variants = &.{} };

                module.asset_data = .{
                    .raw_content = raw,
                    .content_hash = hash,
                    .output_name = output_name,
                    .ext = ext,
                    .scales = scales_result.scales,
                    .scale_variants = scales_result.variants,
                };

                const url = if (self.public_path.len > 0)
                    std.fmt.allocPrint(arena_alloc, "{s}{s}", .{ self.public_path, output_name }) catch {
                        module.state = .ready;
                        return;
                    }
                else
                    std.fmt.allocPrint(arena_alloc, "./{s}", .{output_name}) catch {
                        module.state = .ready;
                        return;
                    };

                if (self.asset_registry) |registry_path| {
                    // loader=.javascript는 호출자의 fall-through 신호.
                    // import_scanner가 source의 require()를 ImportRecord로 추출하고
                    // wrap_kind/exports_kind를 .cjs로 자동 결정한다.
                    module.source = emitAssetRegistryCall(arena_alloc, registry_path, module.path, raw, &hash, ext, name_without_ext, url, scales_result.scales, self.project_root) catch {
                        module.state = .ready;
                        return;
                    };
                    module.module_type = .javascript;
                    module.loader = .javascript;
                    return;
                }

                module.source = std.fmt.allocPrint(arena_alloc, "\"{s}\"", .{url}) catch {
                    module.state = .ready;
                    return;
                };
            },
            .empty => {
                module.source = "undefined";
            },
            else => {
                module.state = .ready;
                return;
            },
        }

        // JSON 모듈과 동일한 CJS wrap 패턴: linker가 import 바인딩을 자동으로 연결.
        // source에는 값 표현식만 저장되고, emitter가 var/module.exports 형태로 출력.
        module.module_type = .javascript;
        module.exports_kind = .commonjs;
        module.wrap_kind = .cjs;
        module.side_effects = false;
        module.state = .ready;
    }

    fn addDiag(
        self: *ModuleGraph,
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        file_path: []const u8,
        span: Span,
        step: BundlerDiagnostic.Step,
        message: []const u8,
        suggestion: ?[]const u8,
    ) void {
        self.diag_mutex.lock();
        defer self.diag_mutex.unlock();
        self.diagnostics.append(self.allocator, .{
            .code = code,
            .severity = severity,
            .message = message,
            .file_path = file_path,
            .span = span,
            .step = step,
            .suggestion = suggestion,
        }) catch {};
    }
};

// ============================================================
// Asset 로더 유틸리티
// ============================================================

/// JS 문자열 리터럴용 이스케이프. \ " \n \r \0 \u2028 \u2029 를 처리한다.
fn escapeJsString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    // fast path: 이스케이프가 필요한 문자가 없으면 복사만
    var needs_escape = false;
    for (input) |c| {
        switch (c) {
            '\\', '"', '\n', '\r', 0 => {
                needs_escape = true;
                break;
            },
            0xe2 => {
                needs_escape = true; // UTF-8 U+2028/U+2029 시작 바이트
                break;
            },
            else => {},
        }
    }
    if (!needs_escape) return try allocator.dupe(u8, input);

    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(allocator, input.len);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            0 => try buf.appendSlice(allocator, "\\0"),
            0xe2 => {
                // U+2028 (LS) = E2 80 A8, U+2029 (PS) = E2 80 A9
                if (i + 2 < input.len and input[i + 1] == 0x80) {
                    if (input[i + 2] == 0xa8) {
                        try buf.appendSlice(allocator, "\\u2028");
                        i += 3;
                        continue;
                    } else if (input[i + 2] == 0xa9) {
                        try buf.appendSlice(allocator, "\\u2029");
                        i += 3;
                        continue;
                    }
                }
                try buf.append(allocator, c);
            },
            else => try buf.append(allocator, c),
        }
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

/// 바이트 배열을 standard base64로 인코딩한다.
fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(buf, data);
    return buf;
}

const contentHash = wyhash.hashHex8;

/// asset naming 패턴 적용: [name] [hash] 치환 + 확장자 추가.
fn applyAssetNamingPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    name: []const u8,
    hash: *const [8]u8,
    ext: []const u8,
    dir: []const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (std.mem.startsWith(u8, pattern[i..], "[name]")) {
            try buf.appendSlice(allocator, name);
            i += "[name]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[hash]")) {
            try buf.appendSlice(allocator, hash);
            i += "[hash]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[dir]")) {
            // Windows 경로 구분자(\)를 URL 구분자(/)로 정규화
            for (dir) |c| {
                try buf.append(allocator, if (c == '\\') '/' else c);
            }
            i += "[dir]".len;
        } else if (std.mem.startsWith(u8, pattern[i..], "[ext]")) {
            // [ext]는 dot 없이 (예: "png")
            if (ext.len > 1) try buf.appendSlice(allocator, ext[1..]);
            i += "[ext]".len;
        } else {
            try buf.append(allocator, pattern[i]);
            i += 1;
        }
    }
    // 확장자 추가
    try buf.appendSlice(allocator, ext);
    return buf.toOwnedSlice(allocator);
}

/// 디렉토리에서 위로 올라가며 첫 `package.json` 위치를 찾는다.
/// Metro/RN CLI의 projectRoot 자동 감지와 동일 — 모노레포의 packages/app/처럼
/// entry가 깊은 곳에 있어도 그 패키지의 루트를 정확히 찾아낸다. 발견 못 하면
/// caller 입력(start_dir)을 fallback으로 반환.
/// 반환 slice는 입력 start_dir의 prefix이므로 caller가 free하지 않는다.
fn findProjectRoot(alloc: std.mem.Allocator, start_dir: []const u8) ![]const u8 {
    var dir: []const u8 = start_dir;
    while (dir.len > 0) {
        const candidate = try std.fs.path.join(alloc, &.{ dir, "package.json" });
        defer alloc.free(candidate);
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return dir;
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len == dir.len) break; // 루트 (e.g. "/")
        dir = parent;
    }
    return start_dir;
}

/// Metro AssetRegistry.registerAsset() 호출식을 생성.
/// RN 런타임은 이 객체의 키를 정확히 요구하므로 shape를 Metro 1:1로 맞춘다.
fn emitAssetRegistryCall(
    alloc: std.mem.Allocator,
    registry_path: []const u8,
    abs_path: []const u8,
    bytes: []const u8,
    hash: *const [8]u8,
    ext: []const u8,
    name_without_ext: []const u8,
    url: []const u8,
    scales: []const u32,
    project_root: []const u8,
) ![]const u8 {
    const asset_meta = @import("asset_meta.zig");
    const dims = asset_meta.extractDimensions(bytes);
    const width = if (dims) |d| d.width else 0;
    const height = if (dims) |d| d.height else 0;
    const asset_type = asset_meta.AssetType.fromExtension(ext);
    const type_name = asset_type.typeName(ext);

    // Metro 호환: httpServerLocation = `/assets/` + projectRoot 기준 상대 경로의 dirname.
    // RN 런타임이 `<dev-server>:<port><httpServerLocation>/<name>.<hash>.<type>` 형태로
    // URL을 만들기 때문에 `.`만 있으면 dev server가 파일을 찾지 못한다 (#1428).
    const http_loc_raw = blk: {
        if (project_root.len == 0) break :blk std.fs.path.dirname(url) orelse ".";
        const rel = std.fs.path.relative(alloc, project_root, abs_path) catch break :blk ".";
        defer alloc.free(rel);
        const rel_dir = std.fs.path.dirname(rel) orelse ".";
        break :blk std.fmt.allocPrint(alloc, "/assets/{s}", .{rel_dir}) catch ".";
    };
    const fs_dir_raw = std.fs.path.dirname(abs_path) orelse ".";

    // 사용자 경로/식별자에 따옴표·역슬래시·개행이 포함되면 JSON 파싱이 깨지므로 escape 필수.
    // RN/Metro에서 파일명에 특수문자 있을 가능성은 낮지만 안전하게 처리.
    const http_loc = try escapeJsString(alloc, http_loc_raw);
    const fs_dir = try escapeJsString(alloc, fs_dir_raw);
    const name_esc = try escapeJsString(alloc, name_without_ext);
    const registry_esc = try escapeJsString(alloc, registry_path);

    // Metro 호환: asset hash는 raw bytes의 MD5 32자 hex (Metro `Assets.js`의 hashFiles 결과).
    // RN 런타임/빌드 시스템이 캐시 키, 디스크 자산명 등에서 32자를 가정하므로
    // 8byte wyhash hex로는 충돌 확률 + Metro 호환성 모두 부족 (#1428).
    // 인자의 hash(`*const [8]u8`)는 기존 caller 호환을 위해 남겨두지만 미사용.
    _ = hash;
    var md5_digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(bytes, &md5_digest, .{});
    var hash_hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (md5_digest, 0..) |b, i| {
        hash_hex[i * 2] = hex_chars[b >> 4];
        hash_hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }

    // scales 배열 직렬화. 일반적으로 [1,2,3] 정도라 스택 버퍼로 충분.
    var scales_stack_buf: [128]u8 = undefined;
    var scales_stream = std.io.fixedBufferStream(&scales_stack_buf);
    const sw = scales_stream.writer();
    sw.writeByte('[') catch return error.OutOfMemory;
    for (scales, 0..) |s, i| {
        if (i > 0) sw.writeAll(", ") catch return error.OutOfMemory;
        std.fmt.format(sw, "{d}", .{s}) catch return error.OutOfMemory;
    }
    sw.writeByte(']') catch return error.OutOfMemory;
    const scales_str = scales_stream.getWritten();

    return try std.fmt.allocPrint(alloc,
        \\module.exports = require("{s}").registerAsset({{
        \\  "__packager_asset": true,
        \\  "httpServerLocation": "{s}",
        \\  "width": {d},
        \\  "height": {d},
        \\  "scales": {s},
        \\  "hash": "{s}",
        \\  "name": "{s}",
        \\  "type": "{s}",
        \\  "fileSystemLocation": "{s}"
        \\}})
    , .{ registry_esc, http_loc, width, height, scales_str, &hash_hex, name_esc, type_name, fs_dir });
}

const ScaleCollection = struct {
    scales: []const u32,
    variants: []const Module.ScaleVariant,
};

/// `name.ext`의 sibling을 스캔해 `name@2x.ext`, `name@3x.ext` 등을 수집.
/// Metro는 base(1x)가 반드시 존재해야 하며 variant만 있으면 매칭 안 함 — 같은 규칙.
fn collectScaleVariants(
    alloc: std.mem.Allocator,
    abs_path: []const u8,
    name_without_ext: []const u8,
    ext: []const u8,
    asset_names: []const u8,
    dir_pattern: []const u8,
) !ScaleCollection {
    const fs_dir = std.fs.path.dirname(abs_path) orelse return ScaleCollection{ .scales = &.{1}, .variants = &.{} };

    var scale_list: std.ArrayList(u32) = .empty;
    defer scale_list.deinit(alloc);
    try scale_list.append(alloc, 1); // base

    var variants: std.ArrayList(Module.ScaleVariant) = .empty;
    defer variants.deinit(alloc);

    // @2x부터 @4x까지 검사 (RN 실전 최대치). @1x 명시는 base와 중복이므로 무시.
    // stat으로 존재 여부 먼저 확인 — 없으면 readFileAlloc의 큰 alloc + read 시도 회피.
    var scale: u32 = 2;
    while (scale <= 4) : (scale += 1) {
        const variant_name = try std.fmt.allocPrint(alloc, "{s}@{d}x{s}", .{ name_without_ext, scale, ext });
        defer alloc.free(variant_name);
        const variant_path = try std.fs.path.join(alloc, &.{ fs_dir, variant_name });
        defer alloc.free(variant_path);

        std.fs.cwd().access(variant_path, .{}) catch continue;
        const raw = std.fs.cwd().readFileAlloc(alloc, variant_path, 100 * 1024 * 1024) catch continue;
        const hash = contentHash(raw);
        const variant_basename = try std.fmt.allocPrint(alloc, "{s}@{d}x", .{ name_without_ext, scale });
        defer alloc.free(variant_basename);
        const output_name = try applyAssetNamingPattern(alloc, asset_names, variant_basename, &hash, ext, dir_pattern);

        try scale_list.append(alloc, scale);
        try variants.append(alloc, .{
            .scale = scale,
            .output_name = output_name,
            .raw_content = raw,
        });
    }

    return ScaleCollection{
        .scales = try scale_list.toOwnedSlice(alloc),
        .variants = try variants.toOwnedSlice(alloc),
    };
}

/// asset 파일의 entry_dir 기준 상대 디렉토리 경로를 계산한다.
/// 예: entry_dir="/app/src", module="/app/src/images/icons/logo.png" → "images/icons"
/// entry_dir 밖이면 빈 문자열 반환.
fn computeAssetDir(module_path: []const u8, entry_dir: []const u8) []const u8 {
    if (entry_dir.len == 0) return "";
    const module_dir = std.fs.path.dirname(module_path) orelse return "";
    // entry_dir이 module_dir의 prefix인지 확인
    if (module_dir.len <= entry_dir.len) return "";
    if (!std.mem.startsWith(u8, module_dir, entry_dir)) return "";
    // 구분자 건너뛰기
    var start = entry_dir.len;
    if (start < module_dir.len and module_dir[start] == std.fs.path.sep) start += 1;
    if (start >= module_dir.len) return "";
    return module_dir[start..];
}

const JsxRuntime = @import("../codegen/codegen.zig").JsxRuntime;
const ImportBinding = binding_scanner_mod.ImportBinding;

/// JSX automatic import를 synthetic하게 추가한다.
/// 기존 import_records 배열 끝에 jsx-runtime import record를 1개 추가.
fn injectJsxRuntimeImport(
    specifier: []const u8,
    arena_alloc: std.mem.Allocator,
    existing_records: []ImportRecord,
) ![]ImportRecord {
    const new_record = ImportRecord{
        .specifier = specifier,
        .kind = .static_import,
        .span = Span.EMPTY,
    };

    // 기존 records + 새 record를 합친 새 슬라이스 생성
    const new_records = try arena_alloc.alloc(ImportRecord, existing_records.len + 1);
    @memcpy(new_records[0..existing_records.len], existing_records);
    new_records[existing_records.len] = new_record;
    return new_records;
}

/// JSX automatic import에 대한 synthetic import bindings를 생성한다.
fn createJsxImportBindings(
    jsx_runtime: JsxRuntime,
    arena_alloc: std.mem.Allocator,
    existing_bindings: []ImportBinding,
    jsx_record_index: u32,
) ![]ImportBinding {
    const is_dev = jsx_runtime == .automatic_dev;

    // dev: jsxDEV, Fragment | prod: jsx, jsxs, Fragment
    const jsx_bindings: []const struct { local: []const u8, imported: []const u8 } = if (is_dev)
        &.{
            .{ .local = "_jsxDEV", .imported = "jsxDEV" },
            .{ .local = "_Fragment", .imported = "Fragment" },
        }
    else
        &.{
            .{ .local = "_jsx", .imported = "jsx" },
            .{ .local = "_jsxs", .imported = "jsxs" },
            .{ .local = "_Fragment", .imported = "Fragment" },
        };

    const new_bindings = try arena_alloc.alloc(ImportBinding, existing_bindings.len + jsx_bindings.len);
    @memcpy(new_bindings[0..existing_bindings.len], existing_bindings);
    for (jsx_bindings, 0..) |jb, i| {
        // 각 synthetic binding에 고유 sentinel span 부여.
        // Span.EMPTY(0,0)를 공유하면 linker의 spanKey 기반 HashMap에서 덮어쓰기 발생.
        const sentinel_start: u32 = ImportBinding.SYNTHETIC_SPAN_BASE + @as(u32, @intCast(i));
        new_bindings[existing_bindings.len + i] = .{
            .kind = .named,
            .local_name = jb.local,
            .imported_name = jb.imported,
            .local_span = .{ .start = sentinel_start, .end = sentinel_start },
            .import_record_index = jsx_record_index,
        };
    }
    return new_bindings;
}

/// 스캔 결과와 파일 확장자로 모듈의 export 방식을 결정한다.
/// 우선순위: 1) ESM+CJS 혼용 → esm_with_dynamic_fallback
///          2) ESM만 → esm
///          3) CJS 신호 → commonjs
///          4) 확장자 (.cjs/.mjs 등) → commonjs/esm
///          5) 판별 불가 → none
pub fn determineExportsKind(
    scan: import_scanner.ScanResult,
    path: []const u8,
) types.ExportsKind {
    const has_cjs = scan.has_cjs_require or scan.has_module_exports or scan.has_exports_dot;

    // ESM + CJS 혼용
    if (scan.has_esm_syntax and has_cjs) return .esm_with_dynamic_fallback;

    // ESM만
    if (scan.has_esm_syntax) return .esm;

    // CJS 신호
    if (has_cjs) return .commonjs;

    // 확장자로 판별
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".cjs") or std.mem.eql(u8, ext, ".cts")) return .commonjs;
    if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".mts")) return .esm;

    return .none;
}

/// import.meta.glob 패턴을 파일 시스템에서 확장한다.
/// 패턴: "./dir/*.ext" — prefix(./dir/) + *와 suffix(.ext)로 분리하여 디렉토리 탐색.
/// 상대 경로 배열을 반환한다 (예: ["./pages/Home.tsx", "./pages/About.tsx"]).
fn expandGlob(allocator: std.mem.Allocator, source_dir: []const u8, pattern: []const u8) ![]const []const u8 {
    // 패턴에서 * 위치 찾기
    const star_pos = std.mem.indexOf(u8, pattern, "*") orelse return &.{};
    const prefix = pattern[0..star_pos]; // "./pages/"
    const suffix = pattern[star_pos + 1 ..]; // ".tsx"

    // prefix에서 디렉토리 경로 추출
    const glob_dir_rel = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else if (std.fs.path.dirname(prefix)) |d| d else ".";

    // 절대 경로로 변환
    const glob_dir_abs = try std.fs.path.resolve(allocator, &.{ source_dir, glob_dir_rel });
    defer allocator.free(glob_dir_abs);

    // 디렉토리 열기
    var dir = std.fs.cwd().openDir(glob_dir_abs, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }

    // prefix에서 디렉토리 이후 부분 (파일명 prefix)
    const file_prefix = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        ""
    else
        std.fs.path.basename(prefix);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const name = entry.name;

        // prefix 매칭
        if (file_prefix.len > 0 and !std.mem.startsWith(u8, name, file_prefix)) continue;
        // suffix 매칭 (확장자)
        if (suffix.len > 0 and !std.mem.endsWith(u8, name, suffix)) continue;

        // 상대 경로 생성: "./dir/filename.ext"
        const rel_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ glob_dir_rel, name });
        try results.append(allocator, rel_path);
    }

    // 결정적 순서를 위해 정렬
    std.mem.sortUnstable([]const u8, results.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp);

    return try results.toOwnedSlice(allocator);
}

/// import_records 배열에서 glob 레코드를 찾아 expandGlob으로 파일 매칭을 수행한다.
/// scanWorker와 resolveModuleImports 양쪽에서 호출되는 공통 헬퍼.
fn expandGlobRecords(allocator: std.mem.Allocator, records: []types.ImportRecord, source_dir: []const u8) void {
    for (records) |*record| {
        if (record.kind == .glob) {
            record.glob_matches = expandGlob(allocator, source_dir, record.specifier) catch &.{};
        }
    }
}

/// require.context(...) 레코드의 매칭 파일 목록을 host plugin (resolveContext) 으로 채운다.
/// (#1579 Phase 2). ZTS 자체 regex executor 가 없어서 host runtime 의 RegExp 위임 (#1771).
///
/// 처리 순서:
///   1. invalid record (`context_invalid_reason != null`) → require_context_invalid error.
///   2. plugin runner 호출 (first non-null wins) → 결과를 record.context_matches 에 저장.
///   3. plugin 미구현 → require_context_no_handler warning (record.context_matches 는 null 유지).
///
/// `self`: ModuleGraph (addDiag, plugins 접근용)
/// `module_path`: 현재 모듈 경로 (importer)
/// `records`: 모듈의 import_records (in-place 수정)
fn expandRequireContextRecords(self: *ModuleGraph, module_path: []const u8, records: []types.ImportRecord) void {
    // require_context 레코드 존재 여부 빠른 체크 (대다수 모듈은 0개 — early return 으로 cheap)
    var has_any = false;
    for (records) |r| {
        if (r.kind == .require_context) {
            has_any = true;
            break;
        }
    }
    if (!has_any) return;

    const plugin_runner: ?plugin_mod.PluginRunner = if (self.plugins.len > 0)
        plugin_mod.PluginRunner.init(self.plugins)
    else
        null;

    for (records) |*record| {
        if (record.kind != .require_context) continue;
        // scanWorker + resolveModuleImports 양쪽에서 호출됨. context_matches 가 채워졌으면 (성공/실패
        // 무관) 이미 처리된 record — diag 중복/plugin 재호출 방지.
        if (record.context_matches != null) continue;

        // Invalid 인자 → diagnostic (Phase 1 의 reason 텍스트 그대로 사용). empty slice 로 마킹.
        if (record.context_invalid_reason) |reason| {
            self.addDiag(.require_context_invalid, .@"error", module_path, record.span, .resolve, reason, null);
            record.context_matches = &.{};
            continue;
        }

        // Plugin 호출
        if (plugin_runner) |runner| {
            const matches = runner.runResolveContext(
                record.specifier,
                record.context_recursive,
                record.context_filter,
                record.context_filter_flags,
                module_path,
                self.allocator,
            ) catch null;
            if (matches) |m| {
                record.context_matches = m;
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
            "require.context requires a host plugin to match files (ZTS regex executor not yet implemented — see #1771)",
            null,
        );
        record.context_matches = &.{};
    }
}

// ============================================================
// findProjectRoot: 패키지 매니저별 디렉토리 레이아웃 단위 테스트
// ============================================================

const test_helpers = @import("test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "findProjectRoot: 일반 npm — src/index.ts → root는 package.json 위치" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{}");
    try writeFile(tmp.dir, "src/index.ts", "");

    const start = try absPath(&tmp, "src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, ".");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}

test "findProjectRoot: npm workspace — packages/app/index.ts → app의 package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"workspaces\": [\"packages/*\"]}");
    try writeFile(tmp.dir, "packages/app/package.json", "{\"name\": \"app\"}");
    try writeFile(tmp.dir, "packages/app/index.ts", "");

    const start = try absPath(&tmp, "packages/app");
    defer std.testing.allocator.free(start);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(start, root);
}

test "findProjectRoot: pnpm workspace — packages/app/src/index.ts → app의 package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "pnpm-workspace.yaml", "packages:\n  - 'packages/*'\n");
    try writeFile(tmp.dir, "package.json", "{}");
    try writeFile(tmp.dir, "packages/app/package.json", "{\"name\": \"app\"}");
    try writeFile(tmp.dir, "packages/app/src/index.ts", "");

    const start = try absPath(&tmp, "packages/app/src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, "packages/app");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}

test "findProjectRoot: bun workspace — packages/app/src/index.ts → app의 package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"workspaces\": [\"packages/*\"]}");
    try writeFile(tmp.dir, "bun.lockb", "");
    try writeFile(tmp.dir, "packages/app/package.json", "{\"name\": \"app\"}");
    try writeFile(tmp.dir, "packages/app/src/index.ts", "");

    const start = try absPath(&tmp, "packages/app/src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, "packages/app");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}

test "findProjectRoot: yarn pnp — .pnp.cjs + package.json 단일 패키지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{}");
    try writeFile(tmp.dir, ".pnp.cjs", "");
    try writeFile(tmp.dir, ".yarnrc.yml", "nodeLinker: pnp\n");
    try writeFile(tmp.dir, "src/index.ts", "");

    const start = try absPath(&tmp, "src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, ".");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
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
