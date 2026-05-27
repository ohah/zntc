//! ZNTC NAPI 진입점
//!
//! Node.js/Bun/Deno에서 .node addon으로 로드되는 네이티브 모듈.
//! 전역 상태 없이 napi_create_string_utf8로 JS 값을 직접 반환한다.
//!
//! JS에서의 사용:
//!   const { transpile } = require('./zntc.node');
//!   const result = transpile(source, filename, flags, unsupported, factory, fragment, importSource);
//!   // result = { code: string, map?: string }

const std = @import("std");
const zntc_lib = @import("zntc_lib");

/// Bun 스타일 crash report: NAPI addon에서 panic이 터지면 Node 프로세스 전체가
/// 죽는다 — 그 전에 ZNTC 배너 + 이슈 URL을 찍어 사용자가 신고하기 쉽게 한다.
pub const panic = zntc_lib.crash_handler.panic;
const profile_mod = zntc_lib.profile;

const common = @import("napi/common.zig");
const tsconfig_cache_mod = @import("napi/tsconfig_cache.zig");
const benchmark_mod = @import("napi/benchmark.zig");
const profile_napi_mod = @import("napi/profile.zig");
const c = common.c;

const native_alloc = common.nativeAlloc();

const transpile_entry = @import("napi/transpile_entry.zig");
const build_sync_entry = @import("napi/build_sync_entry.zig");
const build_async_entry = @import("napi/build_async_entry.zig");

const watch_mod = @import("napi/watch.zig");
const napiWatch = watch_mod.napiWatch;

const mcp_stdio_entry = @import("napi/mcp_stdio_entry.zig");
const tls_smoke = @import("napi/tls_smoke.zig");
const serve_entry = @import("napi/serve_entry.zig");

// ─── 모듈 등록 ───

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    // Debug 빌드 한정: DebugAllocator leak 리포트(stack trace) 를 process 종료 시
    // stderr 로 dump 하는 atexit handler 1회 등록 (#dev-leak-investigation).
    // ReleaseFast 에서는 no-op.
    common.registerLeakDump(env);

    // ZNTC_DEBUG env 를 프로세스 시작 시 1회 파싱해 mask 초기화.
    // 개별 build/watch 호출마다 BundleOptions.debug 로 카테고리 추가 가능.
    @import("zntc_lib").debug_log.initFromEnv(native_alloc);

    // ZNTC_PROFILE / ZNTC_PROFILE_LEVEL 도 동일하게 1회 파싱. 개별 build 호출마다
    // `BundleOptions.profile` / `profileLevel` 로 추가 가능.
    profile_mod.initFromEnv(native_alloc);

    // BUNGAE_HMR_PROFILE=1 호환 — 번개의 기존 HMR profile 토글을 새 인프라로 매핑.
    // 내부적으로 ZNTC_PROFILE=hmr 과 동등.
    if (std.process.getEnvVarOwned(native_alloc, "BUNGAE_HMR_PROFILE")) |v| {
        defer native_alloc.free(v);
        if (v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false")) {
            profile_mod.addFromCsv("hmr");
        }
    } else |_| {}

    var fn_value: c.napi_value = undefined;
    _ = c.napi_create_function(env, "transpile", "transpile".len, transpile_entry.napiTranspile, null, &fn_value);
    _ = c.napi_set_named_property(env, exports, "transpile", fn_value);

    var tokenize_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "tokenize", "tokenize".len, transpile_entry.napiTokenize, null, &tokenize_fn);
    _ = c.napi_set_named_property(env, exports, "tokenize", tokenize_fn);

    var configure_profile_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "configureProfile", "configureProfile".len, profile_napi_mod.napiConfigureProfile, null, &configure_profile_fn);
    _ = c.napi_set_named_property(env, exports, "configureProfile", configure_profile_fn);

    var profile_report_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "profileReport", "profileReport".len, profile_napi_mod.napiProfileReport, null, &profile_report_fn);
    _ = c.napi_set_named_property(env, exports, "profileReport", profile_report_fn);

    // TsconfigCache (#2367)
    var ctc_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "createTsconfigCache", "createTsconfigCache".len, tsconfig_cache_mod.napiCreateTsconfigCache, null, &ctc_fn);
    _ = c.napi_set_named_property(env, exports, "createTsconfigCache", ctc_fn);

    var build_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "buildSync", "buildSync".len, build_sync_entry.napiBuildSync, null, &build_sync_fn);
    _ = c.napi_set_named_property(env, exports, "buildSync", build_sync_fn);

    var build_app_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "buildAppSync", "buildAppSync".len, build_sync_entry.napiBuildAppSync, null, &build_app_sync_fn);
    _ = c.napi_set_named_property(env, exports, "buildAppSync", build_app_sync_fn);

    var prepare_app_dev_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "prepareAppDevSync", "prepareAppDevSync".len, build_sync_entry.napiPrepareAppDevSync, null, &prepare_app_dev_sync_fn);
    _ = c.napi_set_named_property(env, exports, "prepareAppDevSync", prepare_app_dev_sync_fn);

    var build_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "build", "build".len, build_async_entry.napiBuild, null, &build_fn);
    _ = c.napi_set_named_property(env, exports, "build", build_fn);

    var watch_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "watch", "watch".len, napiWatch, null, &watch_fn);
    _ = c.napi_set_named_property(env, exports, "watch", watch_fn);

    var bench_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "benchmark", "benchmark".len, benchmark_mod.napiBenchmark, null, &bench_fn);
    _ = c.napi_set_named_property(env, exports, "benchmark", bench_fn);

    var mcp_stdio_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "mcpStdioServe", "mcpStdioServe".len, mcp_stdio_entry.napiMcpStdioServe, null, &mcp_stdio_fn);
    _ = c.napi_set_named_property(env, exports, "mcpStdioServe", mcp_stdio_fn);

    var tls_self_check_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "tlsSelfCheck", "tlsSelfCheck".len, tls_smoke.napiTlsSelfCheck, null, &tls_self_check_fn);
    _ = c.napi_set_named_property(env, exports, "tlsSelfCheck", tls_self_check_fn);

    var start_dev_server_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "startDevServer", "startDevServer".len, serve_entry.napiStartDevServer, null, &start_dev_server_fn);
    _ = c.napi_set_named_property(env, exports, "startDevServer", start_dev_server_fn);

    var stop_dev_server_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "stopDevServer", "stopDevServer".len, serve_entry.napiStopDevServer, null, &stop_dev_server_fn);
    _ = c.napi_set_named_property(env, exports, "stopDevServer", stop_dev_server_fn);

    var get_dev_server_port_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "getDevServerPort", "getDevServerPort".len, serve_entry.napiGetDevServerPort, null, &get_dev_server_port_fn);
    _ = c.napi_set_named_property(env, exports, "getDevServerPort", get_dev_server_port_fn);

    return exports;
}
