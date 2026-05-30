//! 모듈 파싱 캐시 — 증분 빌드용
//!
//! 변경 안 된 모듈의 파싱 결과(AST, semantic, import_records 등)를
//! 빌드 간 보존하여 재파싱을 스킵한다.
//! Module.parse_arena가 데이터를 소유하므로, arena 소유권 이전으로 캐시를 구현.

const std = @import("std");
const Module_mod = @import("module.zig");
const Module = Module_mod.Module;
const PathRef = Module_mod.PathRef;
const CachedResolvedDep = Module_mod.CachedResolvedDep;
const types = @import("types.zig");

/// (#3755) putModule clone OOM rollback helper. 이미 .owned 로 변환된 partial
/// slot 들의 alloc 을 free + shared backing 이 graph 쪽 module 과 공유라는 점을 고려해
/// .specifier="" (PathRef.deinit no-op variant) 로 sanitize. 그렇지 않으면 graph
/// 쪽 module.deinit 가 같은 freed slice 를 또 free → double-free.
///
/// **Caller invariant**: `transferModulesToStore` (유일한 caller) 는 putModule 호출
/// 후 module.resolved_deps 를 다시 사용하지 않는다 (loop 다음은 graph.deinit). 그러므로
/// sanitize 된 .specifier="" 가 caller-visible silent corruption 으로 표면화하지 않음.
fn rollbackOomCloned(items: []CachedResolvedDep, allocator: std.mem.Allocator) void {
    for (items) |*dep| {
        dep.path.deinit(allocator);
        if (dep.resolve_dir) |rd| rd.deinit(allocator);
        dep.path = .{ .specifier = "" };
        dep.resolve_dir = null;
    }
}

/// PR #3749 Phase 3 (C): cache-borrowed PathRef 를 store-owned 로 clone.
/// - `.interned`: path_pool (cache) 소유 — cache deinit 시 dangling 위험 → clone.
/// - `.specifier`: parse_arena 소유 — parse_arena 가 store 로 양도되어 store 와 같은
///   lifetime → clone 안 함.
/// - `.owned`: 이미 자체 owner → clone 안 함.
/// **명시 enumeration** (M3): 새 PathRef variant 추가 시 compile error 로 결정 강제.
/// 새 variant default 정책: lifetime < store 면 clone, lifetime >= store 면 pass-through.
fn clonePathRefIfNeeded(allocator: std.mem.Allocator, ref: PathRef) !PathRef {
    return switch (ref) {
        .interned => |s| .{ .owned = try allocator.dupe(u8, s) },
        .specifier, .owned => ref,
    };
}

pub const PersistentModuleStore = struct {
    allocator: std.mem.Allocator,
    /// 절대 경로 → 캐시된 모듈. 경로 키는 store allocator 소유.
    modules: std.StringHashMapUnmanaged(CachedModule) = .empty,

    pub const CachedModule = struct {
        /// 캐싱 시점의 파일 mtime (i128 나노초)
        mtime: i128,
        /// Module 구조체. parse_arena 포함.
        /// store가 소유 — graph에 주입 시 parse_arena 소유권을 이전하고 null로 설정.
        module: Module,
        /// import specifier 목록 (store allocator 소유). import 변경 감지용.
        import_specifiers: []const []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) PersistentModuleStore {
        return .{
            .allocator = allocator,
            .modules = .empty,
        };
    }

    pub fn deinit(self: *PersistentModuleStore) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.freeCachedModule(entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.modules.deinit(self.allocator);
    }

    fn freeCachedModule(self: *PersistentModuleStore, cached: *CachedModule) void {
        for (cached.module.import_records) |record| {
            if (record.kind == .require_context) {
                if (record.context_matches) |matches| {
                    for (matches) |s| self.allocator.free(s);
                    self.allocator.free(matches);
                }
            }
        }
        // parse_arena / alias_table 가 아직 store 에 있으면 해제.
        if (cached.module.parse_arena) |arena| Module_mod.destroyParseArena(self.allocator, arena);
        if (cached.module.alias_table) |*t| t.deinit();
        if (cached.module.export_index_by_name) |*m| m.deinit(self.allocator);
        // dependencies/importers/dynamic_imports/dynamic_importers ArrayList 해제
        cached.module.dependencies.deinit(self.allocator);
        cached.module.importers.deinit(self.allocator);
        cached.module.dynamic_imports.deinit(self.allocator);
        cached.module.dynamic_importers.deinit(self.allocator);
        if (cached.module.resolve_dir) |dir| self.allocator.free(dir);
        for (cached.module.resolved_deps.items) |dep| {
            dep.path.deinit(self.allocator);
            if (dep.resolve_dir) |dir| dir.deinit(self.allocator);
        }
        cached.module.resolved_deps.deinit(self.allocator);
        // import_specifiers 해제
        for (cached.import_specifiers) |s| self.allocator.free(s);
        self.allocator.free(cached.import_specifiers);
    }

    /// 캐시에서 모듈을 조회. mtime이 일치하면 캐시 히트.
    pub fn getIfFresh(self: *PersistentModuleStore, path: []const u8, current_mtime: i128) ?*CachedModule {
        const cached = self.modules.getPtr(path) orelse return null;
        if (cached.mtime != current_mtime) return null;
        return cached;
    }

    /// 빌드 완료 후 모듈을 캐시에 저장.
    /// Module의 parse_arena 소유권을 store로 이전 (Module.parse_arena = null 설정).
    pub fn putModule(self: *PersistentModuleStore, path: []const u8, module: *Module, mtime: i128) void {
        // import specifiers 복제 (store allocator 소유)
        const specs = self.extractImportSpecifiers(module) catch return;

        // 기존 캐시가 있으면 제거. (#3755 sweep) freeCachedModule 가 contents 만 free
        // 하므로 entry 자체는 그대로 — 다음 단계에서 map.put 으로 *값* 만 update.
        // OOM rollback 으로 put 에 도달 못하면 entry 가 dangling 으로 남기 때문에
        // rollback 분기에서 반드시 `modules.remove(path)` 호출 필요.
        const had_existing = self.modules.contains(path);
        if (had_existing) {
            if (self.modules.getPtr(path)) |old| {
                self.freeCachedModule(old);
            }
        }

        // Module 복사 — parse_arena 소유권 이전
        var cached_module = module.*;
        // dependencies/importers/dynamic_imports/dynamic_importers를 빈 상태로 —
        // graph deinit에서 원본이 해제되므로 store에 shallow copy를 남기면 안 된다.
        cached_module.dependencies = .empty;
        cached_module.importers = .empty;
        cached_module.dynamic_imports = .empty;
        cached_module.dynamic_importers = .empty;

        // PR #3749 Phase 3 (C): cache-borrowed path 를 store-owned 로 clone.
        // - .interned: cache (path_pool) 가 build 종료 시 deinit (per-build Bundler) →
        //   store 가 *자체 owner* 가 되어야 dangling 안 됨.
        // - .specifier (parse_arena), .owned (자체) 는 store 와 같은 lifetime → clone 안 함.
        // (plugin 경로의 .plugin variant 는 #3761 후 production 미사용 → 본 PR 에서 제거.)
        //
        // H1 fix: OOM 시 swallow 금지. rollback 은 (1) partial-cloned slot sanitize
        // (rollbackOomCloned) + (2) had_existing dangling map entry 제거 + specs leak
        // 차단 (abortPutModule).
        // (#3755) shared backing 주의: `cached_module = module.*` shallow copy 라
        // `cached_module.resolved_deps.items` 가 `module.resolved_deps.items` 와 같은
        // 백킹을 가리킨다. clone 루프가 `dep.path = new_path` 로 element 를 mutate 하면
        // graph 쪽 module 도 함께 .owned 로 바뀐다. OOM 시 rollback 가 그 .owned 를 free
        // 해도 graph 쪽 module 에 그대로 dangling 으로 남아 graph.deinit 가 같은 슬라이스
        // 를 또 free → double-free.
        //
        // Fix: rollback 시 해당 슬롯을 `.specifier = ""` (PathRef.deinit no-op variant)
        // 로 sanitize. graph 쪽 module.deinit 의 `dep.path.deinit(allocator)` 는 .specifier
        // 분기라 free 안 함. resolve_dir 도 null 로.
        for (cached_module.resolved_deps.items, 0..) |*dep, i| {
            const new_path = clonePathRefIfNeeded(self.allocator, dep.path) catch {
                rollbackOomCloned(cached_module.resolved_deps.items[0..i], self.allocator);
                self.abortPutModule(path, had_existing, specs);
                return;
            };
            const new_rd = if (dep.resolve_dir) |rd|
                clonePathRefIfNeeded(self.allocator, rd) catch {
                    new_path.deinit(self.allocator);
                    rollbackOomCloned(cached_module.resolved_deps.items[0..i], self.allocator);
                    self.abortPutModule(path, had_existing, specs);
                    return;
                }
            else
                null;
            dep.path = new_path;
            dep.resolve_dir = new_rd;
        }
        // #3664: implicitlyLoadedAfterOneOf 양방향 관계 리스트도 ModuleIndex ArrayList backing 을
        // graph module 과 공유 → 위 4개와 동일하게 store 복사본은 빈 상태로(graph deinit 이 원본
        // 해제, store 가 dangling 안 되도록). 다음 rebuild 의 injectEmittedChunks 가 재구성.
        cached_module.implicitly_loaded_after_one_of = .empty;
        cached_module.implicitly_loaded_before = .empty;

        // parse_arena / alias_table 소유권 이전: module → store.
        // alias_table 은 AliasTable struct (ArrayList backing) 로 graph module 과
        // store 가 shallow copy 로 backing 을 공유한다. graph.deinit 이 먼저 free 하면
        // store 의 복사본이 dangling pointer 로 남고, 다음 rebuild cache-hit 에서
        // 그 포인터를 통해 setCanonicalName 이 uaf 쓰기를 해 임의의 heap 영역
        // (특히 nested_name_sets HashMap backing 의 Header.capacity) 을 덮어쓴다.
        module.parse_arena = null;
        module.resolve_dir = null;
        module.alias_table = null;
        // export_index_by_name (PR-Y1) 도 alias_table 와 동일 ownership 이전 패턴 —
        // shallow copy 라 양쪽이 같은 HashMap backing 가리킴, graph.deinit 이 free 하면
        // store 쪽 dangling. ownership 을 store 로 이전 (graph 쪽 nullify).
        module.export_index_by_name = null;
        // PR #3738: namespace_access_index 도 동일 — parse_arena 안 HashMap backing 이라
        // arena 양도 시 store 쪽이 (arena, index) 짝 소유. graph 쪽 dangling 방지.
        module.namespace_access_index = null;
        module.import_records = &.{};
        module.resolved_deps = .empty;

        if (had_existing) {
            // 기존 키 재사용 — put은 값만 업데이트
            self.modules.put(self.allocator, path, .{
                .mtime = mtime,
                .module = cached_module,
                .import_specifiers = specs,
            }) catch {
                var orphan: CachedModule = .{ .mtime = mtime, .module = cached_module, .import_specifiers = specs };
                self.freeCachedModule(&orphan);
            };
        } else {
            const key = self.allocator.dupe(u8, path) catch {
                var orphan: CachedModule = .{ .mtime = mtime, .module = cached_module, .import_specifiers = specs };
                self.freeCachedModule(&orphan);
                return;
            };

            self.modules.put(self.allocator, key, .{
                .mtime = mtime,
                .module = cached_module,
                .import_specifiers = specs,
            }) catch {
                self.allocator.free(key);
                var orphan: CachedModule = .{ .mtime = mtime, .module = cached_module, .import_specifiers = specs };
                self.freeCachedModule(&orphan);
            };
        }
    }

    /// (#3755 sweep) putModule rollback 통합 cleanup. 다음 두 P0 시나리오 차단:
    /// 1) had_existing 케이스에서 freeCachedModule(old) 만 했고 map.remove 안 했으면
    ///    dangling CachedModule entry — 다음 getIfFresh UAF + 다음 putModule 의 freeCachedModule 가
    ///    이미 freed 메모리 또 free → double-free. fetchRemove 로 key 까지 회수.
    /// 2) specs (extractImportSpecifiers 결과) 가 N dupe + 1 slice alloc 인데 rollback
    ///    early return 으로 free 안 됨 → 매 OOM 마다 누적 leak.
    fn abortPutModule(self: *PersistentModuleStore, path: []const u8, had_existing: bool, specs: []const []const u8) void {
        if (had_existing) {
            if (self.modules.fetchRemove(path)) |kv| {
                self.allocator.free(kv.key);
            }
        }
        for (specs) |s| self.allocator.free(s);
        self.allocator.free(specs);
    }

    fn extractImportSpecifiers(self: *PersistentModuleStore, module: *const Module) ![]const []const u8 {
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (list.items) |s| self.allocator.free(s);
            list.deinit(self.allocator);
        }
        for (module.import_records) |rec| {
            const dupe = try self.allocator.dupe(u8, rec.specifier);
            try list.append(self.allocator, dupe);
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// 캐시된 모듈의 import specifiers가 새 모듈과 동일한지 확인.
    pub fn importsChanged(_: *const PersistentModuleStore, cached: *const CachedModule, new_module: *const Module) bool {
        if (cached.import_specifiers.len != new_module.import_records.len) return true;
        for (cached.import_specifiers, new_module.import_records) |old_spec, new_rec| {
            if (!std.mem.eql(u8, old_spec, new_rec.specifier)) return true;
        }
        return false;
    }
};

// ── tests ─────────────────────────────────────────────────────

const symbol_mod = @import("symbol.zig");

// Regression: `putModule` 이 `module.alias_table = null` 로 ownership 을 store
// 로 넘기고, cache-hit 시 graph 가 ownership 을 가져간 뒤 다시 putModule 로 돌아오는
// 왕복에서 double-free / UAF 가 없어야 한다.
//
// 과거 버그: graph 쪽 `Module.deinit` 이 `alias_table.deinit` 을 호출한 뒤에도
// store 측 `cached_module.alias_table` 이 같은 backing 을 가리켜 dangling pointer
// 발생 → 다음 rebuild 의 `setCanonicalName` 이 해제된 메모리에 쓰면서 heap 오염
// (nested_name_sets HashMap Header.capacity 를 덮어써 `Linker.deinit` 에서 malloc
// abort). GPA 의 double-free 검출로 이 테스트는 수정 전 반드시 실패한다.
test "PersistentModuleStore: alias_table ownership 왕복 (rebuild 2회)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = PersistentModuleStore.init(allocator);
    defer store.deinit();

    // build 1: graph 가 새 module 을 만든다
    var module = Module.init(@enumFromInt(0), "/virtual/mod.ts");
    module.alias_table = symbol_mod.AliasTable.init(allocator);
    _ = try module.alias_table.?.declare("foo");
    _ = try module.alias_table.?.declare("bar");
    try module.dynamic_importers.append(allocator, @enumFromInt(1));

    // build 1 end: store 로 소유권 이전.
    store.putModule("/virtual/mod.ts", &module, 1);
    try testing.expect(module.alias_table == null); // graph 는 더이상 소유하지 않음
    try testing.expectEqual(@as(usize, 0), store.modules.getPtr("/virtual/mod.ts").?.module.dynamic_importers.items.len);

    // graph.deinit 시뮬레이션 — alias_table 이 null 이므로 deinit 이 no-op 이어야 함.
    module.deinit(allocator);

    // build 2: cache-hit — store 에서 graph 로 소유권 환원.
    const cached = store.getIfFresh("/virtual/mod.ts", 1) orelse return error.CacheMiss;
    var mod2 = Module.init(@enumFromInt(0), "/virtual/mod.ts");
    const saved_deps = mod2.dependencies;
    const saved_importers = mod2.importers;
    const saved_dynamic = mod2.dynamic_imports;
    const saved_dynamic_importers = mod2.dynamic_importers;
    mod2 = cached.module;
    mod2.dependencies = saved_deps;
    mod2.importers = saved_importers;
    mod2.dynamic_imports = saved_dynamic;
    mod2.dynamic_importers = saved_dynamic_importers;
    cached.module.parse_arena = null;
    cached.module.alias_table = null;
    try testing.expect(mod2.alias_table != null);
    try testing.expectEqual(@as(u32, 2), mod2.alias_table.?.count());

    // build 2 에서 alias_table 을 조작 (과거 버그는 여기서 UAF 쓰기 발생).
    const id = try mod2.alias_table.?.declare("baz");
    mod2.alias_table.?.setCanonicalName(id, "baz$2");

    // build 2 end: 다시 store 로 이전.
    store.putModule("/virtual/mod.ts", &mod2, 2);
    try testing.expect(mod2.alias_table == null);

    mod2.deinit(allocator);

    // 재조회해 데이터가 살아있는지 확인.
    const cached2 = store.getIfFresh("/virtual/mod.ts", 2) orelse return error.CacheMiss;
    try testing.expect(cached2.module.alias_table != null);
    try testing.expectEqual(@as(u32, 3), cached2.module.alias_table.?.count());
}

// Regression #2694: 가상 모듈 (mtime=0) 이 cache-hit 으로 store ↔ graph 왕복할 때
// 다음 rebuild 의 첫 alloc 이 panic 하지 않아야 한다. 과거에는 `parse_arena` 가
// `?ArenaAllocator` (value) 라 putModule/getIfFresh 의 struct copy 가 buffer_list 의
// first BufNode 를 두 위치에서 공유해 한쪽 deinit 이후 다른 쪽이 dangling 포인터로
// alloc 시 `start index 16 is larger than end index 0` panic.
test "PersistentModuleStore: parse_arena ownership 왕복 후 alloc 정상 (#2694)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var store = PersistentModuleStore.init(allocator);
    defer store.deinit();

    var module = Module.init(@enumFromInt(0), "\x00zntc:runtime/extends");
    module.parse_arena = Module_mod.createParseArena(allocator) orelse return error.OutOfMemory;
    // 첫 빌드에서 arena 에 alloc — buffer_list 에 BufNode 등록.
    _ = try module.parse_arena.?.allocator().alloc(u8, 256);

    store.putModule("\x00zntc:runtime/extends", &module, 1);
    try testing.expect(module.parse_arena == null);
    module.deinit(allocator);

    // build 2: cache-hit. graph 가 ownership 환수.
    const cached = store.getIfFresh("\x00zntc:runtime/extends", 1) orelse return error.CacheMiss;
    var mod2 = Module.init(@enumFromInt(0), "\x00zntc:runtime/extends");
    const saved_deps = mod2.dependencies;
    const saved_importers = mod2.importers;
    mod2 = cached.module;
    mod2.dependencies = saved_deps;
    mod2.importers = saved_importers;
    cached.module.parse_arena = null;
    cached.module.alias_table = null;

    // 두 번째 빌드 emit 단계의 fold pass 가 ast.allocator (= parse_arena) 로 새 노드
    // 푸시하는 시나리오. 과거에는 buffer_list 의 first 가 dangling 이라 panic.
    try testing.expect(mod2.parse_arena != null);
    const buf2 = try mod2.parse_arena.?.allocator().alloc(u8, 512);
    try testing.expectEqual(@as(usize, 512), buf2.len);

    store.putModule("\x00zntc:runtime/extends", &mod2, 2);
    mod2.deinit(allocator);
}

// Regression #3755: putModule OOM rollback 시 cached_module = module.* shallow copy 의
// resolved_deps shared backing 에 partial-cloned .owned 슬라이스가 남아 graph.deinit
// (= 여기 module.deinit) 에서 double-free.
//
// 시나리오:
//   1) module.resolved_deps 에 .interned variant N 개 등록.
//   2) FailingAllocator 로 N 번째 clone 에서 OOM 유도.
//   3) putModule 의 rollback 이 items[0..K] 의 .owned 를 free.
//   4) 과거 버그: module.resolved_deps.items[0..K] 가 같은 backing 이라 .owned (freed)
//      를 그대로 가리킴 → 이어지는 module.deinit 가 또 .deinit 호출 → double-free.
//   Fix: rollback 시 해당 슬롯을 .specifier="" (no-op variant) 로 덮어 graph 쪽이
//        free 시도하지 않도록 sanitize.
test "PersistentModuleStore: putModule OOM rollback double-free 차단 (#3755)" {
    const testing = std.testing;

    // FailingAllocator — extractImportSpecifiers (import_records 비어 alloc 0) + clone
    // 0/1 성공 후 clone 2 (= 3번째 dupe) 에서 OOM. rollback 가 items[0..1] free.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    const alloc = failing.allocator();

    var store = PersistentModuleStore.init(alloc);
    defer store.deinit();

    var module = Module.init(@enumFromInt(0), "/virtual/oom.ts");
    // resolved_deps 3개를 .interned variant 로 등록 — clone 시 .owned 로 변환 시도.
    // FailingAllocator 가 중간에서 OOM → rollback 실행.
    var deps: std.ArrayListUnmanaged(CachedResolvedDep) = .empty;
    defer module.deinit(testing.allocator); // ← 의도된 free path. double-free 면 GPA panic.
    // module 의 backing 은 testing.allocator (graph) 가 책임 — Module.init 의 default
    // ArrayList 는 unmanaged 이므로 caller alloc 선택.
    try deps.append(testing.allocator, .{ .kind = .static_import, .target = .file, .path = .{ .interned = "a/b" } });
    try deps.append(testing.allocator, .{ .kind = .static_import, .target = .file, .path = .{ .interned = "c/d" } });
    try deps.append(testing.allocator, .{ .kind = .static_import, .target = .file, .path = .{ .interned = "e/f" } });
    module.resolved_deps = deps;

    // OOM 가 putModule 안에서 발생해도 panic/crash 없이 return — graph 쪽 deinit 안전.
    store.putModule("/virtual/oom.ts", &module, 1);

    // module.resolved_deps.items 는 sanitize 되어 .specifier 또는 .interned 만 남아
    // module.deinit 의 dep.path.deinit 가 no-op. (.owned 였다면 freed slice 재 free).
    // sweep review: 단순 .owned 부재만이 아닌 *positive content* 검증 — 알로케이터 instrumentation
    // 비의존 회귀 검출.
    try testing.expect(module.resolved_deps.items[0].path == .specifier);
    try testing.expectEqual(@as(usize, 0), module.resolved_deps.items[0].path.specifier.len);
    try testing.expect(module.resolved_deps.items[1].path == .specifier);
    try testing.expectEqual(@as(usize, 0), module.resolved_deps.items[1].path.specifier.len);
    // i=2 슬롯은 clone 이 OOM 으로 mutate 전 → 원본 .interned 그대로 유지.
    try testing.expect(module.resolved_deps.items[2].path == .interned);
    try testing.expectEqualStrings("e/f", module.resolved_deps.items[2].path.interned);
    // module.deinit 는 defer 에서 호출 — double-free 발생 시 testing.allocator 가 패닉.
}

// Regression #3755 sweep: had_existing 경로 + clone OOM rollback 조합 시 map 에 dangling
// CachedModule entry 가 남는다. 다음 getIfFresh 가 freed 메모리 반환 → UAF.
test "PersistentModuleStore: putModule had_existing + OOM rollback 시 map entry 제거 (#3755)" {
    const testing = std.testing;

    var store = PersistentModuleStore.init(testing.allocator);
    defer store.deinit();

    // 첫 putModule — 정상 저장 (deps 없이).
    var mod1 = Module.init(@enumFromInt(0), "/virtual/oom-had-existing.ts");
    defer mod1.deinit(testing.allocator);
    store.putModule("/virtual/oom-had-existing.ts", &mod1, 1);
    try testing.expect(store.modules.contains("/virtual/oom-had-existing.ts"));

    // 두번째 putModule — had_existing=true, clone loop 에서 OOM 유도. FailingAllocator 는
    // alloc 만 fail injection 하고 free 는 underlying (testing.allocator) 로 passthrough
    // 이므로, store.allocator 만 mid-test swap 해도 ledger 일관성 유지.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const orig_alloc = store.allocator;
    store.allocator = failing.allocator();
    defer store.allocator = orig_alloc; // deinit 도 testing.allocator 로 free 일관.

    var mod2 = Module.init(@enumFromInt(0), "/virtual/oom-had-existing.ts");
    var deps2: std.ArrayListUnmanaged(CachedResolvedDep) = .empty;
    defer mod2.deinit(testing.allocator);
    try deps2.append(testing.allocator, .{ .kind = .static_import, .target = .file, .path = .{ .interned = "x/y" } });
    mod2.resolved_deps = deps2;
    // 이 putModule 안: extractImportSpecifiers (empty import_records → 0 alloc),
    // freeCachedModule(old) (alloc 0, free 만), cached_module = module.* (0 alloc),
    // clone loop 첫 iter dupe → fail_index=0 OOM → rollback 분기 → abortPutModule.
    store.putModule("/virtual/oom-had-existing.ts", &mod2, 2);
    // 핵심 검증: rollback 가 map.remove 를 수행해 dangling entry 제거.
    try testing.expect(!store.modules.contains("/virtual/oom-had-existing.ts"));
}

// H2/.plugin OOM rollback test 들은 `.plugin` variant 제거 (production unused) 와 함께
// 삭제 — `.interned` 케이스는 위 #3755 의 첫 OOM rollback test 가 이미 동일하게 커버.
// rollbackOomCloned 는 PathRef variant 무관 (PathRef.deinit 호출 일관).
