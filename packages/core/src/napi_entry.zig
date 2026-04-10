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
    // 워커 스레드 ↔ 메인 스레드 동기화
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    // 요청/응답 공유 데이터
    request: ?PluginRequest = null,
    response: ?PluginResponse = null,
    response_ready: bool = false,

    const HookType = enum { resolveId, load, transform };

    const PluginRequest = struct {
        hook: HookType,
        arg1: []const u8,
        arg2: ?[]const u8,
    };

    const PluginResponse = struct {
        // resolveId 결과
        resolved_path: ?[]const u8 = null,
        is_external: bool = false,
        // load/transform 결과
        code: ?[]const u8 = null,
    };

    /// threadsafe function의 call_js 콜백 (메인 스레드에서 실행)
    fn callJsCallback(env: c.napi_env, js_callback: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *NapiPlugin = @ptrCast(@alignCast(data.?));
        self.mutex.lock();
        defer {
            self.response_ready = true;
            self.mutex.unlock();
            self.cond.signal();
        }

        const req = self.request orelse {
            self.response = .{};
            return;
        };

        // JS dispatcher 호출: dispatcher(hookName, arg1, arg2)
        var hook_str: c.napi_value = undefined;
        const hook_name: []const u8 = switch (req.hook) {
            .resolveId => "resolveId",
            .load => "load",
            .transform => "transform",
        };
        _ = c.napi_create_string_utf8(env, hook_name.ptr, hook_name.len, &hook_str);

        var js_arg1: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, req.arg1.ptr, req.arg1.len, &js_arg1);

        var js_arg2: c.napi_value = undefined;
        if (req.arg2) |a2| {
            _ = c.napi_create_string_utf8(env, a2.ptr, a2.len, &js_arg2);
        } else {
            _ = c.napi_get_null(env, &js_arg2);
        }

        var js_result: c.napi_value = undefined;
        const args = [_]c.napi_value{ hook_str, js_arg1, js_arg2 };
        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);
        if (c.napi_call_function(env, js_undefined, js_callback, 3, &args, &js_result) != c.napi_ok) {
            self.response = .{};
            return;
        }

        // 결과 파싱
        var result_type: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, js_result, &result_type);
        if (result_type == c.napi_null or result_type == c.napi_undefined) {
            self.response = .{};
            return;
        }

        // 객체에서 필드 추출
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

        self.response = resp;
    }

    /// 워커 스레드에서 호출 — JS 콜백 실행 후 결과 대기
    fn callHook(self: *NapiPlugin, hook: HookType, arg1: []const u8, arg2: ?[]const u8) ?PluginResponse {
        self.mutex.lock();
        self.request = .{ .hook = hook, .arg1 = arg1, .arg2 = arg2 };
        self.response = null;
        self.response_ready = false;
        self.mutex.unlock();

        // threadsafe function 호출 (블로킹 — 큐에 추가될 때까지 대기)
        if (c.napi_call_threadsafe_function(self.tsfn, @ptrCast(self), c.napi_tsfn_blocking) != c.napi_ok) {
            return null;
        }

        // 결과 대기
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.response_ready) {
            self.cond.wait(&self.mutex);
        }

        return self.response;
    }

    // ─── Plugin 인터페이스 구현 ───

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
        const resp = self.callHook(.load, path, null) orelse return null;
        defer {
            if (resp.resolved_path) |p| native_alloc.free(p);
        }

        if (resp.code) |code| {
            const result = alloc.dupe(u8, code) catch return error.OutOfMemory;
            native_alloc.free(code);
            return result;
        }
        return null;
    }

    fn pluginTransform(ctx: ?*anyopaque, code: []const u8, id: []const u8, alloc: std.mem.Allocator) PluginError!?[]const u8 {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));
        const resp = self.callHook(.transform, code, id) orelse return null;
        defer {
            if (resp.resolved_path) |p| native_alloc.free(p);
        }

        if (resp.code) |result_code| {
            const result = alloc.dupe(u8, result_code) catch return error.OutOfMemory;
            native_alloc.free(result_code);
            return result;
        }
        return null;
    }

    fn toPlugin(self: *NapiPlugin) Plugin {
        return .{
            .name = self.name,
            .context = @ptrCast(self),
            .resolveId = pluginResolveId,
            .load = pluginLoad,
            .transform = pluginTransform,
        };
    }

    fn deinit(self: *NapiPlugin) void {
        _ = c.napi_release_threadsafe_function(self.tsfn, c.napi_tsfn_release);
        native_alloc.free(self.name);
        native_alloc.destroy(self);
    }
};

// ─── build() 비동기 (Promise) ───

const BuildAsyncData = struct {
    env: c.napi_env,
    deferred: c.napi_deferred,
    async_work: c.napi_async_work,
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

/// 워커 스레드에서 실행 — 번들링 수행
fn buildExecute(_: c.napi_env, data: ?*anyopaque) callconv(.c) void {
    const async_data: *BuildAsyncData = @ptrCast(@alignCast(data.?));
    var bundler = Bundler.init(native_alloc, async_data.options);
    async_data.result = bundler.bundle() catch |err| {
        async_data.err_msg = @errorName(err);
        return;
    };
}

/// 메인 스레드에서 실행 — 결과를 JS Promise로 반환
fn buildComplete(env: c.napi_env, _: c.napi_status, data: ?*anyopaque) callconv(.c) void {
    const async_data: *BuildAsyncData = @ptrCast(@alignCast(data.?));
    defer {
        // 비동기 작업 정리
        _ = c.napi_delete_async_work(env, async_data.async_work);
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
        // reject
        var js_err: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, msg, std.mem.len(msg), &js_err);
        var js_error: c.napi_value = undefined;
        _ = c.napi_create_error(env, null, js_err, &js_error);
        _ = c.napi_reject_deferred(env, async_data.deferred, js_error);
    } else if (async_data.result) |*result| {
        // resolve
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
        // 방어 코드: result와 err_msg 모두 null인 경우 (이론상 불가능)
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
        .async_work = undefined,
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

    // async work 생성 및 큐잉
    var resource_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "zts_build", "zts_build".len, &resource_name);
    if (c.napi_create_async_work(env, null, resource_name, buildExecute, buildComplete, async_data, &async_data.async_work) != c.napi_ok) {
        native_alloc.destroy(async_data);
        return throwError(env, "failed to create async work");
    }
    if (c.napi_queue_async_work(env, async_data.async_work) != c.napi_ok) {
        _ = c.napi_delete_async_work(env, async_data.async_work);
        native_alloc.destroy(async_data);
        return throwError(env, "failed to queue async work");
    }

    return promise;
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
        if (std.mem.eql(u8, s, "cjs")) .cjs else if (std.mem.eql(u8, s, "iife")) .iife else .esm
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

    const minify = getObjectBool(env, opts_obj, "minify", false);
    return .{
        .entry_points = entries,
        .format = format,
        .platform = platform,
        .external = external orelse &.{},
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
        .flow = getObjectBool(env, opts_obj, "flow", false),
        .jsx_in_js = getObjectBool(env, opts_obj, "jsxInJs", false),
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

    return exports;
}
