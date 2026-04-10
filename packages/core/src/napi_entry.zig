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

    const opts_obj = argv[0];

    // entryPoints (필수)
    const raw_entries = getObjectStringArray(env, opts_obj, "entryPoints", native_alloc) orelse {
        return throwError(env, "entryPoints is required");
    };
    defer {
        for (raw_entries) |e| native_alloc.free(e);
        native_alloc.free(raw_entries);
    }

    // 절대 경로로 해석
    const entries = native_alloc.alloc([]const u8, raw_entries.len) catch return throwError(env, "OutOfMemory");
    defer {
        for (entries) |e| native_alloc.free(e);
        native_alloc.free(entries);
    }
    for (raw_entries, 0..) |e, i| {
        entries[i] = resolveEntryPoint(native_alloc, e) orelse return throwError(env, "failed to resolve entry point");
    }

    // format
    const format_str = getObjectString(env, opts_obj, "format", native_alloc);
    defer if (format_str) |s| native_alloc.free(s);
    const format: EmitFormat = if (format_str) |s|
        if (std.mem.eql(u8, s, "cjs")) .cjs else if (std.mem.eql(u8, s, "iife")) .iife else .esm
    else
        .esm;

    // platform
    const platform_str = getObjectString(env, opts_obj, "platform", native_alloc);
    defer if (platform_str) |s| native_alloc.free(s);
    const platform: Platform = if (platform_str) |s|
        if (std.mem.eql(u8, s, "node")) .node else if (std.mem.eql(u8, s, "neutral")) .neutral else if (std.mem.eql(u8, s, "react-native")) .react_native else .browser
    else
        .browser;

    // external
    const external = getObjectStringArray(env, opts_obj, "external", native_alloc);
    defer if (external) |exts| {
        for (exts) |e| native_alloc.free(e);
        native_alloc.free(exts);
    };

    // 문자열 옵션
    const banner_js = getObjectString(env, opts_obj, "banner", native_alloc);
    defer if (banner_js) |s| native_alloc.free(s);
    const footer_js = getObjectString(env, opts_obj, "footer", native_alloc);
    defer if (footer_js) |s| native_alloc.free(s);
    const global_name = getObjectString(env, opts_obj, "globalName", native_alloc);
    defer if (global_name) |s| native_alloc.free(s);
    const public_path = getObjectString(env, opts_obj, "publicPath", native_alloc);
    defer if (public_path) |s| native_alloc.free(s);
    const entry_names = getObjectString(env, opts_obj, "entryNames", native_alloc);
    defer if (entry_names) |s| native_alloc.free(s);
    const chunk_names = getObjectString(env, opts_obj, "chunkNames", native_alloc);
    defer if (chunk_names) |s| native_alloc.free(s);
    const asset_names = getObjectString(env, opts_obj, "assetNames", native_alloc);
    defer if (asset_names) |s| native_alloc.free(s);

    // JSX 옵션
    const jsx_str = getObjectString(env, opts_obj, "jsx", native_alloc);
    defer if (jsx_str) |s| native_alloc.free(s);
    const jsx_runtime: JsxRuntime = if (jsx_str) |s|
        if (std.mem.eql(u8, s, "automatic")) .automatic else if (std.mem.eql(u8, s, "automatic-dev")) .automatic_dev else .classic
    else
        .classic;
    const jsx_factory = getObjectString(env, opts_obj, "jsxFactory", native_alloc);
    defer if (jsx_factory) |s| native_alloc.free(s);
    const jsx_fragment = getObjectString(env, opts_obj, "jsxFragment", native_alloc);
    defer if (jsx_fragment) |s| native_alloc.free(s);
    const jsx_import_source = getObjectString(env, opts_obj, "jsxImportSource", native_alloc);
    defer if (jsx_import_source) |s| native_alloc.free(s);

    // inject
    const inject = getObjectStringArray(env, opts_obj, "inject", native_alloc);
    defer if (inject) |arr| {
        for (arr) |s| native_alloc.free(s);
        native_alloc.free(arr);
    };

    // BundleOptions 구성
    const minify = getObjectBool(env, opts_obj, "minify", false);
    const bundle_opts = BundleOptions{
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

    // 번들 실행
    var bundler = Bundler.init(native_alloc, bundle_opts);
    var result = bundler.bundle() catch |err| {
        return throwError(env, @errorName(err));
    };
    defer result.deinit(native_alloc);

    // JS 결과 객체 생성: { outputFiles: [...], errors: [...], warnings: [...], metafile?: string }
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

// ─── 모듈 등록 ───

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    var fn_value: c.napi_value = undefined;
    _ = c.napi_create_function(env, "transpile", "transpile".len, napiTranspile, null, &fn_value);
    _ = c.napi_set_named_property(env, exports, "transpile", fn_value);

    var build_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "buildSync", "buildSync".len, napiBuildSync, null, &build_fn);
    _ = c.napi_set_named_property(env, exports, "buildSync", build_fn);

    return exports;
}
