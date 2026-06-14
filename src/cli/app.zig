//! `zntc dev/build/preview` CLI subcommands.

const std = @import("std");
const lib = @import("zntc_lib");

const JsxRuntime = lib.codegen.codegen.JsxRuntime;

pub const Command = enum { dev, build, preview };

pub const Options = struct {
    command: Command,
    root_or_outdir: ?[]const u8 = null,
    outdir: ?[]const u8 = null,
    entry_html: []const u8 = "index.html",
    public_dir: ?[]const u8 = "public",
    base: []const u8 = "/",
    mode: ?[]const u8 = null,
    env_dir: ?[]const u8 = null,
    env_prefixes: std.ArrayList([]const u8) = .empty,
    port: u16 = 12300,
    host: []const u8 = "localhost",
    open: bool = false,
    clean: bool = false,
    minify: bool = false,
    sourcemap: bool = false,
    splitting: bool = true,
    // JSX 옵션 — `zntc --bundle` 과 동일 vocab. null 은 "미지정 → tsconfig 또는 default".
    jsx_runtime: ?JsxRuntime = null,
    jsx_import_source: ?[]const u8 = null,
    jsx_factory: ?[]const u8 = null,
    jsx_fragment: ?[]const u8 = null,
    proxy_list: std.ArrayList(lib.server.DevServer.ProxyRule) = .empty,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.env_prefixes.deinit(allocator);
        self.proxy_list.deinit(allocator);
    }
};

pub fn parseCommandName(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "dev")) return .dev;
    if (std.mem.eql(u8, name, "build")) return .build;
    if (std.mem.eql(u8, name, "preview")) return .preview;
    return null;
}

pub fn parseArgs(allocator: std.mem.Allocator, io: std.Io, command: Command, args: []const []const u8) !Options {
    // 0.16: deprecatedWriter 제거. length-0 buffer = unbuffered (exit 전 flush 불필요).
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;
    var opts = Options{ .command = command };
    errdefer opts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else if (try appStringFlag(args, &i, "--outdir")) |value| {
            opts.outdir = value;
        } else if (try appStringFlag(args, &i, "--entry-html")) |value| {
            opts.entry_html = value;
        } else if (try appStringFlag(args, &i, "--public-dir")) |value| {
            opts.public_dir = value;
        } else if (try appStringFlag(args, &i, "--base")) |value| {
            opts.base = value;
        } else if (try appStringFlag(args, &i, "--mode")) |value| {
            opts.mode = value;
        } else if (try appStringFlag(args, &i, "--env-dir")) |value| {
            opts.env_dir = value;
        } else if (try appStringFlag(args, &i, "--env-prefix")) |value| {
            try appendCsv(&opts.env_prefixes, allocator, value);
        } else if (try appStringFlag(args, &i, "--port")) |value| {
            opts.port = std.fmt.parseInt(u16, value, 10) catch {
                try stderr.print("zntc {s}: invalid --port value: {s}\n", .{ @tagName(command), value });
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                opts.host = args[i];
            } else {
                opts.host = "0.0.0.0";
            }
        } else if (std.mem.startsWith(u8, arg, "--host=")) {
            opts.host = arg["--host=".len..];
        } else if (std.mem.eql(u8, arg, "--open")) {
            opts.open = true;
        } else if (std.mem.eql(u8, arg, "--clean")) {
            opts.clean = true;
        } else if (std.mem.eql(u8, arg, "--minify")) {
            opts.minify = true;
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            opts.sourcemap = true;
        } else if (std.mem.eql(u8, arg, "--splitting")) {
            opts.splitting = true;
        } else if (std.mem.eql(u8, arg, "--no-splitting")) {
            opts.splitting = false;
        } else if (try appStringFlag(args, &i, "--jsx")) |value| {
            opts.jsx_runtime = JsxRuntime.fromString(value) orelse .classic;
        } else if (std.mem.eql(u8, arg, "--jsx-dev")) {
            opts.jsx_runtime = .automatic_dev;
        } else if (try appStringFlag(args, &i, "--jsx-import-source")) |value| {
            opts.jsx_import_source = value;
        } else if (try appStringFlag(args, &i, "--jsx-factory")) |value| {
            opts.jsx_factory = value;
        } else if (try appStringFlag(args, &i, "--jsx-fragment")) |value| {
            opts.jsx_fragment = value;
        } else if (try appStringFlag(args, &i, "--proxy")) |value| {
            try parseProxy(&opts, allocator, value, stderr);
        } else if (arg.len > 0 and arg[0] != '-') {
            if (opts.root_or_outdir == null) {
                opts.root_or_outdir = arg;
            } else {
                try stderr.print("zntc {s}: unexpected positional argument: {s}\n", .{ @tagName(command), arg });
                std.process.exit(1);
            }
        } else {
            try stderr.print("zntc {s}: unknown option: {s}\n", .{ @tagName(command), arg });
            std.process.exit(1);
        }
    }
    return opts;
}

fn appStringFlag(args: []const []const u8, index: *usize, name: []const u8) !?[]const u8 {
    const arg = args[index.*];
    if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=') {
        return arg[name.len + 1 ..];
    }
    if (!std.mem.eql(u8, arg, name)) return null;
    if (index.* + 1 >= args.len) return error.MissingFlagValue;
    index.* += 1;
    return args[index.*];
}

fn appendCsv(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t\r\n");
        if (part.len > 0) try list.append(allocator, part);
    }
}

fn parseProxy(opts: *Options, allocator: std.mem.Allocator, value: []const u8, stderr: anytype) !void {
    const eq_pos = std.mem.indexOf(u8, value, "=") orelse {
        try stderr.print("zntc {s}: --proxy requires PATH=TARGET\n", .{@tagName(opts.command)});
        std.process.exit(1);
    };
    // host/port 추출 + scheme 기본 포트(https=443)는 ProxyRule.fromTarget 공유.
    try opts.proxy_list.append(allocator, lib.server.DevServer.ProxyRule.fromTarget(value[0..eq_pos], value[eq_pos + 1 ..]));
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;
    const app_build = lib.app.build;
    const app_env = lib.app.env;
    const mode = opts.mode orelse if (opts.command == .build) "production" else "development";
    const root = if (opts.command == .preview) "." else opts.root_or_outdir orelse ".";
    const env_prefixes = if (opts.env_prefixes.items.len > 0) opts.env_prefixes.items else &[_][]const u8{ "VITE_", "ZNTC_" };
    const base = try normalizeBase(allocator, opts.base);
    defer allocator.free(base);

    // JSX 설정: CLI 옵션 + `<root>/tsconfig.json` 머지 (`zntc --bundle` 과 동일 우선순위).
    // tsconfig 의 backing string 을 buildApp / DevServer 가 borrow 하므로 run() 끝까지 유지.
    var tsconfig = if (opts.command == .preview)
        lib.config.TsConfig{}
    else
        (lib.config.TsConfig.load(allocator, io, root) catch lib.config.TsConfig{});
    defer tsconfig.deinit();
    const jsx_merged = lib.tsconfig_merge.merge(&tsconfig, .{
        .jsx_runtime = opts.jsx_runtime,
        .jsx_factory = opts.jsx_factory,
        .jsx_fragment = opts.jsx_fragment,
        .jsx_import_source = opts.jsx_import_source,
    });
    const jsx_config = app_build.JsxConfig{
        .runtime = jsx_merged.jsx_runtime,
        .import_source = jsx_merged.jsx_import_source,
        .factory = jsx_merged.jsx_factory,
        .fragment = jsx_merged.jsx_fragment,
    };

    switch (opts.command) {
        .build => {
            const outdir = opts.outdir orelse "dist";
            if (opts.clean) try deleteOutput(allocator, io, root, outdir);
            const written = app_build.buildApp(allocator, io, .{
                .root = root,
                .outdir = outdir,
                .entry_html = opts.entry_html,
                .public_dir = opts.public_dir,
                .base = base,
                .mode = mode,
                .env_dir = opts.env_dir,
                .env_prefixes = env_prefixes,
                .minify = opts.minify,
                .sourcemap = opts.sourcemap,
                .splitting = opts.splitting,
                .jsx = jsx_config,
            }) catch |err| {
                try stderr.print("zntc build: app build failed: {}\n", .{err});
                std.process.exit(1);
            };
            try stderr.print("[build] wrote {d} files to {s}\n", .{ written, outdir });
        },
        .dev => {
            const dev_outdir = opts.outdir orelse ".zntc-dev";
            if (opts.clean) try deleteOutput(allocator, io, root, dev_outdir);
            var prepared = app_build.prepareDev(allocator, io, .{
                .root = root,
                .outdir = dev_outdir,
                .entry_html = opts.entry_html,
                .public_dir = opts.public_dir,
                .base = base,
                .mode = mode,
                .env_dir = opts.env_dir,
                .env_prefixes = env_prefixes,
            }) catch |err| {
                try stderr.print("zntc dev: app prepare failed: {}\n", .{err});
                std.process.exit(1);
            };
            defer prepared.deinit(allocator);

            const root_abs = try std.fs.path.resolve(allocator, &.{root});
            defer allocator.free(root_abs);
            const dev_outdir_abs = try std.fs.path.resolve(allocator, &.{ root_abs, dev_outdir });
            defer allocator.free(dev_outdir_abs);
            var env_map = try app_env.loadEnv(allocator, io, .{
                .mode = mode,
                .env_dir = opts.env_dir orelse root_abs,
                .prefixes = env_prefixes,
            });
            defer app_env.deinitMap(&env_map, allocator);
            const app_defines = try app_env.envToDefine(allocator, &env_map, mode, base);
            defer app_env.freeDefines(allocator, app_defines);
            const server_defines = try copyDefinesForBundler(allocator, app_defines);
            defer allocator.free(server_defines);

            var dev_server = lib.server.DevServer.init(allocator, io, .{
                .root_dir = dev_outdir_abs,
                .port = opts.port,
                .host = opts.host,
                .open = opts.open,
                .entry_point = prepared.entry_path,
                .proxy = opts.proxy_list.items,
                .base_path = base,
                .define = server_defines,
                .jsx_runtime = jsx_config.runtime,
                .jsx_import_source = jsx_config.import_source,
                .jsx_factory = jsx_config.factory,
                .jsx_fragment = jsx_config.fragment,
            }) catch |err| {
                try stderr.print("zntc dev: failed to start dev server: {}\n", .{err});
                std.process.exit(1);
            };
            defer dev_server.deinit();
            dev_server.start(io) catch |err| {
                try stderr.print("zntc dev: server failed: {}\n", .{err});
                std.process.exit(1);
            };
        },
        .preview => {
            const preview_dir = opts.root_or_outdir orelse opts.outdir orelse "dist";
            const preview_abs = try std.fs.path.resolve(allocator, &.{preview_dir});
            defer allocator.free(preview_abs);
            var server = lib.server.DevServer.init(allocator, io, .{
                .root_dir = preview_abs,
                .port = opts.port,
                .host = opts.host,
                .open = opts.open,
                .entry_point = null,
                .proxy = opts.proxy_list.items,
                .base_path = base,
            }) catch |err| {
                try stderr.print("zntc preview: failed to start server: {}\n", .{err});
                std.process.exit(1);
            };
            defer server.deinit();
            server.start(io) catch |err| {
                try stderr.print("zntc preview: server failed: {}\n", .{err});
                std.process.exit(1);
            };
        },
    }
}

fn normalizeBase(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return allocator.dupe(u8, "/");
    if (std.mem.eql(u8, raw, ".")) return allocator.dupe(u8, "");
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (raw[0] != '/') try out.append(allocator, '/');
    try out.appendSlice(allocator, raw);
    if (out.items.len > 0 and out.items[out.items.len - 1] != '/') try out.append(allocator, '/');
    return try out.toOwnedSlice(allocator);
}

fn deleteOutput(allocator: std.mem.Allocator, io: std.Io, root: []const u8, outdir: []const u8) !void {
    const path = try std.fs.path.resolve(allocator, &.{ root, outdir });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return;
    try std.Io.Dir.cwd().deleteTree(io, path);
}

fn copyDefinesForBundler(allocator: std.mem.Allocator, app_defines: []const lib.app.env.DefineEntry) ![]lib.transformer.DefineEntry {
    const out = try allocator.alloc(lib.transformer.DefineEntry, app_defines.len);
    for (app_defines, 0..) |entry, i| {
        out[i] = .{ .key = entry.key, .value = entry.value };
    }
    return out;
}
