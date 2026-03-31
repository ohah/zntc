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
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const ImportKind = types.ImportKind;
const ImportRecord = types.ImportRecord;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("module.zig").Module;
const resolve_cache_mod = @import("resolve_cache.zig");
const ResolveCache = resolve_cache_mod.ResolveCache;
const resolver_mod = @import("resolver.zig");
const import_scanner = @import("import_scanner.zig");
const binding_scanner_mod = @import("binding_scanner.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Span = @import("../lexer/token.zig").Span;
const pkg_json = @import("package_json.zig");
const mime = @import("../server/mime.zig");
const plugin_mod = @import("plugin.zig");
const MpscChannel = @import("mpsc_channel.zig").MpscChannel;
pub const module_store = @import("module_store.zig");

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(Module),
    path_to_module: std.StringHashMap(ModuleIndex),
    diagnostics: std.ArrayList(BundlerDiagnostic),
    resolve_cache: *ResolveCache,
    /// 병렬 워커에서 diagnostics 접근 보호용 mutex
    diag_mutex: std.Thread.Mutex = .{},

    /// 패키지별 sideEffects 캐시. pkg_dir_path → SideEffects.
    /// 같은 패키지의 여러 모듈이 동일 package.json을 반복 읽지 않도록.
    side_effects_cache: std.StringHashMap(pkg_json.PackageJson.SideEffects),

    // DFS 상태
    exec_counter: u32 = 0,
    cycle_counter: u32 = 0,

    /// 파이프라인 단계별 타이밍 출력 (--timing)
    timing: bool = false,
    /// 확장자별 로더 오버라이드 (--loader:.png=file). bundler에서 전달.
    loader_overrides: []const types.LoaderOverride = &.{},
    /// 에셋/청크 URL prefix (--public-path). asset 로더에서 사용.
    public_path: []const u8 = "",
    /// 에셋 파일명 패턴 (--asset-names). asset 로더에서 사용.
    asset_names: []const u8 = "[name]-[hash]",
    /// 엔트리 포인트 기준 디렉토리. [dir] 패턴 치환에 사용.
    /// entry point들의 공통 부모 디렉토리 (esbuild --outbase에 해당).
    entry_dir: []const u8 = "",
    /// --inject 파일 목록. build()에서 모든 엔트리의 의존성으로 추가.
    inject_files: []const []const u8 = &.{},
    /// 플러그인 배열. bundler에서 전파.
    plugins: []const plugin_mod.Plugin = &.{},
    /// Flow 모드 강제 활성화 (--flow). bundler에서 전파.
    flow: bool = false,
    /// Worker 엔트리: new Worker(new URL(...)) 패턴에서 수집된 worker 파일 경로.
    /// 메인 그래프에는 모듈로 추가하지 않고, bundler에서 별도 빌드한다.
    worker_entries: std.ArrayList(WorkerEntry) = .empty,

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
            .side_effects_cache = std.StringHashMap(pkg_json.PackageJson.SideEffects).init(allocator),
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
        var se_it = self.side_effects_cache.valueIterator();
        while (se_it.next()) |se| se.deinit(self.allocator);
        self.side_effects_cache.deinit();
        self.diagnostics.deinit(self.allocator);
        for (self.worker_entries.items) |we| {
            self.allocator.free(we.resolved_path);
        }
        self.worker_entries.deinit(self.allocator);
    }

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
        for (entry_points) |entry_path| {
            _ = try self.addModule(entry_path);
        }

        var pool: std.Thread.Pool = undefined;
        const pool_ok = if (pool.init(.{ .allocator = self.allocator })) |_| true else |_| false;
        defer if (pool_ok) pool.deinit();

        var scan_timer: ?std.time.Timer = if (self.timing) std.time.Timer.start() catch null else null;

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

        if (self.timing) {
            if (scan_timer) |*t| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print(
                    \\  Graph scan: {d:.3} ms  ({d} modules, pool={s})
                    \\
                , .{
                    @as(f64, @floatFromInt(t.read())) / 1_000_000.0,
                    self.modules.items.len,
                    if (pool_ok) "yes" else "no",
                }) catch {};
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

        try self.finalizeGraph(entry_points);
    }

    /// Phase 2-4: DFS exec_index + ExportsKind 승격 + TLA 전파.
    /// build()와 buildIncremental() 양쪽에서 호출.
    fn finalizeGraph(self: *ModuleGraph, entry_points: []const []const u8) !void {
        const count = self.modules.items.len;
        if (count == 0) return;

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer visited.deinit();
        var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer in_stack.deinit();

        for (entry_points) |entry_path| {
            if (self.path_to_module.get(entry_path)) |idx| {
                try self.dfs(idx, &visited, &in_stack);
            }
        }

        self.promoteExportsKinds();
        self.propagateTopLevelAwait();
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
    ) !IncrementalBuildResult {
        // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용)
        if (self.entry_dir.len == 0 and entry_points.len > 0) {
            self.entry_dir = std.fs.path.dirname(entry_points[0]) orelse "";
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

        // 순차 처리 — 증분 빌드는 캐시 히트가 대부분이므로 스레드 풀 오버헤드보다 효율적.
        var parse_start: usize = 0;
        while (parse_start < self.modules.items.len) {
            const parse_end = self.modules.items.len;
            for (parse_start..parse_end) |i| {
                var mod = &self.modules.items[i];
                if (mod.state == .ready) continue; // disabled 모듈 등

                const mod_path = mod.path;
                const mtime = getMtime(mod_path) catch 0;

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
                    // parse_arena 소유권 이전: store → graph
                    cached.module.parse_arena = null;
                    mod.state = .ready;
                } else {
                    // 캐시 미스: 정상 파싱
                    self.parseModule(@enumFromInt(@as(u32, @intCast(i))));
                    self.applySideEffectsFromPackageJson(&self.modules.items[i]);
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

        try self.finalizeGraph(entry_points);

        return .{
            .graph_changed = graph_changed or reparsed.items.len > 0,
            .reparsed_indices = try reparsed.toOwnedSlice(self.allocator),
        };
    }

    /// 파일의 mtime을 나노초로 반환.
    pub fn getMtime(path: []const u8) !i128 {
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

        for (records, 0..) |record, rec_i| {
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

        // Plugin: load 훅 — 모든 module_type 분기 전에 플러그인에게 기회를 줌.
        // 플러그인이 내용을 반환하면 JS 모듈로 전환 (예: .css → JS export).
        if (self.plugins.len > 0) {
            const runner = plugin_mod.PluginRunner.init(self.plugins);
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
                module.parse_arena = tmp_arena;
                module.source = plugin_source;
                // module_type 분기를 건너뛰고 JS 파싱 경로로 직접 이동
                // (아래 "모듈별 Arena" 블록은 parse_arena가 이미 설정되어 있으므로 건너뜀)
            } else {
                tmp_arena.deinit();
            }
        }

        // JSON 모듈: 파싱 불필요, CJS로 래핑만
        if (module.module_type == .json) {
            module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
            const arena_alloc = module.parse_arena.?.allocator();
            module.source = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 10 * 1024 * 1024) catch "";
            module.exports_kind = .commonjs;
            module.wrap_kind = .cjs;
            module.state = .ready;
            return;
        }

        // Asset 로더: 파일을 읽어서 fake JS 모듈로 변환 (rolldown 방식)
        if (module.loader.isAsset()) {
            self.parseAssetModule(module);
            return;
        }

        if (module.module_type != .javascript) {
            module.state = .ready;
            return;
        }

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
        _ = parser.parse() catch {
            self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Parse failed", null);
            module.state = .ready;
            return;
        };

        if (parser.errors.items.len > 0) {
            self.addDiag(.parse_error, .warning, module.path, Span.EMPTY, .parse, "Parse completed with errors", null);
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
        const analyze_ok = if (analyzer.analyze()) |_| true else |_| false;

        // OOM 시 semantic = null로 유지 (부분 데이터로 linker가 오동작하는 것 방지)
        if (analyze_ok) {
            module.semantic = .{
                .symbols = analyzer.symbols.items,
                .scopes = analyzer.scopes.items,
                .scope_maps = analyzer.scope_maps.items,
                .exported_names = analyzer.exported_names,
                .symbol_ids = analyzer.symbol_ids.items,
                .unresolved_references = analyzer.unresolved_references,
                .ref_scope_pairs = analyzer.ref_scope_pairs.items,
            };
            // TLA 감지: semantic analyzer가 스코프 체인을 추적하며 정확히 판별
            module.uses_top_level_await = analyzer.has_top_level_await;
        }

        module.ast = parser.ast;
        module.line_offsets = scanner.line_offsets.items;

        // import/export 추출 (parse_arena — 스레드 안전, graph allocator 불필요)
        const scan_result = import_scanner.extractImportsWithCjsDetection(arena_alloc, &parser.ast) catch {
            module.state = .ready;
            return;
        };
        module.import_records = scan_result.records;

        module.exports_kind = determineExportsKind(scan_result, module.path);
        module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;

        module.import_bindings = binding_scanner_mod.extractImportBindings(arena_alloc, &parser.ast, scan_result.records) catch &.{};
        binding_scanner_mod.collectNamespaceAccesses(arena_alloc, &parser.ast, module.import_bindings) catch {};
        module.export_bindings = binding_scanner_mod.extractExportBindings(arena_alloc, &parser.ast, scan_result.records, module.import_bindings) catch &.{};

        module.state = .parsed;
    }

    /// 모듈 경로에서 node_modules/패키지/ 디렉토리 경로를 추출.
    /// 스코프 패키지 (@scope/name) 지원.
    fn findPackageDirPath(module_path: []const u8) ?[]const u8 {
        const nm = "node_modules" ++ std.fs.path.sep_str;
        const nm_pos = std.mem.lastIndexOf(u8, module_path, nm) orelse return null;
        const pkg_start = nm_pos + nm.len;
        var pkg_end = pkg_start;
        if (pkg_end < module_path.len and module_path[pkg_end] == '@') {
            if (std.mem.indexOfPos(u8, module_path, pkg_end, std.fs.path.sep_str)) |sep1| {
                pkg_end = std.mem.indexOfPos(u8, module_path, sep1 + 1, std.fs.path.sep_str) orelse module_path.len;
            } else pkg_end = module_path.len;
        } else {
            pkg_end = std.mem.indexOfPos(u8, module_path, pkg_start, std.fs.path.sep_str) orelse module_path.len;
        }
        return module_path[0..pkg_end];
    }

    /// node_modules 패키지의 package.json sideEffects 필드를 module.side_effects에 반영.
    fn applySideEffectsFromPackageJson(self: *ModuleGraph, module: *Module) void {
        const pkg_dir_path = findPackageDirPath(module.path) orelse return;

        // 캐시 확인 — 같은 패키지의 package.json을 반복 읽지 않음
        if (self.side_effects_cache.get(pkg_dir_path)) |cached| {
            switch (cached) {
                .all => |val| module.side_effects = val,
                .patterns => |patterns| {
                    module.side_effects = matchSideEffectsPatterns(module.path, pkg_dir_path, patterns);
                },
                .unknown => {},
            }
            return;
        }

        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return;
        defer pkg_dir.close();

        var parsed = pkg_json.parsePackageJson(self.allocator, pkg_dir) catch return;
        defer parsed.deinit();

        // 캐시에 저장 (patterns는 parseSideEffects가 allocator로 dupe 완료)
        const se = parsed.pkg.side_effects;
        self.side_effects_cache.put(pkg_dir_path, se) catch {};
        // 소유권을 캐시로 이전했으므로 parsed.deinit()에서 이중 해제 방지
        parsed.pkg.side_effects = .unknown;

        switch (se) {
            .all => |val| module.side_effects = val,
            .patterns => |patterns| {
                module.side_effects = matchSideEffectsPatterns(module.path, pkg_dir_path, patterns);
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

        for (records, 0..) |record, rec_i| {
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

    /// ExportsKind.none 모듈을 소비하는 쪽에 따라 승격한다.
    /// - 다른 모듈이 `import`하면 → .esm
    /// - 다른 모듈이 `require()`하면 → .commonjs + wrap_kind = .cjs
    /// 모든 모듈의 import_records를 순회하여, 대상 모듈이 .none이면 승격.
    /// require가 import보다 우선: 이미 .esm으로 승격된 모듈도 require가 있으면 .commonjs로 변경.
    fn promoteExportsKinds(self: *ModuleGraph) void {
        for (self.modules.items) |m| {
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= self.modules.items.len) continue;

                var target = &self.modules.items[target_idx];

                if (rec.kind == .require) {
                    // require()로 소비 → CJS로 승격 (이미 ESM으로 승격된 것도 덮어씀, esbuild 동작)
                    if (target.exports_kind == .none or target.exports_kind == .esm) {
                        target.exports_kind = .commonjs;
                        target.wrap_kind = .cjs;
                    }
                    // JSON 모듈이 CJS require()로 참조되면 마킹.
                    // emitter가 ESM 포맷에서 scope-hoist vs __commonJS 래핑을 결정할 때 사용.
                    if (target.module_type == .json) {
                        target.has_cjs_importer = true;
                    }
                } else if (rec.kind == .static_import or rec.kind == .side_effect or rec.kind == .re_export) {
                    // ESM import로 소비 → .none이면 승격
                    if (target.exports_kind == .none) {
                        // node_modules 내 .js 파일이 ESM/CJS 신호 없으면 CJS로 간주 (Node.js 기본값)
                        // package.json "type": "module"인 경우만 ESM
                        if (self.isImplicitCjs(target)) {
                            target.exports_kind = .commonjs;
                            target.wrap_kind = .cjs;
                        } else {
                            target.exports_kind = .esm;
                        }
                    }
                }
            }
        }
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
    fn isPackageTypeModule(self: *ModuleGraph, module_path: []const u8) bool {
        const pkg_dir_path = findPackageDirPath(module_path) orelse return false;
        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return false;
        defer pkg_dir.close();
        var parsed = pkg_json.parsePackageJson(self.allocator, pkg_dir) catch return false;
        defer parsed.deinit();
        return parsed.pkg.isModule();
    }

    /// TLA 전이적 전파: TLA 모듈을 static import하는 모듈도 TLA로 표시.
    /// await가 포함된 모듈의 실행이 완료되기 전에 이를 import하는 모듈이
    /// 실행될 수 없으므로, import하는 쪽도 TLA로 간주해야 한다.
    /// 동적 import는 비동기이므로 전파하지 않는다.
    fn propagateTopLevelAwait(self: *ModuleGraph) void {
        var changed = true;
        var iteration: u32 = 0;
        while (changed and iteration < 100) : (iteration += 1) {
            changed = false;
            for (self.modules.items) |*m| {
                if (m.uses_top_level_await) continue;
                for (m.import_records) |rec| {
                    if (rec.resolved.isNone()) continue;
                    // 동적 import는 비동기 → TLA 전파 불필요
                    if (rec.kind != .static_import and rec.kind != .side_effect and rec.kind != .re_export) continue;
                    const target_idx = @intFromEnum(rec.resolved);
                    if (target_idx >= self.modules.items.len) continue;
                    if (self.modules.items[target_idx].uses_top_level_await) {
                        m.uses_top_level_await = true;
                        changed = true;
                        break;
                    }
                }
            }
        }
    }

    /// Asset 로더 모듈을 파싱한다.
    /// 파일을 읽어서 로더 타입에 따라 fake JS 소스를 생성하고,
    /// module_type을 .javascript로 바꿔서 기존 파이프라인을 그대로 탄다.
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
                module.source = std.fmt.allocPrint(arena_alloc, "__toBinary(\"{s}\")", .{encoded}) catch {
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

                module.asset_data = .{
                    .raw_content = raw,
                    .content_hash = hash,
                    .output_name = output_name,
                    .ext = ext,
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

/// 파일 내용의 content hash (Wyhash → 16진수 8자리).
/// emitter.zig의 content hash와 동일 알고리즘 (Wyhash + 32-bit truncate).
fn contentHash(data: []const u8) [8]u8 {
    const hash_val = std.hash.Wyhash.hash(0, data);
    var buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>8}", .{@as(u32, @truncate(hash_val))}) catch unreachable;
    return buf;
}

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
