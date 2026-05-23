//! Profile NAPI callbacks.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const profile_mod = zntc_lib.profile;
const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const getStringArg = common.getStringArg;
const parseStringArray = common.parseStringArray;

/// configureProfile(categories, level?) → void
pub fn napiConfigureProfile(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }

    var arena = std.heap.ArenaAllocator.init(native_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    if (argc > 0) {
        const cats = parseStringArray(env, argv[0], arena_alloc) orelse &.{};
        profile_mod.resetCounters();
        profile_mod.addCategories(cats);
    }
    if (argc > 1) {
        if (getStringArg(env, argv[1], arena_alloc)) |level| {
            if (profile_mod.Level.fromString(level)) |parsed| {
                profile_mod.setLevel(parsed);
            }
        }
    }

    var out: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &out);
    return out;
}

/// profileReport(format?) → string
pub fn napiProfileReport(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }

    var format: profile_mod.Format = .table;
    if (argc > 0) {
        if (getStringArg(env, argv[0], native_alloc)) |s| {
            defer native_alloc.free(s);
            format = profile_mod.Format.fromString(s) orelse .table;
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(native_alloc);
    profile_mod.report(buf.writer(native_alloc), format) catch return throwError(env, "failed to render profile report");

    var js_report: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, buf.items.ptr, buf.items.len, &js_report) != c.napi_ok) {
        return throwError(env, "failed to create profile report");
    }
    return js_report;
}
