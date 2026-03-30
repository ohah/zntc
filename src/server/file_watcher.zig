//! OS 네이티브 파일 감시 — kqueue (macOS/BSD), inotify (Linux), mtime 폴백
//!
//! 사용법:
//!   var watcher = try FileWatcher.init(allocator);
//!   defer watcher.deinit();
//!   try watcher.addPath("/abs/path/to/file.ts");
//!   const changed = try watcher.waitForChanges(5000); // 최대 5초 대기
//!   for (changed) |path| { ... }
//!
//! kqueue/inotify를 지원하지 않는 OS에서는 자동으로 mtime 폴링 폴백.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// 변경 이벤트 종류.
pub const ChangeKind = enum {
    modified,
    deleted,
    created,
};

/// 변경 이벤트.
pub const ChangeEvent = struct {
    path: []const u8,
    kind: ChangeKind,
};

/// 크로스 플랫폼 파일 감시.
pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    backend: Backend,

    /// 플랫폼별 백엔드 선택.
    const Backend = if (builtin.os.tag == .macos or
        builtin.os.tag == .ios or
        builtin.os.tag == .freebsd or
        builtin.os.tag == .netbsd or
        builtin.os.tag == .openbsd or
        builtin.os.tag == .dragonfly)
        KqueueBackend
    else if (builtin.os.tag == .linux)
        InotifyBackend
    else
        MtimeBackend;

    pub fn init(allocator: std.mem.Allocator) !FileWatcher {
        return .{
            .allocator = allocator,
            .backend = try Backend.init(allocator),
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        self.backend.deinit(self.allocator);
    }

    /// 감시 대상 파일 추가. 절대 경로를 권장.
    pub fn addPath(self: *FileWatcher, path: []const u8) !void {
        try self.backend.addPath(self.allocator, path);
    }

    /// 감시 대상에서 파일 제거.
    pub fn removePath(self: *FileWatcher, path: []const u8) void {
        self.backend.removePath(self.allocator, path);
    }

    /// 모든 감시 대상 제거.
    pub fn clearPaths(self: *FileWatcher) void {
        self.backend.clearPaths(self.allocator);
    }

    /// 파일 변경 대기. timeout_ms 밀리초 후 빈 슬라이스 반환.
    /// 반환값은 다음 waitForChanges 호출 시 무효화됨.
    pub fn waitForChanges(self: *FileWatcher, timeout_ms: u32) ![]const ChangeEvent {
        return self.backend.waitForChanges(self.allocator, timeout_ms);
    }

    /// 현재 감시 중인 파일 수.
    pub fn watchCount(self: *const FileWatcher) usize {
        return self.backend.watchCount();
    }
};

// ============================================================
// kqueue 백엔드 (macOS, FreeBSD, NetBSD, OpenBSD, DragonFly)
// ============================================================

const KqueueBackend = struct {
    kq: i32,
    /// 감시 대상: path → fd 매핑
    watch_fds: std.StringHashMap(WatchEntry),
    /// fd → path 역참조 (kqueue 이벤트에서 O(1) 경로 조회)
    fd_to_path: std.AutoHashMap(i32, []const u8),
    /// kevent 결과 버퍼
    eventbuf: [64]posix.Kevent = undefined,
    /// waitForChanges 결과 버퍼
    result_buf: std.ArrayList(ChangeEvent),

    const WatchEntry = struct {
        fd: i32,
        path: []const u8, // allocator 소유
    };

    fn init(allocator: std.mem.Allocator) !KqueueBackend {
        const kq = try posix.kqueue();
        return .{
            .kq = kq,
            .watch_fds = std.StringHashMap(WatchEntry).init(allocator),
            .fd_to_path = std.AutoHashMap(i32, []const u8).init(allocator),
            .result_buf = .empty,
        };
    }

    fn deinit(self: *KqueueBackend, allocator: std.mem.Allocator) void {
        var it = self.watch_fds.iterator();
        while (it.next()) |entry| {
            posix.close(entry.value_ptr.fd);
            allocator.free(entry.value_ptr.path);
        }
        self.watch_fds.deinit();
        self.fd_to_path.deinit();
        self.result_buf.deinit(allocator);
        posix.close(self.kq);
    }

    fn addPath(self: *KqueueBackend, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.watch_fds.contains(path)) return;

        // 파일을 읽기 전용으로 open (kqueue에 fd 필요)
        const fd = blk: {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            break :blk std.posix.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0) catch return;
        };

        const path_owned = try allocator.dupe(u8, path);

        // EVFILT_VNODE으로 파일 변경 감시 등록
        const changelist = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.VNODE,
            .flags = std.c.EV.ADD | std.c.EV.CLEAR | std.c.EV.ENABLE,
            .fflags = std.c.NOTE.WRITE | std.c.NOTE.DELETE | std.c.NOTE.RENAME | std.c.NOTE.ATTRIB,
            .data = 0,
            .udata = 0,
        }};

        _ = try posix.kevent(self.kq, &changelist, &.{}, null);

        self.watch_fds.put(path, .{ .fd = fd, .path = path_owned }) catch {
            posix.close(fd);
            allocator.free(path_owned);
            return;
        };
        self.fd_to_path.put(fd, path_owned) catch {};
    }

    fn removePath(self: *KqueueBackend, allocator: std.mem.Allocator, path: []const u8) void {
        if (self.watch_fds.fetchRemove(path)) |kv| {
            const changelist = [_]posix.Kevent{.{
                .ident = @intCast(kv.value.fd),
                .filter = std.c.EVFILT.VNODE,
                .flags = std.c.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = posix.kevent(self.kq, &changelist, &.{}, null) catch {};
            _ = self.fd_to_path.remove(kv.value.fd);
            posix.close(kv.value.fd);
            allocator.free(kv.value.path);
        }
    }

    fn clearPaths(self: *KqueueBackend, allocator: std.mem.Allocator) void {
        var it = self.watch_fds.iterator();
        while (it.next()) |entry| {
            posix.close(entry.value_ptr.fd);
            allocator.free(entry.value_ptr.path);
        }
        self.watch_fds.clearRetainingCapacity();
        self.fd_to_path.clearRetainingCapacity();
    }

    fn waitForChanges(self: *KqueueBackend, allocator: std.mem.Allocator, timeout_ms: u32) ![]const ChangeEvent {
        self.result_buf.clearRetainingCapacity();

        const timeout = posix.timespec{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast((@as(u64, timeout_ms % 1000)) * 1_000_000),
        };

        const n = try posix.kevent(self.kq, &.{}, &self.eventbuf, &timeout);

        for (self.eventbuf[0..n]) |ev| {
            // fd → path O(1) 역참조
            const fd: i32 = @intCast(ev.ident);
            const path = self.fd_to_path.get(fd) orelse continue;

            const kind: ChangeKind = if (ev.fflags & std.c.NOTE.DELETE != 0)
                .deleted
            else if (ev.fflags & std.c.NOTE.RENAME != 0)
                .deleted
            else
                .modified;

            try self.result_buf.append(allocator, .{ .path = path, .kind = kind });
        }

        return self.result_buf.items;
    }

    fn watchCount(self: *const KqueueBackend) usize {
        return self.watch_fds.count();
    }
};

// ============================================================
// inotify 백엔드 (Linux)
// ============================================================

const InotifyBackend = struct {
    inotify_fd: i32,
    /// watch descriptor → path 매핑
    wd_map: std.AutoHashMap(i32, []const u8),
    /// path → wd 역매핑
    path_map: std.StringHashMap(i32),
    /// 읽기 버퍼
    read_buf: [4096]u8 = undefined,
    result_buf: std.ArrayList(ChangeEvent),

    fn init(allocator: std.mem.Allocator) !InotifyBackend {
        const fd = try posix.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        return .{
            .inotify_fd = fd,
            .wd_map = std.AutoHashMap(i32, []const u8).init(allocator),
            .path_map = std.StringHashMap(i32).init(allocator),
            .result_buf = .empty,
        };
    }

    fn deinit(self: *InotifyBackend, allocator: std.mem.Allocator) void {
        var it = self.wd_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.wd_map.deinit();
        self.path_map.deinit();
        self.result_buf.deinit(allocator);
        posix.close(self.inotify_fd);
    }

    // Node.js writeFile 등이 CLOSE_WRITE를 발생시키므로 MODIFY만으로는 부족.
    // atomic write (rename)를 감지하려면 부모 디렉토리 감시가 필요하지만,
    // 파일 단위 감시에서는 DELETE_SELF/MOVE_SELF 후 재등록으로 대응.
    const watch_mask = std.os.linux.IN.MODIFY |
        std.os.linux.IN.CLOSE_WRITE |
        std.os.linux.IN.DELETE_SELF |
        std.os.linux.IN.MOVE_SELF;

    fn addPath(self: *InotifyBackend, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.path_map.contains(path)) return;

        // 존재하지 않는 파일은 스킵 (kqueue와 동일 동작)
        const wd = posix.inotify_add_watch(self.inotify_fd, path, watch_mask) catch return;

        const path_owned = try allocator.dupe(u8, path);
        try self.wd_map.put(wd, path_owned);
        try self.path_map.put(path_owned, wd);
    }

    fn removePath(self: *InotifyBackend, allocator: std.mem.Allocator, path: []const u8) void {
        if (self.path_map.fetchRemove(path)) |kv| {
            const wd = kv.value;
            // inotify_rm_watch
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd, wd);
            if (self.wd_map.fetchRemove(wd)) |wkv| {
                allocator.free(wkv.value);
            }
        }
    }

    fn clearPaths(self: *InotifyBackend, allocator: std.mem.Allocator) void {
        var it = self.wd_map.iterator();
        while (it.next()) |entry| {
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd, entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.wd_map.clearRetainingCapacity();
        self.path_map.clearRetainingCapacity();
    }

    fn waitForChanges(self: *InotifyBackend, allocator: std.mem.Allocator, timeout_ms: u32) ![]const ChangeEvent {
        self.result_buf.clearRetainingCapacity();

        // poll로 timeout 대기
        var fds = [_]std.posix.pollfd{.{
            .fd = self.inotify_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const poll_result = try std.posix.poll(&fds, @intCast(timeout_ms));
        if (poll_result == 0) return self.result_buf.items; // timeout

        // inotify 이벤트 읽기
        const n = std.posix.read(self.inotify_fd, &self.read_buf) catch return self.result_buf.items;
        var offset: usize = 0;
        // 재등록이 필요한 경로 (atomic write로 inode가 바뀐 경우)
        var rewatch_count: usize = 0;
        var rewatch_paths: [64][]const u8 = undefined;

        while (offset < n) {
            const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&self.read_buf[offset]));
            offset += @sizeOf(std.os.linux.inotify_event) + event.len;

            const path = self.wd_map.get(event.wd) orelse continue;
            const is_delete = event.mask & std.os.linux.IN.DELETE_SELF != 0;
            const is_move = event.mask & std.os.linux.IN.MOVE_SELF != 0;

            const kind: ChangeKind = if (is_delete or is_move) .deleted else .modified;
            try self.result_buf.append(allocator, .{ .path = path, .kind = kind });

            // atomic write (새 파일 → rename)로 inode가 바뀌면 watch가 해제됨.
            // 같은 경로로 재등록하여 새 inode를 감시.
            if ((is_delete or is_move) and rewatch_count < rewatch_paths.len) {
                rewatch_paths[rewatch_count] = path;
                rewatch_count += 1;
            }
        }

        // 삭제/이동된 파일의 watch 재등록 시도
        for (rewatch_paths[0..rewatch_count]) |path| {
            // 이전 watch 해제
            if (self.path_map.get(path)) |old_wd| {
                _ = self.wd_map.remove(old_wd);
            }
            // 새 inode로 재등록 (파일이 아직 없으면 실패 → 다음 rebuild에서 처리)
            const new_wd = posix.inotify_add_watch(self.inotify_fd, path, watch_mask) catch continue;
            self.wd_map.put(new_wd, path) catch {};
            self.path_map.put(path, new_wd) catch {};
        }

        return self.result_buf.items;
    }

    fn watchCount(self: *const InotifyBackend) usize {
        return self.path_map.count();
    }
};

// ============================================================
// mtime 폴링 폴백 (Windows, 기타 OS)
// ============================================================

const MtimeBackend = struct {
    paths: std.StringHashMap(i128), // path → mtime
    result_buf: std.ArrayList(ChangeEvent),

    fn init(allocator: std.mem.Allocator) !MtimeBackend {
        return .{
            .paths = std.StringHashMap(i128).init(allocator),
            .result_buf = .empty,
        };
    }

    fn deinit(self: *MtimeBackend, allocator: std.mem.Allocator) void {
        var it = self.paths.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.paths.deinit();
        self.result_buf.deinit(allocator);
    }

    fn addPath(self: *MtimeBackend, allocator: std.mem.Allocator, path: []const u8) !void {
        if (self.paths.contains(path)) return;
        const path_owned = try allocator.dupe(u8, path);
        const stat = std.fs.cwd().statFile(path) catch {
            try self.paths.put(path_owned, 0);
            return;
        };
        try self.paths.put(path_owned, stat.mtime);
    }

    fn removePath(self: *MtimeBackend, allocator: std.mem.Allocator, path: []const u8) void {
        if (self.paths.fetchRemove(path)) |kv| {
            allocator.free(kv.key);
        }
    }

    fn clearPaths(self: *MtimeBackend, allocator: std.mem.Allocator) void {
        var it = self.paths.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.paths.clearRetainingCapacity();
    }

    fn waitForChanges(self: *MtimeBackend, allocator: std.mem.Allocator, timeout_ms: u32) ![]const ChangeEvent {
        self.result_buf.clearRetainingCapacity();

        // mtime 폴링: timeout/2 간격으로 2회 체크
        const interval = @max(timeout_ms / 2, 100);
        var elapsed: u32 = 0;

        while (elapsed < timeout_ms) {
            std.Thread.sleep(@as(u64, interval) * std.time.ns_per_ms);
            elapsed += interval;

            var it = self.paths.iterator();
            while (it.next()) |entry| {
                const stat = std.fs.cwd().statFile(entry.key_ptr.*) catch {
                    try self.result_buf.append(allocator, .{ .path = entry.key_ptr.*, .kind = .deleted });
                    continue;
                };
                if (stat.mtime != entry.value_ptr.*) {
                    entry.value_ptr.* = stat.mtime;
                    try self.result_buf.append(allocator, .{ .path = entry.key_ptr.*, .kind = .modified });
                }
            }

            if (self.result_buf.items.len > 0) break;
        }

        return self.result_buf.items;
    }

    fn watchCount(self: *const MtimeBackend) usize {
        return self.paths.count();
    }
};
