//! `zntc dev/build/preview` CLI subcommands.

const std = @import("std");
const lib = @import("zntc_lib");

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

pub fn parseArgs(allocator: std.mem.Allocator, command: Command, args: []const []const u8) !Options {
    const stderr = std.fs.File.stderr().deprecatedWriter();
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
    const path_str = value[0..eq_pos];
    const target_str = value[eq_pos + 1 ..];
    const after_scheme = if (std.mem.indexOf(u8, target_str, "://")) |s| target_str[s + 3 ..] else target_str;
    var target_host: []const u8 = after_scheme;
    var target_port: u16 = 80;
    if (std.mem.indexOf(u8, after_scheme, ":")) |colon| {
        target_host = after_scheme[0..colon];
        target_port = std.fmt.parseInt(u16, after_scheme[colon + 1 ..], 10) catch 80;
    }
    try opts.proxy_list.append(allocator, .{
        .path = path_str,
        .target = target_str,
        .target_host = target_host,
        .target_port = target_port,
    });
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const app_build = lib.app.build;
    const app_env = lib.app.env;
    const mode = opts.mode orelse if (opts.command == .build) "production" else "development";
    const root = if (opts.command == .preview) "." else opts.root_or_outdir orelse ".";
    const env_prefixes = if (opts.env_prefixes.items.len > 0) opts.env_prefixes.items else &[_][]const u8{ "VITE_", "ZNTC_" };
    const base = try normalizeBase(allocator, opts.base);
    defer allocator.free(base);

    switch (opts.command) {
        .build => {
            const outdir = opts.outdir orelse "dist";
            if (opts.clean) try deleteOutput(allocator, root, outdir);
            const written = app_build.buildApp(allocator, .{
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
            }) catch |err| {
                try stderr.print("zntc build: app build failed: {}\n", .{err});
                std.process.exit(1);
            };
            try stderr.print("[build] wrote {d} files to {s}\n", .{ written, outdir });
        },
        .dev => {
            const dev_outdir = opts.outdir orelse ".zntc-dev";
            if (opts.clean) try deleteOutput(allocator, root, dev_outdir);
            var prepared = app_build.prepareDev(allocator, .{
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
            var env_map = try app_env.loadEnv(allocator, .{
                .mode = mode,
                .env_dir = opts.env_dir orelse root_abs,
                .prefixes = env_prefixes,
            });
            defer app_env.deinitMap(&env_map, allocator);
            const app_defines = try app_env.envToDefine(allocator, &env_map, mode, base);
            defer app_env.freeDefines(allocator, app_defines);
            const server_defines = try copyDefinesForBundler(allocator, app_defines);
            defer allocator.free(server_defines);

            var dev_server = lib.server.DevServer.init(allocator, .{
                .root_dir = dev_outdir_abs,
                .port = opts.port,
                .host = opts.host,
                .open = opts.open,
                .entry_point = prepared.entry_path,
                .proxy = opts.proxy_list.items,
                .base_path = base,
                .define = server_defines,
            }) catch |err| {
                try stderr.print("zntc dev: failed to start dev server: {}\n", .{err});
                std.process.exit(1);
            };
            defer dev_server.deinit();
            dev_server.start() catch |err| {
                try stderr.print("zntc dev: server failed: {}\n", .{err});
                std.process.exit(1);
            };
        },
        .preview => {
            const preview_dir = opts.root_or_outdir orelse opts.outdir orelse "dist";
            const preview_abs = try std.fs.path.resolve(allocator, &.{preview_dir});
            defer allocator.free(preview_abs);
            var server = lib.server.DevServer.init(allocator, .{
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
            server.start() catch |err| {
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

fn deleteOutput(allocator: std.mem.Allocator, root: []const u8, outdir: []const u8) !void {
    const path = try std.fs.path.resolve(allocator, &.{ root, outdir });
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return;
    try std.fs.cwd().deleteTree(path);
}

fn copyDefinesForBundler(allocator: std.mem.Allocator, app_defines: []const lib.app.env.DefineEntry) ![]lib.transformer.DefineEntry {
    const out = try allocator.alloc(lib.transformer.DefineEntry, app_defines.len);
    for (app_defines, 0..) |entry, i| {
        out[i] = .{ .key = entry.key, .value = entry.value };
    }
    return out;
}
