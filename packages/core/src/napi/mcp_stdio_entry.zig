//! MCP (Model Context Protocol) stdio transport NAPI entry.
//!
//! JS bin (`zntc mcp` subcommand) 가 호출하는 sync blocking 함수.
//! stdin EOF (Cursor / Claude Code 가 연결 종료) 시 정상 반환.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const DevServer = zntc_lib.server.DevServer;
const serveStdio = zntc_lib.server.mcp_stdio.serveStdio;

const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const getObjectString = common.getObjectString;

/// mcpStdioServe({ rootDir: string }) → undefined.
///
/// stdin 에서 newline-delimited JSON-RPC 2.0 request 한 줄씩 읽어
/// `DevServer.dispatchMcpRequest` 에 forward, 응답을 stdout 에 한 줄씩 쓴다.
/// stdin EOF → 정상 종료 (undefined 반환).
///
/// 이 함수는 blocking — JS event loop 이 stdio loop 안에 갇힌다.
/// 호출자(`zntc mcp` bin)는 main thread 에서 부르므로 의도적 동작.
pub fn napiMcpStdioServe(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "mcpStdioServe requires an options object");

    var arena = std.heap.ArenaAllocator.init(native_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const root_dir = getObjectString(env, argv[0], "rootDir", arena_alloc) orelse
        return throwError(env, "mcpStdioServe: 'rootDir' string option is required");

    // DevServer 인스턴스 — HTTP listener 는 띄우지 않고 in-memory state (cache_reset_requested,
    // event_ring) 만 활용. build 도메인 tool (reset_cache 등) 이 flag 를 토글하면 같은
    // 프로세스 안에서 후속 build 가 그 flag 를 본다 (PR-E 에서 dev server 합본 lifecycle).
    var dev_server = DevServer.init(native_alloc, .{ .root_dir = root_dir }) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "mcpStdioServe: DevServer.init failed: {}", .{err}) catch "mcpStdioServe: DevServer.init failed";
        return throwError(env, msg.ptr);
    };
    defer dev_server.deinit();

    // stdin / stdout file handles.
    var stdin_file = std.fs.File.stdin();
    var stdout_file = std.fs.File.stdout();
    const stdout_writer = stdout_file.deprecatedWriter();

    // line buffer — HTTP 와 같은 64KB 한도. LineTooLong 시 dispatcher 안 닿고 error 반환.
    var line_buf: [64 * 1024]u8 = undefined;

    serveStdio(&dev_server, &stdin_file, stdout_writer, &line_buf) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "mcpStdioServe: stdio loop error: {}", .{err}) catch "mcpStdioServe: stdio loop error";
        return throwError(env, msg.ptr);
    };

    var undefined_val: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &undefined_val);
    return undefined_val;
}
