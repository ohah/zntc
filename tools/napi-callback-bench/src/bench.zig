//! NAPI callback hot-path 마이크로 벤치 (#1891).
//!
//! 두 dispatch 모드의 raw cost 를 측정해 ZTS plugin layer 도입 시 회귀를 추정한다.
//!   1. benchSync(N)  — main thread 에서 napi_call_function N 회 (sync, no worker)
//!   2. benchTsf(N)   — worker 1개에서 napi_call_threadsafe_function N 회 (worker → main, blocking)
//!
//! 등록된 callback 은 no-op 권장 — overhead 격리 측정 목적.

const std = @import("std");
const c = @cImport({
    @cInclude("node_api.h");
});

// 글로벌 callback 상태. register() 호출 시 갱신.
var g_tsfn: c.napi_threadsafe_function = null;
var g_callback_ref: c.napi_ref = null;

// per-call worker stack — tsf 모드에서 worker 가 main thread JS 실행을 기다림.
const CallCtx = struct {
    done: bool = false,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
};

fn callJsCb(env: c.napi_env, js_callback: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const ctx: *CallCtx = @ptrCast(@alignCast(data.?));
    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    var result: c.napi_value = undefined;
    _ = c.napi_call_function(env, js_undefined, js_callback, 0, null, &result);
    ctx.mutex.lock();
    ctx.done = true;
    ctx.cond.signal();
    ctx.mutex.unlock();
}

fn throwError(env: c.napi_env, msg: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, null, msg);
    var undef: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &undef);
    return undef;
}

fn cleanupGlobals(env: c.napi_env) void {
    if (g_tsfn != null) {
        _ = c.napi_release_threadsafe_function(g_tsfn, c.napi_tsfn_release);
        g_tsfn = null;
    }
    if (g_callback_ref != null) {
        _ = c.napi_delete_reference(env, g_callback_ref);
        g_callback_ref = null;
    }
}

fn registerCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "register: cannot get args");
    }
    if (argc < 1) return throwError(env, "register: callback required");

    cleanupGlobals(env);

    if (c.napi_create_reference(env, argv[0], 1, &g_callback_ref) != c.napi_ok) {
        return throwError(env, "register: cannot create ref");
    }

    var work_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "bench_tsfn", "bench_tsfn".len, &work_name);
    if (c.napi_create_threadsafe_function(
        env,
        argv[0],
        null,
        work_name,
        0,
        1,
        null,
        null,
        null,
        callJsCb,
        &g_tsfn,
    ) != c.napi_ok) {
        return throwError(env, "register: cannot create tsfn");
    }

    var undef: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &undef);
    return undef;
}

fn benchSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "benchSync: cannot get args");
    }
    if (argc < 1) return throwError(env, "benchSync: iterations required");

    var n: u32 = 0;
    if (c.napi_get_value_uint32(env, argv[0], &n) != c.napi_ok) {
        return throwError(env, "benchSync: invalid iterations");
    }
    if (g_callback_ref == null) return throwError(env, "benchSync: no callback registered");

    var js_cb: c.napi_value = undefined;
    if (c.napi_get_reference_value(env, g_callback_ref, &js_cb) != c.napi_ok) {
        return throwError(env, "benchSync: cannot get callback");
    }

    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);

    const start_ns = std.time.nanoTimestamp();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var result: c.napi_value = undefined;
        _ = c.napi_call_function(env, js_undefined, js_cb, 0, null, &result);
    }
    const elapsed_ns: f64 = @floatFromInt(std.time.nanoTimestamp() - start_ns);

    var ms: c.napi_value = undefined;
    _ = c.napi_create_double(env, elapsed_ns / 1e6, &ms);
    return ms;
}

const AsyncBenchCtx = struct {
    iterations: u32,
    elapsed_ns: i128 = 0,
    deferred: c.napi_deferred = null,
    work: c.napi_async_work = null,
};

fn doWorkBench(_: c.napi_env, data: ?*anyopaque) callconv(.c) void {
    const ctx: *AsyncBenchCtx = @ptrCast(@alignCast(data.?));
    // CallCtx 를 loop 밖에서 1회 init — mutex/cond init 비용을 hot path 에서 제외해
    // napi_call_threadsafe_function 자체 비용만 측정.
    var call_ctx = CallCtx{};
    const start_ns = std.time.nanoTimestamp();
    var i: u32 = 0;
    while (i < ctx.iterations) : (i += 1) {
        call_ctx.done = false;
        const status = c.napi_call_threadsafe_function(g_tsfn, @ptrCast(&call_ctx), c.napi_tsfn_blocking);
        if (status != c.napi_ok) break;
        call_ctx.mutex.lock();
        while (!call_ctx.done) call_ctx.cond.wait(&call_ctx.mutex);
        call_ctx.mutex.unlock();
    }
    ctx.elapsed_ns = std.time.nanoTimestamp() - start_ns;
}

fn completeWorkBench(env: c.napi_env, _: c.napi_status, data: ?*anyopaque) callconv(.c) void {
    const ctx: *AsyncBenchCtx = @ptrCast(@alignCast(data.?));
    const ms_val: f64 = @as(f64, @floatFromInt(ctx.elapsed_ns)) / 1e6;
    var ms: c.napi_value = undefined;
    _ = c.napi_create_double(env, ms_val, &ms);
    _ = c.napi_resolve_deferred(env, ctx.deferred, ms);
    _ = c.napi_delete_async_work(env, ctx.work);
    std.heap.c_allocator.destroy(ctx);
}

fn benchTsf(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "benchTsf: cannot get args");
    }
    if (argc < 1) return throwError(env, "benchTsf: iterations required");

    var n: u32 = 0;
    if (c.napi_get_value_uint32(env, argv[0], &n) != c.napi_ok) {
        return throwError(env, "benchTsf: invalid iterations");
    }
    if (g_tsfn == null) return throwError(env, "benchTsf: no callback registered");

    const ctx = std.heap.c_allocator.create(AsyncBenchCtx) catch {
        return throwError(env, "benchTsf: OOM");
    };
    ctx.* = .{ .iterations = n };

    var promise: c.napi_value = undefined;
    if (c.napi_create_promise(env, &ctx.deferred, &promise) != c.napi_ok) {
        std.heap.c_allocator.destroy(ctx);
        return throwError(env, "benchTsf: cannot create promise");
    }

    var work_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "bench_tsf_work", "bench_tsf_work".len, &work_name);

    if (c.napi_create_async_work(env, null, work_name, doWorkBench, completeWorkBench, ctx, &ctx.work) != c.napi_ok) {
        std.heap.c_allocator.destroy(ctx);
        return throwError(env, "benchTsf: cannot create async work");
    }
    if (c.napi_queue_async_work(env, ctx.work) != c.napi_ok) {
        _ = c.napi_delete_async_work(env, ctx.work);
        std.heap.c_allocator.destroy(ctx);
        return throwError(env, "benchTsf: cannot queue async work");
    }
    return promise;
}

fn defineFn(env: c.napi_env, exports: c.napi_value, name: [:0]const u8, cb: c.napi_callback) void {
    var fn_value: c.napi_value = undefined;
    _ = c.napi_create_function(env, name.ptr, name.len, cb, null, &fn_value);
    _ = c.napi_set_named_property(env, exports, name.ptr, fn_value);
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    defineFn(env, exports, "register", registerCallback);
    defineFn(env, exports, "benchSync", benchSync);
    defineFn(env, exports, "benchTsf", benchTsf);
    return exports;
}
