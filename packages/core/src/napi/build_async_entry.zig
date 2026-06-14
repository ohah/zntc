const std = @import("std");
const zntc_lib = @import("zntc_lib");
const bundler_mod = zntc_lib.bundler;
const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
const common = @import("common.zig");
const options_mod = @import("options.zig");
const result_napi_mod = @import("result.zig");
const plugin_bridge = @import("plugin_bridge.zig");
const c = common.c;

const native_alloc = common.nativeAlloc();

const throwError = common.throwError;
const getNamedProperty = common.getNamedProperty;

const LogFilterOptions = options_mod.LogFilterOptions;
const parseLogFilterOptions = options_mod.parseLogFilterOptions;
const parseBuildOptions = options_mod.parseBuildOptions;
const freeOptionsTypedSlices = options_mod.freeOptionsTypedSlices;
const buildResultToJS = result_napi_mod.buildResultToJS;

const Plugin = bundler_mod.plugin.Plugin;
const NapiPlugin = plugin_bridge.NapiPlugin;
const NapiManualChunksResolver = plugin_bridge.NapiManualChunksResolver;
const installManualChunksResolver = plugin_bridge.installManualChunksResolver;

const BuildAsyncData = struct {
    env: c.napi_env,
    deferred: c.napi_deferred,
    completion_tsfn: c.napi_threadsafe_function,
    // 소유된 옵션 (워커 스레드에서 유효해야 하므로 복사)
    options: BundleOptions,
    // options 가 parseBuildOptions 결과로 채워졌는지. 에러 경로에서 undefined-options 의
    // freeOptionsTypedSlices 크래시를 막는 가드 (#4277).
    options_set: bool = false,
    // logLevel/logLimit 필터 — buildResultToJS 가 진단 출력 시 사용 (#2158).
    log_opts: LogFilterOptions,
    // 소유된 문자열 목록 (deinit 시 해제)
    owned_strings: std.ArrayList([]const u8),
    owned_string_arrays: std.ArrayList([]const []const u8),
    // NAPI 플러그인 (JS 콜백 기반)
    napi_plugins: std.ArrayList(*NapiPlugin),
    zig_plugins: std.ArrayList(Plugin),
    // manualChunks JS resolver — 소유 (deinit 시 TSFN release)
    napi_manual_chunks: ?*NapiManualChunksResolver = null,
    // 결과
    result: ?bundler_mod.BundleResult = null,
    err_msg: ?[*:0]const u8 = null,
};

/// async_data 가 소유한 모든 리소스 해제 + 구조체 free. 완료 콜백과 진입 함수의
/// 에러 경로가 공유한다(정리 로직 drift 방지). completion_tsfn 의 release 는 생성
/// 여부가 호출 지점마다 달라 호출자가 직접 처리한다. options typed slices 는
/// `options_set` 가드로만 해제(에러 경로의 undefined-options 크래시 방지).
fn deinitAsyncData(async_data: *BuildAsyncData) void {
    for (async_data.owned_strings.items) |s| native_alloc.free(s);
    async_data.owned_strings.deinit(native_alloc);
    for (async_data.owned_string_arrays.items) |arr| native_alloc.free(arr);
    async_data.owned_string_arrays.deinit(native_alloc);
    if (async_data.options_set) freeOptionsTypedSlices(&async_data.options);
    for (async_data.napi_plugins.items) |np| np.deinit();
    async_data.napi_plugins.deinit(native_alloc);
    async_data.zig_plugins.deinit(native_alloc);
    if (async_data.napi_manual_chunks) |mc| mc.deinit();
    native_alloc.destroy(async_data);
}

/// 독립 스레드에서 번들링 실행 (libuv 워커 미사용 → TSFN 데드락 방지)
fn buildWorkerThread(async_data: *BuildAsyncData) void {
    common.setJobs(async_data.options.max_threads); // #4004: --jobs → io async_limit
    var bundler = Bundler.init(native_alloc, async_data.options);
    defer bundler.deinit();
    async_data.result = bundler.bundle(common.io()) catch |err| {
        async_data.err_msg = @errorName(err);
        // 완료 TSFN 호출
        _ = c.napi_call_threadsafe_function(async_data.completion_tsfn, @ptrCast(async_data), c.napi_tsfn_blocking);
        return;
    };
    // 완료 TSFN 호출 → 메인 스레드에서 Promise resolve
    _ = c.napi_call_threadsafe_function(async_data.completion_tsfn, @ptrCast(async_data), c.napi_tsfn_blocking);
}

/// 메인 스레드에서 실행 — 결과를 JS Promise로 반환 (TSFN 콜백)
fn buildCompleteTsfn(env: c.napi_env, _: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const async_data: *BuildAsyncData = @ptrCast(@alignCast(data.?));
    defer {
        // 완료 시점엔 completion_tsfn 이 항상 생성돼 있으므로 여기서 release.
        _ = c.napi_release_threadsafe_function(async_data.completion_tsfn, c.napi_tsfn_release);
        deinitAsyncData(async_data);
    }

    if (async_data.err_msg) |msg| {
        var js_err: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, msg, std.mem.len(msg), &js_err);
        var js_error: c.napi_value = undefined;
        _ = c.napi_create_error(env, null, js_err, &js_error);
        _ = c.napi_reject_deferred(env, async_data.deferred, js_error);
    } else if (async_data.result) |*result| {
        defer result.deinit(native_alloc);
        const js_result = buildResultToJS(env, result, async_data.log_opts);
        if (js_result) |val| {
            _ = c.napi_resolve_deferred(env, async_data.deferred, val);
        } else {
            var js_err_str: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, "failed to create result", "failed to create result".len, &js_err_str);
            var js_error: c.napi_value = undefined;
            _ = c.napi_create_error(env, null, js_err_str, &js_error);
            _ = c.napi_reject_deferred(env, async_data.deferred, js_error);
        }
    } else {
        var js_err_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "unknown build error", "unknown build error".len, &js_err_str);
        var js_error: c.napi_value = undefined;
        _ = c.napi_create_error(env, null, js_err_str, &js_error);
        _ = c.napi_reject_deferred(env, async_data.deferred, js_error);
    }
}

pub fn napiBuild(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "build requires an options object");

    // async data 할당
    const async_data = native_alloc.create(BuildAsyncData) catch return throwError(env, "OutOfMemory");
    async_data.* = .{
        .env = env,
        .deferred = undefined,
        .completion_tsfn = undefined,
        .options = undefined,
        .log_opts = parseLogFilterOptions(env, argv[0]),
        .owned_strings = .empty,
        .owned_string_arrays = .empty,
        .napi_plugins = .empty,
        .zig_plugins = .empty,
    };

    // 옵션 파싱 (모든 문자열을 소유 메모리로 복사)
    var opts = parseBuildOptions(env, argv[0], &async_data.owned_strings, &async_data.owned_string_arrays) orelse {
        deinitAsyncData(async_data);
        return throwError(env, "invalid build options");
    };
    // typed slices 를 정리 대상으로 즉시 등록 — 이후 에러 경로의 deinitAsyncData 가 해제.
    async_data.options = opts;
    async_data.options_set = true;

    // _pluginDispatcher가 있으면 NapiPlugin 생성
    if (getNamedProperty(env, argv[0], "_pluginDispatcher")) |dispatcher_fn| {
        const np = native_alloc.create(NapiPlugin) catch {
            deinitAsyncData(async_data);
            return throwError(env, "OutOfMemory");
        };
        np.* = .{
            .name = native_alloc.dupe(u8, "js-plugin") catch {
                native_alloc.destroy(np);
                deinitAsyncData(async_data);
                return throwError(env, "OutOfMemory");
            },
            .tsfn = undefined,
        };

        // threadsafe function 생성
        var resource_name_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zntc_plugin", "zntc_plugin".len, &resource_name_str);
        if (c.napi_create_threadsafe_function(
            env,
            dispatcher_fn,
            null,
            resource_name_str,
            0, // max_queue_size: 0 = unlimited
            1, // initial_thread_count
            null, // thread_finalize_data
            null, // thread_finalize_cb
            @ptrCast(np), // context passed to call_js
            NapiPlugin.callJsCallback,
            &np.tsfn,
        ) != c.napi_ok) {
            native_alloc.free(np.name);
            native_alloc.destroy(np);
            deinitAsyncData(async_data);
            return throwError(env, "failed to create threadsafe function");
        }

        async_data.napi_plugins.append(native_alloc, np) catch {};
        async_data.zig_plugins.append(native_alloc, np.toPlugin()) catch {};
        opts.plugins = async_data.zig_plugins.items;
    }

    // _manualChunks JS 함수가 있으면 TSFN 으로 감싸 Zig resolver 로 연결 (#1027 Phase 2).
    if (getNamedProperty(env, argv[0], "_manualChunks")) |fn_val| {
        if (installManualChunksResolver(env, fn_val, &opts)) |resolver| {
            async_data.napi_manual_chunks = resolver;
        } else {
            deinitAsyncData(async_data);
            return throwError(env, "failed to install manualChunks resolver");
        }
    }

    // opts.plugins / manualChunks resolver 가 채워진 최종 상태로 갱신 (worker 가 읽음).
    async_data.options = opts;

    // Promise 생성
    var promise: c.napi_value = undefined;
    if (c.napi_create_promise(env, &async_data.deferred, &promise) != c.napi_ok) {
        deinitAsyncData(async_data);
        return throwError(env, "failed to create promise");
    }

    // 완료 TSFN 생성 (빌드 완료 시 메인 스레드에서 Promise resolve)
    var resource_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "zntc_build_complete", "zntc_build_complete".len, &resource_name);
    if (c.napi_create_threadsafe_function(
        env,
        null, // js_func: 사용 안 함 (call_js에서 직접 처리)
        null, // async_resource
        resource_name,
        0, // max_queue_size: unlimited
        1, // initial_thread_count
        null, // thread_finalize_data
        null, // thread_finalize_cb
        null, // context
        buildCompleteTsfn,
        &async_data.completion_tsfn,
    ) != c.napi_ok) {
        // completion_tsfn 생성 실패 — 아직 미생성이라 release 불필요.
        deinitAsyncData(async_data);
        return throwError(env, "failed to create completion tsfn");
    }

    // 독립 스레드에서 빌드 실행 (libuv 워커 미사용 → TSFN 데드락 방지)
    const thread = std.Thread.spawn(.{}, buildWorkerThread, .{async_data}) catch {
        // completion_tsfn 은 생성됐으므로 release 후 나머지 자원 정리.
        _ = c.napi_release_threadsafe_function(async_data.completion_tsfn, c.napi_tsfn_release);
        deinitAsyncData(async_data);
        return throwError(env, "failed to spawn build thread");
    };
    thread.detach();

    return promise;
}
