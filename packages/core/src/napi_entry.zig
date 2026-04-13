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
const zts_lib = @import("zts_lib");
const transpile_mod = zts_lib.transpile;
const bundler_mod = zts_lib.bundler;
const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
const Platform = zts_lib.codegen.codegen.Platform;
const JsxRuntime = zts_lib.codegen.codegen.JsxRuntime;
const EmitFormat = bundler_mod.emitter.EmitOptions.Format;
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

// ─── 객체 프로퍼티 헬퍼 ───

fn getNamedProperty(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8) ?c.napi_value {
    var val: c.napi_value = undefined;
    if (c.napi_get_named_property(env, obj, key, &val) != c.napi_ok) return null;
    // undefined/null 체크
    var val_type: c.napi_valuetype = undefined;
    _ = c.napi_typeof(env, val, &val_type);
    if (val_type == c.napi_undefined or val_type == c.napi_null) return null;
    return val;
}

fn getObjectBool(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, default_val: bool) bool {
    const val = getNamedProperty(env, obj, key) orelse return default_val;
    var result: bool = default_val;
    _ = c.napi_get_value_bool(env, val, &result);
    return result;
}

fn getObjectUint32(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, default_val: u32) u32 {
    const val = getNamedProperty(env, obj, key) orelse return default_val;
    var result: u32 = default_val;
    _ = c.napi_get_value_uint32(env, val, &result);
    return result;
}

fn getObjectString(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[]const u8 {
    const val = getNamedProperty(env, obj, key) orelse return null;
    return getStringArg(env, val, alloc);
}

fn getObjectStringArray(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[]const []const u8 {
    const val = getNamedProperty(env, obj, key) orelse return null;
    return parseStringArray(env, val, alloc);
}

/// JS 배열 값을 문자열 슬라이스로 변환. (key 없이 직접 배열 값을 받는 버전)
fn parseStringArray(env: c.napi_env, val: c.napi_value, alloc: std.mem.Allocator) ?[]const []const u8 {
    var is_array: bool = false;
    _ = c.napi_is_array(env, val, &is_array);
    if (!is_array) return null;
    var len: u32 = 0;
    _ = c.napi_get_array_length(env, val, &len);
    if (len == 0) return null;
    const result = alloc.alloc([]const u8, len) catch return null;
    var count: u32 = 0;
    for (0..len) |i| {
        var elem: c.napi_value = undefined;
        if (c.napi_get_element(env, val, @intCast(i), &elem) != c.napi_ok) continue;
        if (getStringArg(env, elem, alloc)) |s| {
            result[count] = s;
            count += 1;
        }
    }
    if (count == 0) {
        alloc.free(result);
        return null;
    }
    return result[0..count];
}

/// JS 객체의 키-값 쌍을 [2][]const u8 배열로 추출. { "key": "value", ... }
fn getObjectKeyValuePairs(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[][2][]const u8 {
    const val = getNamedProperty(env, obj, key) orelse return null;

    // 프로퍼티 이름 목록 가져오기
    var prop_names: c.napi_value = undefined;
    if (c.napi_get_property_names(env, val, &prop_names) != c.napi_ok) return null;
    var len: u32 = 0;
    _ = c.napi_get_array_length(env, prop_names, &len);
    if (len == 0) return null;

    const result = alloc.alloc([2][]const u8, len) catch return null;
    var count: u32 = 0;
    for (0..len) |i| {
        var prop_key: c.napi_value = undefined;
        if (c.napi_get_element(env, prop_names, @intCast(i), &prop_key) != c.napi_ok) continue;
        const k = getStringArg(env, prop_key, alloc) orelse continue;

        // napi_get_property로 키에 대한 값 가져오기 (null-terminated 불필요)
        var prop_val: c.napi_value = undefined;
        if (c.napi_get_property(env, val, prop_key, &prop_val) != c.napi_ok) {
            alloc.free(k);
            continue;
        }

        const v = getStringArg(env, prop_val, alloc) orelse {
            alloc.free(k);
            continue;
        };

        result[count] = .{ k, v };
        count += 1;
    }
    if (count == 0) {
        alloc.free(result);
        return null;
    }
    return result[0..count];
}

fn resolveEntryPoint(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const resolved = std.fs.cwd().realpathAlloc(alloc, path) catch return alloc.dupe(u8, path) catch null;
    return resolved;
}

// ─── buildSync 함수 ───

fn napiBuildSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "buildSync requires an options object");

    var owned_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_strings.items) |s| native_alloc.free(s);
        owned_strings.deinit(native_alloc);
    }
    var owned_string_arrays: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (owned_string_arrays.items) |arr| {
            // 개별 문자열은 owned_strings에서 해제되므로 배열 자체만 해제
            native_alloc.free(arr);
        }
        owned_string_arrays.deinit(native_alloc);
    }

    const bundle_opts = parseBuildOptions(env, argv[0], &owned_strings, &owned_string_arrays) orelse {
        return throwError(env, "invalid build options (entryPoints required)");
    };

    var bundler = Bundler.init(native_alloc, bundle_opts);
    var result = bundler.bundle() catch |err| {
        return throwError(env, @errorName(err));
    };
    defer result.deinit(native_alloc);

    return buildResultToJS(env, &result);
}

fn buildResultToJS(env: c.napi_env, result: *const bundler_mod.BundleResult) c.napi_value {
    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) return null;

    // outputFiles 배열
    var js_outputs: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_outputs);

    if (result.outputs) |outputs| {
        // code splitting: 다중 파일
        for (outputs, 0..) |out, i| {
            var js_file: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_file);

            var js_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, out.path.ptr, out.path.len, &js_path);
            _ = c.napi_set_named_property(env, js_file, "path", js_path);

            var js_text: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, out.contents.ptr, out.contents.len, &js_text);
            _ = c.napi_set_named_property(env, js_file, "text", js_text);

            _ = c.napi_set_element(env, js_outputs, @intCast(i), js_file);
        }
    } else {
        // 단일 파일
        var js_file: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_file);

        var js_path: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "bundle.js", "bundle.js".len, &js_path);
        _ = c.napi_set_named_property(env, js_file, "path", js_path);

        var js_text: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, result.output.ptr, result.output.len, &js_text);
        _ = c.napi_set_named_property(env, js_file, "text", js_text);

        _ = c.napi_set_element(env, js_outputs, 0, js_file);

        // 소스맵이 있으면 별도 파일로 추가
        if (result.sourcemap) |sm| {
            var js_sm_file: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_sm_file);

            var js_sm_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, "bundle.js.map", "bundle.js.map".len, &js_sm_path);
            _ = c.napi_set_named_property(env, js_sm_file, "path", js_sm_path);

            var js_sm_text: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, sm.ptr, sm.len, &js_sm_text);
            _ = c.napi_set_named_property(env, js_sm_file, "text", js_sm_text);

            _ = c.napi_set_element(env, js_outputs, 1, js_sm_file);
        }
    }
    _ = c.napi_set_named_property(env, js_result, "outputFiles", js_outputs);

    // errors/warnings 배열
    var js_errors: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_errors);
    var js_warnings: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_warnings);

    var err_idx: u32 = 0;
    var warn_idx: u32 = 0;
    for (result.getDiagnostics()) |d| {
        var js_diag: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_diag);

        var js_msg: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, d.message.ptr, d.message.len, &js_msg);
        _ = c.napi_set_named_property(env, js_diag, "text", js_msg);

        if (d.file_path.len > 0) {
            var js_loc: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_loc);
            var js_file_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, d.file_path.ptr, d.file_path.len, &js_file_path);
            _ = c.napi_set_named_property(env, js_loc, "file", js_file_path);
            _ = c.napi_set_named_property(env, js_diag, "location", js_loc);
        }

        if (d.severity == .@"error") {
            _ = c.napi_set_element(env, js_errors, err_idx, js_diag);
            err_idx += 1;
        } else {
            _ = c.napi_set_element(env, js_warnings, warn_idx, js_diag);
            warn_idx += 1;
        }
    }
    _ = c.napi_set_named_property(env, js_result, "errors", js_errors);
    _ = c.napi_set_named_property(env, js_result, "warnings", js_warnings);

    // metafile
    if (result.metafile_json) |mf| {
        var js_mf: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, mf.ptr, mf.len, &js_mf);
        _ = c.napi_set_named_property(env, js_result, "metafile", js_mf);
    }

    // moduleCodes — HMR용 per-module 코드 (devMode + collectModuleCodes 활성 시)
    if (result.module_dev_codes) |codes| {
        var js_codes: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, codes.len, &js_codes);
        for (codes, 0..) |mc, i| {
            var js_mc: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_mc);

            var js_id: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, mc.id.ptr, mc.id.len, &js_id);
            _ = c.napi_set_named_property(env, js_mc, "id", js_id);

            var js_code: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, mc.code.ptr, mc.code.len, &js_code);
            _ = c.napi_set_named_property(env, js_mc, "code", js_code);

            _ = c.napi_set_element(env, js_codes, @intCast(i), js_mc);
        }
        _ = c.napi_set_named_property(env, js_result, "moduleCodes", js_codes);
    }

    // modulePaths — 번들에 포함된 모든 모듈 절대 경로 (watch용)
    if (result.module_paths) |paths| {
        var js_paths: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, paths.len, &js_paths);
        for (paths, 0..) |p, i| {
            var js_p: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, p.ptr, p.len, &js_p);
            _ = c.napi_set_element(env, js_paths, @intCast(i), js_p);
        }
        _ = c.napi_set_named_property(env, js_result, "modulePaths", js_paths);
    }

    return js_result;
}

// ─── NapiPlugin: JS 플러그인 브릿지 ───
// 워커 스레드에서 JS 콜백을 호출하기 위한 napi_threadsafe_function 기반 브릿지.
// 워커 스레드: 요청 저장 → tsfn 호출 → condvar 대기
// 메인 스레드: JS 콜백 실행 → 결과 저장 → condvar 시그널

const plugin_mod = bundler_mod.plugin;
const Plugin = plugin_mod.Plugin;
const PluginError = plugin_mod.PluginError;
const ResolveResult = bundler_mod.ResolveResult;

const NapiPlugin = struct {
    name: []const u8,
    tsfn: c.napi_threadsafe_function,

    const HookType = enum { resolveId, load, transform, renderChunk, generateBundle, astFunction };

    const PluginResponse = struct {
        resolved_path: ?[]const u8 = null,
        is_external: bool = false,
        code: ?[]const u8 = null,
        /// AST plugin: 제거할 디렉티브 이름
        strip_directive: ?[]const u8 = null,
        /// AST plugin: 함수 뒤에 삽입할 코드 문자열 배열
        trailing_code: ?[]const []const u8 = null,
    };

    /// Per-call 요청 컨텍스트. 여러 워커 스레드가 동시에 호출해도 안전.
    const CallContext = struct {
        hook: HookType,
        arg1: []const u8,
        arg2: ?[]const u8,
        /// generateBundle 전용: OutputFile 배열 (callJsCallback에서 JS 배열로 변환)
        output_files: ?[]const bundler_mod.emitter.OutputFile = null,
        response: ?PluginResponse = null,
        response_ready: bool = false,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
    };

    /// JS 결과 객체에서 PluginResponse 필드를 추출한다.
    fn parseJsResult(env: c.napi_env, js_result: c.napi_value) PluginResponse {
        var result_type: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, js_result, &result_type);
        if (result_type == c.napi_null or result_type == c.napi_undefined) {
            return .{};
        }

        var resp = PluginResponse{};
        if (getObjectString(env, js_result, "path", native_alloc)) |path| {
            resp.resolved_path = path;
        }
        resp.is_external = getObjectBool(env, js_result, "external", false);
        if (getObjectString(env, js_result, "contents", native_alloc)) |contents| {
            resp.code = contents;
        }
        if (resp.code == null) {
            if (getObjectString(env, js_result, "code", native_alloc)) |code| {
                resp.code = code;
            }
        }
        // AST plugin 응답 파싱
        if (getObjectString(env, js_result, "stripDirective", native_alloc)) |sd| {
            resp.strip_directive = sd;
        }
        if (getNamedProperty(env, js_result, "trailingCode")) |tc_val| {
            resp.trailing_code = parseStringArray(env, tc_val, native_alloc);
        }
        return resp;
    }

    /// CallContext에 응답을 기록하고 워커 스레드에 시그널을 보낸다.
    fn signalResponse(ctx: *CallContext, resp: PluginResponse) void {
        ctx.mutex.lock();
        ctx.response = resp;
        ctx.response_ready = true;
        ctx.cond.signal();
        ctx.mutex.unlock();
    }

    /// Promise의 .then() 콜백 — resolve 시 결과를 파싱하여 워커 스레드에 전달
    fn promiseThenCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var argc: usize = 1;
        var argv: [1]c.napi_value = undefined;
        var cb_data: ?*anyopaque = null;
        _ = c.napi_get_cb_info(env, info, &argc, &argv, null, &cb_data);
        const ctx: *CallContext = @ptrCast(@alignCast(cb_data.?));
        signalResponse(ctx, if (argc > 0) parseJsResult(env, argv[0]) else .{});
        var undef: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &undef);
        return undef;
    }

    /// Promise의 .catch() 콜백 — reject 시 빈 응답으로 워커 스레드에 전달
    fn promiseCatchCallback(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
        var cb_data: ?*anyopaque = null;
        _ = c.napi_get_cb_info(env, info, null, null, null, &cb_data);
        const ctx: *CallContext = @ptrCast(@alignCast(cb_data.?));
        signalResponse(ctx, .{});
        var undef: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &undef);
        return undef;
    }

    /// threadsafe function의 call_js 콜백 (메인 스레드에서 실행)
    /// data = CallContext 포인터 (per-call, 워커 스레드가 스택에 소유하며 condvar 대기 중)
    fn callJsCallback(env: c.napi_env, js_callback: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const ctx: *CallContext = @ptrCast(@alignCast(data.?));

        // JS dispatcher 호출: dispatcher(hookName, arg1, arg2)
        var hook_str: c.napi_value = undefined;
        const hook_name: []const u8 = switch (ctx.hook) {
            .resolveId => "resolveId",
            .load => "load",
            .transform => "transform",
            .renderChunk => "renderChunk",
            .generateBundle => "generateBundle",
            .astFunction => "astFunction",
        };
        _ = c.napi_create_string_utf8(env, hook_name.ptr, hook_name.len, &hook_str);

        var js_arg1: c.napi_value = undefined;
        // generateBundle: arg1 대신 output_files JS 배열을 생성
        if (ctx.output_files) |files| {
            _ = c.napi_create_array_with_length(env, files.len, &js_arg1);
            for (files, 0..) |file, i| {
                var js_file: c.napi_value = undefined;
                _ = c.napi_create_object(env, &js_file);
                var js_path: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, file.path.ptr, file.path.len, &js_path);
                _ = c.napi_set_named_property(env, js_file, "path", js_path);
                var js_text: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, file.contents.ptr, file.contents.len, &js_text);
                _ = c.napi_set_named_property(env, js_file, "text", js_text);
                _ = c.napi_set_element(env, js_arg1, @intCast(i), js_file);
            }
        } else {
            _ = c.napi_create_string_utf8(env, ctx.arg1.ptr, ctx.arg1.len, &js_arg1);
        }

        var js_arg2: c.napi_value = undefined;
        if (ctx.arg2) |a2| {
            _ = c.napi_create_string_utf8(env, a2.ptr, a2.len, &js_arg2);
        } else {
            _ = c.napi_get_null(env, &js_arg2);
        }

        var js_result: c.napi_value = undefined;
        const args = [_]c.napi_value{ hook_str, js_arg1, js_arg2 };
        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);
        if (c.napi_call_function(env, js_undefined, js_callback, 3, &args, &js_result) != c.napi_ok) {
            signalResponse(ctx, .{});
            return;
        }

        // Promise 체크: 결과가 Promise이면 .then()/.catch()로 비동기 대기
        var is_promise: bool = false;
        _ = c.napi_is_promise(env, js_result, &is_promise);
        if (is_promise) {
            // .then(onFulfilled) 등록
            var then_fn: c.napi_value = undefined;
            if (getNamedProperty(env, js_result, "then")) |t| {
                then_fn = t;
            } else {
                signalResponse(ctx, .{});
                return;
            }

            var on_fulfilled: c.napi_value = undefined;
            _ = c.napi_create_function(env, "onFulfilled", "onFulfilled".len, promiseThenCallback, @ptrCast(ctx), &on_fulfilled);
            var on_rejected: c.napi_value = undefined;
            _ = c.napi_create_function(env, "onRejected", "onRejected".len, promiseCatchCallback, @ptrCast(ctx), &on_rejected);

            var then_args = [_]c.napi_value{ on_fulfilled, on_rejected };
            var then_result: c.napi_value = undefined;
            if (c.napi_call_function(env, js_result, then_fn, 2, &then_args, &then_result) != c.napi_ok) {
                signalResponse(ctx, .{});
            }
            // Promise 경우: 여기서 리턴. 워커 스레드는 then/catch 콜백이 signal할 때까지 대기.
            return;
        }

        // 동기 결과: 즉시 파싱하여 시그널
        signalResponse(ctx, parseJsResult(env, js_result));
    }

    /// 워커 스레드에서 호출 — JS 콜백 실행 후 결과 대기.
    /// per-call CallContext를 스택에 생성하여 멀티스레드 안전.
    fn callHookFull(self: *NapiPlugin, hook: HookType, arg1: []const u8, arg2: ?[]const u8, files: ?[]const bundler_mod.emitter.OutputFile) ?PluginResponse {
        var ctx = CallContext{
            .hook = hook,
            .arg1 = arg1,
            .arg2 = arg2,
            .output_files = files,
        };

        if (c.napi_call_threadsafe_function(self.tsfn, @ptrCast(&ctx), c.napi_tsfn_blocking) != c.napi_ok) {
            return null;
        }

        // 30초 타임아웃: Promise가 resolve/reject되지 않는 경우 hang 방지
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        const timeout_ns: u64 = 30 * std.time.ns_per_s;
        while (!ctx.response_ready) {
            ctx.cond.timedWait(&ctx.mutex, timeout_ns) catch return null;
        }

        return ctx.response;
    }

    fn callHook(self: *NapiPlugin, hook: HookType, arg1: []const u8, arg2: ?[]const u8) ?PluginResponse {
        return self.callHookFull(hook, arg1, arg2, null);
    }

    // ─── Plugin 인터페이스 구현 ───

    /// code를 반환하는 훅 공통 구현 (transform, renderChunk, load)
    fn callCodeHook(self: *NapiPlugin, hook: HookType, arg1: []const u8, arg2: ?[]const u8, alloc: std.mem.Allocator) PluginError!?[]const u8 {
        const resp = self.callHook(hook, arg1, arg2) orelse return null;
        defer if (resp.resolved_path) |p| native_alloc.free(p);
        if (resp.code) |result_code| {
            const result = alloc.dupe(u8, result_code) catch return error.OutOfMemory;
            native_alloc.free(result_code);
            return result;
        }
        return null;
    }

    fn pluginResolveId(ctx: ?*anyopaque, specifier: []const u8, importer: ?[]const u8, alloc: std.mem.Allocator) PluginError!?ResolveResult {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));
        const resp = self.callHook(.resolveId, specifier, importer) orelse return null;
        defer {
            if (resp.resolved_path) |p| native_alloc.free(p);
            if (resp.code) |co| native_alloc.free(co);
        }

        if (resp.resolved_path) |path| {
            return .{
                .path = alloc.dupe(u8, path) catch return error.OutOfMemory,
                .module_type = .javascript,
            };
        }
        return null;
    }

    fn pluginLoad(ctx: ?*anyopaque, path: []const u8, alloc: std.mem.Allocator) PluginError!?[]const u8 {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));
        return self.callCodeHook(.load, path, null, alloc);
    }

    fn pluginTransform(ctx: ?*anyopaque, code: []const u8, id: []const u8, alloc: std.mem.Allocator) PluginError!?[]const u8 {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));
        return self.callCodeHook(.transform, code, id, alloc);
    }

    fn pluginRenderChunk(ctx: ?*anyopaque, code: []const u8, chunk_name: []const u8, alloc: std.mem.Allocator) PluginError!?[]const u8 {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));
        return self.callCodeHook(.renderChunk, code, chunk_name, alloc);
    }

    fn pluginGenerateBundle(ctx: ?*anyopaque, output_files: []const bundler_mod.emitter.OutputFile) void {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));
        _ = self.callHookFull(.generateBundle, "", null, output_files);
    }

    fn toPlugin(self: *NapiPlugin) Plugin {
        return .{
            .name = self.name,
            .context = @ptrCast(self),
            .resolveId = pluginResolveId,
            .load = pluginLoad,
            .transform = pluginTransform,
            .renderChunk = pluginRenderChunk,
            .generateBundle = pluginGenerateBundle,
            .onFunction = pluginAstFunction,
        };
    }

    // ─── AST 훅 구현 ───

    const AstTransformCtx = zts_lib.transformer.ast_plugin_mod.AstTransformCtx;
    const FunctionInfo = zts_lib.transformer.ast_plugin_mod.FunctionInfo;

    fn pluginAstFunction(ctx: ?*anyopaque, api: *AstTransformCtx, func: FunctionInfo) PluginError!void {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));

        // FunctionInfo를 JSON 문자열로 직렬화
        const json = serializeFunctionInfo(api, func) catch return;
        defer native_alloc.free(json);

        // JS 호출
        const resp = self.callHook(.astFunction, json, null) orelse return;
        defer {
            if (resp.strip_directive) |sd| native_alloc.free(sd);
            if (resp.trailing_code) |tc| {
                for (tc) |s| native_alloc.free(s);
                native_alloc.free(tc);
            }
            if (resp.resolved_path) |p| native_alloc.free(p);
            if (resp.code) |co| native_alloc.free(co);
        }

        if (resp.strip_directive != null) {
            _ = api.stripDirective(func.body_idx) catch return;
        }

        // 응답 처리: trailingCode → 파싱하여 trailing statements에 추가
        if (resp.trailing_code) |codes| {
            for (codes) |code_str| {
                // 코드 문자열을 파싱하여 AST 노드로 변환
                const stmts = api.parseAndInjectStatements(code_str) catch continue;
                for (stmts) |stmt| {
                    api.addTrailingStatement(stmt) catch continue;
                }
            }
        }
    }

    fn deinit(self: *NapiPlugin) void {
        _ = c.napi_release_threadsafe_function(self.tsfn, c.napi_tsfn_release);
        native_alloc.free(self.name);
        native_alloc.destroy(self);
    }
};

const appendJsonEscaped = zts_lib.string_escape.appendEscaped;

/// FunctionInfo를 JSON 문자열로 직렬화한다.
/// JS dispatcher에 arg1로 전달되어 JS 측에서 JSON.parse()로 역직렬화.
fn serializeFunctionInfo(
    api: *NapiPlugin.AstTransformCtx,
    func: NapiPlugin.FunctionInfo,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const alloc = native_alloc;

    try buf.appendSlice(alloc, "{\"name\":");
    if (func.name) |name| {
        try buf.append(alloc, '"');
        try appendJsonEscaped(&buf, alloc, name);
        try buf.append(alloc, '"');
    } else {
        try buf.appendSlice(alloc, "null");
    }

    // directives: body 첫 문장이 디렉티브(string literal)이면 추출
    var has_directives = false;
    try buf.appendSlice(alloc, ",\"directives\":[");
    if (!func.body_idx.isNone()) {
        const Ast = zts_lib.parser.ast;
        const body = api.transformer.ast.getNode(func.body_idx);
        if ((body.tag == .block_statement or body.tag == .function_body) and body.data.list.len > 0) {
            const first_raw = api.transformer.ast.extra_data.items[body.data.list.start];
            const first_idx: Ast.NodeIndex = @enumFromInt(first_raw);
            if (!first_idx.isNone()) {
                const first = api.transformer.ast.getNode(first_idx);
                // directive 태그 또는 expression_statement > string_literal
                const directive_text: ?[]const u8 = if (first.tag == .directive)
                    blk: {
                        const t = api.transformer.ast.getText(first.span);
                        break :blk if (t.len >= 2) t[1 .. t.len - 1] else null;
                    }
                else if (first.tag == .expression_statement) blk: {
                    const op = api.transformer.ast.getNode(first.data.unary.operand);
                    if (op.tag == .string_literal) {
                        const t = api.transformer.ast.getText(op.data.string_ref);
                        break :blk if (t.len >= 2) t[1 .. t.len - 1] else null;
                    }
                    break :blk null;
                } else null;

                if (directive_text) |dt| {
                    try buf.append(alloc, '"');
                    try appendJsonEscaped(&buf, alloc, dt);
                    try buf.append(alloc, '"');
                    has_directives = true;
                }
            }
        }
    }
    try buf.append(alloc, ']');

    // closureVars: 디렉티브가 있을 때만 계산 (스코프 분석은 비용이 크므로).
    // ctx 캐시 덕분에 worklet_plugin이 먼저 계산했다면 재사용 (#1114).
    try buf.appendSlice(alloc, ",\"closureVars\":[");
    if (has_directives) {
        const closure_vars = api.getClosureVars(&func) catch &.{};
        for (closure_vars, 0..) |cv, i| {
            if (i > 0) try buf.append(alloc, ',');
            try buf.append(alloc, '"');
            try buf.appendSlice(alloc, cv.name);
            try buf.append(alloc, '"');
        }
    }
    try buf.append(alloc, ']');

    // params
    try buf.appendSlice(alloc, ",\"params\":[");
    {
        var pi: u32 = 0;
        while (pi < func.params_len) : (pi += 1) {
            if (pi > 0) try buf.append(alloc, ',');
            const param_raw = api.transformer.ast.extra_data.items[func.params_start + pi];
            const param_idx: zts_lib.parser.ast.NodeIndex = @enumFromInt(param_raw);
            if (!param_idx.isNone()) {
                const param_node = api.transformer.ast.getNode(param_idx);
                const param_text = api.transformer.ast.getText(param_node.span);
                try buf.append(alloc, '"');
                try buf.appendSlice(alloc, param_text);
                try buf.append(alloc, '"');
            }
        }
    }
    try buf.append(alloc, ']');

    // sourcePath
    try buf.appendSlice(alloc, ",\"sourcePath\":\"");
    try appendJsonEscaped(&buf, alloc, func.source_path);
    try buf.append(alloc, '"');

    // flags
    try buf.appendSlice(alloc, ",\"flags\":{\"async\":");
    try buf.appendSlice(alloc, if (func.flags & 0x01 != 0) "true" else "false");
    try buf.appendSlice(alloc, ",\"generator\":");
    try buf.appendSlice(alloc, if (func.flags & 0x02 != 0) "true" else "false");
    try buf.append(alloc, '}');

    // bodyText: 소스 원본에서 추출
    try buf.appendSlice(alloc, ",\"bodyText\":");
    {
        const body_node = api.transformer.ast.getNode(func.body_idx);
        if (body_node.span.start < body_node.span.end and
            body_node.span.start & 0x8000_0000 == 0 and
            body_node.span.end <= @as(u32, @intCast(api.transformer.ast.source.len)))
        {
            const text = api.transformer.ast.source[body_node.span.start..body_node.span.end];
            try buf.append(alloc, '"');
            try appendJsonEscaped(&buf, alloc, text);
            try buf.append(alloc, '"');
        } else {
            try buf.appendSlice(alloc, "\"\"");
        }
    }

    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

// ─── build() 비동기 (Promise) ───

const BuildAsyncData = struct {
    env: c.napi_env,
    deferred: c.napi_deferred,
    completion_tsfn: c.napi_threadsafe_function,
    // 소유된 옵션 (워커 스레드에서 유효해야 하므로 복사)
    options: BundleOptions,
    // 소유된 문자열 목록 (deinit 시 해제)
    owned_strings: std.ArrayList([]const u8),
    owned_string_arrays: std.ArrayList([]const []const u8),
    // NAPI 플러그인 (JS 콜백 기반)
    napi_plugins: std.ArrayList(*NapiPlugin),
    zig_plugins: std.ArrayList(Plugin),
    // 결과
    result: ?bundler_mod.BundleResult = null,
    err_msg: ?[*:0]const u8 = null,
};

/// 독립 스레드에서 번들링 실행 (libuv 워커 미사용 → TSFN 데드락 방지)
fn buildWorkerThread(async_data: *BuildAsyncData) void {
    var bundler = Bundler.init(native_alloc, async_data.options);
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
        // NAPI 플러그인 해제
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
    } else if (async_data.result) |*result| {
        defer result.deinit(native_alloc);
        const js_result = buildResultToJS(env, result);
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

fn napiBuild(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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
        _ = c.napi_create_string_utf8(env, "zts_plugin", "zts_plugin".len, &resource_name_str);
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

    async_data.options = opts;

    // Promise 생성
    var promise: c.napi_value = undefined;
    if (c.napi_create_promise(env, &async_data.deferred, &promise) != c.napi_ok) {
        native_alloc.destroy(async_data);
        return throwError(env, "failed to create promise");
    }

    // 완료 TSFN 생성 (빌드 완료 시 메인 스레드에서 Promise resolve)
    var resource_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "zts_build_complete", "zts_build_complete".len, &resource_name);
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

// ─── watch() 비동기 (콜백 기반) ───

const WatchAsyncData = struct {
    env: c.napi_env,
    // 소유된 옵션 (워커 스레드에서 유효해야 하므로 복사)
    options: BundleOptions,
    owned_strings: std.ArrayList([]const u8),
    owned_string_arrays: std.ArrayList([]const []const u8),
    // NAPI 플러그인 (JS 콜백 기반)
    napi_plugins: std.ArrayList(*NapiPlugin),
    zig_plugins: std.ArrayList(Plugin),
    // Watch-specific
    ready_tsfn: c.napi_threadsafe_function,
    rebuild_tsfn: c.napi_threadsafe_function,
    stop_flag: std.atomic.Value(bool),

    fn deinit(self: *WatchAsyncData) void {
        // 소유된 문자열 해제
        for (self.owned_strings.items) |s| native_alloc.free(s);
        self.owned_strings.deinit(native_alloc);
        // 배열 컨테이너 해제 (내부 문자열은 owned_strings에서 이미 해제됨)
        for (self.owned_string_arrays.items) |arr| native_alloc.free(arr);
        self.owned_string_arrays.deinit(native_alloc);
        // NAPI 플러그인 해제
        for (self.napi_plugins.items) |np| np.deinit();
        self.napi_plugins.deinit(native_alloc);
        self.zig_plugins.deinit(native_alloc);
        native_alloc.destroy(self);
    }
};

/// onReady 콜백에 전달할 이벤트 데이터
const WatchReadyEvent = struct {
    files: usize,
    bytes: usize,
};

/// onRebuild 콜백에 전달할 이벤트 데이터
const WatchRebuildEvent = struct {
    success: bool,
    // 성공 시
    changed: ?[]const []const u8 = null,
    graph_changed: bool = false,
    updates: ?[]const ModuleUpdate = null,
    bytes: usize = 0,
    // 실패 시
    error_msg: ?[]const u8 = null,

    const ModuleUpdate = struct {
        id: []const u8,
        code: []const u8,
    };

    fn deinit(self: *WatchRebuildEvent) void {
        if (self.changed) |ch| {
            for (ch) |s| native_alloc.free(s);
            native_alloc.free(ch);
        }
        if (self.updates) |upd| {
            for (upd) |u| {
                native_alloc.free(u.id);
                native_alloc.free(u.code);
            }
            native_alloc.free(upd);
        }
        if (self.error_msg) |msg| native_alloc.free(msg);
        native_alloc.destroy(self);
    }
};

/// 파일의 mtime을 가져온다.
fn getFileMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

/// onReady TSFN 콜백 — 메인 스레드에서 실행
fn watchReadyTsfn(env: c.napi_env, js_func: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const event: *WatchReadyEvent = @ptrCast(@alignCast(data.?));
    defer native_alloc.destroy(event);

    if (js_func == null) return;

    // {files: N, bytes: N} 객체 생성
    var js_event: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_event) != c.napi_ok) return;

    var js_files: c.napi_value = undefined;
    _ = c.napi_create_int64(env, @intCast(event.files), &js_files);
    _ = c.napi_set_named_property(env, js_event, "files", js_files);

    var js_bytes: c.napi_value = undefined;
    _ = c.napi_create_int64(env, @intCast(event.bytes), &js_bytes);
    _ = c.napi_set_named_property(env, js_event, "bytes", js_bytes);

    // onReady(event) 호출
    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    var js_result: c.napi_value = undefined;
    var call_args = [_]c.napi_value{js_event};
    _ = c.napi_call_function(env, js_undefined, js_func, 1, &call_args, &js_result);
}

/// onRebuild TSFN 콜백 — 메인 스레드에서 실행
fn watchRebuildTsfn(env: c.napi_env, js_func: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const event: *WatchRebuildEvent = @ptrCast(@alignCast(data.?));
    defer event.deinit();

    if (js_func == null) return;

    var js_event: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_event) != c.napi_ok) return;

    // success
    var js_success: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, event.success, &js_success);
    _ = c.napi_set_named_property(env, js_event, "success", js_success);

    if (event.success) {
        // changed: string[]
        var js_changed: c.napi_value = undefined;
        if (event.changed) |ch| {
            _ = c.napi_create_array_with_length(env, ch.len, &js_changed);
            for (ch, 0..) |path, i| {
                var js_path: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, path.ptr, path.len, &js_path);
                _ = c.napi_set_element(env, js_changed, @intCast(i), js_path);
            }
        } else {
            _ = c.napi_create_array(env, &js_changed);
        }
        _ = c.napi_set_named_property(env, js_event, "changed", js_changed);

        // graphChanged?: bool
        if (event.graph_changed) {
            var js_gc: c.napi_value = undefined;
            _ = c.napi_get_boolean(env, true, &js_gc);
            _ = c.napi_set_named_property(env, js_event, "graphChanged", js_gc);
        }

        // updates?: [{id, code}]
        if (event.updates) |upd| {
            var js_updates: c.napi_value = undefined;
            _ = c.napi_create_array_with_length(env, upd.len, &js_updates);
            for (upd, 0..) |u, i| {
                var js_u: c.napi_value = undefined;
                _ = c.napi_create_object(env, &js_u);
                var js_id: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, u.id.ptr, u.id.len, &js_id);
                _ = c.napi_set_named_property(env, js_u, "id", js_id);
                var js_code: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, u.code.ptr, u.code.len, &js_code);
                _ = c.napi_set_named_property(env, js_u, "code", js_code);
                _ = c.napi_set_element(env, js_updates, @intCast(i), js_u);
            }
            _ = c.napi_set_named_property(env, js_event, "updates", js_updates);
        }

        // bytes
        var js_bytes: c.napi_value = undefined;
        _ = c.napi_create_int64(env, @intCast(event.bytes), &js_bytes);
        _ = c.napi_set_named_property(env, js_event, "bytes", js_bytes);
    } else {
        // error: string
        if (event.error_msg) |msg| {
            var js_err: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, msg.ptr, msg.len, &js_err);
            _ = c.napi_set_named_property(env, js_event, "error", js_err);
        }
    }

    // onRebuild(event) 호출
    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    var js_result: c.napi_value = undefined;
    var call_args = [_]c.napi_value{js_event};
    _ = c.napi_call_function(env, js_undefined, js_func, 1, &call_args, &js_result);
}

/// watch 워커 스레드: 초기 빌드 → ready 이벤트 → 폴링 루프 → rebuild 이벤트
fn watchWorkerThread(async_data: *WatchAsyncData) void {
    const allocator = native_alloc;
    const bundle_opts = async_data.options;

    // 초기 빌드
    var bundler = Bundler.init(allocator, bundle_opts);
    var result = bundler.bundle() catch |err| {
        // 초기 빌드 실패 — rebuild 이벤트로 에러 전달
        const event = allocator.create(WatchRebuildEvent) catch {
            // OOM — TSFN 해제 + 정리 후 종료
            _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
            _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
            async_data.deinit();
            return;
        };
        const err_name: [:0]const u8 = @errorName(err);
        event.* = .{
            .success = false,
            .error_msg = allocator.dupe(u8, err_name) catch null,
        };
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }
        // TSFN 해제 + 정리 후 종료
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return;
    };
    defer result.deinit(allocator);

    // 증분 빌드용 PersistentModuleStore + ResolveCache
    const module_store_mod = bundler_mod.module_store;
    const ResolveCache = bundler_mod.ResolveCache;
    var persistent_store = module_store_mod.PersistentModuleStore.init(allocator);
    defer persistent_store.deinit();

    // dev mode: per-module code 캐시 (HMR diff용)
    var module_code_cache = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = module_code_cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        module_code_cache.deinit();
    }

    // 초기 빌드의 module_dev_codes로 캐시 초기화
    if (result.module_dev_codes) |codes| {
        for (codes) |mc| {
            const id_copy = allocator.dupe(u8, mc.id) catch continue;
            const code_copy = allocator.dupe(u8, mc.code) catch {
                allocator.free(id_copy);
                continue;
            };
            module_code_cache.put(id_copy, code_copy) catch {
                allocator.free(id_copy);
                allocator.free(code_copy);
            };
        }
    }

    var persistent_resolve_cache = ResolveCache.init(allocator, .{
        .platform = bundle_opts.platform,
        .external_patterns = bundle_opts.external,
        .custom_conditions = bundle_opts.conditions,
        .preserve_symlinks = bundle_opts.preserve_symlinks,
        .alias = bundle_opts.alias,
        .resolve_extensions = bundle_opts.resolve_extensions,
        .main_fields = bundle_opts.main_fields,
        .packages_external = bundle_opts.packages_external,
        .node_paths = bundle_opts.node_paths,
    });
    defer persistent_resolve_cache.deinit();

    // mtime 맵 초기화
    var mtime_map = std.StringHashMap(i128).init(allocator);
    defer {
        var it = mtime_map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        mtime_map.deinit();
    }

    // 엔트리 파일을 감시 대상에 추가
    if (bundle_opts.entry_points.len > 0) {
        const entry_path = bundle_opts.entry_points[0];
        const entry_dupe = allocator.dupe(u8, entry_path) catch @as([]u8, "");
        if (entry_dupe.len > 0) {
            const entry_mtime = getFileMtime(entry_path) catch 0;
            mtime_map.put(entry_dupe, entry_mtime) catch {
                allocator.free(entry_dupe);
            };
        }
    }

    // 초기 빌드의 module_paths에서 mtime 수집
    if (result.module_paths) |paths| {
        for (paths) |p| {
            const duped = allocator.dupe(u8, p) catch continue;
            const mt = getFileMtime(p) catch continue;
            mtime_map.put(duped, mt) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    // 초기 빌드 결과를 파일에 쓰기 (onReady 전에 완료해야 서버가 읽을 수 있음)
    var initial_bytes: usize = 0;
    if (result.outputs) |outputs| {
        for (outputs) |o| initial_bytes += o.contents.len;
        // code splitting: 각 output의 path로 직접 쓰기
        for (outputs) |o| {
            if (std.fs.path.dirname(o.path)) |dir| std.fs.cwd().makePath(dir) catch {};
            const file = std.fs.cwd().createFile(o.path, .{}) catch continue;
            defer file.close();
            file.writeAll(o.contents) catch continue;
        }
    } else {
        initial_bytes = result.output.len;
        // 단일 파일: output_filename으로 쓰기
        if (bundle_opts.output_filename.len > 0) {
            if (std.fs.path.dirname(bundle_opts.output_filename)) |dir| std.fs.cwd().makePath(dir) catch {};
            if (std.fs.cwd().createFile(bundle_opts.output_filename, .{})) |file| {
                defer file.close();
                file.writeAll(result.output) catch {};
                if (result.sourcemap) |sm| {
                    const map_path = std.fmt.allocPrint(allocator, "{s}.map", .{bundle_opts.output_filename}) catch null;
                    if (map_path) |mp| {
                        defer allocator.free(mp);
                        if (std.fs.cwd().createFile(mp, .{})) |sm_file| {
                            defer sm_file.close();
                            sm_file.writeAll(sm) catch {};
                        } else |_| {}
                    }
                }
            } else |_| {}
        }
    }

    // ready 이벤트 전송
    {
        const ready_event = allocator.create(WatchReadyEvent) catch return;
        ready_event.* = .{
            .files = mtime_map.count(),
            .bytes = initial_bytes,
        };
        if (c.napi_call_threadsafe_function(async_data.ready_tsfn, @ptrCast(ready_event), c.napi_tsfn_blocking) != c.napi_ok) {
            allocator.destroy(ready_event);
        }
    }

    // 폴링 루프 — 500ms 간격으로 파일 변경 감지
    while (!async_data.stop_flag.load(.acquire)) {
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // stop_flag 재확인 (sleep 후)
        if (async_data.stop_flag.load(.acquire)) break;

        // mtime 변경 확인 + 변경 파일 수집
        var changed = false;
        var changed_files: std.ArrayList([]const u8) = .empty;
        defer changed_files.deinit(allocator);

        var mit = mtime_map.iterator();
        while (mit.next()) |entry| {
            const current_mtime = getFileMtime(entry.key_ptr.*) catch continue;
            if (current_mtime != entry.value_ptr.*) {
                entry.value_ptr.* = current_mtime;
                changed = true;
                changed_files.append(allocator, entry.key_ptr.*) catch {};
            }
        }

        if (!changed) continue;

        // 재번들 — 증분 빌드: persistent_store + persistent_resolve_cache 재사용
        var incremental_opts = bundle_opts;
        incremental_opts.collect_module_codes = bundle_opts.dev_mode;
        incremental_opts.module_store = &persistent_store;
        var rebundler = Bundler.initWithResolveCache(allocator, incremental_opts, &persistent_resolve_cache);
        defer rebundler.deinit();

        const rebuild_result = rebundler.bundle() catch |err| {
            // 재빌드 실패
            const event = allocator.create(WatchRebuildEvent) catch continue;
            const err_name: [:0]const u8 = @errorName(err);
            event.* = .{
                .success = false,
                .error_msg = allocator.dupe(u8, err_name) catch null,
            };
            if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
                event.deinit();
            }
            continue;
        };
        defer rebuild_result.deinit(allocator);

        // 출력 파일 쓰기 + 바이트 수 계산
        var output_bytes: usize = 0;
        if (rebuild_result.outputs) |outputs| {
            for (outputs) |o| output_bytes += o.contents.len;
            for (outputs) |o| {
                if (std.fs.path.dirname(o.path)) |dir| std.fs.cwd().makePath(dir) catch {};
                const file = std.fs.cwd().createFile(o.path, .{}) catch continue;
                defer file.close();
                file.writeAll(o.contents) catch continue;
            }
        } else {
            output_bytes = rebuild_result.output.len;
            if (bundle_opts.output_filename.len > 0) {
                if (std.fs.path.dirname(bundle_opts.output_filename)) |dir| std.fs.cwd().makePath(dir) catch {};
                if (std.fs.cwd().createFile(bundle_opts.output_filename, .{})) |file| {
                    defer file.close();
                    file.writeAll(rebuild_result.output) catch {};
                    if (rebuild_result.sourcemap) |sm| {
                        const map_path = std.fmt.allocPrint(allocator, "{s}.map", .{bundle_opts.output_filename}) catch null;
                        if (map_path) |mp| {
                            defer allocator.free(mp);
                            if (std.fs.cwd().createFile(mp, .{})) |sm_file| {
                                defer sm_file.close();
                                sm_file.writeAll(sm) catch {};
                            } else |_| {}
                        }
                    }
                } else |_| {}
            }
        }

        // rebuild 이벤트 생성
        const event = allocator.create(WatchRebuildEvent) catch continue;
        event.* = .{
            .success = true,
            .bytes = output_bytes,
        };

        // changed 파일 목록 복사
        {
            const ch = allocator.alloc([]const u8, changed_files.items.len) catch null;
            if (ch) |ch_arr| {
                var valid: usize = 0;
                for (changed_files.items) |path| {
                    ch_arr[valid] = allocator.dupe(u8, path) catch continue;
                    valid += 1;
                }
                if (valid > 0) {
                    event.changed = ch_arr[0..valid];
                } else {
                    allocator.free(ch_arr);
                }
            }
        }

        // dev mode: HMR diff
        if (rebuild_result.module_dev_codes) |dev_codes| {
            // 모듈 ID 집합 비교 — graph 변경 감지
            const graph_changed_flag = blk: {
                if (dev_codes.len != module_code_cache.count()) break :blk true;
                for (dev_codes) |dc| {
                    if (!module_code_cache.contains(dc.id)) break :blk true;
                }
                break :blk false;
            };

            if (graph_changed_flag) {
                event.graph_changed = true;
            } else {
                // 단일 패스: 캐시와 비교하여 변경된 모듈만 수집
                var update_list: std.ArrayList(WatchRebuildEvent.ModuleUpdate) = .empty;
                for (dev_codes) |dc| {
                    const cached = module_code_cache.get(dc.id);
                    if (cached == null or !std.mem.eql(u8, cached.?, dc.code)) {
                        const id_copy = allocator.dupe(u8, dc.id) catch continue;
                        const code_copy = allocator.dupe(u8, dc.code) catch {
                            allocator.free(id_copy);
                            continue;
                        };
                        update_list.append(allocator, .{ .id = id_copy, .code = code_copy }) catch {
                            allocator.free(id_copy);
                            allocator.free(code_copy);
                            continue;
                        };
                    }
                }
                if (update_list.items.len > 0) {
                    event.updates = update_list.toOwnedSlice(allocator) catch null;
                } else {
                    update_list.deinit(allocator);
                    // 코드 변경 없음 — 힙 할당된 빈 슬라이스 (deinit에서 free 가능)
                    event.updates = allocator.alloc(WatchRebuildEvent.ModuleUpdate, 0) catch null;
                }
            }

            // 캐시 업데이트
            {
                var it = module_code_cache.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                module_code_cache.clearRetainingCapacity();
            }
            for (dev_codes) |dc| {
                const id_copy = allocator.dupe(u8, dc.id) catch continue;
                const code_copy = allocator.dupe(u8, dc.code) catch {
                    allocator.free(id_copy);
                    continue;
                };
                module_code_cache.put(id_copy, code_copy) catch {
                    allocator.free(id_copy);
                    allocator.free(code_copy);
                };
            }
        }

        // rebuild 이벤트 전송
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }

        // watch 대상 재구축 — 삭제된 모듈 제거 + 새 모듈 추가
        {
            var kit = mtime_map.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            mtime_map.clearRetainingCapacity();

            // 엔트리 재추가
            if (bundle_opts.entry_points.len > 0) {
                const entry_path = bundle_opts.entry_points[0];
                const re_entry = allocator.dupe(u8, entry_path) catch continue;
                const re_mtime = getFileMtime(entry_path) catch 0;
                mtime_map.put(re_entry, re_mtime) catch {
                    allocator.free(re_entry);
                    continue;
                };
            }

            if (rebuild_result.module_paths) |paths| {
                for (paths) |p| {
                    const duped = allocator.dupe(u8, p) catch continue;
                    const mt = getFileMtime(p) catch continue;
                    mtime_map.put(duped, mt) catch {
                        allocator.free(duped);
                        continue;
                    };
                }
            }
        }
    }

    // 스레드 종료: TSFN 해제
    _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
    _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);

    // async_data는 stop handle의 reference가 해제될 때까지 유지되어야 한다.
    // stop()이 호출되면 stop_flag가 설정되고, 여기에 도달한다.
    // stop handle의 ref가 GC되면 wrap의 weak ref callback으로 정리.
    // 단, TSFN은 이미 release했으므로 플러그인/문자열만 정리.
    async_data.deinit();
}

/// stop() 네이티브 메서드 — JS에서 handle.stop() 호출 시
fn napiWatchStop(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    // this 객체에서 WatchAsyncData 포인터 추출
    var argc: usize = 0;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, null, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get this");
    }

    // napi_remove_wrap: 포인터를 추출하면서 wrap 해제 (double stop 방지)
    var async_data_ptr: ?*anyopaque = null;
    if (c.napi_remove_wrap(env, this, &async_data_ptr) != c.napi_ok) {
        // 이미 stop()이 호출된 경우 — 무시
        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);
        return js_undefined;
    }
    if (async_data_ptr) |ptr| {
        const async_data: *WatchAsyncData = @ptrCast(@alignCast(ptr));
        async_data.stop_flag.store(true, .release);
    }

    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    return js_undefined;
}

fn napiWatch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "watch requires an options object");

    // async data 할당
    const async_data = native_alloc.create(WatchAsyncData) catch return throwError(env, "OutOfMemory");
    async_data.* = .{
        .env = env,
        .options = undefined,
        .owned_strings = .empty,
        .owned_string_arrays = .empty,
        .napi_plugins = .empty,
        .zig_plugins = .empty,
        .ready_tsfn = undefined,
        .rebuild_tsfn = undefined,
        .stop_flag = std.atomic.Value(bool).init(false),
    };

    // 옵션 파싱
    var opts = parseBuildOptions(env, argv[0], &async_data.owned_strings, &async_data.owned_string_arrays) orelse {
        native_alloc.destroy(async_data);
        return throwError(env, "invalid watch options");
    };

    // _pluginDispatcher가 있으면 NapiPlugin 생성 (napiBuild와 동일 패턴)
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

        var resource_name_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zts_watch_plugin", "zts_watch_plugin".len, &resource_name_str);
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
            native_alloc.destroy(async_data);
            return throwError(env, "failed to create threadsafe function");
        }

        async_data.napi_plugins.append(native_alloc, np) catch {};
        async_data.zig_plugins.append(native_alloc, np.toPlugin()) catch {};
        opts.plugins = async_data.zig_plugins.items;
    }

    async_data.options = opts;

    // onReady 콜백 추출
    const on_ready_fn = getNamedProperty(env, argv[0], "onReady");

    // onRebuild 콜백 추출
    const on_rebuild_fn = getNamedProperty(env, argv[0], "onRebuild");

    // onReady TSFN 생성
    {
        var resource_name: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zts_watch_ready", "zts_watch_ready".len, &resource_name);
        if (c.napi_create_threadsafe_function(
            env,
            on_ready_fn orelse null,
            null,
            resource_name,
            0,
            1,
            null,
            null,
            null,
            watchReadyTsfn,
            &async_data.ready_tsfn,
        ) != c.napi_ok) {
            async_data.deinit();
            return throwError(env, "failed to create ready tsfn");
        }
    }

    // onRebuild TSFN 생성
    {
        var resource_name: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zts_watch_rebuild", "zts_watch_rebuild".len, &resource_name);
        if (c.napi_create_threadsafe_function(
            env,
            on_rebuild_fn orelse null,
            null,
            resource_name,
            0,
            1,
            null,
            null,
            null,
            watchRebuildTsfn,
            &async_data.rebuild_tsfn,
        ) != c.napi_ok) {
            _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
            async_data.deinit();
            return throwError(env, "failed to create rebuild tsfn");
        }
    }

    // TSFN의 ref를 해제하여 watch 스레드만으로는 Node.js 프로세스가 종료되는 것을 막지 않도록 한다.
    // (stop() 호출 없이도 프로세스가 종료되도록)
    _ = c.napi_unref_threadsafe_function(env, async_data.ready_tsfn);
    _ = c.napi_unref_threadsafe_function(env, async_data.rebuild_tsfn);

    // 리턴할 handle 객체 생성: { stop() }
    var js_handle: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_handle) != c.napi_ok) {
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return throwError(env, "failed to create handle object");
    }

    // napi_wrap으로 async_data를 handle 객체에 연결
    if (c.napi_wrap(env, js_handle, @ptrCast(async_data), null, null, null) != c.napi_ok) {
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return throwError(env, "failed to wrap handle");
    }

    // stop() 메서드 추가
    var stop_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "stop", "stop".len, napiWatchStop, null, &stop_fn);
    _ = c.napi_set_named_property(env, js_handle, "stop", stop_fn);

    // 워커 스레드 시작
    const thread = std.Thread.spawn(.{}, watchWorkerThread, .{async_data}) catch {
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return throwError(env, "failed to spawn watch thread");
    };
    thread.detach();

    return js_handle;
}

/// 옵션 파싱 함수. owned_strings/owned_string_arrays에 할당된 메모리를 추적.
/// 반환된 BundleOptions의 문자열은 owned 리스트가 소유.
fn parseBuildOptions(
    env: c.napi_env,
    opts_obj: c.napi_value,
    owned_strings: *std.ArrayList([]const u8),
    owned_string_arrays: *std.ArrayList([]const []const u8),
) ?BundleOptions {
    // 문자열 소유권 추적 헬퍼 (OOM 시 false 반환)
    const trackStr = struct {
        fn f(list: *std.ArrayList([]const u8), s: []const u8) bool {
            list.append(native_alloc, s) catch return false;
            return true;
        }
    }.f;
    const trackArr = struct {
        fn f(list: *std.ArrayList([]const []const u8), arr: []const []const u8) bool {
            list.append(native_alloc, arr) catch return false;
            return true;
        }
    }.f;

    // entryPoints
    const raw_entries = getObjectStringArray(env, opts_obj, "entryPoints", native_alloc) orelse return null;
    for (raw_entries) |e| if (!trackStr(owned_strings, e)) return null;
    if (!trackArr(owned_string_arrays, raw_entries)) return null;

    const entries = native_alloc.alloc([]const u8, raw_entries.len) catch return null;
    if (!trackArr(owned_string_arrays, entries)) return null;
    for (raw_entries, 0..) |e, i| {
        entries[i] = resolveEntryPoint(native_alloc, e) orelse return null;
        if (!trackStr(owned_strings, entries[i])) return null;
    }

    // format
    const format_str = getObjectString(env, opts_obj, "format", native_alloc);
    if (format_str) |s| if (!trackStr(owned_strings, s)) return null;
    const format: EmitFormat = if (format_str) |s|
        std.meta.stringToEnum(EmitFormat, s) orelse .esm
    else
        .esm;

    // platform
    const platform_str = getObjectString(env, opts_obj, "platform", native_alloc);
    if (platform_str) |s| if (!trackStr(owned_strings, s)) return null;
    const platform: Platform = if (platform_str) |s|
        if (std.mem.eql(u8, s, "node")) .node else if (std.mem.eql(u8, s, "neutral")) .neutral else if (std.mem.eql(u8, s, "react-native")) .react_native else .browser
    else
        .browser;

    // external
    const external = getObjectStringArray(env, opts_obj, "external", native_alloc);
    if (external) |exts| {
        for (exts) |e| if (!trackStr(owned_strings, e)) return null;
        if (!trackArr(owned_string_arrays, exts)) return null;
    }

    // 문자열 옵션 헬퍼
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

    const banner_js = ownStr(env, opts_obj, "banner", owned_strings);
    const footer_js = ownStr(env, opts_obj, "footer", owned_strings);
    const global_name = ownStr(env, opts_obj, "globalName", owned_strings);
    const public_path = ownStr(env, opts_obj, "publicPath", owned_strings);
    const entry_names = ownStr(env, opts_obj, "entryNames", owned_strings);
    const chunk_names = ownStr(env, opts_obj, "chunkNames", owned_strings);
    const asset_names = ownStr(env, opts_obj, "assetNames", owned_strings);

    // JSX
    const jsx_str = ownStr(env, opts_obj, "jsx", owned_strings);
    const jsx_runtime: JsxRuntime = if (jsx_str) |s|
        if (std.mem.eql(u8, s, "automatic")) .automatic else if (std.mem.eql(u8, s, "automatic-dev")) .automatic_dev else .classic
    else
        .classic;
    const jsx_factory = ownStr(env, opts_obj, "jsxFactory", owned_strings);
    const jsx_fragment = ownStr(env, opts_obj, "jsxFragment", owned_strings);
    const jsx_import_source = ownStr(env, opts_obj, "jsxImportSource", owned_strings);

    // inject
    const inject = getObjectStringArray(env, opts_obj, "inject", native_alloc);
    if (inject) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // define: { "key": "value" } → []DefineEntry
    const define_pairs = getObjectKeyValuePairs(env, opts_obj, "define", native_alloc);
    var define_entries: []const @import("zts_lib").transformer.transformer.DefineEntry = &.{};
    if (define_pairs) |pairs| {
        const defs = native_alloc.alloc(@import("zts_lib").transformer.transformer.DefineEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            defs[idx] = .{ .key = pair[0], .value = pair[1] };
        }
        // pairs 배열 자체는 해제 (키/값은 owned_strings가 소유)
        native_alloc.free(pairs);
        define_entries = defs;
    }

    // alias: { "from": "to" } → []AliasEntry
    const alias_pairs = getObjectKeyValuePairs(env, opts_obj, "alias", native_alloc);
    var alias_entries: []const bundler_mod.types.AliasEntry = &.{};
    if (alias_pairs) |pairs| {
        const als = native_alloc.alloc(bundler_mod.types.AliasEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            als[idx] = .{ .from = pair[0], .to = pair[1] };
        }
        native_alloc.free(pairs);
        alias_entries = als;
    }

    // loader: { ".png": "file", ".svg": "text" } → []LoaderOverride
    const loader_pairs = getObjectKeyValuePairs(env, opts_obj, "loader", native_alloc);
    var loader_overrides: []const bundler_mod.types.LoaderOverride = &.{};
    if (loader_pairs) |pairs| {
        const overrides = native_alloc.alloc(bundler_mod.types.LoaderOverride, pairs.len) catch return null;
        var valid_count: usize = 0;
        for (pairs) |pair| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            const loader = bundler_mod.types.Loader.fromString(pair[1]) orelse continue;
            overrides[valid_count] = .{ .ext = pair[0], .loader = loader };
            valid_count += 1;
        }
        native_alloc.free(pairs);
        loader_overrides = overrides[0..valid_count];
    }

    const conditions = getObjectStringArray(env, opts_obj, "conditions", native_alloc);
    if (conditions) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const resolve_extensions = getObjectStringArray(env, opts_obj, "resolveExtensions", native_alloc);
    if (resolve_extensions) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const main_fields = getObjectStringArray(env, opts_obj, "mainFields", native_alloc);
    if (main_fields) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const compat = @import("zts_lib").transformer.transformer.TransformOptions.compat;
    const target_str = getObjectString(env, opts_obj, "target", native_alloc);
    if (target_str) |s| if (!trackStr(owned_strings, s)) return null;
    const unsupported: compat.UnsupportedFeatures = if (target_str) |s|
        if (std.meta.stringToEnum(compat.ESTarget, s)) |t| compat.fromESTarget(t) else .{}
    else
        .{};

    const outfile = ownStr(env, opts_obj, "outfile", owned_strings);
    const outbase = ownStr(env, opts_obj, "outbase", owned_strings);
    const tsconfig_raw = ownStr(env, opts_obj, "tsconfigRaw", owned_strings);
    const out_extension_js = ownStr(env, opts_obj, "outExtension", owned_strings);
    const source_root = ownStr(env, opts_obj, "sourceRoot", owned_strings);
    const root_dir = ownStr(env, opts_obj, "rootDir", owned_strings);
    const preserve_modules_root = ownStr(env, opts_obj, "preserveModulesRoot", owned_strings);

    // legalComments: "none" | "inline" | "eof" | "linked"
    const legal_str = getObjectString(env, opts_obj, "legalComments", native_alloc);
    if (legal_str) |s| if (!trackStr(owned_strings, s)) return null;
    const legal_comments: bundler_mod.types.LegalComments = if (legal_str) |s|
        if (std.mem.eql(u8, s, "none")) .none
        else if (std.mem.eql(u8, s, "inline")) .@"inline"
        else if (std.mem.eql(u8, s, "eof")) .eof
        else if (std.mem.eql(u8, s, "linked")) .linked
        else .default
    else .default;

    // globalIdentifiers: string[]
    const global_identifiers = getObjectStringArray(env, opts_obj, "globalIdentifiers", native_alloc);
    if (global_identifiers) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // polyfills: string[]
    const polyfills = getObjectStringArray(env, opts_obj, "polyfills", native_alloc);
    if (polyfills) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // runBeforeMain: string[]
    const run_before_main = getObjectStringArray(env, opts_obj, "runBeforeMain", native_alloc);
    if (run_before_main) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // dropLabels: string[]
    const drop_labels = getObjectStringArray(env, opts_obj, "dropLabels", native_alloc);
    if (drop_labels) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // pure: string[]
    const pure = getObjectStringArray(env, opts_obj, "pure", native_alloc);
    if (pure) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    // nodePaths: string[]
    const node_paths = getObjectStringArray(env, opts_obj, "nodePaths", native_alloc);
    if (node_paths) |arr| {
        for (arr) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, arr)) return null;
    }

    const minify = getObjectBool(env, opts_obj, "minify", false);
    return .{
        .entry_points = entries,
        .format = format,
        .platform = platform,
        .external = external orelse &.{},
        .define = define_entries,
        .alias = alias_entries,
        .minify_whitespace = if (minify) true else getObjectBool(env, opts_obj, "minifyWhitespace", false),
        .minify_identifiers = if (minify) true else getObjectBool(env, opts_obj, "minifyIdentifiers", false),
        .minify_syntax = if (minify) true else getObjectBool(env, opts_obj, "minifySyntax", false),
        .code_splitting = getObjectBool(env, opts_obj, "splitting", false),
        .sourcemap = getObjectBool(env, opts_obj, "sourcemap", false),
        .sourcemap_debug_ids = getObjectBool(env, opts_obj, "sourcemapDebugIds", false),
        .sources_content = getObjectBool(env, opts_obj, "sourcesContent", true),
        .tree_shaking = getObjectBool(env, opts_obj, "treeShaking", true),
        .scope_hoist = getObjectBool(env, opts_obj, "scopeHoist", true),
        .metafile = getObjectBool(env, opts_obj, "metafile", false),
        .keep_names = getObjectBool(env, opts_obj, "keepNames", false),
        .shim_missing_exports = getObjectBool(env, opts_obj, "shimMissingExports", false),
        .flow = getObjectBool(env, opts_obj, "flow", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.flow),
        .jsx_in_js = getObjectBool(env, opts_obj, "jsxInJs", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.jsx_in_js),
        .charset_utf8 = getObjectBool(env, opts_obj, "charsetUtf8", false),
        .use_define_for_class_fields = getObjectBool(env, opts_obj, "useDefineForClassFields", true),
        .experimental_decorators = getObjectBool(env, opts_obj, "experimentalDecorators", false),
        .emit_decorator_metadata = getObjectBool(env, opts_obj, "emitDecoratorMetadata", false),
        .banner_js = banner_js,
        .footer_js = footer_js,
        .global_name = global_name,
        .public_path = public_path orelse "",
        .entry_names = entry_names orelse "[name]",
        .chunk_names = chunk_names orelse "[name]-[hash]",
        .asset_names = asset_names orelse "[name]-[hash]",
        .jsx_runtime = jsx_runtime,
        .jsx_factory = jsx_factory orelse "React.createElement",
        .jsx_fragment = jsx_fragment orelse "React.Fragment",
        .jsx_import_source = jsx_import_source orelse "react",
        .inject = inject orelse &.{},
        .max_threads = getObjectUint32(env, opts_obj, "jobs", 0),
        .loader_overrides = loader_overrides,
        .conditions = conditions orelse &.{},
        .resolve_extensions = resolve_extensions orelse &.{},
        .main_fields = main_fields orelse &.{},
        .unsupported = unsupported,
        .output_filename = outfile orelse "bundle.js",
        .outbase = outbase,
        .packages_external = getObjectBool(env, opts_obj, "packagesExternal", false),
        .preserve_symlinks = getObjectBool(env, opts_obj, "preserveSymlinks", false),
        .ignore_annotations = getObjectBool(env, opts_obj, "ignoreAnnotations", false),
        .jsx_side_effects = getObjectBool(env, opts_obj, "jsxSideEffects", false),
        .analyze = getObjectBool(env, opts_obj, "analyze", false),
        .drop_labels = drop_labels orelse &.{},
        .pure = pure orelse &.{},
        .tsconfig_raw = tsconfig_raw,
        .node_paths = node_paths orelse &.{},
        .line_limit = getObjectUint32(env, opts_obj, "lineLimit", 0),
        .out_extension_js = out_extension_js,
        .source_root = source_root,
        .legal_comments = legal_comments,
        .preserve_modules = getObjectBool(env, opts_obj, "preserveModules", false),
        .preserve_modules_root = preserve_modules_root,
        .timing = getObjectBool(env, opts_obj, "timing", false),
        .dev_mode = getObjectBool(env, opts_obj, "devMode", false),
        .root_dir = root_dir,
        .react_refresh = getObjectBool(env, opts_obj, "reactRefresh", false),
        .collect_module_codes = getObjectBool(env, opts_obj, "collectModuleCodes", false),
        // RN 프리셋(bundler.zig의 RN_BOOL_PRESET 단일 소스): platform=react-native이면
        // 사용자가 명시하지 않아도 CLI와 동일하게 auto-enable. worklet_transform 없이는
        // node_modules/react-native-reanimated의 'worklet' directive가 serialize되지
        // 않아 LayoutAnimation 등에서 JSI getObject assert 실패로 크래시 발생.
        .configurable_exports = getObjectBool(env, opts_obj, "configurableExports", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.configurable_exports),
        .strict_execution_order = getObjectBool(env, opts_obj, "strictExecutionOrder", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.strict_execution_order),
        .worklet_transform = getObjectBool(env, opts_obj, "workletTransform", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.worklet_transform),
        .worklet_plugin_version = ownStr(env, opts_obj, "workletPluginVersion", owned_strings),
        .global_identifiers = global_identifiers orelse &.{},
        .polyfills = polyfills orelse &.{},
        .run_before_main = run_before_main orelse &.{},
    };
}

// ─── 모듈 등록 ───

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    var fn_value: c.napi_value = undefined;
    _ = c.napi_create_function(env, "transpile", "transpile".len, napiTranspile, null, &fn_value);
    _ = c.napi_set_named_property(env, exports, "transpile", fn_value);

    var build_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "buildSync", "buildSync".len, napiBuildSync, null, &build_sync_fn);
    _ = c.napi_set_named_property(env, exports, "buildSync", build_sync_fn);

    var build_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "build", "build".len, napiBuild, null, &build_fn);
    _ = c.napi_set_named_property(env, exports, "build", build_fn);

    var watch_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "watch", "watch".len, napiWatch, null, &watch_fn);
    _ = c.napi_set_named_property(env, exports, "watch", watch_fn);

    return exports;
}
