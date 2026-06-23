//! 디스크 캐시 IO 레이어 — #4438. 캐시 키(u64) → 캐시 파일 atomic read/write.
//!
//! codec(module_codec)이 만든 바이트를 실제 디스크에 영속화하는 순수 IO 레이어다.
//!
//! ## 책임
//! - **샤딩 경로**: key(u64)를 16-hex 로 찍어 2-level(`<root>/<ab>/<cdef0123456789>`)로 나눠
//!   한 디렉토리에 파일이 폭증하는 것을 막는다. 앞 2자리를 디렉토리로 쓰는 흔한 샤딩 방식.
//! - **atomic write**: 유니크 tmp 파일에 쓰고 `rename` 으로 교체한다. POSIX rename 은 원자적이라
//!   reader 가 half-written 파일을 보지 못한다. tmp 이름에 프로세스 전역 단조 카운터(seq)를
//!   박아 같은 프로세스 내 동시 쓰기끼리 충돌하지 않는다.
//!   (**의도적 비-fsync**: rename 전 fsync 를 하지 않는다. 전원손실 시 final 이 zero-length/부분
//!   일 수 있으나, get 이 fail-open + codec checksum 으로 miss→재파싱하므로 정확성 안전. 매 write
//!   fsync 는 write 비용만 늘고 정확성 이득 0이라 트레이드오프상 생략 — 손실=엔트리 1건 재파싱.)
//! - **fail-open get**: 캐시 읽기 실패(없음/권한/손상/크기초과)는 전부 cache miss(`null`)로
//!   degrade 해 재파싱하게 한다 — 캐시는 no-cache 보다 빌드를 더 깨뜨리면 안 된다. 시스템 자원
//!   고갈(`OutOfMemory`)만 전파한다.
//!
//! ## 비책임 (후속 PR)
//! - **위치 정책**: 캐시 루트를 어디(`node_modules/.cache/zntc/` 등)에 둘지는 caller 가
//!   `root` 로 주입한다 — graph 통합 PR 이 결정. 여기선 "주어진 root 에 읽고 쓴다"만.
//! - **무효화 키**: key 가 옵션/tsconfig/.env/컴파일러버전을 반영하는지는 무효화 키 PR 의 몫.
//! - graph cache-hit 경로 연결도 후속. 현재는 단위 테스트 전용.
//!
//! ## 안전
//! 한 프로세스 내 동시 쓰기는 seq(전역 atomic)가 tmp 이름의 유일성을 보장한다. 멀티프로세스가
//! 같은 key 를 동시에 쓰면 tmp 이름이 충돌할 수 있으나, ①같은 key = 같은 콘텐츠(무효화 키가
//! 내용 기반)이고 ②rename 이 원자적이라 최종 파일은 항상 온전한 한 writer 의 것이며, ③설령 tmp
//! 가 섞여 깨진 파일이 남아도 codec 의 magic/checksum 검증이 읽을 때 이를 걸러 fail-safe
//! 재파싱한다 — silent miscompile 은 불가능하다.
//!
//! 한 DiskCache 인스턴스를 여러 스레드가 공유해 동시 호출하려면 thread-safe allocator 를
//! 주입해야 한다(put/get 이 self.allocator 로 임시 경로 문자열을 할당).

const std = @import("std");

/// put 마다 1씩 증가하는 프로세스 전역 단조 카운터. 같은 프로세스 내 모든 put 의 tmp 이름을
/// 유일하게 만든다(atomic fetchAdd 라 두 put 이 같은 값을 받지 않음).
/// usize: 32-bit 타겟(wasm32/x86-win)은 64-bit atomic 을 지원하지 않으므로 워드 크기 카운터 사용.
var put_seq = std.atomic.Value(usize).init(0);

pub const DiskCache = struct {
    allocator: std.mem.Allocator,
    /// 캐시 루트 디렉토리(`Dir.cwd()` 기준 상대 또는 절대). init 에서 dupe 해 소유.
    root: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) std.mem.Allocator.Error!DiskCache {
        return .{ .allocator = allocator, .root = try allocator.dupe(u8, root_dir) };
    }

    /// `root_dir/<build_id:016x>` 를 실제 캐시 루트로 쓴다(컴파일러 버전별 격리). 동시에 같은
    /// `root_dir` 안의 **다른** build_id 디렉토리(16-hex 이름)를 best-effort 삭제(GC). 컴파일러
    /// 버전이 바뀌면 옛 캐시는 키가 달라 영영 안 읽혀 누적되므로(디스크 bloat) 새 버전 init 때
    /// 정리한다. 삭제는 16-hex 디렉토리 이름으로만 게이트(사용자 파일 오삭제 방지)+best-effort.
    /// 동일 바이너리 재빌드는 같은 build_id → 같은 subdir → load hit 유지.
    pub fn initVersioned(allocator: std.mem.Allocator, io: std.Io, root_dir: []const u8, build_id: u64) std.mem.Allocator.Error!DiskCache {
        var hex: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{build_id}) catch unreachable; // 16자리 고정
        pruneOtherVersions(io, root_dir, hex[0..]);
        const versioned = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, hex[0..] });
        defer allocator.free(versioned);
        return init(allocator, versioned);
    }

    pub fn deinit(self: *DiskCache) void {
        self.allocator.free(self.root);
    }

    /// key → "<root>/<ab>/<cdef0123456789>" (2-level hex 샤딩). caller 가 free.
    fn pathFor(self: *const DiskCache, allocator: std.mem.Allocator, key: u64) ![]u8 {
        var hex: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{key}) catch unreachable; // 16자리 고정
        return std.fs.path.join(allocator, &.{ self.root, hex[0..2], hex[2..16] });
    }

    /// `bytes` 를 key 에 atomic 하게 쓴다(샤드 디렉토리 생성 → 유니크 tmp 쓰기 → rename).
    pub fn put(self: *const DiskCache, io: std.Io, key: u64, bytes: []const u8) !void {
        // final 경로는 get 과 동일하게 pathFor 로 계산(샤딩 로직 단일 소스 — 분기 시 silent miss 방지).
        const final = try self.pathFor(self.allocator, key);
        defer self.allocator.free(final);

        // 샤드 디렉토리 = final 의 부모(`<root>/<ab>`). pathFor 가 항상 shard/name 2-component 라 non-null.
        const shard_dir = std.fs.path.dirname(final) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, shard_dir); // 멱등(이미 있으면 통과)

        // 유니크 tmp: 전역 atomic seq 가 같은 프로세스 내 모든 put 에 distinct 값을 보장.
        const seq = put_seq.fetchAdd(1, .monotonic);
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.{d}.tmp", .{ final, seq });
        defer self.allocator.free(tmp);

        errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {}; // 실패 시 tmp 잔재 정리
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
        // rename 은 0.16 에서 (old_dir, old_sub, new_dir, new_sub, io) — io 가 마지막 인자.
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), final, io);
    }

    /// key 의 캐시 바이트를 `allocator` 로 읽어 반환. **fail-open**: 읽기 실패(없음/권한/손상/
    /// `max_bytes` 초과 등)는 전부 `null`(cache miss)로 degrade 해 재파싱하게 한다 — 캐시가
    /// no-cache 보다 빌드를 더 깨뜨리지 않게. 시스템 자원 고갈(`OutOfMemory`)만 전파한다.
    /// `max_bytes` 는 손상/거대 파일 방어 상한(초과 시 miss).
    pub fn get(self: *const DiskCache, io: std.Io, allocator: std.mem.Allocator, key: u64, max_bytes: usize) !?[]u8 {
        const path = try self.pathFor(self.allocator, key);
        defer self.allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return err, // 자원 고갈은 캐시 문제 아님 → 전파
            else => null, // 그 외 모든 read 실패는 cache miss → 재파싱
        };
    }
};

/// `root_dir` 안의 16-hex 디렉토리 중 `current_hex` 가 아닌 것을 삭제(다른 컴파일러 버전 캐시 GC).
/// best-effort: 루트 부재/권한/삭제 실패는 전부 무시(캐시 정리가 빌드를 막으면 안 됨). 16-hex
/// 이름 게이트로 사용자 파일/디렉토리는 건드리지 않는다.
fn pruneOtherVersions(io: std.Io, root_dir: []const u8, current_hex: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, root_dir, .{ .iterate = true }) catch return; // 루트 없음/권한 → skip
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind != .directory) continue;
        if (!isHex16(entry.name)) continue;
        if (std.mem.eql(u8, entry.name, current_hex)) continue;
        dir.deleteTree(io, entry.name) catch {}; // best-effort
    }
}

/// 정확히 16자리 소문자 hex 인지(캐시 build_id 디렉토리 이름 형식 — 삭제 게이트).
fn isHex16(name: []const u8) bool {
    if (name.len != 16) return false;
    for (name) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}
