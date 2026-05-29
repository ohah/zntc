//! CLI modes that bypass the normal transpile/bundle pipeline.

const std = @import("std");
const lib = @import("zntc_lib");

const Scanner = lib.lexer.Scanner;
const runner = lib.test262.runner;

pub fn runTest262(allocator: std.mem.Allocator, io: std.Io, dir_path: ?[]const u8) !void {
    // 0.16: deprecatedWriter 제거. length-0 buffer = unbuffered (exit 전 flush 불필요).
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;
    const raw_dir = dir_path orelse {
        try stderr.print("zntc: --test262 requires a directory path\n", .{});
        std.process.exit(1);
    };
    const abs_path = try std.Io.Dir.cwd().realPathFileAlloc(io, raw_dir, allocator);
    defer allocator.free(abs_path);

    // test262 repo root 자동 감지: `test/` 와 `tools/` 가 둘 다 있으면 conformance `test/` 만 측정.
    // tools/lint·generation 의 self-fixture (의도적으로 invalid 한 frontmatter 를 갖는 .js)
    // 가 함께 walk 되어 fake fail 로 카운트되는 것을 막는다.
    const test_sub = try std.fs.path.join(allocator, &.{ abs_path, "test" });
    defer allocator.free(test_sub);
    const tools_sub = try std.fs.path.join(allocator, &.{ abs_path, "tools" });
    defer allocator.free(tools_sub);
    const is_repo_root = blk: {
        // 0.16: std.fs.accessAbsolute 제거 → Dir.access (절대경로 sub_path 허용).
        std.Io.Dir.cwd().access(io, test_sub, .{}) catch break :blk false;
        std.Io.Dir.cwd().access(io, tools_sub, .{}) catch break :blk false;
        break :blk true;
    };

    const walk_path = if (is_repo_root) test_sub else abs_path;
    if (is_repo_root) {
        try stdout.print("Detected test262 repo root — restricting walk to '{s}'\n", .{walk_path});
    }
    try stdout.print("Running Test262: {s}\n", .{walk_path});
    const summary = try runner.runDirectory(allocator, io, walk_path, false);
    try summary.print(stdout);
    if (summary.failed > 0) std.process.exit(1);
}

pub fn runTokenize(allocator: std.mem.Allocator, io: std.Io, input_file: ?[]const u8) !void {
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;
    const file_path = input_file orelse {
        try stderr.print("zntc: --tokenize requires a file path\n", .{});
        std.process.exit(1);
    };
    const source = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024));
    defer allocator.free(source);

    var scanner = try Scanner.init(allocator, source);
    defer scanner.deinit();

    while (true) {
        try scanner.next();
        const lc = scanner.getLineColumn(scanner.token.span.start);
        try stdout.print("{d}:{d}\t{s}\t\"{s}\"\n", .{
            lc.line + 1,
            lc.column + 1,
            scanner.token.kind.symbol(),
            scanner.tokenText(),
        });
        if (scanner.token.kind == .eof) break;
    }
}

pub const ServeOptions = struct {
    is_bundle: bool,
    input_file: ?[]const u8,
    port: u16,
    host: []const u8,
    open: bool,
    proxy: []const lib.server.DevServer.ProxyRule,
    /// TLS cert/key — 둘 다 set 되면 HTTPS, 둘 다 null 이면 plain. 한쪽만 set 은
    /// DevServer.init 에서 명시적 error.TlsKeyMissing.
    cert_path: ?[]const u8 = null,
    key_path: ?[]const u8 = null,
};

pub fn runServe(allocator: std.mem.Allocator, io: std.Io, opts: ServeOptions) !void {
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;

    // --serve --bundle entry.ts → entry의 디렉토리를 root로 사용
    const serve_dir: []const u8 = if (opts.is_bundle and opts.input_file != null) blk: {
        break :blk std.fs.path.dirname(opts.input_file.?) orelse ".";
    } else opts.input_file orelse ".";

    const entry: ?[]const u8 = if (opts.is_bundle) blk: {
        break :blk opts.input_file orelse {
            try stderr.print("zntc: --serve --bundle requires an entry file path\n", .{});
            std.process.exit(1);
        };
    } else null;

    var dev_server = lib.server.DevServer.init(allocator, io, .{
        .root_dir = serve_dir,
        .port = opts.port,
        .host = opts.host,
        .open = opts.open,
        .entry_point = entry,
        .proxy = opts.proxy,
        .cert_path = opts.cert_path,
        .key_path = opts.key_path,
    }) catch |err| {
        try stderr.print("zntc: failed to start dev server: {}\n", .{err});
        std.process.exit(1);
    };
    defer dev_server.deinit();
    dev_server.start(io) catch |err| {
        try stderr.print("zntc: dev server failed: {}\n", .{err});
        std.process.exit(1);
    };
}
