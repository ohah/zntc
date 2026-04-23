//! 모듈 파싱 캐시 — 증분 빌드용
//!
//! 변경 안 된 모듈의 파싱 결과(AST, semantic, import_records 등)를
//! 빌드 간 보존하여 재파싱을 스킵한다.
//! Module.parse_arena가 데이터를 소유하므로, arena 소유권 이전으로 캐시를 구현.

const std = @import("std");
const Module = @import("module.zig").Module;
const types = @import("types.zig");

pub const PersistentModuleStore = struct {
    allocator: std.mem.Allocator,
    /// 절대 경로 → 캐시된 모듈. 경로 키는 store allocator 소유.
    modules: std.StringHashMap(CachedModule),

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
            .modules = std.StringHashMap(CachedModule).init(allocator),
        };
    }

    pub fn deinit(self: *PersistentModuleStore) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.freeCachedModule(entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.modules.deinit();
    }

    fn freeCachedModule(self: *PersistentModuleStore, cached: *CachedModule) void {
        // parse_arena / alias_table 가 아직 store 에 있으면 해제.
        if (cached.module.parse_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        if (cached.module.alias_table) |*t| t.deinit();
        // dependencies/importers/dynamic_imports ArrayList 해제
        cached.module.dependencies.deinit(self.allocator);
        cached.module.importers.deinit(self.allocator);
        cached.module.dynamic_imports.deinit(self.allocator);
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

        // 기존 캐시가 있으면 제거
        const had_existing = self.modules.contains(path);
        if (had_existing) {
            if (self.modules.getPtr(path)) |old| {
                self.freeCachedModule(old);
            }
        }

        // Module 복사 — parse_arena 소유권 이전
        var cached_module = module.*;
        // dependencies/importers/dynamic_imports를 빈 상태로 — graph deinit에서 원본이 해제되므로
        cached_module.dependencies = .empty;
        cached_module.importers = .empty;
        cached_module.dynamic_imports = .empty;

        // parse_arena / alias_table 소유권 이전: module → store.
        // alias_table 은 AliasTable struct (ArrayList backing) 로 graph module 과
        // store 가 shallow copy 로 backing 을 공유한다. graph.deinit 이 먼저 free 하면
        // store 의 복사본이 dangling pointer 로 남고, 다음 rebuild cache-hit 에서
        // 그 포인터를 통해 setCanonicalName 이 uaf 쓰기를 해 임의의 heap 영역
        // (특히 nested_name_sets HashMap backing 의 Header.capacity) 을 덮어쓴다.
        module.parse_arena = null;
        module.alias_table = null;

        if (had_existing) {
            // 기존 키 재사용 — put은 값만 업데이트
            self.modules.put(path, .{
                .mtime = mtime,
                .module = cached_module,
                .import_specifiers = specs,
            }) catch {
                if (cached_module.parse_arena) |a| {
                    a.deinit();
                    self.allocator.destroy(a);
                }
                if (cached_module.alias_table) |*t| t.deinit();
                for (specs) |s| self.allocator.free(s);
                self.allocator.free(specs);
            };
        } else {
            const key = self.allocator.dupe(u8, path) catch {
                if (cached_module.parse_arena) |a| {
                    a.deinit();
                    self.allocator.destroy(a);
                }
                if (cached_module.alias_table) |*t| t.deinit();
                for (specs) |s| self.allocator.free(s);
                self.allocator.free(specs);
                return;
            };

            self.modules.put(key, .{
                .mtime = mtime,
                .module = cached_module,
                .import_specifiers = specs,
            }) catch {
                self.allocator.free(key);
                if (cached_module.parse_arena) |a| {
                    a.deinit();
                    self.allocator.destroy(a);
                }
                if (cached_module.alias_table) |*t| t.deinit();
                for (specs) |s| self.allocator.free(s);
                self.allocator.free(specs);
            };
        }
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

    // build 1 end: store 로 소유권 이전.
    store.putModule("/virtual/mod.ts", &module, 1);
    try testing.expect(module.alias_table == null); // graph 는 더이상 소유하지 않음

    // graph.deinit 시뮬레이션 — alias_table 이 null 이므로 deinit 이 no-op 이어야 함.
    module.deinit(allocator);

    // build 2: cache-hit — store 에서 graph 로 소유권 환원.
    const cached = store.getIfFresh("/virtual/mod.ts", 1) orelse return error.CacheMiss;
    var mod2 = Module.init(@enumFromInt(0), "/virtual/mod.ts");
    const saved_deps = mod2.dependencies;
    const saved_importers = mod2.importers;
    const saved_dynamic = mod2.dynamic_imports;
    mod2 = cached.module;
    mod2.dependencies = saved_deps;
    mod2.importers = saved_importers;
    mod2.dynamic_imports = saved_dynamic;
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
