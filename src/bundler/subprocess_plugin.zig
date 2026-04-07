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
    has_render_chunk: bool = false,
    has_generate_bundle: bool = false,

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
    plugin_name: []const u8 = "subprocess",
    last_error: ?[]const u8 = null,
    /// config 파일에서 전달된 빌드 옵션
    config: InitResponse.ConfigOptions = .{},
    allocator: std.mem.Allocator,
    filter_arena: std.heap.ArenaAllocator,

    /// Node.js/Bun 프로세스를 spawn하고 핸드셰이크를 수행.
    /// .ts/.mts/.cts 파일은 bun 또는 tsx로 실행.
    pub fn spawn(allocator: std.mem.Allocator, config_path: []const u8) !*SubprocessPlugin {
        const runtime = detectRuntime();
        var argv_buf: [3][]const u8 = undefined;
        const argv: []const []const u8 = switch (runtime) {
            .bun => blk: {
                argv_buf = .{ "bun", "run", config_path };
                break :blk argv_buf[0..3];
            },
            .node => blk: {
                argv_buf = .{ "node", config_path, "" };
                break :blk argv_buf[0..2];
            },
        };

        var child = std.process.Child.init(argv, allocator);
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

        self.handshake() catch {
            self.shutdown();
            return error.PluginFailed;
        };

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
            .has_render_chunk = init_resp.hooks.renderChunk orelse false,
            .has_generate_bundle = init_resp.hooks.generateBundle orelse false,
        };
        if (init_resp.name) |name| {
            self.plugin_name = name;
        }
        self.config = init_resp.config;
    }

    /// config에서 loader 옵션을 loader_overrides 배열로 변환
    pub fn getLoaderOverrides(self: *SubprocessPlugin, allocator: std.mem.Allocator) ![]const @import("types.zig").LoaderOverride {
        const LoaderOverride = @import("types.zig").LoaderOverride;
        const Loader = @import("types.zig").Loader;
        const loader_val = self.config.loader orelse return &.{};
        if (loader_val != .object) return &.{};

        var result: std.ArrayList(LoaderOverride) = .empty;
        var it = loader_val.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                const loader = Loader.fromString(entry.value_ptr.string) orelse continue;
                try result.append(allocator, .{ .ext = entry.key_ptr.*, .loader = loader });
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// config에서 define 옵션을 define 배열로 변환
    pub fn getDefines(self: *SubprocessPlugin, allocator: std.mem.Allocator) ![]const @import("../transformer/transformer.zig").DefineEntry {
        const DefineEntry = @import("../transformer/transformer.zig").DefineEntry;
        const define_val = self.config.define orelse return &.{};
        if (define_val != .object) return &.{};

        var result: std.ArrayList(DefineEntry) = .empty;
        var it = define_val.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                try result.append(allocator, .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string });
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// config에서 external 배열 반환
    pub fn getExternals(self: *SubprocessPlugin) []const []const u8 {
        return self.config.external orelse &.{};
    }

    /// config에서 alias 옵션을 AliasEntry 배열로 변환
    pub fn getAliases(self: *SubprocessPlugin, allocator: std.mem.Allocator) ![]const @import("types.zig").AliasEntry {
        const AliasEntry = @import("types.zig").AliasEntry;
        const alias_val = self.config.alias orelse return &.{};
        if (alias_val != .object) return &.{};

        var result: std.ArrayList(AliasEntry) = .empty;
        var it = alias_val.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == .string) {
                try result.append(allocator, .{ .from = entry.key_ptr.*, .to = entry.value_ptr.string });
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// config에서 inject 배열 반환
    pub fn getInject(self: *SubprocessPlugin) []const []const u8 {
        return self.config.inject orelse &.{};
    }

    /// config에서 banner.js 반환
    pub fn getBannerJs(self: *SubprocessPlugin) ?[]const u8 {
        const banner_val = self.config.banner orelse return null;
        if (banner_val != .object) return null;
        const js_val = banner_val.object.get("js") orelse return null;
        if (js_val == .string) return js_val.string;
        return null;
    }

    /// config에서 footer.js 반환
    pub fn getFooterJs(self: *SubprocessPlugin) ?[]const u8 {
        const footer_val = self.config.footer orelse return null;
        if (footer_val != .object) return null;
        const js_val = footer_val.object.get("js") orelse return null;
        if (js_val == .string) return js_val.string;
        return null;
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
            .renderChunk = subprocessRenderChunk,
            .generateBundle = subprocessGenerateBundle,
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
        const parsed = std.json.parseFromSlice(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;
        defer parsed.deinit();

        if (parsed.value.@"error") |err_msg| {
            self.reportError("resolveId", specifier, err_msg);
            return error.PluginFailed;
        }

        if (parsed.value.result) |result| {
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
        const parsed = std.json.parseFromSlice(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;
        defer parsed.deinit();

        if (parsed.value.@"error") |err_msg| {
            self.reportError("load", path, err_msg);
            return error.PluginFailed;
        }

        if (parsed.value.result) |result| {
            if (result.contents) |contents| {
                // loader에 따라 JS 모듈로 래핑 (esbuild 호환)
                const loader_str = result.loader orelse "js";
                if (std.mem.eql(u8, loader_str, "text") or std.mem.eql(u8, loader_str, "css")) {
                    const escaped = escapeJsonString(allocator, contents) catch return error.OutOfMemory;
                    defer allocator.free(escaped);
                    return std.fmt.allocPrint(allocator, "export default \"{s}\";", .{escaped}) catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, loader_str, "json")) {
                    return std.fmt.allocPrint(allocator, "export default {s};", .{contents}) catch return error.OutOfMemory;
                }
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
        const parsed = std.json.parseFromSlice(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;
        defer parsed.deinit();

        if (parsed.value.@"error") |err_msg| {
            self.reportError("transform", id, err_msg);
            return error.PluginFailed;
        }

        if (parsed.value.result) |result| {
            if (result.contents) |contents| {
                return allocator.dupe(u8, contents) catch return error.OutOfMemory;
            }
        }
        return null;
    }

    fn subprocessRenderChunk(ctx: ?*anyopaque, code: []const u8, chunk_name: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 {
        const self = getSelf(ctx);
        if (!self.filters.has_render_chunk) return null;

        const escaped_code = escapeJsonString(allocator, code) catch return error.OutOfMemory;
        defer allocator.free(escaped_code);
        const escaped_name = escapeJsonString(allocator, chunk_name) catch return error.OutOfMemory;
        defer allocator.free(escaped_name);

        const fields = std.fmt.allocPrint(allocator, "\"code\":\"{s}\",\"chunkName\":\"{s}\"", .{
            escaped_code, escaped_name,
        }) catch return error.OutOfMemory;
        defer allocator.free(fields);

        const response = self.sendAndReceive(allocator, "renderChunk", fields) catch {
            self.reportError("renderChunk", chunk_name, null);
            return error.PluginFailed;
        };
        defer allocator.free(response);
        const parsed = std.json.parseFromSlice(HookResponse, allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return error.PluginFailed;
        defer parsed.deinit();

        if (parsed.value.@"error") |err_msg| {
            self.reportError("renderChunk", chunk_name, err_msg);
            return error.PluginFailed;
        }

        if (parsed.value.result) |result| {
            if (result.contents) |contents| {
                return allocator.dupe(u8, contents) catch return error.OutOfMemory;
            }
        }
        return null;
    }

    fn subprocessGenerateBundle(ctx: ?*anyopaque, output_files: []const OutputFile) void {
        const self = getSelf(ctx);
        if (!self.filters.has_generate_bundle) return;

        // 출력 파일 목록을 JSON 배열로 전송
        var fields_buf: std.ArrayList(u8) = .empty;
        defer fields_buf.deinit(self.allocator);

        fields_buf.appendSlice(self.allocator, "\"outputs\":[") catch return;
        for (output_files, 0..) |f, i| {
            if (i > 0) fields_buf.append(self.allocator, ',') catch return;
            fields_buf.appendSlice(self.allocator, "{\"path\":\"") catch return;
            const escaped = escapeJsonString(self.allocator, f.path) catch return;
            defer self.allocator.free(escaped);
            fields_buf.appendSlice(self.allocator, escaped) catch return;
            fields_buf.appendSlice(self.allocator, "\"}") catch return;
        }
        fields_buf.append(self.allocator, ']') catch return;

        const response = self.sendAndReceive(self.allocator, "generateBundle", fields_buf.items) catch return;
        defer self.allocator.free(response);

        // Parse response to check for emitted files from plugins
        const parsed = std.json.parseFromSlice(GenerateBundleResponse, self.allocator, response, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();

        if (parsed.value.@"error") |err_msg| {
            self.reportError("generateBundle", "bundle", err_msg);
            return;
        }

        // Write emitted files to disk (relative to outdir of the first output file)
        if (parsed.value.result) |result| {
            const emitted = result.emittedFiles orelse return;
            if (emitted.len == 0) return;

            // Determine outdir from the first output file's parent directory
            const outdir: ?[]const u8 = if (output_files.len > 0) blk: {
                if (std.fs.path.dirname(output_files[0].path)) |dir| break :blk dir;
                break :blk null;
            } else null;

            for (emitted) |file| {
                const file_name = file.fileName orelse continue;
                const source = file.source orelse continue;

                // Build the full output path
                const full_path = if (outdir) |dir|
                    std.fs.path.join(self.allocator, &.{ dir, file_name }) catch continue
                else
                    self.allocator.dupe(u8, file_name) catch continue;
                defer self.allocator.free(full_path);

                // Ensure parent directory exists
                if (std.fs.path.dirname(full_path)) |parent| {
                    std.fs.cwd().makePath(parent) catch {};
                }

                // Write the file
                const file_handle = std.fs.cwd().createFile(full_path, .{}) catch {
                    self.reportError("emitFile", file_name, "failed to create file");
                    continue;
                };
                defer file_handle.close();
                file_handle.writeAll(source) catch {
                    self.reportError("emitFile", file_name, "failed to write file");
                };
            }
        }
    }

    inline fn getSelf(ctx: ?*anyopaque) *SubprocessPlugin {
        return @ptrCast(@alignCast(ctx.?));
    }
};

const JsRuntime = enum { bun, node };

var cached_runtime: ?JsRuntime = null;

fn detectRuntime() JsRuntime {
    if (cached_runtime) |r| return r;
    const r: JsRuntime = if (canExec("bun")) .bun else .node;
    cached_runtime = r;
    return r;
}

fn canExec(name: []const u8) bool {
    var child = std.process.Child.init(&.{ name, "--version" }, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return term == .Exited and term.Exited == 0;
}

// ===== JSON 타입 =====

const InitResponse = struct {
    id: u32 = 0,
    name: ?[]const u8 = null,
    filters: Filters = .{},
    hooks: Hooks = .{},
    config: ConfigOptions = .{},
    @"error": ?[]const u8 = null,

    const Filters = struct {
        resolveId: ?[]const []const u8 = null,
        load: ?[]const []const u8 = null,
        transform: ?[]const []const u8 = null,
    };

    const Hooks = struct {
        resolveId: ?bool = null,
        load: ?bool = null,
        transform: ?bool = null,
        renderChunk: ?bool = null,
        generateBundle: ?bool = null,
    };

    /// config 파일에서 전달된 빌드 옵션 (Vite/esbuild 호환)
    const ConfigOptions = struct {
        loader: ?std.json.Value = null,
        define: ?std.json.Value = null,
        alias: ?std.json.Value = null,
        external: ?[]const []const u8 = null,
        sourcemap: ?bool = null,
        minify: ?bool = null,
        server: ?ServerOptions = null,
        // 새 옵션
        format: ?[]const u8 = null,
        platform: ?[]const u8 = null,
        target: ?std.json.Value = null,
        splitting: ?bool = null,
        preserveModules: ?bool = null,
        preserveModulesRoot: ?[]const u8 = null,
        jsx: ?[]const u8 = null,
        jsxFactory: ?[]const u8 = null,
        jsxFragment: ?[]const u8 = null,
        jsxImportSource: ?[]const u8 = null,
        banner: ?std.json.Value = null,
        footer: ?std.json.Value = null,
        publicPath: ?[]const u8 = null,
        inject: ?[]const []const u8 = null,
        globalName: ?[]const u8 = null,
        legalComments: ?[]const u8 = null,
        keepNames: ?bool = null,

        const ServerOptions = struct {
            port: ?u16 = null,
            host: ?[]const u8 = null,
            open: ?bool = null,
            proxy: ?std.json.Value = null,
        };
    };
};

const HookResponse = struct {
    id: u32 = 0,
    result: ?HookResult = null,
    @"error": ?[]const u8 = null,

    const HookResult = struct {
        path: ?[]const u8 = null,
        contents: ?[]const u8 = null,
        loader: ?[]const u8 = null,
    };
};

/// generateBundle 훅 응답 — emittedFiles 포함 가능
const GenerateBundleResponse = struct {
    id: u32 = 0,
    result: ?GenerateBundleResult = null,
    @"error": ?[]const u8 = null,

    const GenerateBundleResult = struct {
        emittedFiles: ?[]const EmittedFile = null,
    };

    const EmittedFile = struct {
        fileName: ?[]const u8 = null,
        source: ?[]const u8 = null,
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

test "FilterMap: prefix matching (virtual:)" {
    const filters: []const []const u8 = &.{"virtual:"};
    try std.testing.expect(FilterMap.matchesAny(filters, "virtual:config"));
    try std.testing.expect(FilterMap.matchesAny(filters, "virtual:env"));
    try std.testing.expect(!FilterMap.matchesAny(filters, "not-virtual"));
}

test "FilterMap: no false positives from substring" {
    const filters: []const []const u8 = &.{".css"};
    try std.testing.expect(FilterMap.matchesAny(filters, "style.css"));
    // .css가 중간에 있는 경우는 매칭하지 않음 (suffix/prefix만)
    try std.testing.expect(!FilterMap.matchesAny(filters, "file.css-backup.ts"));
}

test "SubprocessPlugin: spawn with invalid path fails" {
    if (SubprocessPlugin.spawn(std.testing.allocator, "/nonexistent/plugin.js")) |sp| {
        sp.shutdown();
        try std.testing.expect(false); // should not succeed
    } else |_| {
        // 에러가 발생해야 정상
    }
}

test "escapeJsonString: control characters" {
    const result = try escapeJsonString(std.testing.allocator, "a\x00b\x01c");
    defer std.testing.allocator.free(result);
    // null과 SOH가 \u0000, \u0001로 이스케이프됨
    try std.testing.expect(std.mem.indexOf(u8, result, "\\u") != null);
}

test "escapeJsonString: windows path backslash" {
    const result = try escapeJsonString(std.testing.allocator, "C:\\Users\\test\\file.ts");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("C:\\\\Users\\\\test\\\\file.ts", result);
}

test "detectRuntime: returns bun or node" {
    const runtime = detectRuntime();
    // 어떤 런타임이든 유효해야 함
    try std.testing.expect(runtime == .bun or runtime == .node);
}

test "canExec: valid command returns true" {
    // 'true'는 POSIX 필수 유틸리티, 항상 exit 0
    try std.testing.expect(canExec("true"));
}

test "canExec: invalid command returns false" {
    try std.testing.expect(!canExec("nonexistent_binary_zts_test_12345"));
}
