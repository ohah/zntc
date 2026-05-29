const std = @import("std");
const zntc_lib = @import("zntc_lib");
const bundler_mod = zntc_lib.bundler;
const Bundler = bundler_mod.Bundler;
const transformer_mod = zntc_lib.transformer.transformer;
const JsxRuntime = zntc_lib.codegen.codegen.JsxRuntime;
const JsxConfig = zntc_lib.app.build.JsxConfig;
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

const getAutoLabelMode = options_mod.getAutoLabelMode;
const parseLogFilterOptions = options_mod.parseLogFilterOptions;
const parseBuildOptions = options_mod.parseBuildOptions;
const freeOptionsTypedSlices = options_mod.freeOptionsTypedSlices;
const buildResultToJS = result_napi_mod.buildResultToJS;
const Plugin = bundler_mod.plugin.Plugin;
const NapiSyncPlugin = plugin_bridge.NapiSyncPlugin;

pub fn napiBuildSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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

    var bundle_opts = parseBuildOptions(env, argv[0], &owned_strings, &owned_string_arrays) orelse {
        return throwError(env, "invalid build options (entryPoints required)");
    };
    defer freeOptionsTypedSlices(&bundle_opts);

    var sync_plugin: ?*NapiSyncPlugin = null;
    defer if (sync_plugin) |sp| sp.deinit();
    var sync_plugin_storage: [1]Plugin = undefined;
    if (getNamedProperty(env, argv[0], "_pluginDispatcherSync")) |dispatcher_fn| {
        const sp = native_alloc.create(NapiSyncPlugin) catch return throwError(env, "OutOfMemory");
        sp.* = .{
            .name = native_alloc.dupe(u8, "js-plugin") catch {
                native_alloc.destroy(sp);
                return throwError(env, "OutOfMemory");
            },
            .env = env,
            .callback_ref = undefined,
        };
        if (c.napi_create_reference(env, dispatcher_fn, 1, &sp.callback_ref) != c.napi_ok) {
            native_alloc.free(sp.name);
            native_alloc.destroy(sp);
            return throwError(env, "failed to create plugin reference");
        }
        sync_plugin = sp;
        sync_plugin_storage[0] = sp.toPlugin();
        bundle_opts.plugins = sync_plugin_storage[0..1];
    }

    var bundler = Bundler.init(native_alloc, bundle_opts);
    defer bundler.deinit();
    var result = bundler.bundle(common.io()) catch |err| {
        return throwError(env, @errorName(err));
    };
    defer result.deinit(native_alloc);

    return buildResultToJS(env, &result, parseLogFilterOptions(env, argv[0]));
}

pub fn napiBuildAppSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "buildAppSync requires an options object");

    var owned_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_strings.items) |s| native_alloc.free(s);
        owned_strings.deinit(native_alloc);
    }
    var owned_arrays: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (owned_arrays.items) |arr| native_alloc.free(arr);
        owned_arrays.deinit(native_alloc);
    }

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

    const root = ownStr(env, opts_obj, "root", &owned_strings) orelse ".";
    const outdir = ownStr(env, opts_obj, "outdir", &owned_strings) orelse "dist";
    const entry_html = ownStr(env, opts_obj, "entryHtml", &owned_strings) orelse "index.html";
    const public_dir_value = ownStr(env, opts_obj, "publicDir", &owned_strings);
    const public_dir: ?[]const u8 = if (getObjectBool(env, opts_obj, "disablePublicDir", false)) null else (public_dir_value orelse "public");
    const base = ownStr(env, opts_obj, "base", &owned_strings) orelse "/";
    const mode = ownStr(env, opts_obj, "mode", &owned_strings) orelse "production";
    const env_dir = ownStr(env, opts_obj, "envDir", &owned_strings);

    const env_prefixes = getObjectStringArray(env, opts_obj, "envPrefixes", native_alloc);
    if (env_prefixes) |arr| {
        for (arr) |s| owned_strings.append(native_alloc, s) catch return throwError(env, "OutOfMemory");
        owned_arrays.append(native_alloc, arr) catch return throwError(env, "OutOfMemory");
    }

    const define_pairs = getObjectKeyValuePairs(env, opts_obj, "define", native_alloc);
    var define_entries: []const transformer_mod.DefineEntry = &.{};
    if (define_pairs) |pairs| {
        const defs = native_alloc.alloc(transformer_mod.DefineEntry, pairs.len) catch return throwError(env, "OutOfMemory");
        for (pairs, 0..) |pair, i| {
            owned_strings.append(native_alloc, pair[0]) catch return throwError(env, "OutOfMemory");
            owned_strings.append(native_alloc, pair[1]) catch return throwError(env, "OutOfMemory");
            defs[i] = .{ .key = pair[0], .value = pair[1] };
        }
        native_alloc.free(pairs);
        define_entries = defs;
    }
    defer if (define_entries.len > 0) native_alloc.free(define_entries);

    const emotion_extra_css = getObjectStringArray(env, opts_obj, "emotionExtraCssSources", native_alloc);
    if (emotion_extra_css) |arr| {
        for (arr) |s| owned_strings.append(native_alloc, s) catch return throwError(env, "OutOfMemory");
        owned_arrays.append(native_alloc, arr) catch return throwError(env, "OutOfMemory");
    }
    const emotion_extra_styled = getObjectStringArray(env, opts_obj, "emotionExtraStyledSources", native_alloc);
    if (emotion_extra_styled) |arr| {
        for (arr) |s| owned_strings.append(native_alloc, s) catch return throwError(env, "OutOfMemory");
        owned_arrays.append(native_alloc, arr) catch return throwError(env, "OutOfMemory");
    }
    const sc_meaningless = getObjectStringArray(env, opts_obj, "styledComponentsMeaninglessFileNames", native_alloc);
    if (sc_meaningless) |arr| {
        for (arr) |s| owned_strings.append(native_alloc, s) catch return throwError(env, "OutOfMemory");
        owned_arrays.append(native_alloc, arr) catch return throwError(env, "OutOfMemory");
    }
    const sc_top_level = getObjectStringArray(env, opts_obj, "styledComponentsTopLevelImportPaths", native_alloc);
    if (sc_top_level) |arr| {
        for (arr) |s| owned_strings.append(native_alloc, s) catch return throwError(env, "OutOfMemory");
        owned_arrays.append(native_alloc, arr) catch return throwError(env, "OutOfMemory");
    }

    // JSX 옵션 — buildApp(=app build) 도 일반 build 처럼 jsx runtime/import-source 를
    // 전달해야 한다. 누락 시 JsxConfig default(.classic, React.createElement)로 떨어져
    // pragma 없는 파일이 `React.createElement` 로 변환되는데 automatic 모드 사용자는
    // React 를 import 하지 않아 런타임 `React is not defined`. invalid vocab 은
    // options.zig(buildSync)와 동일하게 strict throw — silent classic fallback 은
    // 사용자 typo 디버깅을 어렵게 한다. 미지정(null)은 JsxConfig default 그대로.
    const jsx_str = ownStr(env, opts_obj, "jsx", &owned_strings);
    var jsx_cfg = JsxConfig{};
    if (jsx_str) |s| {
        jsx_cfg.runtime = JsxRuntime.fromString(s) orelse
            return throwError(env, "invalid 'jsx' option (expected automatic / automatic-dev / classic / preserve)");
    }
    if (ownStr(env, opts_obj, "jsxImportSource", &owned_strings)) |s| jsx_cfg.import_source = s;
    if (ownStr(env, opts_obj, "jsxFactory", &owned_strings)) |s| jsx_cfg.factory = s;
    if (ownStr(env, opts_obj, "jsxFragment", &owned_strings)) |s| jsx_cfg.fragment = s;

    // JS plugin dispatcher — `napiBuildSync` 의 동일 패턴. `_pluginDispatcherSync`
    // 미지정 시 plugin 없는 build. AppBuildOptions.plugins 로 전달돼 buildApp 의
    // Bundler.init 이 받는다 (#2538 4-4 PR-1).
    var sync_plugin: ?*NapiSyncPlugin = null;
    defer if (sync_plugin) |sp| sp.deinit();
    var sync_plugin_storage: [1]Plugin = undefined;
    var plugins_slice: []const Plugin = &.{};
    if (getNamedProperty(env, opts_obj, "_pluginDispatcherSync")) |dispatcher_fn| {
        const sp = native_alloc.create(NapiSyncPlugin) catch return throwError(env, "OutOfMemory");
        sp.* = .{
            .name = native_alloc.dupe(u8, "js-plugin") catch {
                native_alloc.destroy(sp);
                return throwError(env, "OutOfMemory");
            },
            .env = env,
            .callback_ref = undefined,
        };
        if (c.napi_create_reference(env, dispatcher_fn, 1, &sp.callback_ref) != c.napi_ok) {
            native_alloc.free(sp.name);
            native_alloc.destroy(sp);
            return throwError(env, "failed to create plugin reference");
        }
        sync_plugin = sp;
        sync_plugin_storage[0] = sp.toPlugin();
        plugins_slice = sync_plugin_storage[0..1];
    }

    const output_count = zntc_lib.app.build.buildApp(native_alloc, common.io(), .{
        .root = root,
        .outdir = outdir,
        .entry_html = entry_html,
        .public_dir = public_dir,
        .base = base,
        .mode = mode,
        .env_dir = env_dir,
        .env_prefixes = env_prefixes orelse &.{ "VITE_", "ZNTC_" },
        .define = define_entries,
        .minify = getObjectBool(env, opts_obj, "minify", false),
        .sourcemap = getObjectBool(env, opts_obj, "sourcemap", false),
        .splitting = getObjectBool(env, opts_obj, "splitting", true),
        .styled_components = getObjectBool(env, opts_obj, "styledComponents", false),
        .styled_components_ssr = getObjectBool(env, opts_obj, "styledComponentsSsr", true),
        .styled_components_minify = getObjectBool(env, opts_obj, "styledComponentsMinify", false),
        .styled_components_file_name = getObjectBool(env, opts_obj, "styledComponentsFileName", true),
        .styled_components_pure = getObjectBool(env, opts_obj, "styledComponentsPure", false),
        .styled_components_namespace = ownStr(env, opts_obj, "styledComponentsNamespace", &owned_strings) orelse "",
        .styled_components_meaningless_file_names = sc_meaningless orelse &.{"index"},
        .styled_components_top_level_import_paths = sc_top_level orelse &.{},
        .styled_components_css_prop = getObjectBool(env, opts_obj, "styledComponentsCssProp", false),
        .emotion = getObjectBool(env, opts_obj, "emotion", false),
        .emotion_auto_label = getAutoLabelMode(env, opts_obj, native_alloc),
        .emotion_source_map = getObjectBool(env, opts_obj, "emotionSourceMap", false),
        .emotion_label_format = ownStr(env, opts_obj, "emotionLabelFormat", &owned_strings) orelse "",
        .emotion_extra_css_sources = emotion_extra_css orelse &.{},
        .emotion_extra_styled_sources = emotion_extra_styled orelse &.{},
        .jsx = jsx_cfg,
        .plugins = plugins_slice,
    }) catch |err| {
        return throwError(env, @errorName(err));
    };

    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) return throwError(env, "failed to create result");

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
    _ = c.napi_create_uint32(env, @intCast(output_count), &js_count);
    _ = c.napi_set_named_property(env, js_result, "outputCount", js_count);
    return js_result;
}

pub fn napiPrepareAppDevSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "prepareAppDevSync requires an options object");

    var owned_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_strings.items) |s| native_alloc.free(s);
        owned_strings.deinit(native_alloc);
    }
    var owned_arrays: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (owned_arrays.items) |arr| native_alloc.free(arr);
        owned_arrays.deinit(native_alloc);
    }

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

    const root = ownStr(env, opts_obj, "root", &owned_strings) orelse ".";
    const outdir = ownStr(env, opts_obj, "outdir", &owned_strings) orelse ".zntc-dev";
    const entry_html = ownStr(env, opts_obj, "entryHtml", &owned_strings) orelse "index.html";
    const public_dir_value = ownStr(env, opts_obj, "publicDir", &owned_strings);
    const public_dir: ?[]const u8 = if (getObjectBool(env, opts_obj, "disablePublicDir", false)) null else (public_dir_value orelse "public");
    const base = ownStr(env, opts_obj, "base", &owned_strings) orelse "/";
    const mode = ownStr(env, opts_obj, "mode", &owned_strings) orelse "development";
    const env_dir = ownStr(env, opts_obj, "envDir", &owned_strings);

    const env_prefixes = getObjectStringArray(env, opts_obj, "envPrefixes", native_alloc);
    if (env_prefixes) |arr| {
        for (arr) |s| owned_strings.append(native_alloc, s) catch return throwError(env, "OutOfMemory");
        owned_arrays.append(native_alloc, arr) catch return throwError(env, "OutOfMemory");
    }

    var result = zntc_lib.app.build.prepareDev(native_alloc, common.io(), .{
        .root = root,
        .outdir = outdir,
        .entry_html = entry_html,
        .public_dir = public_dir,
        .base = base,
        .mode = mode,
        .env_dir = env_dir,
        .env_prefixes = env_prefixes orelse &.{ "VITE_", "ZNTC_" },
    }) catch |err| {
        return throwError(env, @errorName(err));
    };
    defer result.deinit(native_alloc);

    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) return throwError(env, "failed to create result");
    var js_entry: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, result.entry_path.ptr, result.entry_path.len, &js_entry);
    _ = c.napi_set_named_property(env, js_result, "entryPath", js_entry);
    var js_count: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, @intCast(result.output_count), &js_count);
    _ = c.napi_set_named_property(env, js_result, "outputCount", js_count);
    return js_result;
}
