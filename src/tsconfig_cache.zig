//! tsconfig autodiscover walk 결과 per-process 캐시 (#2367).
//!
//! `TsConfig.autodiscoverFromEntry` 가 entry 의 부모 디렉토리부터 fs root 까지
//! `cwd.access(...)` syscall 로 walk 하므로 같은 workspace 안의 다수 파일을
//! in-process 반복 transpile 시 같은 답을 매번 재계산. 본 캐시는 NAPI consumer
//! (Vite/Rollup plugin 등) 가 인스턴스 1 회 생성해 transform 호출들에 재사용 →
//! file 당 5–10 fs syscall 제거.
//!
//! 디자인은 rolldown `TsconfigCache` (`reference/rolldown/.../transform_cache.rs`)
//! 와 정합 — `FxDashMap<PathBuf, Arc<TsConfig>>` 의 ZNTC 변형. 본 1차 구현은
//! _walk 결과만_ 캐시 (entry_dir → tsconfig_path). parse 결과 캐시는 후속 개선
//! 여지로 남김 (OS page cache 가 같은 file 의 fs read 비용을 작게 만들기 때문).
//!
//! Thread safety: NAPI 가 worker thread 에서 호출 가능 → Mutex 보호. 내부 string
//! 은 arena 소유 — clear() 시 arena reset 으로 일괄 해제.

const std = @import("std");
const TsConfig = @import("config.zig").TsConfig;

pub const TsconfigCache = struct {
    /// HashMap 컨테이너 자체 할당용 — arena reset 의 영향 안 받음.
    parent_alloc: std.mem.Allocator,
    /// 내부 string (entry_dir, tsconfig_path) 만 arena 소유. clear() 시 reset.
    arena: std.heap.ArenaAllocator,
    /// entry_dir (arena-owned) → tsconfig_path (arena-owned) 또는 null (no tsconfig found).
    /// "찾았다" 와 "없음 확정" 을 구분하기 위해 optional.
    by_entry_dir: std.StringHashMapUnmanaged(?[]const u8) = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init(parent_alloc: std.mem.Allocator) !*TsconfigCache {
        const self = try parent_alloc.create(TsconfigCache);
        self.* = .{
            .parent_alloc = parent_alloc,
            .arena = std.heap.ArenaAllocator.init(parent_alloc),
        };
        return self;
    }

    pub fn deinit(self: *TsconfigCache) void {
        self.by_entry_dir.deinit(self.parent_alloc);
        self.arena.deinit();
        self.parent_alloc.destroy(self);
    }

    /// entry_path 의 dirname 으로 cache lookup. miss 시 `autodiscoverFromEntry` 호출 후 결과
    /// 저장. 반환 string 은 cache (arena) 소유 — caller 가 free 하면 안 됨.
    /// 반환 null 은 "위로 올라가도 tsconfig 없음" 을 의미.
    pub fn findTsconfigPath(self: *TsconfigCache, entry_path: []const u8) ?[]const u8 {
        const dir = std.fs.path.dirname(entry_path) orelse ".";

        self.mutex.lock();
        if (self.by_entry_dir.get(dir)) |cached| {
            self.mutex.unlock();
            return cached;
        }
        // walk 동안은 unlock — 다른 entry_dir 는 병렬 진행 가능. 같은 dir 의 race 는
        // 아래 double-check 로 정리.
        self.mutex.unlock();

        // walk 임시 alloc — 결과 path 만 arena 로 dupe 후 임시 해제.
        var tmp_arena = std.heap.ArenaAllocator.init(self.parent_alloc);
        defer tmp_arena.deinit();
        const found = TsConfig.autodiscoverFromEntry(tmp_arena.allocator(), entry_path);

        const arena_alloc = self.arena.allocator();
        const dir_owned = arena_alloc.dupe(u8, dir) catch return null;
        // path dupe 실패 시 "tsconfig 없음" 으로 잘못 캐싱하지 않도록 분리 — found 가 있는데
        // dupe OOM 이면 negative 결과로 poison 안 되게 캐시 진입 자체 포기.
        const path_owned: ?[]const u8 = if (found) |p|
            (arena_alloc.dupe(u8, p) catch return p)
        else
            null;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.by_entry_dir.get(dir)) |cached| return cached;
        // put 실패 (OOM) 도 best-effort — 본 호출 결과만 반환, 다음 호출은 다시 walk.
        self.by_entry_dir.put(self.parent_alloc, dir_owned, path_owned) catch return path_owned;
        return path_owned;
    }

    /// 모든 cache entry 제거 + 내부 string 메모리 회수. HashMap 컨테이너는 parent_alloc 소유라
    /// arena reset 영향 안 받음 — clearRetainingCapacity 로 entry 비우고 arena reset 으로
    /// string 메모리 회수.
    pub fn clear(self: *TsconfigCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.by_entry_dir.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn size(self: *TsconfigCache) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.by_entry_dir.count();
    }
};

// ─── 단위 테스트 ───

const testing = std.testing;

test "TsconfigCache: 같은 entry_dir 는 1 회만 walk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tsconfig.json", .data = "{}" });
    try tmp.dir.makeDir("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/a.ts", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "src/b.ts", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const a = try std.fs.path.join(testing.allocator, &.{ tmp_path, "src", "a.ts" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ tmp_path, "src", "b.ts" });
    defer testing.allocator.free(b);

    var cache = try TsconfigCache.init(testing.allocator);
    defer cache.deinit();

    const r1 = cache.findTsconfigPath(a);
    const r2 = cache.findTsconfigPath(b);
    try testing.expect(r1 != null);
    try testing.expect(r2 != null);
    try testing.expectEqualStrings(r1.?, r2.?);
    try testing.expectEqual(@as(usize, 1), cache.size()); // 같은 dirname → 1 entry
}

test "TsconfigCache: tsconfig 없을 때도 negative 결과 캐시" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/a.ts", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const a = try std.fs.path.join(testing.allocator, &.{ tmp_path, "src", "a.ts" });
    defer testing.allocator.free(a);

    var cache = try TsconfigCache.init(testing.allocator);
    defer cache.deinit();

    const r = cache.findTsconfigPath(a);
    // tsconfig 없음 (root 까지 올라가도 못 찾음 가정 — 실제 환경에 따라 fallback 가능).
    // 본 테스트는 "negative 결과도 캐시" 만 검증하므로 size==1 만 보장.
    _ = r;
    try testing.expectEqual(@as(usize, 1), cache.size());
}

test "TsconfigCache: 두 인스턴스는 독립 state" {
    var cache_a = try TsconfigCache.init(testing.allocator);
    defer cache_a.deinit();
    var cache_b = try TsconfigCache.init(testing.allocator);
    defer cache_b.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tsconfig.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "a.ts", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const a = try std.fs.path.join(testing.allocator, &.{ tmp_path, "a.ts" });
    defer testing.allocator.free(a);

    _ = cache_a.findTsconfigPath(a);
    try testing.expectEqual(@as(usize, 1), cache_a.size());
    try testing.expectEqual(@as(usize, 0), cache_b.size());

    cache_a.clear();
    try testing.expectEqual(@as(usize, 0), cache_a.size());
    try testing.expectEqual(@as(usize, 0), cache_b.size());
}

test "TsconfigCache: 같은 dirname 의 다른 파일 lookup 도 1 entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tsconfig.json", .data = "{}" });
    try tmp.dir.makeDir("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/a.ts", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "src/b.ts", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "src/c.ts", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const a = try std.fs.path.join(testing.allocator, &.{ tmp_path, "src", "a.ts" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ tmp_path, "src", "b.ts" });
    defer testing.allocator.free(b);
    const c = try std.fs.path.join(testing.allocator, &.{ tmp_path, "src", "c.ts" });
    defer testing.allocator.free(c);

    var cache = try TsconfigCache.init(testing.allocator);
    defer cache.deinit();

    const r_a = cache.findTsconfigPath(a);
    const r_b = cache.findTsconfigPath(b);
    const r_c = cache.findTsconfigPath(c);
    try testing.expect(r_a != null);
    // 모두 같은 tsconfig.json path 반환
    try testing.expectEqualStrings(r_a.?, r_b.?);
    try testing.expectEqualStrings(r_a.?, r_c.?);
    try testing.expectEqual(@as(usize, 1), cache.size());
}

test "TsconfigCache: clear 후 같은 dir 다시 lookup 시 정상 재캐시" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tsconfig.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "a.ts", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const a = try std.fs.path.join(testing.allocator, &.{ tmp_path, "a.ts" });
    defer testing.allocator.free(a);

    var cache = try TsconfigCache.init(testing.allocator);
    defer cache.deinit();

    const r1 = cache.findTsconfigPath(a);
    try testing.expect(r1 != null);
    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.size());

    const r2 = cache.findTsconfigPath(a);
    try testing.expect(r2 != null);
    try testing.expectEqual(@as(usize, 1), cache.size());
    try testing.expectEqualStrings(r1.?, r2.?); // 같은 결과
}

test "TsconfigCache: bare filename (no dirname) 안전 처리" {
    // dirname() orelse "." fallback 경로 — `findPackageDirPath` 의 cwd 의존이지만
    // 본 cache 는 실패해도 panic 없이 null 반환해야 함.
    var cache = try TsconfigCache.init(testing.allocator);
    defer cache.deinit();
    _ = cache.findTsconfigPath("input.js");
    // 환경에 따라 결과가 있을 수도 없을 수도 있음 — 핵심은 panic 없이 캐시 1 entry.
    try testing.expectEqual(@as(usize, 1), cache.size());
}

test "TsconfigCache: clear 후 size 0" {
    var cache = try TsconfigCache.init(testing.allocator);
    defer cache.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tsconfig.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "a.ts", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);
    const a = try std.fs.path.join(testing.allocator, &.{ tmp_path, "a.ts" });
    defer testing.allocator.free(a);

    _ = cache.findTsconfigPath(a);
    try testing.expect(cache.size() > 0);

    cache.clear();
    try testing.expectEqual(@as(usize, 0), cache.size());
}
