//! CLI watch helpers.

const std = @import("std");

/// 폴링 fallback watch 의 mtime 확인 주기(ms). `--watch-delay`(기본 16) 값을 쓰되 0/과소값은
/// busy-loop 방지로 10ms floor. JS CLI(bin/zntc.mjs)의 fs.watch debounce 와 같은 노브 —
/// 거기선 이벤트 후 debounce, 폴링인 여기선 확인 주기. (예전엔 500ms 하드코딩이라 반응성 저하.)
pub fn pollIntervalMs(delay_ms: u32) i64 {
    return @max(@as(i64, delay_ms), 10);
}

/// 단일 파일을 폴링 방식으로 감시한다 (D048).
/// 파일의 mtime을 `delay_ms`(--watch-delay, 기본 16ms)마다 확인하여 변경되면 재트랜스파일.
/// Ctrl+C로 종료될 때까지 무한 루프를 돈다.
pub fn watchFile(
    comptime transpileFn: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    output_path: ?[]const u8,
    delay_ms: u32,
    options: anytype,
    stderr: anytype,
) !void {
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;

    // 초기 mtime 저장
    var last_mtime = getFileMtime(io, file_path) catch |err| {
        try stderr.print("zntc: cannot stat '{s}': {}\n", .{ file_path, err });
        return error.WatchFailed;
    };

    try stdout.print("[watch] Watching for file changes...\n", .{});

    const poll_ms = pollIntervalMs(delay_ms);
    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(poll_ms), .awake) catch {};

        const current_mtime = getFileMtime(io, file_path) catch continue;

        if (current_mtime != last_mtime) {
            last_mtime = current_mtime;
            try stdout.print("[watch] File changed: {s}\n", .{file_path});
            transpileFn(allocator, io, file_path, null, output_path, options) catch |err| {
                try stderr.print("zntc: watch re-transpile error: {}\n", .{err});
            };
        }
    }
}

/// 디렉토리를 폴링 방식으로 감시한다 (D048).
/// 매 `delay_ms`(--watch-delay, 기본 16ms)마다 디렉토리를 재순회하여 .ts/.tsx 파일의
/// mtime을 확인하고, 변경된 파일만 재트랜스파일한다.
pub fn watchDirectory(
    comptime transpileFn: anytype,
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    output_dir: []const u8,
    delay_ms: u32,
    options: anytype,
    stderr: anytype,
) !void {
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;

    // mtime 맵: 파일 경로(소유) -> mtime
    var mtime_map: std.StringHashMapUnmanaged(i128) = .empty;
    defer {
        var it = mtime_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        mtime_map.deinit(allocator);
    }

    // 초기 mtime 수집
    try collectMtimes(allocator, io, input_dir, &mtime_map);

    try stdout.print("[watch] Watching for file changes...\n", .{});

    const poll_ms = pollIntervalMs(delay_ms);
    while (true) {
        io.sleep(std.Io.Duration.fromMilliseconds(poll_ms), .awake) catch {};

        // 현재 파일 상태 수집
        var current_mtimes: std.StringHashMapUnmanaged(i128) = .empty;
        defer {
            var it = current_mtimes.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            current_mtimes.deinit(allocator);
        }

        collectMtimes(allocator, io, input_dir, &current_mtimes) catch continue;

        // 변경된 파일 찾기
        var it = current_mtimes.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const current_mtime = entry.value_ptr.*;

            const old_mtime = mtime_map.get(path);
            if (old_mtime == null or old_mtime.? != current_mtime) {
                try stdout.print("[watch] File changed: {s}\n", .{path});

                // 출력 경로 계산
                // path는 input_dir/relative 형태이므로 input_dir 접두사를 제거
                const rel_path = if (std.mem.startsWith(u8, path, input_dir))
                    path[input_dir.len + 1 ..] // +1 for path separator
                else
                    path;

                const is_tsx = std.mem.endsWith(u8, rel_path, ".tsx");
                const basename_no_ext = if (is_tsx)
                    rel_path[0 .. rel_path.len - 4]
                else
                    rel_path[0 .. rel_path.len - 3];
                const output_rel = try std.fmt.allocPrint(allocator, "{s}.js", .{basename_no_ext});
                defer allocator.free(output_rel);
                const out_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel });
                defer allocator.free(out_path);

                transpileFn(allocator, io, path, null, out_path, options) catch |err| {
                    try stderr.print("zntc: watch re-transpile error: {}\n", .{err});
                };

                // mtime 맵 업데이트 - 키를 복제하여 저장
                const owned_key = try allocator.dupe(u8, path);
                if (mtime_map.fetchPut(allocator, owned_key, current_mtime) catch null) |old| {
                    allocator.free(old.key);
                }
            }
        }
    }
}

/// JSON 문자열을 이스케이프하여 출력한다 (--watch-json용).
pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                // RFC 8259: 제어 문자 (0x00-0x1F)는 \u00XX로 이스케이프
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

/// 파일의 mtime(수정 시각)을 i128 나노초 단위로 반환한다.
pub fn getFileMtime(io: std.Io, path: []const u8) !i128 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    // 0.16: stat.mtime 은 Io.Timestamp → ns(i128) 로 변환.
    return stat.mtime.toNanoseconds();
}

/// path → mtime upsert. 키 충돌 시 std.HashMap.put 이 기존 키 유지 +
/// 값만 갱신하는 동작 때문에 무조건 dupe 후 put 하면 두 번째 dupe 가 leak.
/// getPtr 로 존재 확인 후 새 entry 일 때만 dupe.
pub fn upsertMtimePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    map: *std.StringHashMapUnmanaged(i128),
    path: []const u8,
) void {
    const mt = getFileMtime(io, path) catch return;
    if (map.getPtr(path)) |existing| {
        existing.* = mt;
        return;
    }
    const duped = allocator.dupe(u8, path) catch return;
    map.put(allocator, duped, mt) catch allocator.free(duped);
}

/// 디렉토리를 순회하며 .ts/.tsx 파일의 mtime을 수집한다.
/// mtime_map에 파일 전체 경로(소유) -> mtime을 저장한다.
pub fn collectMtimes(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    mtime_map: *std.StringHashMapUnmanaged(i128),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, input_dir, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const path = entry.path;
        if (std.mem.indexOf(u8, path, "node_modules") != null) continue;

        const is_ts = std.mem.endsWith(u8, path, ".ts");
        const is_tsx = std.mem.endsWith(u8, path, ".tsx");
        if (!is_ts and !is_tsx) continue;
        if (std.mem.endsWith(u8, path, ".d.ts")) continue;

        // 전체 경로 구성
        const full_path = try std.fs.path.join(allocator, &.{ input_dir, path });

        const mtime = getFileMtime(io, full_path) catch {
            allocator.free(full_path);
            continue;
        };

        // full_path를 키로 소유권 이전
        mtime_map.put(allocator, full_path, mtime) catch {
            allocator.free(full_path);
            continue;
        };
    }
}

/// watchFolder 루트를 재귀 스캔해 파일 mtime을 mtime_map에 등록.
/// visitor는 true 반환으로 full_path 소유권을 map 키로 이전한다.
pub fn collectWatchRootMtimes(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    mtime_map: *std.StringHashMapUnmanaged(i128),
) !void {
    // 0.16: statFile 가 io 를 요구하므로 visitor closure 가 ctx 로 io 를 받는다.
    const Ctx = struct { map: *std.StringHashMapUnmanaged(i128), allocator: std.mem.Allocator, io: std.Io };
    const visit = struct {
        fn f(ctx: Ctx, full_path: []const u8) bool {
            const gop = ctx.map.getOrPut(ctx.allocator, full_path) catch return false;
            if (gop.found_existing) return false;
            gop.value_ptr.* = getFileMtime(ctx.io, full_path) catch {
                _ = ctx.map.remove(full_path);
                return false;
            };
            return true;
        }
    }.f;
    try @import("zntc_lib").server.watch_scan.scanRoot(
        allocator,
        io,
        root,
        .{ .include = include, .exclude = exclude },
        Ctx{ .map = mtime_map, .allocator = allocator, .io = io },
        visit,
    );
}
