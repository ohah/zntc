//! ZTS Bundler FileSystem 추상화 (#1885 epic — Phase 1 PR 1).
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
pub fn readFile(alloc: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModule {
    return Implementation.init().readFile(alloc, path, max_bytes);
}

pub fn statFile(path: []const u8) FsError!FileStat {
    return Implementation.init().statFile(path);
}

pub fn access(path: []const u8) FsError!void {
    return Implementation.init().access(path);
}

pub fn realpath(alloc: std.mem.Allocator, path: []const u8) FsError![]const u8 {
    return Implementation.init().realpath(alloc, path);
}

pub fn listDir(alloc: std.mem.Allocator, path: []const u8) FsError![]DirEntry {
    return Implementation.init().listDir(alloc, path);
}

/// 호스트 OS 의 std.fs.cwd() 를 wrapping. NAPI / CLI 빌드의 default 구현.
pub const RealFS = struct {
    pub fn init() RealFS {
        return .{};
    }

    pub fn readFile(_: RealFS, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModule {
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, max_bytes) catch |err| return mapFsError(err);
        return .{
            .contents = bytes,
            .path = path,
            .namespace = .file,
        };
    }

    pub fn statFile(_: RealFS, path: []const u8) FsError!FileStat {
        const stat = std.fs.cwd().statFile(path) catch |err| return mapFsError(err);
        const kind = mapEntryKind(stat.kind);
        return .{
            .size = stat.size,
            .is_dir = kind == .directory,
            .mtime = stat.mtime,
            .kind = kind,
        };
    }

    pub fn access(_: RealFS, path: []const u8) FsError!void {
        std.fs.cwd().access(path, .{}) catch |err| return mapFsError(err);
    }

    /// symlink 정규화. resolver 의 preserve_symlinks=false 경로에 사용 (bun/.bun, pnpm/.pnpm).
    /// caller 가 반환 slice 의 메모리 소유.
    pub fn realpath(_: RealFS, allocator: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        return std.fs.cwd().realpathAlloc(allocator, path) catch |err| return mapFsError(err);
    }

    /// 디렉토리 항목을 ArrayList 에 모아 반환. caller 가 메모리 소유.
    /// resolver 의 typical use case = 전체 항목 한 번에 보고 매칭.
    pub fn listDir(_: RealFS, allocator: std.mem.Allocator, path: []const u8) FsError![]DirEntry {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| return mapFsError(err);
        defer dir.close();

        var list: std.ArrayList(DirEntry) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item.name);
            list.deinit(allocator);
        }

        var it = dir.iterate();
        while (it.next() catch return FsError.IoError) |entry| {
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

/// WASM host import. JS 측 `zts_fs` namespace 에 fn 들 노출 — wasm_entry 가
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
    extern "zts_fs" fn readFile(path_ptr: u32, path_len: u32, max_bytes: u32) u64;
    extern "zts_fs" fn statFile(path_ptr: u32, path_len: u32, out_size: *u64, out_kind: *u8, out_mtime_lo: *u64, out_mtime_hi: *u64) u32;
    extern "zts_fs" fn access(path_ptr: u32, path_len: u32) u32;
    extern "zts_fs" fn realpath(path_ptr: u32, path_len: u32) u64;
    extern "zts_fs" fn listDir(path_ptr: u32, path_len: u32) u64;
    extern "zts_fs" fn hostFreeBytes(ptr: u32, len: u32) void;
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

/// WASM 빌드의 fs 구현. host JS callback (zts_fs namespace) 위임.
/// listDir 는 후속 PR — Phase 2 의 minimal use case (단일 entry + 명시 imports) 는
/// require.context 미사용이라 제외.
pub const VirtualFS = struct {
    pub fn init() VirtualFS {
        return .{};
    }

    pub fn readFile(_: VirtualFS, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) FsError!LoadedModule {
        const packed_result = wasm_imports.readFile(@intCast(@intFromPtr(path.ptr)), @intCast(path.len), @intCast(max_bytes));
        const dupe = try readPackedBytes(allocator, packed_result);
        return .{
            .contents = dupe,
            .path = path,
            .namespace = .file,
        };
    }

    pub fn statFile(_: VirtualFS, path: []const u8) FsError!FileStat {
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

    pub fn access(_: VirtualFS, path: []const u8) FsError!void {
        const status = wasm_imports.access(@intCast(@intFromPtr(path.ptr)), @intCast(path.len));
        if (status != 0) return mapStatusError(status);
    }

    pub fn realpath(_: VirtualFS, allocator: std.mem.Allocator, path: []const u8) FsError![]const u8 {
        const packed_result = wasm_imports.realpath(@intCast(@intFromPtr(path.ptr)), @intCast(path.len));
        return readPackedBytes(allocator, packed_result);
    }

    pub fn listDir(_: VirtualFS, _: std.mem.Allocator, _: []const u8) FsError![]DirEntry {
        // Phase 2 후속 — JSON 파싱 비용 회피 위해 minimal use case 에선 제외.
        // require.context / glob import 사용 시 channel 통과.
        @compileError("VirtualFS.listDir: Phase 2 후속 — host JSON ABI 미구현");
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

fn mapEntryKind(kind: std.fs.Dir.Entry.Kind) EntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}
