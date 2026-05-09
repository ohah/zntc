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
const transpile_mod = zntc_lib.transpile;
const Scanner = zntc_lib.lexer.Scanner;
const rich_diagnostic = zntc_lib.rich_diagnostic;
const diagnostic_renderer = zntc_lib.diagnostic_renderer;
const napi_render_opts: diagnostic_renderer.RenderOptions = .{ .color = false, .unicode = true };
const bundler_mod = zntc_lib.bundler;
const Bundler = bundler_mod.Bundler;
const profile_mod = zntc_lib.profile;

const BundleOptions = bundler_mod.BundleOptions;
const transformer_mod = zntc_lib.transformer.transformer;
const common = @import("napi/common.zig");
const options_mod = @import("napi/options.zig");
const tsconfig_cache_mod = @import("napi/tsconfig_cache.zig");
const benchmark_mod = @import("napi/benchmark.zig");
const c = common.c;

const native_alloc = std.heap.c_allocator;

// ─── NAPI 헬퍼 ───

const throwError = common.throwError;
const getStringArg = common.getStringArg;
const getNamedProperty = common.getNamedProperty;
const getObjectBool = common.getObjectBool;
const getObjectUint32 = common.getObjectUint32;
const getObjectString = common.getObjectString;
const getObjectStringArray = common.getObjectStringArray;
const parseStringArray = common.parseStringArray;
const getObjectKeyValuePairs = common.getObjectKeyValuePairs;
const setUint32Prop = common.setUint32Prop;
const setStringProp = common.setStringProp;

const LogFilterOptions = options_mod.LogFilterOptions;
const getAutoLabelMode = options_mod.getAutoLabelMode;
const parseLogFilterOptions = options_mod.parseLogFilterOptions;
const parseBuildOptions = options_mod.parseBuildOptions;
const freeOptionsTypedSlices = options_mod.freeOptionsTypedSlices;

// ─── transpile 함수 ───

/// transpile(source, filename, optionsJson, cache?)
/// optionsJson: ConfigOptionsDto JSON payload (camelCase 키)
/// cache: 옵셔널 TsconfigCache handle (#2367) — autodiscover 결과 재사용 → 다수 파일 in-process
///         transpile 시 file 당 5–10 fs syscall 절약. options.tsconfigPath 가 명시되면 무시.
/// → { code: string, map?: string, errors?: string }
fn napiTranspile(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 4;
    var argv: [4]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 2) {
        return throwError(env, "transpile requires at least 2 arguments (source, filename)");
    }

    // source (필수)
    const source = getStringArg(env, argv[0], native_alloc) orelse {
        return throwError(env, "invalid or empty source");
    };
    defer native_alloc.free(source);

    // filename (필수)
    const filename = getStringArg(env, argv[1], native_alloc) orelse
        native_alloc.dupe(u8, "input.js") catch {
        return throwError(env, "OutOfMemory");
    };
    defer native_alloc.free(filename);

    // optionsJson (선택) + 파싱된 문자열의 수명을 위한 arena
    var opts_arena = std.heap.ArenaAllocator.init(native_alloc);
    defer opts_arena.deinit();
    const opts_alloc = opts_arena.allocator();

    const opts_json: []const u8 = if (argc > 2) (getStringArg(env, argv[2], opts_alloc) orelse "{}") else "{}";

    var options = transpile_mod.optionsFromJson(opts_alloc, opts_json, filename) catch {
        return throwError(env, "invalid options JSON");
    };

    // 4 번째 cache handle (옵션) — options.tsconfig_path 미설정 시 autodiscover 결과 캐시 활용.
    // cache 의 string 은 cache 인스턴스 lifetime 동안 유효 — transpile 은 sync 라 안전 공유.
    // tsconfigRaw 명시 시 transpile.zig 가 file 경로를 무시하므로 cache lookup 자체 스킵 (불필요
    // walk 회피). raw 는 options struct 에 매핑 안 되고 parsed DTO 에서 직접 사용되므로
    // JSON 문자열 substring 으로 검사. false-positive (raw 가 다른 string 값에 등장) 시
    // cache 만 스킵 — 결과는 여전히 정확.
    const has_raw = std.mem.indexOf(u8, opts_json, "\"tsconfigRaw\"") != null;
    if (argc > 3 and options.tsconfig_path == null and !has_raw) {
        if (tsconfig_cache_mod.unwrapTsconfigCache(env, argv[3])) |cache| {
            if (cache.findTsconfigPath(filename)) |path| {
                options.tsconfig_path = path;
            }
        }
    }

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

    // errors (선택적, tsc 호환): 시맨틱 에러가 있으면 CLI와 동일한 포맷으로
    // 렌더링하여 string으로 노출. WASM 바인딩과 일치하는 schema.
    if (result.diagnostics.len > 0) {
        const source_info: rich_diagnostic.SourceInfo = .{
            .source = source,
            .line_offsets = result.line_offsets,
        };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(native_alloc);
        diagnostic_renderer.renderAll(buf.writer(native_alloc), result.diagnostics, source_info, filename, napi_render_opts) catch {};
        if (buf.items.len > 0) {
            var js_errors: c.napi_value = undefined;
            if (c.napi_create_string_utf8(env, buf.items.ptr, buf.items.len, &js_errors) == c.napi_ok) {
                _ = c.napi_set_named_property(env, js_result, "errors", js_errors);
            }
        }
    }

    return js_result;
}

/// tokenize(source, filename) → [{ kind, text, start, end, line, column, hasNewlineBefore }]
fn napiTokenize(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 2;
    var argv: [2]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "tokenize requires source");

    const source = getStringArg(env, argv[0], native_alloc) orelse {
        return throwError(env, "invalid or empty source");
    };
    defer native_alloc.free(source);

    const filename = if (argc > 1) (getStringArg(env, argv[1], native_alloc) orelse "") else "";
    defer if (filename.len > 0) native_alloc.free(filename);

    var scanner = Scanner.init(native_alloc, source) catch return throwError(env, "OutOfMemory");
    defer scanner.deinit();
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".mts") or
        std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx"))
    {
        scanner.is_module = true;
    }

    var js_tokens: c.napi_value = undefined;
    if (c.napi_create_array(env, &js_tokens) != c.napi_ok) return throwError(env, "failed to create token array");

    var index: u32 = 0;
    while (true) : (index += 1) {
        scanner.next() catch return throwError(env, "tokenize failed");
        const tok = scanner.token;
        const loc = scanner.getLineColumn(tok.span.start);
        const text = scanner.tokenText();

        var js_tok: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_tok);

        setStringProp(env, js_tok, "kind", tok.kind.symbol());
        setStringProp(env, js_tok, "text", text);
        setUint32Prop(env, js_tok, "start", tok.span.start);
        setUint32Prop(env, js_tok, "end", tok.span.end);
        setUint32Prop(env, js_tok, "line", loc.line);
        setUint32Prop(env, js_tok, "column", loc.column);

        var js_newline: c.napi_value = undefined;
        _ = c.napi_get_boolean(env, tok.has_newline_before, &js_newline);
        _ = c.napi_set_named_property(env, js_tok, "hasNewlineBefore", js_newline);

        _ = c.napi_set_element(env, js_tokens, index, js_tok);
        if (tok.kind == .eof) break;
    }

    return js_tokens;
}

/// configureProfile(categories, level?) → void
fn napiConfigureProfile(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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
fn napiProfileReport(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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
    var result = bundler.bundle() catch |err| {
        return throwError(env, @errorName(err));
    };
    defer result.deinit(native_alloc);

    return buildResultToJS(env, &result, parseLogFilterOptions(env, argv[0]));
}

fn napiBuildAppSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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

    const output_count = @import("zntc_lib").app.build.buildApp(native_alloc, .{
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

fn napiPrepareAppDevSync(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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

    var result = @import("zntc_lib").app.build.prepareDev(native_alloc, .{
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

fn buildResultToJS(env: c.napi_env, result: *const bundler_mod.BundleResult, log_opts: LogFilterOptions) c.napi_value {
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

            // rolldown chunk.moduleIds 호환 — string[]
            var js_ids: c.napi_value = undefined;
            _ = c.napi_create_array(env, &js_ids);
            for (out.module_ids, 0..) |id, k| {
                var s: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, id.ptr, id.len, &s);
                _ = c.napi_set_element(env, js_ids, @intCast(k), s);
            }
            _ = c.napi_set_named_property(env, js_file, "moduleIds", js_ids);

            // exports 심볼 이름들 — cross-chunk 검증용
            var js_exports: c.napi_value = undefined;
            _ = c.napi_create_array(env, &js_exports);
            for (out.exports, 0..) |ex, k| {
                var s: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, ex.ptr, ex.len, &s);
                _ = c.napi_set_element(env, js_exports, @intCast(k), s);
            }
            _ = c.napi_set_named_property(env, js_file, "exports", js_exports);

            // imports — cross-chunk 로 참조하는 다른 chunk 들의 최종 filename
            var js_imports: c.napi_value = undefined;
            _ = c.napi_create_array(env, &js_imports);
            for (out.imports, 0..) |im, k| {
                var s: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, im.ptr, im.len, &s);
                _ = c.napi_set_element(env, js_imports, @intCast(k), s);
            }
            _ = c.napi_set_named_property(env, js_file, "imports", js_imports);

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

    // logLevel / logLimit 필터링 (#2158) — caller (sync/async) 가 opts 파싱 시점에
    // 미리 추출한 값 사용. 함수 시그니처가 LogFilterOptions 받음.
    const log_filter = log_opts.filter;
    const log_limit = log_opts.limit;

    var err_idx: u32 = 0;
    var warn_idx: u32 = 0;
    for (result.getDiagnostics()) |d| {
        const is_err = d.severity == .@"error";
        if (is_err and !log_filter.allow_errors) continue;
        if (!is_err and !log_filter.allow_warnings) continue;
        if (log_limit > 0) {
            if (is_err and err_idx >= log_limit) continue;
            if (!is_err and warn_idx >= log_limit) continue;
        }

        var js_diag: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_diag);

        var js_msg: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, d.message.ptr, d.message.len, &js_msg);
        _ = c.napi_set_named_property(env, js_diag, "text", js_msg);

        const code_name = @tagName(d.code);
        var js_code: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, code_name.ptr, code_name.len, &js_code);
        _ = c.napi_set_named_property(env, js_diag, "code", js_code);

        if (d.file_path.len > 0) {
            var js_loc: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_loc);
            var js_file_path: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, d.file_path.ptr, d.file_path.len, &js_file_path);
            _ = c.napi_set_named_property(env, js_loc, "file", js_file_path);
            _ = c.napi_set_named_property(env, js_diag, "location", js_loc);
        }

        if (is_err) {
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

// ─── NAPI plugin bridge ───
const plugin_bridge = @import("napi/plugin_bridge.zig");
const Plugin = bundler_mod.plugin.Plugin;
const NapiPlugin = plugin_bridge.NapiPlugin;
const NapiSyncPlugin = plugin_bridge.NapiSyncPlugin;
const NapiManualChunksResolver = plugin_bridge.NapiManualChunksResolver;
const installManualChunksResolver = plugin_bridge.installManualChunksResolver;
const watch_mod = @import("napi/watch.zig");
const napiWatch = watch_mod.napiWatch;

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

// ─── 모듈 등록 ───

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
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
    _ = c.napi_create_function(env, "transpile", "transpile".len, napiTranspile, null, &fn_value);
    _ = c.napi_set_named_property(env, exports, "transpile", fn_value);

    var tokenize_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "tokenize", "tokenize".len, napiTokenize, null, &tokenize_fn);
    _ = c.napi_set_named_property(env, exports, "tokenize", tokenize_fn);

    var configure_profile_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "configureProfile", "configureProfile".len, napiConfigureProfile, null, &configure_profile_fn);
    _ = c.napi_set_named_property(env, exports, "configureProfile", configure_profile_fn);

    var profile_report_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "profileReport", "profileReport".len, napiProfileReport, null, &profile_report_fn);
    _ = c.napi_set_named_property(env, exports, "profileReport", profile_report_fn);

    // TsconfigCache (#2367)
    var ctc_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "createTsconfigCache", "createTsconfigCache".len, tsconfig_cache_mod.napiCreateTsconfigCache, null, &ctc_fn);
    _ = c.napi_set_named_property(env, exports, "createTsconfigCache", ctc_fn);

    var build_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "buildSync", "buildSync".len, napiBuildSync, null, &build_sync_fn);
    _ = c.napi_set_named_property(env, exports, "buildSync", build_sync_fn);

    var build_app_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "buildAppSync", "buildAppSync".len, napiBuildAppSync, null, &build_app_sync_fn);
    _ = c.napi_set_named_property(env, exports, "buildAppSync", build_app_sync_fn);

    var prepare_app_dev_sync_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "prepareAppDevSync", "prepareAppDevSync".len, napiPrepareAppDevSync, null, &prepare_app_dev_sync_fn);
    _ = c.napi_set_named_property(env, exports, "prepareAppDevSync", prepare_app_dev_sync_fn);

    var build_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "build", "build".len, napiBuild, null, &build_fn);
    _ = c.napi_set_named_property(env, exports, "build", build_fn);

    var watch_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "watch", "watch".len, napiWatch, null, &watch_fn);
    _ = c.napi_set_named_property(env, exports, "watch", watch_fn);

    var bench_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "benchmark", "benchmark".len, benchmark_mod.napiBenchmark, null, &bench_fn);
    _ = c.napi_set_named_property(env, exports, "benchmark", bench_fn);

    return exports;
}
