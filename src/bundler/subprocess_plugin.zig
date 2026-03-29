//! ZTS Bundler — Subprocess Plugin
//!
//! Node.js 프로세스를 spawn하여 stdin/stdout JSON 메시지로 통신하는
//! esbuild 방식의 JS 플러그인 시스템.
//!
//! 생명주기:
//!   1. spawn() — Node.js 프로세스 실행 + 핸드셰이크 (필터 목록 수신)
//!   2. toPlugin() — Plugin 인터페이스로 변환 (파이프라인에 주입)
//!   3. 번들링 중 — 필터 매칭 시 JSON 요청/응답 교환
//!   4. shutdown() — 프로세스 종료
//!
//! JSON 프로토콜:
//!   ZTS→Node: {"id":N,"type":"resolveId","specifier":"...","importer":"..."}\n
//!   Node→ZTS: {"id":N,"result":{"path":"..."},"error":null}\n

const std = @import("std");
const plugin_mod = @import("plugin.zig");
const Plugin = plugin_mod.Plugin;
const PluginError = plugin_mod.PluginError;
const ResolveResult = @import("resolver.zig").ResolveResult;
const OutputFile = @import("emitter.zig").OutputFile;

/// 훅별 suffix 필터 목록.
/// ZTS가 각 모듈에 대해 suffix 매칭 후, 매칭된 경우에만 IPC 호출.
pub const FilterMap = struct {
    resolve_filters: []const []const u8 = &.{},
    load_filters: []const []const u8 = &.{},
    transform_filters: []const []const u8 = &.{},

    /// specifier가 필터 목록의 어떤 suffix로든 끝나면 true
    pub fn matchesAny(filters: []const []const u8, target: []const u8) bool {
        if (filters.len == 0) return true; // 필터 없으면 모든 대상에 적용
        for (filters) |f| {
            if (std.mem.endsWith(u8, target, f)) return true;
        }
        return false;
    }
};

pub const SubprocessPlugin = struct {
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    next_id: u32 = 1,
    filters: FilterMap = .{},
    allocator: std.mem.Allocator,
    /// 핸드셰이크에서 수신한 필터 문자열 저장용
    filter_arena: std.heap.ArenaAllocator,

    /// Node.js 프로세스를 spawn하고 핸드셰이크를 수행.
    /// 실패 시 에러 반환, 성공 시 heap에 할당된 포인터 반환.
    pub fn spawn(allocator: std.mem.Allocator, config_path: []const u8) !*SubprocessPlugin {
        var child = std.process.Child.init(
            &.{ "node", config_path },
            allocator,
        );
        child.stdin_behavior = .pipe;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .inherit;

        try child.spawn();

        const stdin_file = child.stdin orelse return error.StdinNotAvailable;
        const stdout_file = child.stdout orelse return error.StdoutNotAvailable;

        const self = try allocator.create(SubprocessPlugin);
        self.* = .{
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .allocator = allocator,
            .filter_arena = std.heap.ArenaAllocator.init(allocator),
        };

        // 핸드셰이크: init 메시지 전송 → 필터 목록 수신
        try self.handshake();

        return self;
    }

    /// 핸드셰이크: {"id":0,"type":"init"} 전송 → 필터 목록 수신
    fn handshake(self: *SubprocessPlugin) !void {
        try self.sendRaw("{\"id\":0,\"type\":\"init\"}\n");

        const response = try self.readLine();
        // 응답에서 필터 파싱
        const arena_alloc = self.filter_arena.allocator();
        const parsed = std.json.parseFromSlice(InitResponse, arena_alloc, response, .{
            .ignore_unknown_fields = true,
        }) catch return; // 핸드셰이크 파싱 실패 시 필터 없이 진행
        const init_resp = parsed.value;

        self.filters = .{
            .resolve_filters = init_resp.filters.resolveId orelse &.{},
            .load_filters = init_resp.filters.load orelse &.{},
            .transform_filters = init_resp.filters.transform orelse &.{},
        };
    }

    /// Plugin 인터페이스로 변환. context에 self 포인터 전달.
    pub fn toPlugin(self: *SubprocessPlugin) Plugin {
        return .{
            .name = "subprocess",
            .context = @ptrCast(self),
            .resolveId = subprocessResolveId,
            .load = subprocessLoad,
            .transform = subprocessTransform,
            .renderChunk = null,
            .generateBundle = null,
        };
    }

    /// 프로세스 종료.
    pub fn shutdown(self: *SubprocessPlugin) void {
        self.sendRaw("{\"type\":\"shutdown\"}\n") catch {};
        // stdin 닫으면 Node.js가 자연스럽게 종료됨
        self.stdin_file.close();
        _ = self.child.wait() catch {};
        self.filter_arena.deinit();
        self.allocator.destroy(self);
    }

    // ===== IPC 함수 =====

    /// stdin에 원시 바이트 쓰기
    fn sendRaw(self: *SubprocessPlugin, data: []const u8) !void {
        try self.stdin_file.writeAll(data);
    }

    /// JSON 요청 전송. 자동으로 \n 추가.
    fn sendJsonRequest(self: *SubprocessPlugin, allocator: std.mem.Allocator, msg_type: []const u8, fields: []const u8) !void {
        const id = self.next_id;
        self.next_id += 1;

        const request = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"type\":\"{s}\",{s}}}\n", .{ id, msg_type, fields });
        defer allocator.free(request);
        try self.sendRaw(request);
    }

    /// stdout에서 한 줄 읽기 (줄바꿈 제거)
    fn readLine(self: *SubprocessPlugin) ![]const u8 {
        var buf: [256 * 1024]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = self.stdout_file.read(buf[total..]) catch |err| {
                if (total > 0) break;
                return err;
            };
            if (n == 0) break; // EOF
            total += n;
            // 줄바꿈을 찾으면 거기까지만 반환
            if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
        }

        if (total == 0) return error.EndOfStream;

        // 줄바꿈 제거
        var end = total;
        while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) end -= 1;
        return buf[0..end];
    }

    /// JSON 응답에서 "result" 필드의 문자열 값을 추출.
    /// result가 null이면 null 반환. error가 있으면 PluginFailed.
    fn parseStringResult(self: *SubprocessPlugin, allocator: std.mem.Allocator, key: []const u8) PluginError!?[]const u8 {
        _ = self;
        _ = allocator;
        _ = key;
        // readLine + JSON 파싱은 각 훅 함수에서 직접 처리
        return null;
    }

    // ===== 훅 구현 (static 함수 — Plugin 함수 포인터에 대입) =====

    fn subprocessResolveId(ctx: ?*anyopaque, specifier: []const u8, importer: ?[]const u8, allocator: std.mem.Allocator) PluginError!?ResolveResult {
        const self = getSelf(ctx);
        if (!FilterMap.matchesAny(self.filters.resolve_filters, specifier)) return null;

        // JSON 요청 생성
        const importer_str = importer orelse "";
        const fields = std.fmt.allocPrint(allocator, "\"specifier\":\"{s}\",\"importer\":\"{s}\"", .{
            specifier, importer_str,
        }) catch return error.OutOfMemory;
        defer allocator.free(fields);

        self.sendJsonRequest(allocator, "resolveId", fields) catch return error.PluginFailed;

        // 응답 읽기 + 파싱
        const response = self.readLine() catch return error.PluginFailed;
        const parsed = std.json.parseFromSliceLeaky(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        if (parsed.@"error") |_| return error.PluginFailed;

        if (parsed.result) |result| {
            if (result.path) |path| {
                return .{
                    .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
                    .module_type = .javascript,
                };
            }
        }
        return null;
    }

    fn subprocessLoad(ctx: ?*anyopaque, path: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 {
        const self = getSelf(ctx);
        if (!FilterMap.matchesAny(self.filters.load_filters, path)) return null;

        const fields = std.fmt.allocPrint(allocator, "\"path\":\"{s}\"", .{path}) catch return error.OutOfMemory;
        defer allocator.free(fields);

        self.sendJsonRequest(allocator, "load", fields) catch return error.PluginFailed;

        const response = self.readLine() catch return error.PluginFailed;
        const parsed = std.json.parseFromSliceLeaky(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        if (parsed.@"error") |_| return error.PluginFailed;

        if (parsed.result) |result| {
            if (result.contents) |contents| {
                return allocator.dupe(u8, contents) catch return error.OutOfMemory;
            }
        }
        return null;
    }

    fn subprocessTransform(ctx: ?*anyopaque, code: []const u8, id: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 {
        const self = getSelf(ctx);
        if (!FilterMap.matchesAny(self.filters.transform_filters, id)) return null;

        // code에 특수문자가 있을 수 있으므로 JSON 이스케이프 필요
        const escaped_code = escapeJsonString(allocator, code) catch return error.OutOfMemory;
        defer allocator.free(escaped_code);

        const fields = std.fmt.allocPrint(allocator, "\"code\":\"{s}\",\"moduleId\":\"{s}\"", .{
            escaped_code, id,
        }) catch return error.OutOfMemory;
        defer allocator.free(fields);

        self.sendJsonRequest(allocator, "transform", fields) catch return error.PluginFailed;

        const response = self.readLine() catch return error.PluginFailed;
        const parsed = std.json.parseFromSliceLeaky(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        if (parsed.@"error") |_| return error.PluginFailed;

        if (parsed.result) |result| {
            if (result.contents) |contents| {
                return allocator.dupe(u8, contents) catch return error.OutOfMemory;
            }
        }
        return null;
    }

    /// context 포인터에서 SubprocessPlugin 포인터 복원
    inline fn getSelf(ctx: ?*anyopaque) *SubprocessPlugin {
        return @ptrCast(@alignCast(ctx.?));
    }
};

// ===== JSON 직렬화/역직렬화 타입 =====

const InitResponse = struct {
    id: u32 = 0,
    filters: Filters = .{},
    @"error": ?[]const u8 = null,

    const Filters = struct {
        resolveId: ?[]const []const u8 = null,
        load: ?[]const []const u8 = null,
        transform: ?[]const []const u8 = null,
    };
};

const HookResponse = struct {
    id: u32 = 0,
    result: ?HookResult = null,
    @"error": ?[]const u8 = null,

    const HookResult = struct {
        path: ?[]const u8 = null,
        contents: ?[]const u8 = null,
    };
};

/// JSON 문자열 이스케이프 (줄바꿈, 탭, 따옴표, 백슬래시)
fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const len = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try result.appendSlice(allocator, len);
                } else {
                    try result.append(allocator, c);
                }
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

// ===== 테스트 =====

test "FilterMap: matchesAny with empty filters matches everything" {
    try std.testing.expect(FilterMap.matchesAny(&.{}, "anything.ts"));
    try std.testing.expect(FilterMap.matchesAny(&.{}, "foo.css"));
}

test "FilterMap: matchesAny with suffix filters" {
    const filters: []const []const u8 = &.{ ".css", ".svg" };
    try std.testing.expect(FilterMap.matchesAny(filters, "styles.css"));
    try std.testing.expect(FilterMap.matchesAny(filters, "icon.svg"));
    try std.testing.expect(!FilterMap.matchesAny(filters, "index.ts"));
    try std.testing.expect(!FilterMap.matchesAny(filters, "data.json"));
}

test "escapeJsonString: basic escaping" {
    const result = try escapeJsonString(std.testing.allocator, "hello\nworld\t\"test\"\\path");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\\nworld\\t\\\"test\\\"\\\\path", result);
}

test "escapeJsonString: no escaping needed" {
    const result = try escapeJsonString(std.testing.allocator, "simple text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("simple text", result);
}
