//! ZNTC Bundler FileSystem 추상화 (#1885 epic — Phase 1 PR 1).
//!
//! comptime polymorphism 으로 빌드 타겟별 fs 구현 선택. NAPI/CLI 빌드는
//! `RealFS` (호스트 std.fs.cwd() wrapping), WASM 빌드는 `VirtualFS`
//! (host JS callback 위임 — Phase 2 PR 6 에서 구현).
//!
//! Plugin layer (PR 4) 도입 시 `ModuleLoadResult` union(enum) 을 위에 얹어
//! "plugin first → fs fallback" 흐름 구성.
//!
//! 호출처는 PR 2/3 (graph.zig, resolver.zig) 에서 std.fs.cwd() 직접 호출을
//! `Implementation.readFile/iterDir/...` 로 점진 마이그레이션.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const profile = @import("../profile.zig");
const debug_log = @import("../debug_log.zig");
const spin = @import("../util/spin_lock.zig");

const is_wasm_build = builtin.target.cpu.arch == .wasm32;

/// `plugin.ResolvedModule` (union(enum)) 의 tag 로 사용되는 namespace 분류.
///
/// **위치 주의**: 진짜 fs layer 책임은 `file` 뿐. `virtual / dataurl / external /
/// disabled / custom` 은 모두 plugin/resolver layer 의 분류이며, 단일 enum 동기화
/// 부담을 피하기 위해 통합 정의. PR 4d (ResolveResult 제거) 시점에 plugin.zig 로
/// 이동 검토 — 그때 fs.LoadedModule 의 namespace 필드도 함께 결정.
pub const Namespace = enum {
    /// fs 가 직접 읽음 (RealFS) 또는 host VirtualFS (WASM)
    file,
    /// plugin 의 메모리 모듈
    virtual,
    /// data: URL — 인라인 base64 asset
    dataurl,
    /// 번들 미포함 — 런타임 import 유지
    external,
    /// browser 필드 false 매핑 — 빈 CJS 로 대체 (esbuild "(disabled)" 호환)
    disabled,
    /// 사용자 plugin 의 자유 namespace
    custom,
};

/// fs.readFile 또는 plugin.load 의 결과.
pub const LoadedModule = struct {
    contents: []const u8,
    path: []const u8,
    namespace: Namespace = .file,
    /// caller 가 확장자 / shebang / 내용으로 결정.
    /// fs 계층은 `unknown` 으로 반환 — graph 가 `ModuleType.fromExtension` 호출.
    module_type: types.ModuleType = .unknown,
};

pub const LoadedModuleWithStat = struct {
    loaded: LoadedModule,
    stat: FileStat,
};

pub const DirEntry = struct {
    name: []const u8,
    kind: EntryKind,
};

pub const EntryKind = enum {
    file,
    directory,
    symlink,
    other,
};

/// VirtualFS (WASM) 가 호스트로부터 받을 수 있는 최소 정보만 노출.
/// std.fs.File.Stat 의 inode/mode_t 같은 OS-dependent 필드는 의도적 제외.
/// mtime 은 HMR 의 cache key (#1894) 에 사용 — RealFS 는 항상 stat.mtime 으로 채우고,
/// VirtualFS 는 host 가 mtime 미제공 시 0 으로 두면 HMR 의 mtime=0 virtual 분기로 자연 fallback.
/// kind 는 file / directory / symlink 정확 분류 — symlink-to-file 과 file 을 구분해야 하는
/// resolver 의 fileExists 같은 use case 에서 필요.
pub const FileStat = struct {
    size: u64,
    is_dir: bool,
    mtime: i128,
    kind: EntryKind,
};

pub const FsError = error{
    NotFound,
    PermissionDenied,
    NotDirectory,
    IsDirectory,
    OutOfMemory,
    IoError,
};

/// 빌드 타겟별 fs 구현 (comptime 선택, vtable 비용 0).
/// bun 의 `pub const Implementation = RealFS;` 패턴 — `references/bun/src/fs.zig:1475`.
pub const Implementation = if (is_wasm_build) VirtualFS else RealFS;

/// Implementation default instance 사용 — 호출처가 환경 무관하게 `fs.readFile(...)` 형태로
/// 호출. state 보유가 필요해지는 환경 (Phase 2 VirtualFS host_callback) 에선 ModuleGraph 등이
/// fs.Implementation 인스턴스 필드로 보유하는 패턴으로 전환.
pub fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModule {
    return Implementation.init().readFile(io, alloc, path, max_bytes);
}

pub fn readFileWithStat(io: std.Io, alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModuleWithStat {
    return Implementation.init().readFileWithStat(io, alloc, path, max_bytes);
}

pub fn statFile(io: std.Io, path: []const u8) FsError!FileStat {
    return Implementation.init().statFile(io, path);
}

pub fn access(io: std.Io, path: []const u8) FsError!void {
    return Implementation.init().access(io, path);
}

pub fn realpath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) FsError![]const u8 {
    return Implementation.init().realpath(io, alloc, path);
}

pub fn listDir(io: std.Io, alloc: std.mem.Allocator, path: []const u8) FsError![]DirEntry {
    return Implementation.init().listDir(io, alloc, path);
}

pub const ReadFileCache = if (is_wasm_build) VirtualReadFileCache else RealReadFileCache;

pub const RealReadFileCache = struct {
    dirs: std.StringHashMapUnmanaged(std.Io.Dir) = .empty,
    // 0.16: getOrOpenDir 가 openDir(blocking syscall)을 락 *밖* double-check 로 빼서
    // 임계구역이 HashMap get/put 뿐이 됐다 → io-free 스핀락 (다른 캐시와 일관). std.Thread.
    // Mutex 제거 + std.Io.Mutex.lock 의 io 요구 회피.
    mutex: spin.SpinLock = .{},

    pub fn deinit(self: *RealReadFileCache, io: std.Io, allocator: std.mem.Allocator) void {
        var value_it = self.dirs.valueIterator();
        while (value_it.next()) |dir| dir.close(io);
        var key_it = self.dirs.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        self.dirs.deinit(allocator);
    }

    /// stat 없는 read — fresh build path 에서 mtime 이 caller 없을 때 사용.
    /// dir-fd cache (`openFile`) 는 그대로 활용해 path lookup 비용 절감.
    pub fn readFile(
        self: *RealReadFileCache,
        io: std.Io,
        cache_allocator: std.mem.Allocator,
        content_allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) FsError!LoadedModule {
        const file = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_open);
            defer scope.end();
            break :blk self.openFile(io, cache_allocator, path) catch |err| return mapFsError(err);
        };
        defer {
            var close_scope = profile.begin(.graph_discover_pm_setup_read_close);
            defer close_scope.end();
            file.close(io);
        }

        const bytes = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_bytes);
            defer scope.end();
            // 0.16: File.readToEndAlloc 제거 → File.Reader.allocRemaining (EOF 까지 grow).
            var read_buf: [64 * 1024]u8 = undefined;
            var fr = file.reader(io, &read_buf);
            break :blk fr.interface.allocRemaining(content_allocator, std.Io.Limit.limited(max_bytes)) catch |err| return mapFsError(err);
        };

        return .{
            .contents = bytes,
            .path = path,
            .namespace = .file,
        };
    }

    pub fn readFileWithStat(
        self: *RealReadFileCache,
        io: std.Io,
        cache_allocator: std.mem.Allocator,
        content_allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) FsError!LoadedModuleWithStat {
        var with_stat_scope = profile.begin(.graph_discover_pm_setup_read_with_stat);
        defer with_stat_scope.end();

        const file = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_open);
            defer scope.end();
            break :blk self.openFile(io, cache_allocator, path) catch |err| return mapFsError(err);
        };
        defer {
            var close_scope = profile.begin(.graph_discover_pm_setup_read_close);
            defer close_scope.end();
            file.close(io);
        }

        const stat = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_stat);
            defer scope.end();
            break :blk file.stat(io) catch |err| return mapFsError(err);
        };
        const bytes = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_bytes);
            defer scope.end();
            // 0.16: readToEndAllocOptions 제거 → File.Reader.allocRemaining.
            var read_buf: [64 * 1024]u8 = undefined;
            var fr = file.reader(io, &read_buf);
            break :blk fr.interface.allocRemaining(content_allocator, std.Io.Limit.limited(max_bytes)) catch |err| return mapFsError(err);
        };
        const kind = mapEntryKind(stat.kind);

        return .{
            .loaded = .{
                .contents = bytes,
                .path = path,
                .namespace = .file,
            },
            .stat = .{
                .size = stat.size,
                .is_dir = kind == .directory,
                .mtime = stat.mtime.toNanoseconds(),
                .kind = kind,
            },
        };
    }

    /// 신규 모듈 등록 시점에 dir-fd cache 를 미리 채워 hot path 의 첫 openDir MISS 를
    /// 줄인다. best-effort (에러 swallow). non-absolute / null-byte path 는 skip.
    pub fn preopenDir(self: *RealReadFileCache, io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) void {
        if (dir_path.len == 0) return;
        if (!std.fs.path.isAbsolute(dir_path)) return;
        if (std.mem.indexOfScalar(u8, dir_path, 0) != null) return;
        _ = self.getOrOpenDir(io, allocator, dir_path) catch {};
    }

    fn openFile(self: *RealReadFileCache, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.Io.File {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        const file_name = std.fs.path.basename(path);
        if (file_name.len == 0) return error.FileNotFound;

        var audit = debug_log.auditScope(.graph_io_audit);
        const dir_cache_hit: bool = if (audit.on) blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.dirs.contains(dir_path);
        } else false;
        const dir = try self.getOrOpenDir(io, allocator, dir_path);
        const f = try dir.openFile(io, file_name, .{});
        if (audit.on) debug_log.print(.graph_io_audit, "open path_len={d} dir_cache_hit={d} ns={d}\n", .{ path.len, @intFromBool(dir_cache_hit), audit.elapsedNs() });
        return f;
    }

    /// dir-fd 캐시. 0.16: openDir(blocking)을 락 *밖* 에 두는 double-check 패턴 —
    /// 임계구역(HashMap get/put)이 io-free 라 스핀락으로 충분. fd 중복 open race 는
    /// "먼저 put 한 쪽 채택, 내 fd close" 로 처리.
    fn getOrOpenDir(self: *RealReadFileCache, io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !std.Io.Dir {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.dirs.get(dir_path)) |dir| return dir;
        }
        // openDir 은 락 밖 (blocking syscall — 락 안에서 하면 contention).
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        errdefer dir.close(io);

        self.mutex.lock();
        defer self.mutex.unlock();
        // 2nd check: 그 사이 다른 스레드가 먼저 넣었으면 내 fd 닫고 그걸 쓴다.
        if (self.dirs.get(dir_path)) |existing| {
            dir.close(io);
            return existing;
        }
        const key = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(key);
        try self.dirs.put(allocator, key, dir);
        return dir;
    }
};

pub const VirtualReadFileCache = struct {
    // RealReadFileCache 와 comptime 시그니처 일치 (ReadFileCache dispatch). io 는
    // host callback 위임이라 미사용이지만 시그니처 통일을 위해 받는다.
    pub fn deinit(_: *VirtualReadFileCache, _: std.Io, _: std.mem.Allocator) void {}

    pub fn readFile(
        _: *VirtualReadFileCache,
        io: std.Io,
        _: std.mem.Allocator,
        content_allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) FsError!LoadedModule {
        return Implementation.init().readFile(io, content_allocator, path, max_bytes);
    }

    pub fn readFileWithStat(
        _: *VirtualReadFileCache,
        io: std.Io,
        _: std.mem.Allocator,
        content_allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) FsError!LoadedModuleWithStat {
        return Implementation.init().readFileWithStat(io, content_allocator, path, max_bytes);
    }

    /// WASM 빌드 noop — VFS 는 dir-fd cache 가 없으므로 pre-warm 의미 없음.
    pub fn preopenDir(_: *VirtualReadFileCache, _: std.Io, _: std.mem.Allocator, _: []const u8) void {}
};

/// 호스트 OS 의 std.fs.cwd() 를 wrapping. NAPI / CLI 빌드의 default 구현.
pub const RealFS = struct {
    pub fn init() RealFS {
        return .{};
    }

    pub fn readFile(_: RealFS, io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModule {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_bytes)) catch |err| return mapFsError(err);
        return .{
            .contents = bytes,
            .path = path,
            .namespace = .file,
        };
    }

    pub fn readFileWithStat(_: RealFS, io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModuleWithStat {
        var with_stat_scope = profile.begin(.graph_discover_pm_setup_read_with_stat);
        defer with_stat_scope.end();

        const file = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_open);
            defer scope.end();
            break :blk std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return mapFsError(err);
        };
        defer file.close(io);

        const stat = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_stat);
            defer scope.end();
            break :blk file.stat(io) catch |err| return mapFsError(err);
        };
        const bytes = blk: {
            var scope = profile.begin(.graph_discover_pm_setup_read_bytes);
            defer scope.end();
            // 0.16: readToEndAllocOptions 제거 → File.Reader.allocRemaining.
            var read_buf: [64 * 1024]u8 = undefined;
            var fr = file.reader(io, &read_buf);
            break :blk fr.interface.allocRemaining(allocator, std.Io.Limit.limited(max_bytes)) catch |err| return mapFsError(err);
        };
        const kind = mapEntryKind(stat.kind);

        return .{
            .loaded = .{
                .contents = bytes,
                .path = path,
                .namespace = .file,
            },
            .stat = .{
                .size = stat.size,
                .is_dir = kind == .directory,
                .mtime = stat.mtime.toNanoseconds(),
                .kind = kind,
            },
        };
    }

    pub fn statFile(_: RealFS, io: std.Io, path: []const u8) FsError!FileStat {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return mapFsError(err);
        const kind = mapEntryKind(stat.kind);
        return .{
            .size = stat.size,
            .is_dir = kind == .directory,
            .mtime = stat.mtime.toNanoseconds(),
            .kind = kind,
        };
    }

    pub fn access(_: RealFS, io: std.Io, path: []const u8) FsError!void {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| return mapFsError(err);
    }

    /// symlink 정규화. resolver 의 preserve_symlinks=false 경로에 사용 (bun/.bun, pnpm/.pnpm).
    /// caller 가 반환 slice 의 메모리 소유.
    pub fn realpath(_: RealFS, io: std.Io, allocator: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| return mapFsError(err);
    }

    /// 디렉토리 항목을 ArrayList 에 모아 반환. caller 가 메모리 소유.
    /// resolver 의 typical use case = 전체 항목 한 번에 보고 매칭.
    pub fn listDir(_: RealFS, io: std.Io, allocator: std.mem.Allocator, path: []const u8) FsError![]DirEntry {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| return mapFsError(err);
        defer dir.close(io);

        var list: std.ArrayList(DirEntry) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item.name);
            list.deinit(allocator);
        }

        var it = dir.iterate();
        while (it.next(io) catch return FsError.IoError) |entry| {
            const name_copy = allocator.dupe(u8, entry.name) catch return FsError.OutOfMemory;
            errdefer allocator.free(name_copy);
            list.append(allocator, .{
                .name = name_copy,
                .kind = mapEntryKind(entry.kind),
            }) catch return FsError.OutOfMemory;
        }
        return list.toOwnedSlice(allocator) catch FsError.OutOfMemory;
    }
};

/// WASM host import. JS 측 `zntc_fs` namespace 에 fn 들 노출 — wasm_entry 가
/// instantiate 시 imports 로 주입. comptime 분기로 NAPI 빌드는 link 영향 X.
///
/// ABI:
/// - readFile(path_ptr, path_len, max_bytes) → packed u64: (data_ptr<<32) | data_len.
///   0 = error (NotFound/IoError 통합). caller (Zig) 가 데이터 dupe 후 hostFreeBytes 호출.
/// - statFile(path_ptr, path_len, out_size, out_kind, out_mtime_lo, out_mtime_hi) → status u32.
///   0 = ok. EntryKind: 0=file, 1=directory, 2=symlink, 3=other.
/// - access(path_ptr, path_len) → status u32 (0=ok, 1=NotFound, 2=PermissionDenied, 3=IoError).
/// - realpath(path_ptr, path_len) → packed u64 (data_ptr<<32 | data_len), 0=error.
/// - listDir(path_ptr, path_len) → packed u64 (json_ptr<<32 | json_len), 0=error.
///   JSON: `[{"name":"a","kind":0}, ...]`.
/// - hostFreeBytes(ptr, len) — host 가 alloc 한 버퍼 해제.
const wasm_imports = if (is_wasm_build) struct {
    extern "zntc_fs" fn readFile(path_ptr: u32, path_len: u32, max_bytes: u32) u64;
    extern "zntc_fs" fn statFile(path_ptr: u32, path_len: u32, out_size: *u64, out_kind: *u8, out_mtime_lo: *u64, out_mtime_hi: *u64) u32;
    extern "zntc_fs" fn access(path_ptr: u32, path_len: u32) u32;
    extern "zntc_fs" fn realpath(path_ptr: u32, path_len: u32) u64;
    extern "zntc_fs" fn listDir(path_ptr: u32, path_len: u32) u64;
    extern "zntc_fs" fn hostFreeBytes(ptr: u32, len: u32) void;
} else struct {};

/// host 반환의 packed (ptr<<32 | len) 디코드 — 0 = error sentinel.
inline fn decodePacked(packed_val: u64) ?struct { ptr: u32, len: u32 } {
    if (packed_val == 0) return null;
    return .{
        .ptr = @intCast(packed_val >> 32),
        .len = @intCast(packed_val & 0xffff_ffff),
    };
}

/// host packed bytes → caller 소유 dupe + hostFreeBytes. readFile/realpath 공통.
fn readPackedBytes(allocator: std.mem.Allocator, packed_val: u64) FsError![]u8 {
    const decoded = decodePacked(packed_val) orelse return FsError.NotFound;
    const bytes_ptr: [*]u8 = @ptrFromInt(decoded.ptr);
    defer wasm_imports.hostFreeBytes(decoded.ptr, decoded.len);
    return allocator.dupe(u8, bytes_ptr[0..decoded.len]) catch FsError.OutOfMemory;
}

/// WASM 빌드의 fs 구현. host JS callback (zntc_fs namespace) 위임.
/// listDir 는 후속 PR — Phase 2 의 minimal use case (단일 entry + 명시 imports) 는
/// require.context 미사용이라 제외.
pub const VirtualFS = struct {
    pub fn init() VirtualFS {
        return .{};
    }

    // io 는 host callback 위임이라 미사용 — RealFS 와 comptime 시그니처 일치를 위해 받는다.
    pub fn readFile(_: VirtualFS, _: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModule {
        const packed_result = wasm_imports.readFile(@intCast(@intFromPtr(path.ptr)), @intCast(path.len), @intCast(max_bytes));
        const dupe = try readPackedBytes(allocator, packed_result);
        return .{
            .contents = dupe,
            .path = path,
            .namespace = .file,
        };
    }

    pub fn readFileWithStat(self: VirtualFS, io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModuleWithStat {
        return .{
            .loaded = try self.readFile(io, allocator, path, max_bytes),
            .stat = try self.statFile(io, path),
        };
    }

    pub fn statFile(_: VirtualFS, _: std.Io, path: []const u8) FsError!FileStat {
        var size: u64 = 0;
        var kind: u8 = 0;
        var mtime_lo: u64 = 0;
        var mtime_hi: u64 = 0;
        const status = wasm_imports.statFile(@intCast(@intFromPtr(path.ptr)), @intCast(path.len), &size, &kind, &mtime_lo, &mtime_hi);
        if (status != 0) return mapStatusError(status);
        return .{
            .size = size,
            .is_dir = kind == 1,
            .mtime = (@as(i128, @intCast(mtime_hi)) << 64) | @as(i128, @intCast(mtime_lo)),
            .kind = mapStatusKind(kind),
        };
    }

    pub fn access(_: VirtualFS, _: std.Io, path: []const u8) FsError!void {
        const status = wasm_imports.access(@intCast(@intFromPtr(path.ptr)), @intCast(path.len));
        if (status != 0) return mapStatusError(status);
    }

    pub fn realpath(_: VirtualFS, _: std.Io, allocator: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        const packed_result = wasm_imports.realpath(@intCast(@intFromPtr(path.ptr)), @intCast(path.len));
        return readPackedBytes(allocator, packed_result);
    }

    pub fn listDir(_: VirtualFS, _: std.Io, _: std.mem.Allocator, _: []const u8) FsError![]DirEntry {
        // Phase 2 minimal — require.context / glob import 미사용 가정. 빈 slice 반환으로
        // 호출처 (graph.expandRequireContextRecords 등) 가 silent fallback.
        // 후속 PR 에서 host JSON ABI 추가 시 실 구현.
        return &.{};
    }
};

// host ABI status code: 0=ok, 1=NotFound, 2=PermissionDenied, 3+=IoError
fn mapStatusError(status: u32) FsError {
    return switch (status) {
        1 => FsError.NotFound,
        2 => FsError.PermissionDenied,
        else => FsError.IoError,
    };
}

// host ABI kind code: 0=file, 1=directory, 2=symlink, 3+=other
fn mapStatusKind(kind: u8) EntryKind {
    return switch (kind) {
        0 => .file,
        1 => .directory,
        2 => .symlink,
        else => .other,
    };
}

/// std.fs 의 OS error 를 fs 도메인 error 로 통일 매핑.
/// readFile/statFile/access/openDir 공통.
fn mapFsError(err: anyerror) FsError {
    return switch (err) {
        error.FileNotFound => FsError.NotFound,
        error.AccessDenied, error.PermissionDenied => FsError.PermissionDenied,
        error.NotDir => FsError.NotDirectory,
        error.IsDir => FsError.IsDirectory,
        error.OutOfMemory => FsError.OutOfMemory,
        else => FsError.IoError,
    };
}

fn mapEntryKind(kind: std.Io.File.Kind) EntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}
