const std = @import("std");
const zntc_lib = @import("zntc_lib");
const bundler_mod = zntc_lib.bundler;
const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
const transformer_mod = zntc_lib.transformer.transformer;
const JsxRuntime = zntc_lib.codegen.codegen.JsxRuntime;
const JsxConfig = zntc_lib.app.build.JsxConfig;
const AppBuildOptions = zntc_lib.app.build.AppBuildOptions;
const common = @import("common.zig");
const options_mod = @import("options.zig");
const result_napi_mod = @import("result.zig");
const plugin_bridge = @import("plugin_bridge.zig");
const c = common.c;

const native_alloc = common.nativeAlloc();

const throwError = common.throwError;
const getNamedProperty = common.getNamedProperty;
const getObjectBool = common.getObjectBool;
const getObjectString = common.getObjectString;
const getObjectStringArray = common.getObjectStringArray;
const getObjectKeyValuePairs = common.getObjectKeyValuePairs;

const LogFilterOptions = options_mod.LogFilterOptions;
const parseLogFilterOptions = options_mod.parseLogFilterOptions;
const parseBuildOptions = options_mod.parseBuildOptions;
const freeOptionsTypedSlices = options_mod.freeOptionsTypedSlices;
const getAutoLabelMode = options_mod.getAutoLabelMode;
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

/// 독립 스레드에서 번들링 실행 (libuv 워커 미사용 → TSFN 데드락 방지)
fn buildWorkerThread(async_data: *BuildAsyncData) void {
    var bundler = Bundler.init(native_alloc, async_data.options);
    defer bundler.deinit();
    async_data.result = bundler.bundle() catch |err| {
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
        // TSFN 해제
        _ = c.napi_release_threadsafe_function(async_data.completion_tsfn, c.napi_tsfn_release);
        // 소유된 문자열 해제 (개별 문자열)
        for (async_data.owned_strings.items) |s| native_alloc.free(s);
        async_data.owned_strings.deinit(native_alloc);
        // 배열 컨테이너만 해제 (내부 문자열은 owned_strings에서 이미 해제됨)
        for (async_data.owned_string_arrays.items) |arr| native_alloc.free(arr);
        async_data.owned_string_arrays.deinit(native_alloc);
        // typed slices (define/module_specifier_map/alias) — native_alloc 소유, 명시 free (#2396).
        freeOptionsTypedSlices(&async_data.options);
        // NAPI 플러그인 해제
        for (async_data.napi_plugins.items) |np| np.deinit();
        async_data.napi_plugins.deinit(native_alloc);
        async_data.zig_plugins.deinit(native_alloc);
        if (async_data.napi_manual_chunks) |mc| mc.deinit();
        native_alloc.destroy(async_data);
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
        native_alloc.destroy(async_data);
        return throwError(env, "invalid build options");
    };

    // _pluginDispatcher가 있으면 NapiPlugin 생성
    if (getNamedProperty(env, argv[0], "_pluginDispatcher")) |dispatcher_fn| {
        const np = native_alloc.create(NapiPlugin) catch {
            native_alloc.destroy(async_data);
            return throwError(env, "OutOfMemory");
        };
        np.* = .{
            .name = native_alloc.dupe(u8, "js-plugin") catch {
                native_alloc.destroy(np);
                native_alloc.destroy(async_data);
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
            native_alloc.destroy(async_data);
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
            native_alloc.destroy(async_data);
            return throwError(env, "failed to install manualChunks resolver");
        }
    }

    async_data.options = opts;

    // Promise 생성
    var promise: c.napi_value = undefined;
    if (c.napi_create_promise(env, &async_data.deferred, &promise) != c.napi_ok) {
        native_alloc.destroy(async_data);
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
        native_alloc.destroy(async_data);
        return throwError(env, "failed to create completion tsfn");
    }

    // 독립 스레드에서 빌드 실행 (libuv 워커 미사용 → TSFN 데드락 방지)
    const thread = std.Thread.spawn(.{}, buildWorkerThread, .{async_data}) catch {
        _ = c.napi_release_threadsafe_function(async_data.completion_tsfn, c.napi_tsfn_release);
        native_alloc.destroy(async_data);
        return throwError(env, "failed to spawn build thread");
    };
    thread.detach();

    return promise;
}

// ─── napiBuildApp (async, RFC #3833 v2-A / D1a) ───
// `buildAppSync` 의 sync 대응 — `runAppBuild` 가 async `build` 호출로 전환되어
// async plugin onLoad (예: PostCSS) 가 sync dispatcher 의 `syncPluginPromiseFailure`
// 함정에 빠지지 않도록 한다 (PR-3a dead-code 원인). `buildAppSync` export 자체는
// thin sync wrapper 로 유지해 Vite adapter / NAPI 직접 호출 사용자 호환 보존.

const BuildAppAsyncData = struct {
    env: c.napi_env,
    deferred: c.napi_deferred,
    completion_tsfn: c.napi_threadsafe_function,
    /// `app.build.buildApp` 가 받는 옵션 — 워커 스레드 수명까지 유효해야 하므로 소유.
    options: AppBuildOptions,
    /// 옵션의 backing 문자열 (root/outdir/entry_html/base/mode/env_dir/jsx fields 등).
    owned_strings: std.ArrayList([]const u8),
    /// 옵션의 backing string-array (env_prefixes/emotion_extra_*/sc_meaningless 등).
    owned_string_arrays: std.ArrayList([]const []const u8),
    /// define entries — caller 가 alloc 한 slice, deinit 에서 free.
    define_entries: []const transformer_mod.DefineEntry = &.{},
    /// NAPI plugin (async dispatcher slot `_pluginDispatcher` 기반).
    napi_plugins: std.ArrayList(*NapiPlugin),
    zig_plugins: std.ArrayList(Plugin),
    /// 결과: app build 는 outputFiles 가 디스크 write 되므로 count 만 반환.
    output_count: usize = 0,
    err_msg: ?[*:0]const u8 = null,
};

fn buildAppWorkerThread(async_data: *BuildAppAsyncData) void {
    async_data.output_count = zntc_lib.app.build.buildApp(native_alloc, async_data.options) catch |err| {
        async_data.err_msg = @errorName(err);
        _ = c.napi_call_threadsafe_function(async_data.completion_tsfn, @ptrCast(async_data), c.napi_tsfn_blocking);
        return;
    };
    _ = c.napi_call_threadsafe_function(async_data.completion_tsfn, @ptrCast(async_data), c.napi_tsfn_blocking);
}

fn buildAppCompleteTsfn(env: c.napi_env, _: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const async_data: *BuildAppAsyncData = @ptrCast(@alignCast(data.?));
    defer {
        _ = c.napi_release_threadsafe_function(async_data.completion_tsfn, c.napi_tsfn_release);
        for (async_data.owned_strings.items) |s| native_alloc.free(s);
        async_data.owned_strings.deinit(native_alloc);
        for (async_data.owned_string_arrays.items) |arr| native_alloc.free(arr);
        async_data.owned_string_arrays.deinit(native_alloc);
        if (async_data.define_entries.len > 0) native_alloc.free(async_data.define_entries);
        for (async_data.napi_plugins.items) |np| np.deinit();
        async_data.napi_plugins.deinit(native_alloc);
        async_data.zig_plugins.deinit(native_alloc);
        native_alloc.destroy(async_data);
    }

    if (async_data.err_msg) |msg| {
        var js_err: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, msg, std.mem.len(msg), &js_err);
        var js_error: c.napi_value = undefined;
        _ = c.napi_create_error(env, null, js_err, &js_error);
        _ = c.napi_reject_deferred(env, async_data.deferred, js_error);
        return;
    }

    // `napiBuildAppSync` 의 result 객체 동형 — outputFiles/errors/warnings 빈 array
    // + outputCount(uint32). app build 는 disk write 가 native 안에서 끝나서 JS layer
    // 가 받을 outputFiles 없음.
    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) {
        var js_err_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "failed to create result", "failed to create result".len, &js_err_str);
        var js_error: c.napi_value = undefined;
        _ = c.napi_create_error(env, null, js_err_str, &js_error);
        _ = c.napi_reject_deferred(env, async_data.deferred, js_error);
        return;
    }
    var js_outputs: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_outputs);
    _ = c.napi_set_named_property(env, js_result, "outputFiles", js_outputs);
    var js_errors: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_errors);
    _ = c.napi_set_named_property(env, js_result, "errors", js_errors);
    var js_warnings: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_warnings);
    _ = c.napi_set_named_property(env, js_result, "warnings", js_warnings);
    var js_count: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, @intCast(async_data.output_count), &js_count);
    _ = c.napi_set_named_property(env, js_result, "outputCount", js_count);
    _ = c.napi_resolve_deferred(env, async_data.deferred, js_result);
}

pub fn napiBuildApp(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "buildApp requires an options object");

    const async_data = native_alloc.create(BuildAppAsyncData) catch return throwError(env, "OutOfMemory");
    async_data.* = .{
        .env = env,
        .deferred = undefined,
        .completion_tsfn = undefined,
        .options = .{},
        .owned_strings = .empty,
        .owned_string_arrays = .empty,
        .napi_plugins = .empty,
        .zig_plugins = .empty,
    };

    // cleanup helper — early error path 에서 부분-초기화 async_data 해제.
    const cleanupAsyncData = struct {
        fn f(ad: *BuildAppAsyncData) void {
            for (ad.owned_strings.items) |s| native_alloc.free(s);
            ad.owned_strings.deinit(native_alloc);
            for (ad.owned_string_arrays.items) |arr| native_alloc.free(arr);
            ad.owned_string_arrays.deinit(native_alloc);
            if (ad.define_entries.len > 0) native_alloc.free(ad.define_entries);
            for (ad.napi_plugins.items) |np| np.deinit();
            ad.napi_plugins.deinit(native_alloc);
            ad.zig_plugins.deinit(native_alloc);
            native_alloc.destroy(ad);
        }
    }.f;

    // 옵션 파싱 — `napiBuildAppSync` 와 동일 mirror. ownStr 로 owned_strings 에 push.
    const opts_obj = argv[0];
    const ownStr = struct {
        fn f(e: c.napi_env, obj: c.napi_value, key: [*:0]const u8, list: *std.ArrayList([]const u8)) ?[]const u8 {
            const s = getObjectString(e, obj, key, native_alloc) orelse return null;
            list.append(native_alloc, s) catch {
                native_alloc.free(s);
                return null;
            };
            return s;
        }
    }.f;

    const root = ownStr(env, opts_obj, "root", &async_data.owned_strings) orelse ".";
    const outdir = ownStr(env, opts_obj, "outdir", &async_data.owned_strings) orelse "dist";
    const entry_html = ownStr(env, opts_obj, "entryHtml", &async_data.owned_strings) orelse "index.html";
    const public_dir_value = ownStr(env, opts_obj, "publicDir", &async_data.owned_strings);
    const public_dir: ?[]const u8 = if (getObjectBool(env, opts_obj, "disablePublicDir", false)) null else (public_dir_value orelse "public");
    const base = ownStr(env, opts_obj, "base", &async_data.owned_strings) orelse "/";
    const mode = ownStr(env, opts_obj, "mode", &async_data.owned_strings) orelse "production";
    const env_dir = ownStr(env, opts_obj, "envDir", &async_data.owned_strings);

    // string-array helper — OOM 중간 실패 시 잔여 elements + arr outer slice 모두 free.
    // /code-review max finding: 기존 inline for-loop 패턴은 append 실패 시 i+1 이후
    // strings 와 outer slice 가 leak. helper 로 single-path 정리.
    const takeStringArray = struct {
        fn f(ad: *BuildAppAsyncData, arr_opt: ?[]const []const u8) bool {
            const arr = arr_opt orelse return true;
            ad.owned_strings.ensureUnusedCapacity(native_alloc, arr.len) catch {
                // OOM — arr 전체 free
                for (arr) |s| native_alloc.free(s);
                native_alloc.free(arr);
                return false;
            };
            for (arr) |s| ad.owned_strings.append(native_alloc, s) catch unreachable; // ensureUnusedCapacity 후라 안전
            ad.owned_string_arrays.append(native_alloc, arr) catch {
                // strings 는 이미 owned_strings 안 → cleanup 이 free. arr outer 만 free.
                native_alloc.free(arr);
                return false;
            };
            return true;
        }
    }.f;

    const env_prefixes = getObjectStringArray(env, opts_obj, "envPrefixes", native_alloc);
    if (!takeStringArray(async_data, env_prefixes)) {
        cleanupAsyncData(async_data);
        return throwError(env, "OutOfMemory");
    }

    const define_pairs = getObjectKeyValuePairs(env, opts_obj, "define", native_alloc);
    if (define_pairs) |pairs| {
        const defs = native_alloc.alloc(transformer_mod.DefineEntry, pairs.len) catch {
            for (pairs) |pair| {
                native_alloc.free(pair[0]);
                native_alloc.free(pair[1]);
            }
            native_alloc.free(pairs);
            cleanupAsyncData(async_data);
            return throwError(env, "OutOfMemory");
        };
        // /code-review max finding: 기존 inline loop 가 mid-iteration OOM 시 defs +
        // 잔여 pair[0]/pair[1] + pairs outer slice leak. ensureUnusedCapacity (pair 당
        // 2개 = pairs.len * 2) 로 pre-grow 후 append 는 무조건 성공.
        async_data.owned_strings.ensureUnusedCapacity(native_alloc, pairs.len * 2) catch {
            native_alloc.free(defs);
            for (pairs) |pair| {
                native_alloc.free(pair[0]);
                native_alloc.free(pair[1]);
            }
            native_alloc.free(pairs);
            cleanupAsyncData(async_data);
            return throwError(env, "OutOfMemory");
        };
        for (pairs, 0..) |pair, i| {
            async_data.owned_strings.append(native_alloc, pair[0]) catch unreachable;
            async_data.owned_strings.append(native_alloc, pair[1]) catch unreachable;
            defs[i] = .{ .key = pair[0], .value = pair[1] };
        }
        native_alloc.free(pairs);
        async_data.define_entries = defs;
    }

    const emotion_extra_css = getObjectStringArray(env, opts_obj, "emotionExtraCssSources", native_alloc);
    if (!takeStringArray(async_data, emotion_extra_css)) {
        cleanupAsyncData(async_data);
        return throwError(env, "OutOfMemory");
    }
    const emotion_extra_styled = getObjectStringArray(env, opts_obj, "emotionExtraStyledSources", native_alloc);
    if (!takeStringArray(async_data, emotion_extra_styled)) {
        cleanupAsyncData(async_data);
        return throwError(env, "OutOfMemory");
    }
    const sc_meaningless = getObjectStringArray(env, opts_obj, "styledComponentsMeaninglessFileNames", native_alloc);
    if (!takeStringArray(async_data, sc_meaningless)) {
        cleanupAsyncData(async_data);
        return throwError(env, "OutOfMemory");
    }
    const sc_top_level = getObjectStringArray(env, opts_obj, "styledComponentsTopLevelImportPaths", native_alloc);
    if (!takeStringArray(async_data, sc_top_level)) {
        cleanupAsyncData(async_data);
        return throwError(env, "OutOfMemory");
    }

    // JSX — napiBuildAppSync 와 동일. invalid 는 strict throw.
    const jsx_str = ownStr(env, opts_obj, "jsx", &async_data.owned_strings);
    var jsx_cfg = JsxConfig{};
    if (jsx_str) |s| {
        jsx_cfg.runtime = JsxRuntime.fromString(s) orelse {
            cleanupAsyncData(async_data);
            return throwError(env, "invalid 'jsx' option (expected automatic / automatic-dev / classic / preserve)");
        };
    }
    if (ownStr(env, opts_obj, "jsxImportSource", &async_data.owned_strings)) |s| jsx_cfg.import_source = s;
    if (ownStr(env, opts_obj, "jsxFactory", &async_data.owned_strings)) |s| jsx_cfg.factory = s;
    if (ownStr(env, opts_obj, "jsxFragment", &async_data.owned_strings)) |s| jsx_cfg.fragment = s;

    // _pluginDispatcher (async slot) — `napiBuild` 의 NapiPlugin TSFN 패턴 mirror.
    // sync slot `_pluginDispatcherSync` 는 본 entry 에서 무시 (caller 가 async
    // dispatcher 보내야 함).
    if (getNamedProperty(env, opts_obj, "_pluginDispatcher")) |dispatcher_fn| {
        const np = native_alloc.create(NapiPlugin) catch {
            cleanupAsyncData(async_data);
            return throwError(env, "OutOfMemory");
        };
        np.* = .{
            .name = native_alloc.dupe(u8, "js-plugin") catch {
                native_alloc.destroy(np);
                cleanupAsyncData(async_data);
                return throwError(env, "OutOfMemory");
            },
            .tsfn = undefined,
        };

        var resource_name_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zntc_plugin", "zntc_plugin".len, &resource_name_str);
        if (c.napi_create_threadsafe_function(
            env,
            dispatcher_fn,
            null,
            resource_name_str,
            0,
            1,
            null,
            null,
            @ptrCast(np),
            NapiPlugin.callJsCallback,
            &np.tsfn,
        ) != c.napi_ok) {
            native_alloc.free(np.name);
            native_alloc.destroy(np);
            cleanupAsyncData(async_data);
            return throwError(env, "failed to create threadsafe function");
        }

        async_data.napi_plugins.append(native_alloc, np) catch {
            // np 가 아직 list 에 없어서 cleanupAsyncData 의 for-loop 가 못 잡음 → 직접 deinit.
            np.deinit();
            cleanupAsyncData(async_data);
            return throwError(env, "OutOfMemory");
        };
        async_data.zig_plugins.append(native_alloc, np.toPlugin()) catch {
            // np 는 이미 napi_plugins 안 → cleanupAsyncData 의 for-loop 가 deinit.
            cleanupAsyncData(async_data);
            return throwError(env, "OutOfMemory");
        };
    } else if (getNamedProperty(env, opts_obj, "_pluginDispatcherSync")) |_| {
        // /code-review max finding — sync slot 만 wire 된 경우 silent 로 plugin 미동작.
        // buildApp 은 async dispatcher 만 인식. JS layer (`buildApp` export) 가 항상
        // `_pluginDispatcher` set 하므로 정상 path 는 도달 안 함. 자체 어댑터 작성
        // 사용자의 wiring 버그 진단용 stderr warn.
        std.debug.print("warning: buildApp received _pluginDispatcherSync but expects _pluginDispatcher (async). plugin hooks will not fire.\n", .{});
    }

    // AppBuildOptions 채움 — napiBuildAppSync 의 buildApp 호출 인자와 동일.
    async_data.options = .{
        .root = root,
        .outdir = outdir,
        .entry_html = entry_html,
        .public_dir = public_dir,
        .base = base,
        .mode = mode,
        .env_dir = env_dir,
        .env_prefixes = env_prefixes orelse &.{ "VITE_", "ZNTC_" },
        .define = async_data.define_entries,
        .minify = getObjectBool(env, opts_obj, "minify", false),
        .sourcemap = getObjectBool(env, opts_obj, "sourcemap", false),
        .splitting = getObjectBool(env, opts_obj, "splitting", true),
        .styled_components = getObjectBool(env, opts_obj, "styledComponents", false),
        .styled_components_ssr = getObjectBool(env, opts_obj, "styledComponentsSsr", true),
        .styled_components_minify = getObjectBool(env, opts_obj, "styledComponentsMinify", false),
        .styled_components_file_name = getObjectBool(env, opts_obj, "styledComponentsFileName", true),
        .styled_components_pure = getObjectBool(env, opts_obj, "styledComponentsPure", false),
        .styled_components_namespace = ownStr(env, opts_obj, "styledComponentsNamespace", &async_data.owned_strings) orelse "",
        .styled_components_meaningless_file_names = sc_meaningless orelse &.{"index"},
        .styled_components_top_level_import_paths = sc_top_level orelse &.{},
        .styled_components_css_prop = getObjectBool(env, opts_obj, "styledComponentsCssProp", false),
        .emotion = getObjectBool(env, opts_obj, "emotion", false),
        .emotion_auto_label = getAutoLabelMode(env, opts_obj, native_alloc),
        .emotion_source_map = getObjectBool(env, opts_obj, "emotionSourceMap", false),
        .emotion_label_format = ownStr(env, opts_obj, "emotionLabelFormat", &async_data.owned_strings) orelse "",
        .emotion_extra_css_sources = emotion_extra_css orelse &.{},
        .emotion_extra_styled_sources = emotion_extra_styled orelse &.{},
        .jsx = jsx_cfg,
        .plugins = async_data.zig_plugins.items,
    };

    // Promise 생성
    var promise: c.napi_value = undefined;
    if (c.napi_create_promise(env, &async_data.deferred, &promise) != c.napi_ok) {
        cleanupAsyncData(async_data);
        return throwError(env, "failed to create promise");
    }

    // 완료 TSFN
    var resource_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "zntc_buildapp_complete", "zntc_buildapp_complete".len, &resource_name);
    if (c.napi_create_threadsafe_function(
        env,
        null,
        null,
        resource_name,
        0,
        1,
        null,
        null,
        null,
        buildAppCompleteTsfn,
        &async_data.completion_tsfn,
    ) != c.napi_ok) {
        cleanupAsyncData(async_data);
        return throwError(env, "failed to create completion tsfn");
    }

    // 독립 스레드에서 buildApp 실행
    const thread = std.Thread.spawn(.{}, buildAppWorkerThread, .{async_data}) catch {
        _ = c.napi_release_threadsafe_function(async_data.completion_tsfn, c.napi_tsfn_release);
        cleanupAsyncData(async_data);
        return throwError(env, "failed to spawn buildApp thread");
    };
    thread.detach();

    return promise;
}
