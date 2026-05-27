//! HTTPS-capable dev server NAPI entry.
//!
//! `startDevServer({rootDir, port?, host?, entry?, open?, certPath?, keyPath?})`
//!   → opaque handle (napi_external).
//! `stopDevServer(handle)` → undefined. shutdown + thread join + deinit.
//!
//! 동작:
//!   - HTTPS 옵션 `certPath`/`keyPath` 양쪽 주면 BoringSSL TLS context 로 listener.
//!     fix chain (#3894/#3898/#3899 + PR-G1 sanity) 의 결실.
//!   - `start()` 는 blocking 이라 별도 native thread 에서 실행. Node event loop
//!     는 자유.
//!   - handle 은 `napi_create_external` — JS GC 가 수거 시 자동 stop (safety net).
//!     명시 `stopDevServer(handle)` 호출이 정석 (예측 가능한 종료 시점).
//!
//! **Memory model (F1/F2 fix)**: `callconv(.c)` callback 는 plain `c.napi_value`
//! 반환이라 Zig `errdefer` 가 dead code. 모든 error path 는 명시 cleanup. 또
//! `DevServer.init` 가 옵션 string 의 own copy 안 만들기 때문에 (`root_dir`, `host`,
//! `entry`, `certPath`, `keyPath`) NAPI 측이 dupe 해서 handle 에 보관 — server
//! lifetime 과 align. arena 패턴 (string 만 짧게 살리는 것) 은 listener thread /
//! handler thread 가 종료 후에도 일시 reference 가능해 UAF 위험 → 제거.
//!
//! **Dev-only entry — caller 신뢰 전제**: arbitrary host/port bind + cert/key 파일
//! 읽기. 일반 사용자 머신의 dev workflow 가정.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const DevServer = zntc_lib.server.DevServer;

const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const getObjectString = common.getObjectString;
const getObjectBool = common.getObjectBool;
const getNamedProperty = common.getNamedProperty;

/// JS 쪽에서 보유하는 opaque handle. heap alloc — JS reference 가 유지하는 동안
/// 살아있고 finalize 시점에 자원 해제. 옵션 string 들의 own copy 도 같이 보관.
const DevServerHandle = struct {
    server: *DevServer,
    thread: std.Thread,

    // string 들은 server 가 reference 만 보관 → handle 안에서 own. shutdown 시
    // server.deinit() 이후 free (server 가 reference 끊은 후).
    root_dir: []u8,
    host: []u8,
    entry: ?[]u8,
    cert_path: ?[]u8,
    key_path: ?[]u8,

    /// stopDevServer 가 한 번 호출되면 idempotent 처리 위해 atomic flag.
    /// finalize callback 이 GC 후에 다시 stop 시도해도 no-op.
    stopped: std.atomic.Value(bool),

    fn shutdown(self: *DevServerHandle) void {
        // shutdown() 자체가 atomic flag set + self-connect 라 race 안전. 다만
        // join / deinit / free 는 race 가능하므로 single-shot.
        if (self.stopped.swap(true, .acq_rel)) return;
        self.server.shutdown();
        self.thread.join();
        self.server.deinit();
        native_alloc.destroy(self.server);
        native_alloc.free(self.root_dir);
        native_alloc.free(self.host);
        if (self.entry) |s| native_alloc.free(s);
        if (self.cert_path) |s| native_alloc.free(s);
        if (self.key_path) |s| native_alloc.free(s);
    }
};

/// thread entry — server.start() 호출. start() 가 정상 종료 (shutdown_requested)
/// 되면 thread 도 종료. fail 시 stderr log 만.
fn serveThreadEntry(server: *DevServer) void {
    server.start() catch |err| {
        std.fs.File.stderr().deprecatedWriter().print(
            "zntc: dev server thread error: {}\n",
            .{err},
        ) catch {};
    };
}

/// finalize callback — JS GC 가 external value 를 수거할 때 호출. 명시 stop 안
/// 됐으면 여기서 정리.
fn finalizeHandle(env: c.napi_env, finalize_data: ?*anyopaque, finalize_hint: ?*anyopaque) callconv(.c) void {
    _ = env;
    _ = finalize_hint;
    if (finalize_data == null) return;
    const handle: *DevServerHandle = @ptrCast(@alignCast(finalize_data.?));
    handle.shutdown();
    native_alloc.destroy(handle);
}

pub fn napiStartDevServer(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "startDevServer: failed to get arguments");
    }
    if (argc < 1) return throwError(env, "startDevServer requires an options object");

    var arg_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, argv[0], &arg_type) != c.napi_ok or arg_type != c.napi_object) {
        return throwError(env, "startDevServer: options must be an object");
    }

    // String 들은 어차피 native_alloc 에서 dupe — 임시 alloc 도 native_alloc 사용해
    // 본 함수 안에서 명시 free. errdefer 가 callconv(.c) 에서 dead code 라 모든
    // error path 가 직접 정리해야 함.
    var root_dir: ?[]u8 = null;
    var host: ?[]u8 = null;
    var entry: ?[]u8 = null;
    var cert_path: ?[]u8 = null;
    var key_path: ?[]u8 = null;

    // 에러 시 alloc 된 옵션 string 들 free 하는 inline cleanup.
    const cleanupStrings = struct {
        fn run(rd: ?[]u8, h: ?[]u8, e: ?[]u8, cp: ?[]u8, kp: ?[]u8) void {
            if (rd) |s| native_alloc.free(s);
            if (h) |s| native_alloc.free(s);
            if (e) |s| native_alloc.free(s);
            if (cp) |s| native_alloc.free(s);
            if (kp) |s| native_alloc.free(s);
        }
    }.run;

    // root_dir — required.
    const rd_slice = getObjectString(env, argv[0], "rootDir", native_alloc) orelse {
        return throwError(env, "startDevServer: 'rootDir' string option is required");
    };
    root_dir = @constCast(rd_slice);

    // optional / 기본값. getObjectString 는 caller-owned slice 반환.
    if (getObjectString(env, argv[0], "host", native_alloc)) |s| host = @constCast(s);
    if (getObjectString(env, argv[0], "entry", native_alloc)) |s| entry = @constCast(s);
    if (getObjectString(env, argv[0], "certPath", native_alloc)) |s| cert_path = @constCast(s);
    if (getObjectString(env, argv[0], "keyPath", native_alloc)) |s| key_path = @constCast(s);

    // host 가 비어있으면 default "127.0.0.1" 로 채우기 (DevServer 가 비빈 string
    // 받으면 listen fail).
    if (host == null) {
        host = native_alloc.dupe(u8, "127.0.0.1") catch {
            cleanupStrings(root_dir, host, entry, cert_path, key_path);
            return throwError(env, "startDevServer: out of memory (host default)");
        };
    }

    // port — required type number, default 12300.
    var port: u16 = 12300;
    if (getNamedProperty(env, argv[0], "port")) |port_val| {
        var port_type: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, port_val, &port_type);
        if (port_type == c.napi_number) {
            var port_u32: u32 = 0;
            if (c.napi_get_value_uint32(env, port_val, &port_u32) != c.napi_ok) {
                cleanupStrings(root_dir, host, entry, cert_path, key_path);
                return throwError(env, "startDevServer: failed to read 'port' number");
            }
            if (port_u32 == 0 or port_u32 > 65535) {
                cleanupStrings(root_dir, host, entry, cert_path, key_path);
                return throwError(env, "startDevServer: 'port' must be 1..65535");
            }
            port = @intCast(port_u32);
        } else if (port_type != c.napi_undefined and port_type != c.napi_null) {
            cleanupStrings(root_dir, host, entry, cert_path, key_path);
            return throwError(env, "startDevServer: 'port' must be a number");
        }
    }

    const open = getObjectBool(env, argv[0], "open", false);

    // cert 와 key 둘 다 있거나 둘 다 없거나.
    if ((cert_path == null) != (key_path == null)) {
        cleanupStrings(root_dir, host, entry, cert_path, key_path);
        return throwError(env, "startDevServer: both 'certPath' and 'keyPath' must be provided together (or neither)");
    }

    // heap alloc DevServer — thread 가 reference 유지하는 동안 살아있어야.
    const server = native_alloc.create(DevServer) catch {
        cleanupStrings(root_dir, host, entry, cert_path, key_path);
        return throwError(env, "startDevServer: out of memory (DevServer alloc)");
    };

    server.* = DevServer.init(native_alloc, .{
        .root_dir = root_dir.?,
        .port = port,
        .host = host.?,
        .open = open,
        .entry_point = entry,
        .cert_path = cert_path,
        .key_path = key_path,
    }) catch |err| {
        native_alloc.destroy(server);
        cleanupStrings(root_dir, host, entry, cert_path, key_path);
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "startDevServer: DevServer.init failed: {}", .{err}) catch
            "startDevServer: DevServer.init failed";
        return throwError(env, msg.ptr);
    };

    const handle = native_alloc.create(DevServerHandle) catch {
        server.deinit();
        native_alloc.destroy(server);
        cleanupStrings(root_dir, host, entry, cert_path, key_path);
        return throwError(env, "startDevServer: out of memory (handle alloc)");
    };

    const thread = std.Thread.spawn(.{}, serveThreadEntry, .{server}) catch {
        native_alloc.destroy(handle);
        server.deinit();
        native_alloc.destroy(server);
        cleanupStrings(root_dir, host, entry, cert_path, key_path);
        return throwError(env, "startDevServer: failed to spawn thread");
    };

    handle.* = .{
        .server = server,
        .thread = thread,
        .root_dir = root_dir.?,
        .host = host.?,
        .entry = entry,
        .cert_path = cert_path,
        .key_path = key_path,
        .stopped = std.atomic.Value(bool).init(false),
    };

    var external_value: c.napi_value = undefined;
    if (c.napi_create_external(env, handle, finalizeHandle, null, &external_value) != c.napi_ok) {
        // external 생성 실패 — handle.shutdown() 으로 thread join + server deinit
        // + string free 한 후 handle 자체 free.
        handle.shutdown();
        native_alloc.destroy(handle);
        return throwError(env, "startDevServer: napi_create_external failed");
    }
    return external_value;
}

pub fn napiStopDevServer(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "stopDevServer: failed to get arguments");
    }
    if (argc < 1) return throwError(env, "stopDevServer requires a handle argument");

    var arg_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, argv[0], &arg_type) != c.napi_ok or arg_type != c.napi_external) {
        return throwError(env, "stopDevServer: argument must be a handle from startDevServer");
    }

    var data: ?*anyopaque = null;
    if (c.napi_get_value_external(env, argv[0], &data) != c.napi_ok or data == null) {
        return throwError(env, "stopDevServer: failed to unwrap handle");
    }
    const handle: *DevServerHandle = @ptrCast(@alignCast(data.?));
    handle.shutdown();

    var undefined_val: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &undefined_val);
    return undefined_val;
}
