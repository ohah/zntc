const std = @import("std");
const Bundler = @import("bundler.zig").Bundler;
const BundleResult = @import("bundler.zig").BundleResult;
const BundleOptions = @import("bundler.zig").BundleOptions;
const resolve_cache_mod = @import("resolve_cache.zig");

/// 테스트용 번들 결과 wrapper: arena 가 linker 관련 로컬 할당의 수명을 보장.
pub const Bundled = struct {
    arena: std.heap.ArenaAllocator,
    result: BundleResult,

    pub fn code(self: *const Bundled) []const u8 {
        return self.result.output;
    }

    pub fn deinit(self: *Bundled) void {
        self.result.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }
};

/// tmpDir 의 entry 파일을 IIFE 로 번들링. `extra` 로 scope_hoist / tree_shaking 등 추가 옵션 전달.
/// `entry_points` / `format` 은 헬퍼가 강제로 채우므로 caller 는 나머지 필드만 명시.
pub fn bundleEntry(
    backing: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    entry_name: []const u8,
    extra: anytype,
) !Bundled {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const dp = try tmp.dir.realpathAlloc(arena_alloc, ".");
    const entry = try std.fs.path.resolve(arena_alloc, &.{ dp, entry_name });

    var cache = resolve_cache_mod.ResolveCache.init(backing, .{});
    defer cache.deinit();

    const entries: []const []const u8 = &.{entry};
    var opts: BundleOptions = .{ .entry_points = entries, .format = .iife };
    inline for (@typeInfo(@TypeOf(extra)).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "entry_points")) continue;
        if (comptime std.mem.eql(u8, f.name, "format")) continue;
        @field(opts, f.name) = @field(extra, f.name);
    }

    var bundler = Bundler.initWithResolveCache(backing, opts, &cache);
    defer bundler.deinit();

    const result = try bundler.bundle();
    return .{ .arena = arena, .result = result };
}

/// 테스트용 헬퍼: tmpDir에 파일 생성 + 내용 쓰기 (부모 디렉토리 자동 생성)
pub fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

/// 테스트용 헬퍼: tmpDir 상대 경로를 절대 경로로 변환 (caller가 free 해야 함)
pub fn absPath(tmp: *std.testing.TmpDir, rel: []const u8) ![]const u8 {
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    return try std.fs.path.resolve(std.testing.allocator, &.{ dp, rel });
}

/// 테스트용 헬퍼: ArenaAllocator 를 ThreadSafeAllocator 로 감싸 worker 동시 alloc 보호.
/// bundler worker 가 self.allocator 로 동시 할당하므로 단일 thread arena 는 race.
/// 프로덕션 (bungae) 은 GPA thread-safe 가 기본이라 영향 없음 — 테스트만의 보호.
/// 사용: `var ts = threadSafeArena(&arena); const alloc = ts.allocator();`
pub fn threadSafeArena(arena: *std.heap.ArenaAllocator) std.heap.ThreadSafeAllocator {
    return .{ .child_allocator = arena.allocator() };
}
