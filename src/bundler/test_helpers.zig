const std = @import("std");
const spin = @import("../util/spin_lock.zig");
const Bundler = @import("bundler.zig").Bundler;
const BundleResult = @import("bundler.zig").BundleResult;
const BundleOptions = @import("bundler.zig").BundleOptions;
const resolve_cache_mod = @import("resolve_cache.zig");
const OutputFile = @import("emitter.zig").OutputFile;

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

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena_alloc);
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

    const result = try bundler.bundle(std.testing.io);
    return .{ .arena = arena, .result = result };
}

/// 테스트용 헬퍼: tmpDir에 파일 생성 + 내용 쓰기 (부모 디렉토리 자동 생성)
pub fn writeFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(std.testing.io, parent) catch {};
    }
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

/// 테스트용 헬퍼: tmpDir 상대 경로를 절대 경로로 변환 (caller가 free 해야 함)
pub fn absPath(tmp: *std.testing.TmpDir, rel: []const u8) ![]const u8 {
    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    return try std.fs.path.resolve(std.testing.allocator, &.{ dp, rel });
}

/// code_splitting=true 번들 결과에서 이름이 포함된 청크 존재 확인.
pub fn hasChunk(outs: []const OutputFile, name: []const u8) bool {
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.path, name) != null) return true;
    }
    return false;
}

/// 특정 marker 문자열이 포함된 청크의 path 반환 (없으면 null).
pub fn chunkContaining(outs: []const OutputFile, marker: []const u8) ?[]const u8 {
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, marker) != null) return o.path;
    }
    return null;
}

/// io-free thread-safe allocator wrapper. 0.16 에서 std.heap.ThreadSafeAllocator 가
/// 제거됐는데(std.Thread.Mutex 의존), alloc/free 임계구역이 짧아 io-free 스핀락으로 충분.
/// 0.15 std.heap.ThreadSafeAllocator 와 동일 API(.allocator()).
pub const ThreadSafeAllocator = struct {
    child_allocator: std.mem.Allocator,
    lock: spin.SpinLock = .{},

    pub fn allocator(self: *ThreadSafeAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock.lock();
        defer self.lock.unlock();
        return self.child_allocator.rawAlloc(n, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock.lock();
        defer self.lock.unlock();
        return self.child_allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock.lock();
        defer self.lock.unlock();
        return self.child_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock.lock();
        defer self.lock.unlock();
        return self.child_allocator.rawFree(buf, alignment, ret_addr);
    }
};

/// 테스트용 헬퍼: ArenaAllocator 를 ThreadSafeAllocator 로 감싸 worker 동시 alloc 보호.
/// bundler worker 가 self.allocator 로 동시 할당하므로 단일 thread arena 는 race.
/// 프로덕션 (bungae) 은 GPA thread-safe 가 기본이라 영향 없음 — 테스트만의 보호.
/// 사용: `var ts = threadSafeArena(&arena); const alloc = ts.allocator();`
pub fn threadSafeArena(arena: *std.heap.ArenaAllocator) ThreadSafeAllocator {
    return .{ .child_allocator = arena.allocator() };
}
