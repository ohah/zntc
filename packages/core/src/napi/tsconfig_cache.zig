//! TsconfigCache NAPI handle helpers.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const TsconfigCache = zntc_lib.tsconfig_cache.TsconfigCache;
const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const unwrapNapi = common.unwrapNapi;

/// `napi_wrap` finalizer — JS handle GC 시 native cache deinit.
fn tsconfigCacheFinalize(_: c.napi_env, finalize_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (finalize_data) |data| {
        const cache: *TsconfigCache = @ptrCast(@alignCast(data));
        cache.deinit();
    }
}

/// `cache.clear()` — 모든 entry 와 내부 string 메모리 회수.
fn napiTsconfigCacheClear(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 0;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, null, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get this");
    }
    const cache = unwrapNapi(TsconfigCache, env, this) orelse return throwError(env, "TsconfigCache: unwrap failed");
    cache.clear();
    var js_undef: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undef);
    return js_undef;
}

/// `cache.size()` — 현재 캐시된 entry 수 (number).
fn napiTsconfigCacheSize(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 0;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, null, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get this");
    }
    const cache = unwrapNapi(TsconfigCache, env, this) orelse return throwError(env, "TsconfigCache: unwrap failed");
    var js_n: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, @intCast(cache.size()), &js_n);
    return js_n;
}

/// `createTsconfigCache()` → handle 객체 ({ clear, size }).
/// JS 측 `class TsconfigCache` 가 본 handle 을 wrapping 해서 사용. NAPI 가 finalizer 로
/// GC 시 자동 cleanup — 사용자가 명시 dispose 안 해도 메모리 안전.
pub fn napiCreateTsconfigCache(env: c.napi_env, _: c.napi_callback_info) callconv(.c) c.napi_value {
    const cache = TsconfigCache.init(native_alloc) catch {
        return throwError(env, "TsconfigCache: OOM");
    };

    var js_handle: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_handle) != c.napi_ok) {
        cache.deinit();
        return throwError(env, "failed to create handle object");
    }

    if (c.napi_wrap(env, js_handle, @ptrCast(cache), tsconfigCacheFinalize, null, null) != c.napi_ok) {
        cache.deinit();
        return throwError(env, "failed to wrap TsconfigCache");
    }

    var clear_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "clear", "clear".len, napiTsconfigCacheClear, null, &clear_fn);
    _ = c.napi_set_named_property(env, js_handle, "clear", clear_fn);

    var size_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "size", "size".len, napiTsconfigCacheSize, null, &size_fn);
    _ = c.napi_set_named_property(env, js_handle, "size", size_fn);

    return js_handle;
}

/// 옵셔널 인자 (transpile 4번째) 가 TsconfigCache handle 이면 internal pointer 반환.
/// undefined / null / wrap 실패 시 null. caller 가 null-check 으로 fallback (직접 walk).
///
/// **Lifetime**: 반환 pointer 는 _현재 sync NAPI 호출_ 동안만 유효. JS handle 이 caller
/// stack 에 잡혀있어 GC finalizer 가 실행되지 않음을 전제. 호출 종료 후 보관 금지.
pub fn unwrapTsconfigCache(env: c.napi_env, value: c.napi_value) ?*TsconfigCache {
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok) return null;
    if (value_type != c.napi_object) return null;
    return unwrapNapi(TsconfigCache, env, value);
}
