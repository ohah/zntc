//! ZTS NAPI 진입점
//!
//! Node.js/Bun/Deno에서 .node addon으로 로드되는 네이티브 모듈.
//! 전역 상태 없이 napi_create_string_utf8로 JS 값을 직접 반환한다.
//!
//! JS에서의 사용:
//!   const { transpile } = require('./zts.node');
//!   const result = transpile(source, filename, flags, unsupported, factory, fragment, importSource);
//!   // result = { code: string, map?: string }

const std = @import("std");
const transpile_mod = @import("zts_lib").transpile;
const c = @cImport({
    @cDefine("NAPI_VERSION", "8");
    @cInclude("node_api.h");
});

const native_alloc = std.heap.c_allocator;

// ─── NAPI 헬퍼 ───

fn throwError(env: c.napi_env, msg: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, null, msg);
    return null;
}

/// JS string 인자를 Zig 슬라이스로 추출. 빈 문자열이면 null 반환.
fn getStringArg(env: c.napi_env, value: c.napi_value, alloc: std.mem.Allocator) ?[]const u8 {
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, null, 0, &len) != c.napi_ok) return null;
    if (len == 0) return null;
    const buf = alloc.alloc(u8, len + 1) catch return null;
    var actual: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, buf.ptr, len + 1, &actual) != c.napi_ok) {
        alloc.free(buf);
        return null;
    }
    return buf[0..actual];
}

fn getUint32Arg(env: c.napi_env, value: c.napi_value) u32 {
    var val: u32 = 0;
    _ = c.napi_get_value_uint32(env, value, &val);
    return val;
}

// ─── transpile 함수 ───

/// transpile(source, filename, flags, unsupported, jsxFactory, jsxFragment, jsxImportSource)
/// → { code: string, map?: string }
fn napiTranspile(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 7;
    var argv: [7]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 4) {
        return throwError(env, "transpile requires at least 4 arguments");
    }

    // source (필수)
    const source = getStringArg(env, argv[0], native_alloc) orelse {
        return throwError(env, "invalid or empty source");
    };
    defer native_alloc.free(source);

    // filename (필수)
    const filename = getStringArg(env, argv[1], native_alloc) orelse
        native_alloc.dupe(u8, "input.ts") catch {
        return throwError(env, "OutOfMemory");
    };
    defer native_alloc.free(filename);

    // flags, unsupported
    const flags = getUint32Arg(env, argv[2]);
    const unsupported = getUint32Arg(env, argv[3]);

    // 선택적 문자열 옵션
    const jsx_factory = if (argc > 4) getStringArg(env, argv[4], native_alloc) else null;
    defer if (jsx_factory) |f| native_alloc.free(f);
    const jsx_fragment = if (argc > 5) getStringArg(env, argv[5], native_alloc) else null;
    defer if (jsx_fragment) |f| native_alloc.free(f);
    const jsx_import_source = if (argc > 6) getStringArg(env, argv[6], native_alloc) else null;
    defer if (jsx_import_source) |f| native_alloc.free(f);

    // 옵션 구성
    var options = transpile_mod.decodeFlags(flags);
    options.unsupported = @bitCast(unsupported);
    if (jsx_factory) |f| if (f.len > 0) {
        options.jsx_factory = f;
    };
    if (jsx_fragment) |f| if (f.len > 0) {
        options.jsx_fragment = f;
    };
    if (jsx_import_source) |f| if (f.len > 0) {
        options.jsx_import_source = f;
    };

    // 트랜스파일 실행
    var result = transpile_mod.transpile(native_alloc, source, filename, options) catch |err| {
        const msg: [*:0]const u8 = switch (err) {
            error.ParseError => "ParseError",
            error.SemanticError => "SemanticError",
            error.TransformError => "TransformError",
            error.CodegenError => "CodegenError",
            error.OutOfMemory => "OutOfMemory",
        };
        return throwError(env, msg);
    };
    defer result.deinit(native_alloc);

    // JS 결과 객체 생성: { code: string, map?: string }
    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) {
        return throwError(env, "failed to create result object");
    }

    // code
    var js_code: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, result.code.ptr, result.code.len, &js_code) != c.napi_ok) {
        return throwError(env, "failed to create code string");
    }
    _ = c.napi_set_named_property(env, js_result, "code", js_code);

    // map (선택적)
    if (result.sourcemap) |sm| {
        var js_map: c.napi_value = undefined;
        if (c.napi_create_string_utf8(env, sm.ptr, sm.len, &js_map) != c.napi_ok) {
            return throwError(env, "failed to create sourcemap string");
        }
        _ = c.napi_set_named_property(env, js_result, "map", js_map);
    }

    return js_result;
}

// ─── 모듈 등록 ───

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    var fn_value: c.napi_value = undefined;
    _ = c.napi_create_function(env, "transpile", "transpile".len, napiTranspile, null, &fn_value);
    _ = c.napi_set_named_property(env, exports, "transpile", fn_value);
    return exports;
}
