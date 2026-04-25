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

/// 모듈의 namespace 분류. `union(enum) ResolveResult` (PR 4 plugin.zig) 의
/// tag 로도 사용 — `file` 만 fs 통과, 나머지는 plugin 책임.
pub const Namespace = enum {
    file,
    virtual,
    dataurl,
    external,
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

/// WASM 빌드용 placeholder. Phase 2 PR 6 에서 host JS callback (zts_plugins
/// import) 으로 실제 구현. 현재는 wasm 빌드 시 호출하면 컴파일 에러.
pub const VirtualFS = struct {
    pub fn init() VirtualFS {
        return .{};
    }

    pub fn readFile(_: VirtualFS, _: std.mem.Allocator, _: []const u8, _: usize) FsError!LoadedModule {
        @compileError("VirtualFS.readFile: WASM fs callback 미구현 (Phase 2 PR 6)");
    }

    pub fn statFile(_: VirtualFS, _: []const u8) FsError!FileStat {
        @compileError("VirtualFS.statFile: WASM fs callback 미구현 (Phase 2 PR 6)");
    }

    pub fn access(_: VirtualFS, _: []const u8) FsError!void {
        @compileError("VirtualFS.access: WASM fs callback 미구현 (Phase 2 PR 6)");
    }

    pub fn realpath(_: VirtualFS, _: std.mem.Allocator, _: []const u8) FsError![]const u8 {
        @compileError("VirtualFS.realpath: WASM fs callback 미구현 (Phase 2 PR 6)");
    }

    pub fn listDir(_: VirtualFS, _: std.mem.Allocator, _: []const u8) FsError![]DirEntry {
        @compileError("VirtualFS.listDir: WASM fs callback 미구현 (Phase 2 PR 6)");
    }
};

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
