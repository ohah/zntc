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
    /// 각 훅에 플러그인이 등록되어 있는지 (핸드셰이크에서 설정)
    has_resolve: bool = false,
    has_load: bool = false,
    has_transform: bool = false,

    /// target이 필터의 suffix 또는 prefix에 매칭되면 true.
    /// suffix: ".css", ".svg" / prefix: "virtual:", "\0"
    /// 필터가 비어있으면 모든 대상에 적용 (esbuild 호환).
    pub fn matchesAny(filters: []const []const u8, target: []const u8) bool {
        if (filters.len == 0) return true;
        for (filters) |f| {
            if (std.mem.endsWith(u8, target, f) or std.mem.startsWith(u8, target, f)) return true;
        }
        return false;
    }
};

pub const SubprocessPlugin = struct {
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    read_buf: [8192]u8 = undefined,
    read_buf_len: usize = 0,
    read_buf_pos: usize = 0,
    next_id: u32 = 1,
    ipc_mutex: std.Thread.Mutex = .{},
    filters: FilterMap = .{},
    /// 플러그인 이름 (핸드셰이크에서 수신, 에러 메시지용)
    plugin_name: []const u8 = "subprocess",
    /// 마지막 플러그인 에러 메시지 (stderr 출력용)
    last_error: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    filter_arena: std.heap.ArenaAllocator,

    /// Node.js 프로세스를 spawn하고 핸드셰이크를 수행.
    pub fn spawn(allocator: std.mem.Allocator, config_path: []const u8) !*SubprocessPlugin {
        var child = std.process.Child.init(
            &.{ "node", config_path },
            allocator,
        );
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        const stdin_file = child.stdin orelse return error.SpawnFailed;
        const stdout_file = child.stdout orelse return error.SpawnFailed;

        const self = try allocator.create(SubprocessPlugin);
        self.* = .{
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .allocator = allocator,
            .filter_arena = std.heap.ArenaAllocator.init(allocator),
        };

        try self.handshake();

        return self;
    }

    /// 핸드셰이크: {"id":0,"type":"init"} 전송 → 필터 목록 수신
    fn handshake(self: *SubprocessPlugin) !void {
        try self.sendRaw("{\"id\":0,\"type\":\"init\"}\n");

        // filter_arena에 응답을 할당 — parseFromSliceLeaky가 문자열을 참조하므로 arena와 같은 수명 필요
        const arena_alloc = self.filter_arena.allocator();
        const response = self.readLine(arena_alloc) catch return error.PluginFailed;

        const init_resp = std.json.parseFromSliceLeaky(InitResponse, arena_alloc, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        const resolve_f = init_resp.filters.resolveId orelse &.{};
        const load_f = init_resp.filters.load orelse &.{};
        const transform_f = init_resp.filters.transform orelse &.{};
        self.filters = .{
            .resolve_filters = resolve_f,
            .load_filters = load_f,
            .transform_filters = transform_f,
            .has_resolve = init_resp.hooks.resolveId orelse (resolve_f.len > 0),
            .has_load = init_resp.hooks.load orelse (load_f.len > 0),
            .has_transform = init_resp.hooks.transform orelse (transform_f.len > 0),
        };
        if (init_resp.name) |name| {
            self.plugin_name = name;
        }
    }

    /// 플러그인 에러를 stderr에 출력
    fn reportError(self: *SubprocessPlugin, hook_name: []const u8, target: []const u8, err_msg: ?[]const u8) void {
        const w = std.fs.File.stderr().deprecatedWriter();
        if (err_msg) |msg| {
            w.print("[plugin:{s}] {s} error for '{s}': {s}\n", .{ self.plugin_name, hook_name, target, msg }) catch {};
        } else {
            w.print("[plugin:{s}] {s} failed for '{s}'\n", .{ self.plugin_name, hook_name, target }) catch {};
        }
    }

    /// Plugin 인터페이스로 변환. context에 self 포인터 전달.
    pub fn toPlugin(self: *SubprocessPlugin) Plugin {
        return .{
            .name = self.plugin_name,
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
        // stdin close → Node.js에 EOF 전달 → 프로세스 종료 유도
        self.stdin_file.close();
        self.stdout_file.close();
        // child.wait()가 이미 닫힌 fd를 다시 닫지 않도록 null 설정
        self.child.stdin = null;
        self.child.stdout = null;
        _ = self.child.wait() catch {};
        self.filter_arena.deinit();
        self.allocator.destroy(self);
    }

    // ===== IPC 함수 =====

    fn sendRaw(self: *SubprocessPlugin, data: []const u8) !void {
        try self.stdin_file.writeAll(data);
    }

    /// JSON 요청 전송 + 응답 읽기 (mutex로 보호). caller가 응답을 free.
    fn sendAndReceive(self: *SubprocessPlugin, allocator: std.mem.Allocator, msg_type: []const u8, fields: []const u8) ![]u8 {
        self.ipc_mutex.lock();
        defer self.ipc_mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        const request = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"type\":\"{s}\",{s}}}\n", .{ id, msg_type, fields });
        defer allocator.free(request);
        try self.sendRaw(request);
        return self.readLine(allocator);
    }

    /// stdout에서 한 줄 읽기 (줄바꿈 경계 정확 처리). heap 할당, caller가 free.
    fn readLine(self: *SubprocessPlugin, allocator: std.mem.Allocator) ![]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);

        while (true) {
            // 내부 버퍼에 데이터가 있으면 줄바꿈 검색
            if (self.read_buf_pos < self.read_buf_len) {
                const remaining = self.read_buf[self.read_buf_pos..self.read_buf_len];
                if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_pos| {
                    try line.appendSlice(allocator, remaining[0..nl_pos]);
                    self.read_buf_pos += nl_pos + 1; // 줄바꿈 건너뜀
                    return line.toOwnedSlice(allocator);
                }
                // 줄바꿈 없으면 남은 전부 복사
                try line.appendSlice(allocator, remaining);
                self.read_buf_pos = 0;
                self.read_buf_len = 0;
            }

            // 버퍼 리필
            const n = self.stdout_file.read(&self.read_buf) catch return error.PluginFailed;
            if (n == 0) {
                if (line.items.len > 0) return line.toOwnedSlice(allocator);
                return error.EndOfStream;
            }
            self.read_buf_len = n;
            self.read_buf_pos = 0;
        }
    }

    // ===== 훅 구현 =====

    fn subprocessResolveId(ctx: ?*anyopaque, specifier: []const u8, importer: ?[]const u8, allocator: std.mem.Allocator) PluginError!?ResolveResult {
        const self = getSelf(ctx);
        if (!self.filters.has_resolve) return null;
        if (!FilterMap.matchesAny(self.filters.resolve_filters, specifier)) return null;

        const escaped_spec = escapeJsonString(allocator, specifier) catch return error.OutOfMemory;
        defer allocator.free(escaped_spec);
        const escaped_imp = escapeJsonString(allocator, importer orelse "") catch return error.OutOfMemory;
        defer allocator.free(escaped_imp);

        const fields = std.fmt.allocPrint(allocator, "\"specifier\":\"{s}\",\"importer\":\"{s}\"", .{
            escaped_spec, escaped_imp,
        }) catch return error.OutOfMemory;
        defer allocator.free(fields);

        const response = self.sendAndReceive(allocator, "resolveId", fields) catch {
            self.reportError("resolveId", specifier, null);
            return error.PluginFailed;
        };
        defer allocator.free(response);
        const parsed = std.json.parseFromSliceLeaky(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        if (parsed.@"error") |err_msg| {
            self.reportError("resolveId", specifier, err_msg);
            return error.PluginFailed;
        }

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
        if (!self.filters.has_load) return null;
        if (!FilterMap.matchesAny(self.filters.load_filters, path)) return null;

        const escaped_path = escapeJsonString(allocator, path) catch return error.OutOfMemory;
        defer allocator.free(escaped_path);

        const fields = std.fmt.allocPrint(allocator, "\"path\":\"{s}\"", .{escaped_path}) catch return error.OutOfMemory;
        defer allocator.free(fields);

        const response = self.sendAndReceive(allocator, "load", fields) catch {
            self.reportError("load", path, null);
            return error.PluginFailed;
        };
        defer allocator.free(response);
        const parsed = std.json.parseFromSliceLeaky(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        if (parsed.@"error") |err_msg| {
            self.reportError("load", path, err_msg);
            return error.PluginFailed;
        }

        if (parsed.result) |result| {
            if (result.contents) |contents| {
                return allocator.dupe(u8, contents) catch return error.OutOfMemory;
            }
        }
        return null;
    }

    fn subprocessTransform(ctx: ?*anyopaque, code: []const u8, id: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 {
        const self = getSelf(ctx);
        if (!self.filters.has_transform) return null;
        if (!FilterMap.matchesAny(self.filters.transform_filters, id)) return null;

        const escaped_code = escapeJsonString(allocator, code) catch return error.OutOfMemory;
        defer allocator.free(escaped_code);
        const escaped_id = escapeJsonString(allocator, id) catch return error.OutOfMemory;
        defer allocator.free(escaped_id);

        const fields = std.fmt.allocPrint(allocator, "\"code\":\"{s}\",\"moduleId\":\"{s}\"", .{
            escaped_code, escaped_id,
        }) catch return error.OutOfMemory;
        defer allocator.free(fields);

        const response = self.sendAndReceive(allocator, "transform", fields) catch {
            self.reportError("transform", id, null);
            return error.PluginFailed;
        };
        defer allocator.free(response);
        const parsed = std.json.parseFromSliceLeaky(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;

        if (parsed.@"error") |err_msg| {
            self.reportError("transform", id, err_msg);
            return error.PluginFailed;
        }

        if (parsed.result) |result| {
            if (result.contents) |contents| {
                return allocator.dupe(u8, contents) catch return error.OutOfMemory;
            }
        }
        return null;
    }

    inline fn getSelf(ctx: ?*anyopaque) *SubprocessPlugin {
        return @ptrCast(@alignCast(ctx.?));
    }
};

// ===== JSON 타입 =====

const InitResponse = struct {
    id: u32 = 0,
    name: ?[]const u8 = null,
    filters: Filters = .{},
    hooks: Hooks = .{},
    @"error": ?[]const u8 = null,

    const Filters = struct {
        resolveId: ?[]const []const u8 = null,
        load: ?[]const []const u8 = null,
        transform: ?[]const []const u8 = null,
    };

    /// 각 훅에 콜백이 등록되어 있는지 (필터가 비어도 훅이 없으면 IPC 건너뜀)
    const Hooks = struct {
        resolveId: ?bool = null,
        load: ?bool = null,
        transform: ?bool = null,
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

/// JSON 문자열 이스케이프 (줄바꿈, 탭, 따옴표, 백슬래시, 제어 문자)
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
