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
const TsconfigCache = zntc_lib.tsconfig_cache.TsconfigCache;
const rich_diagnostic = zntc_lib.rich_diagnostic;
const diagnostic_renderer = zntc_lib.diagnostic_renderer;
const napi_render_opts: diagnostic_renderer.RenderOptions = .{ .color = false, .unicode = true };
const bundler_mod = zntc_lib.bundler;
const Bundler = bundler_mod.Bundler;
const TrackedFileSet = zntc_lib.server.TrackedFileSet;
const profile_mod = zntc_lib.profile;
const bench_mod = zntc_lib.bench;

/// Issue #1223 Phase 1: 워처 튜닝 상수.
/// - watch_poll_timeout_ms: stop_flag 체크 주기 (이벤트 워처에서도 주기적으로 깨어나기 위함).
/// - watch_debounce_ms: 첫 이벤트 이후 정적(idle) 구간 — 연속 저장 병합 윈도우.
///   debounce loop 첫 iteration 이 kqueue/inotify 에서 최소 이 시간만큼 블로킹되므로
///   HMR detect 페이즈에 그대로 더해진다. 25ms 는 VS Code / vim 의 atomic save
///   (rename + write) 사이 간격(5-15ms)을 여전히 흡수하면서 detect 비용을 절반으로.
/// - watch_debounce_max_ms: 디바운스 최대 대기 시간 — 지속 변경되는 파일에 의한 기아 방지.
const watch_poll_timeout_ms: u32 = 200;
const watch_debounce_ms: u32 = 25;
const watch_debounce_max_ms: u64 = 500;

/// 파일 내용 해시 상한 (#1233). RN 등 대형 프로젝트의 vendor 번들/asset catalog/locale
/// JSON이 수십 MB에 이를 수 있어 넉넉히 잡음. 초과 시 `util.wyhash.hashFileStreaming`이
/// size+mtime 기반 pseudo-hash로 폴백한다 — 해당 파일이 영영 리빌드 트리거되지 않는 stale
/// output 방지.
const watch_hash_max_bytes: usize = 256 * 1024 * 1024;

/// 이벤트 배열의 path들을 중복 제거 set에 병합.
/// FileWatcher.waitForChanges 결과는 다음 호출에서 무효화되므로 path를 dupe.
fn collectTouched(
    set: *std.StringHashMap(void),
    alloc: std.mem.Allocator,
    evts: []const zntc_lib.server.ChangeEvent,
) void {
    for (evts) |e| {
        if (set.contains(e.path)) continue;
        const dup = alloc.dupe(u8, e.path) catch continue;
        set.put(dup, {}) catch alloc.free(dup);
    }
}
const BundleOptions = bundler_mod.BundleOptions;
const SourceMap = zntc_lib.codegen.sourcemap;
const types_mod = zntc_lib.bundler.types;
const transformer_mod = zntc_lib.transformer.transformer;
const common = @import("napi/common.zig");
const options_mod = @import("napi/options.zig");
const c = common.c;

const native_alloc = std.heap.c_allocator;

// ─── NAPI 헬퍼 ───

const throwError = common.throwError;
const unwrapNapi = common.unwrapNapi;
const getStringArg = common.getStringArg;
const getNamedProperty = common.getNamedProperty;
const getObjectBool = common.getObjectBool;
const getObjectBoolOptional = common.getObjectBoolOptional;
const getObjectUint32 = common.getObjectUint32;
const getObjectString = common.getObjectString;
const getObjectBytes = common.getObjectBytes;
const getObjectStringArray = common.getObjectStringArray;
const parseStringArray = common.parseStringArray;
const getObjectKeyValuePairs = common.getObjectKeyValuePairs;
const getObjectKeyValuePairsWithNullable = common.getObjectKeyValuePairsWithNullable;
const setDoubleProp = common.setDoubleProp;
const setUint32Prop = common.setUint32Prop;
const setStringProp = common.setStringProp;

const LogFilterOptions = options_mod.LogFilterOptions;
const getAutoLabelMode = options_mod.getAutoLabelMode;
const parseLogFilterOptions = options_mod.parseLogFilterOptions;
const parseBuildOptions = options_mod.parseBuildOptions;
const freeOptionsTypedSlices = options_mod.freeOptionsTypedSlices;

// ─── TsconfigCache (#2367) ───

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
fn napiCreateTsconfigCache(env: c.napi_env, _: c.napi_callback_info) callconv(.c) c.napi_value {
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
fn unwrapTsconfigCache(env: c.napi_env, value: c.napi_value) ?*TsconfigCache {
    var value_type: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, value, &value_type) != c.napi_ok) return null;
    if (value_type != c.napi_object) return null;
    return unwrapNapi(TsconfigCache, env, value);
}

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
        if (unwrapTsconfigCache(env, argv[3])) |cache| {
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
    // manualChunks JS resolver — 소유 (deinit 시 TSFN release)
    napi_manual_chunks: ?*NapiManualChunksResolver = null,
    // Watch-specific
    ready_tsfn: c.napi_threadsafe_function,
    rebuild_tsfn: c.napi_threadsafe_function,
    stop_flag: std.atomic.Value(bool),
    /// Metro watchFolders 호환. 그래프 밖 감시 루트(절대/상대 경로).
    watch_roots: []const []const u8 = &.{},
    /// watch_roots 스캔 시 포함할 파일 glob (루트 기준 상대).
    watch_include: []const []const u8 = &.{},
    /// watch_roots 스캔 시 제외할 파일 glob (루트 기준 상대).
    watch_exclude: []const []const u8 = &.{},
    /// 워커 스레드에서 매 rebuild 마다 주입되는 compiled output cache.
    /// watch worker 수명 내내 유지되어 변경 안 된 모듈의 emit 을 스킵.
    compiled_cache: bundler_mod.CompiledOutputCache,

    /// Lazy sourcemap 캐시 (Issue #1727 Phase B). 구조는 rspack `MappedAssetsCache`
    /// 와 동형 — chunk-level / version-based invalidation 같은 확장은 이 struct 안으로 수용.
    sm_cache: LazySourceMapCache = .{},

    /// `.map` 파일을 디스크에 기록할지 여부. bungae 등 lazy 엔드포인트를 갖춘 dev 서버는
    /// false 로 보내 rebuild 경로의 디스크 I/O 를 완전히 제거할 수 있다. CLI 빌드는
    /// 기본 true 유지.
    emit_disk_sourcemap: bool = true,

    fn deinit(self: *WatchAsyncData) void {
        // 소유된 문자열 해제
        for (self.owned_strings.items) |s| native_alloc.free(s);
        self.owned_strings.deinit(native_alloc);
        // 배열 컨테이너 해제 (내부 문자열은 owned_strings에서 이미 해제됨)
        for (self.owned_string_arrays.items) |arr| native_alloc.free(arr);
        self.owned_string_arrays.deinit(native_alloc);
        // typed slices (define/module_specifier_map/alias) — native_alloc 소유, 명시 free (#2396).
        freeOptionsTypedSlices(&self.options);
        // NAPI 플러그인 해제
        for (self.napi_plugins.items) |np| np.deinit();
        self.napi_plugins.deinit(native_alloc);
        self.zig_plugins.deinit(native_alloc);
        if (self.napi_manual_chunks) |mc| mc.deinit();
        self.compiled_cache.deinit();
        self.sm_cache.deinit(native_alloc);
        native_alloc.destroy(self);
    }
};

/// Handle-scoped lazy sourcemap 캐시 (Issue #1727 Phase B).
///
/// rebuild 마다 bundler 가 이관한 `SourceMapBuilder` 들을 보관해 dev server 가
/// `/bundle.js.map` / `/hmr-map/:moduleId` 요청을 받으면 NAPI getter 로 JSON 을 즉석
/// 생성. HMR 경로에서 VLQ encode 29ms 를 경로 밖으로 빼낸다. rebuild (worker thread) 와
/// getter (NAPI main thread) 가 동시에 접근할 수 있어 `mutex` 로 직렬화 — builder.buf
/// 가 재사용 버퍼이므로 동시 `generateJSON` 호출도 racy.
///
/// rspack `MappedAssetsCache(FxDashMap)` 과 동형 구조. 향후 chunk-level sourcemap
/// (code splitting + HMR 조합) 이나 version-based invalidation 같은 확장은 이 struct
/// 안으로 수용하기 위해 sub-struct 로 분리.
const LazySourceMapCache = struct {
    /// 최신 rebuild 의 번들 레벨 sourcemap builder. null 이면 lazy 비활성 상태거나 초기
    /// 빌드 실패.
    bundle: ?*SourceMap.SourceMapBuilder = null,
    /// 최신 rebuild 의 모듈 id → per-module sourcemap builder. key/value 모두 caller 가
    /// 전달한 allocator 소유 — `deinit` / `clear` 가 정리한다.
    modules: std.StringHashMapUnmanaged(*SourceMap.SourceMapBuilder) = .{},
    /// swap / getter 호출을 직렬화.
    mutex: std.Thread.Mutex = .{},

    /// 현재 캐시된 bundle + module builder 들을 모두 free + 맵 clear. 내부에서 lock
    /// 하지 않으므로 caller 가 `mutex` 를 이미 잡았거나 (stop 경로처럼) 동시 접근이
    /// 없음을 보장해야 한다.
    fn clear(self: *LazySourceMapCache, allocator: std.mem.Allocator) void {
        if (self.bundle) |sm| sm.destroy(allocator);
        self.bundle = null;
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.destroy(allocator);
        }
        self.modules.clearRetainingCapacity();
    }

    /// rebuild 완료 후 builder 들을 swap. 이전 builder 는 free. **내부에서 `mutex` 를
    /// 직접 acquire** — caller 는 추가 lock 불필요.
    ///
    /// Side effect: `module_codes` 의 각 엔트리 `.sm_builder` 를 null 로 되돌린다
    /// (소유권 이전). 이후 `ModuleDevCode.freeAll` 이 double-free 없이 나머지 필드만 정리.
    fn swap(
        self: *LazySourceMapCache,
        allocator: std.mem.Allocator,
        new_bundle: ?*SourceMap.SourceMapBuilder,
        module_codes: []types_mod.ModuleDevCode,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clear(allocator);
        self.bundle = new_bundle;
        for (module_codes) |*mc| {
            const builder = mc.sm_builder orelse continue;
            const id_copy = allocator.dupe(u8, mc.id) catch {
                builder.destroy(allocator);
                mc.sm_builder = null;
                continue;
            };
            self.modules.put(allocator, id_copy, builder) catch {
                allocator.free(id_copy);
                builder.destroy(allocator);
                mc.sm_builder = null;
                continue;
            };
            mc.sm_builder = null;
        }
    }

    /// 최종 정리 — clear 후 map 자체도 deinit.
    fn deinit(self: *LazySourceMapCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.modules.deinit(allocator);
    }
};

/// onReady 콜백에 전달할 이벤트 데이터
const WatchReadyEvent = struct {
    files: usize,
    bytes: usize,
};

/// HMR rebuild phase 별 소요시간 (밀리초). Issue #1223 관측성.
///
/// 기본 phase (`detect_ms`/`graph_ms`/`link_ms`/`shake_ms`/`emit_ms`/`delta_ms`/`total_ms`)
/// 는 profile 비활성 상태에서도 항상 측정 (bundler `BundleTimings` 기반 — 가벼움).
///
/// Sub-phase (`scan_ms`/`parse_ms`/`resolve_ms`/`semantic_ms`/`transform_ms`/`codegen_ms`/
/// `metadata_ms`) 는 `ZNTC_PROFILE=<cat>` / `BUNGAE_HMR_PROFILE=1` / `BundleOptions.profile`
/// 활성 상태에서만 의미있는 값. 비활성 시 모두 0.
///
/// 이름 매핑 이력: 2026-04-22 이전의 `parse_ms` / `semantic_ms` 는 실제로는 `graph_ns` /
/// `link+shake` 를 담았던 레거시 이름이었다. 이름=의미 일치를 위해 기본 phase 에서
/// `parse_ms`/`semantic_ms` 를 제거하고 `graph_ms`/`link_ms`/`shake_ms` 로 분리.
/// Sub-phase 의 `parse_ms`/`semantic_ms` 는 이제 진짜 parser/analyzer 시간을 의미.
///
/// Sub-phase 필드는 `profile.Category` enum 과 1:1 매핑. Category 에 phase 추가 시
/// 동기화 위치: (1) 이 struct, (2) `fields[]` 배열 (rebuild 이벤트 변환), (3) phase_durations
/// 초기화, (4) `packages/core/index.ts` TS 타입, (5) docs/HMR.md / docs/DEBUG.md.
const PhaseDurations = struct {
    // ── 기본 phase (항상 측정) ──
    detect_ms: f64 = 0,
    graph_ms: f64 = 0,
    link_ms: f64 = 0,
    shake_ms: f64 = 0,
    emit_ms: f64 = 0,
    delta_ms: f64 = 0,
    total_ms: f64 = 0,

    // ── Sub-phase (ZNTC_PROFILE=<cat> 활성 시에만 값 기록) ──
    scan_ms: f64 = 0,
    parse_ms: f64 = 0,
    resolve_ms: f64 = 0,
    semantic_ms: f64 = 0,
    transform_ms: f64 = 0,
    codegen_ms: f64 = 0,
    metadata_ms: f64 = 0,

    // ── Graph sub-phase (graph 내부 분해) ──
    graph_build_ms: f64 = 0,
    graph_worker_ms: f64 = 0,
    graph_discover_ms: f64 = 0,
    graph_finalize_ms: f64 = 0,

    // ── Emit sub-phase (emit 내부 분해) ──
    emit_polyfill_ms: f64 = 0,
    emit_refresh_ms: f64 = 0,
    emit_output_ms: f64 = 0,
    emit_metafile_ms: f64 = 0,
    emit_css_ms: f64 = 0,

    // ── emit_output 내부 분해 (emitter.emitWithTreeShaking) ──
    emit_prelude_ms: f64 = 0,
    emit_module_pass_ms: f64 = 0,
    emit_concat_ms: f64 = 0,
    emit_sourcemap_finalize_ms: f64 = 0,
};

/// onRebuild 콜백에 전달할 이벤트 데이터
const WatchRebuildEvent = struct {
    success: bool,
    // 성공 시
    changed: ?[]const []const u8 = null,
    graph_changed: bool = false,
    updates: ?[]const ModuleUpdate = null,
    bytes: usize = 0,
    phase_durations: ?PhaseDurations = null,
    /// 증분 그래프에서 재파싱된 모듈 수 (Issue #1223 Phase 2).
    reparsed_modules: ?usize = null,
    // 실패 시
    error_msg: ?[]const u8 = null,

    const ModuleUpdate = struct {
        id: []const u8,
        code: []const u8,
        /// 모듈별 standalone source map (V3 JSON). null이면 미수집 (Issue #1248).
        map: ?[]const u8 = null,
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
                if (u.map) |m| native_alloc.free(m);
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
                if (u.map) |m| {
                    var js_map: c.napi_value = undefined;
                    _ = c.napi_create_string_utf8(env, m.ptr, m.len, &js_map);
                    _ = c.napi_set_named_property(env, js_u, "map", js_map);
                }
                _ = c.napi_set_element(env, js_updates, @intCast(i), js_u);
            }
            _ = c.napi_set_named_property(env, js_event, "updates", js_updates);
        }

        // bytes
        var js_bytes: c.napi_value = undefined;
        _ = c.napi_create_int64(env, @intCast(event.bytes), &js_bytes);
        _ = c.napi_set_named_property(env, js_event, "bytes", js_bytes);

        if (event.phase_durations) |pd| {
            var js_pd: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_pd);
            const fields = [_]struct { name: [:0]const u8, value: f64 }{
                // 기본 phase (항상 측정).
                .{ .name = "detect", .value = pd.detect_ms },
                .{ .name = "graph", .value = pd.graph_ms },
                .{ .name = "link", .value = pd.link_ms },
                .{ .name = "shake", .value = pd.shake_ms },
                .{ .name = "emit", .value = pd.emit_ms },
                .{ .name = "delta", .value = pd.delta_ms },
                .{ .name = "total", .value = pd.total_ms },
                // Sub-phase (ZNTC_PROFILE=<cat> 활성 시 의미있는 값, 아니면 0).
                .{ .name = "scan", .value = pd.scan_ms },
                .{ .name = "parse", .value = pd.parse_ms },
                .{ .name = "resolve", .value = pd.resolve_ms },
                .{ .name = "semantic", .value = pd.semantic_ms },
                .{ .name = "transform", .value = pd.transform_ms },
                .{ .name = "codegen", .value = pd.codegen_ms },
                .{ .name = "metadata", .value = pd.metadata_ms },
                // Graph sub-phase.
                .{ .name = "graphBuild", .value = pd.graph_build_ms },
                .{ .name = "graphWorker", .value = pd.graph_worker_ms },
                .{ .name = "graphDiscover", .value = pd.graph_discover_ms },
                .{ .name = "graphFinalize", .value = pd.graph_finalize_ms },
                // Emit sub-phase (bundler.zig 수준).
                .{ .name = "emitPolyfill", .value = pd.emit_polyfill_ms },
                .{ .name = "emitRefresh", .value = pd.emit_refresh_ms },
                .{ .name = "emitOutput", .value = pd.emit_output_ms },
                .{ .name = "emitMetafile", .value = pd.emit_metafile_ms },
                .{ .name = "emitCss", .value = pd.emit_css_ms },
                // emit_output 내부 (emitter.emitWithTreeShaking 분해).
                .{ .name = "emitPrelude", .value = pd.emit_prelude_ms },
                .{ .name = "emitModulePass", .value = pd.emit_module_pass_ms },
                .{ .name = "emitConcat", .value = pd.emit_concat_ms },
                .{ .name = "emitSourcemapFinalize", .value = pd.emit_sourcemap_finalize_ms },
            };
            for (fields) |f| {
                var js_num: c.napi_value = undefined;
                _ = c.napi_create_double(env, f.value, &js_num);
                _ = c.napi_set_named_property(env, js_pd, f.name.ptr, js_num);
            }
            _ = c.napi_set_named_property(env, js_event, "phaseDurations", js_pd);
        }

        if (event.reparsed_modules) |n| {
            var js_n: c.napi_value = undefined;
            _ = c.napi_create_int64(env, @intCast(n), &js_n);
            _ = c.napi_set_named_property(env, js_event, "reparsedModules", js_n);
        }
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

/// watchFolders 루트를 재귀 스캔해 TrackedFileSet에 등록.
/// tracked.addPath가 내부에서 key를 dupe하므로 visitor는 false로 walker가 free하게 둔다.
fn addWatchRootFiles(
    allocator: std.mem.Allocator,
    root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    tracked: *zntc_lib.server.TrackedFileSet,
    count: *usize,
) void {
    const Ctx = struct { tracked: *zntc_lib.server.TrackedFileSet, count: *usize };
    const visit = struct {
        fn f(ctx: Ctx, full_path: []const u8) bool {
            if (ctx.tracked.addPath(full_path, true)) ctx.count.* += 1;
            return false;
        }
    }.f;
    zntc_lib.server.watch_scan.scanRoot(
        allocator,
        root,
        .{ .include = include, .exclude = exclude },
        Ctx{ .tracked = tracked, .count = count },
        visit,
    ) catch {};
}

/// 단일 파일 빌드 산출물의 `.map` 을 디스크에 기록. lazy 경로 (`sourcemap_json == null`)
/// 이거나 `enabled == false` 이면 no-op. 실패는 silently ignore — dev server 경로에서
/// disk I/O 장애가 빌드 흐름을 막으면 안 됨.
fn writeSourcemapFile(
    allocator: std.mem.Allocator,
    output_filename: []const u8,
    sourcemap_json: ?[]const u8,
    enabled: bool,
) void {
    if (!enabled) return;
    const sm = sourcemap_json orelse return;
    const map_path = std.fmt.allocPrint(allocator, "{s}.map", .{output_filename}) catch return;
    defer allocator.free(map_path);
    const sm_file = std.fs.cwd().createFile(map_path, .{}) catch return;
    defer sm_file.close();
    sm_file.writeAll(sm) catch {};
}

fn watchWorkerThread(async_data: *WatchAsyncData) void {
    const allocator = native_alloc;
    const bundle_opts = async_data.options;

    // Issue #1223 Phase 2: 초기 빌드에도 PersistentModuleStore 전달.
    // 초기 빌드에서 store가 채워져야 첫 리빌드가 캐시 히트 경로로 진입한다.
    const module_store_mod = bundler_mod.module_store;
    const ResolveCache = bundler_mod.ResolveCache;
    var persistent_store = module_store_mod.PersistentModuleStore.init(allocator);
    defer persistent_store.deinit();

    var initial_opts = bundle_opts;
    initial_opts.module_store = &persistent_store;
    initial_opts.compiled_cache = &async_data.compiled_cache;
    // rebuild 루프와 동일한 collect_module_codes 로 맞춘다 — options_hash 가 같아야
    // first-build 의 cache put 이 첫 rebuild 에서 그대로 hit 된다.
    initial_opts.collect_module_codes = bundle_opts.dev_mode;
    // Lazy sourcemap (Issue #1727 Phase B): dev watch 세션에서는 initial/rebuild 모두
    // builder 를 handle 에 캐시해 `/bundle.js.map`, `/hmr-map/:id` 요청을 즉석 서빙.
    // rebuild 경로의 `emit_sourcemap_finalize` 29ms 를 HMR latency 밖으로 빼낸다.
    if (bundle_opts.dev_mode and bundle_opts.sourcemap.enable) initial_opts.sourcemap.lazy = true;

    var bundler = Bundler.init(allocator, initial_opts);
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

    // Lazy sourcemap (Issue #1727 Phase B): initial build 의 builder 들을 handle 로 이관.
    // `swapSourceMapCache` 가 각 `mc.sm_builder` 를 null 로 되돌리므로 `result.deinit` 의
    // `ModuleDevCode.freeAll` 이 이중 해제하지 않는다. bundle builder 도 같은 규칙.
    if (initial_opts.sourcemap.lazy) {
        const mut_codes: []types_mod.ModuleDevCode = if (result.module_dev_codes) |codes|
            @constCast(codes)
        else
            &.{};
        async_data.sm_cache.swap(native_alloc, result.sourcemap_builder, mut_codes);
        result.sourcemap_builder = null;
    }

    var persistent_resolve_cache = ResolveCache.init(allocator, .{
        .platform = bundle_opts.platform,
        .external_patterns = bundle_opts.external,
        .custom_conditions = bundle_opts.conditions,
        .preserve_symlinks = bundle_opts.preserve_symlinks,
        .alias = bundle_opts.alias,
        .fallback = bundle_opts.fallback,
        .resolve_extensions = bundle_opts.resolve_extensions,
        .main_fields = bundle_opts.main_fields,
        .packages_external = bundle_opts.packages_external,
        .node_paths = bundle_opts.node_paths,
    });
    defer persistent_resolve_cache.deinit();

    // Issue #1223 Phase 1: 이벤트 기반 파일 워처 (kqueue/inotify, mtime 폴백).
    // 실패 시 워치 스레드 진입 직전에 종료한다.
    var tracked = TrackedFileSet.init(allocator, watch_hash_max_bytes) catch |err| {
        const event = allocator.create(WatchRebuildEvent) catch {
            _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
            _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
            async_data.deinit();
            return;
        };
        const err_name: [:0]const u8 = @errorName(err);
        event.* = .{ .success = false, .error_msg = allocator.dupe(u8, err_name) catch null };
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return;
    };
    defer tracked.deinit();

    var initial_watch_count: usize = 0;
    if (bundle_opts.entry_points.len > 0 and
        tracked.addPath(bundle_opts.entry_points[0], true))
    {
        initial_watch_count += 1;
    }
    if (result.module_paths) |paths| {
        for (paths) |p| {
            if (tracked.addPath(p, true)) initial_watch_count += 1;
        }
    }

    // watchFolders: 번들 그래프 밖 루트를 재귀 스캔해 tracked에 추가
    for (async_data.watch_roots) |root| {
        addWatchRootFiles(
            allocator,
            root,
            async_data.watch_include,
            async_data.watch_exclude,
            &tracked,
            &initial_watch_count,
        );
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
                writeSourcemapFile(allocator, bundle_opts.output_filename, result.sourcemap, async_data.emit_disk_sourcemap);
            } else |_| {}
        }
    }

    // ready 이벤트 전송
    {
        const ready_event = allocator.create(WatchReadyEvent) catch return;
        ready_event.* = .{
            .files = initial_watch_count,
            .bytes = initial_bytes,
        };
        if (c.napi_call_threadsafe_function(async_data.ready_tsfn, @ptrCast(ready_event), c.napi_tsfn_blocking) != c.napi_ok) {
            allocator.destroy(ready_event);
        }
    }

    // Issue #1223 Phase 1: 이벤트 기반 워처 + 디바운스 + content hash 필터링.
    while (!async_data.stop_flag.load(.acquire)) {
        const first_events = tracked.waitForChanges(watch_poll_timeout_ms) catch &[_]zntc_lib.server.ChangeEvent{};
        if (async_data.stop_flag.load(.acquire)) break;

        var total_timer: ?std.time.Timer = std.time.Timer.start() catch null;
        var detect_timer: ?std.time.Timer = std.time.Timer.start() catch null;

        var touched: std.StringHashMap(void) = .init(allocator);
        defer {
            var kit = touched.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            touched.deinit();
        }
        collectTouched(&touched, allocator, first_events);

        if (touched.count() == 0) continue;

        // 디바운스: idle 50ms 확보까지 드레인. 지속 변경되는 파일로 인한 기아를 막기 위해
        // 첫 이벤트로부터 watch_debounce_max_ms 초과 시 강제 종료.
        var debounce_timer: ?std.time.Timer = std.time.Timer.start() catch null;
        while (!async_data.stop_flag.load(.acquire)) {
            const more = tracked.waitForChanges(watch_debounce_ms) catch break;
            if (more.len == 0) break;
            collectTouched(&touched, allocator, more);
            if (debounce_timer) |*t| {
                if (t.read() / std.time.ns_per_ms > watch_debounce_max_ms) break;
            }
        }
        if (async_data.stop_flag.load(.acquire)) break;

        // content hash 필터링.
        var changed_files: std.ArrayList([]const u8) = .empty;
        defer changed_files.deinit(allocator);
        var tkit = touched.keyIterator();
        while (tkit.next()) |pkey| {
            if (tracked.markIfChanged(pkey.*)) {
                changed_files.append(allocator, pkey.*) catch {};
            }
        }
        const detect_ns: u64 = if (detect_timer) |*t| t.read() else 0;

        if (changed_files.items.len == 0) continue;

        // Profile counters reset — 이전 rebuild 의 누적치가 이월되지 않도록.
        // mask 와 level 은 유지 (`ZNTC_PROFILE=hmr` 등의 활성 상태는 보존).
        // profile 비활성 상태에선 skip — 불필요한 memset 회피.
        if (profile_mod.anyEnabled()) profile_mod.resetCounters();

        // 재번들 — 증분 빌드: persistent_store + persistent_resolve_cache + compiled_cache 재사용
        var incremental_opts = bundle_opts;
        incremental_opts.collect_module_codes = bundle_opts.dev_mode;
        incremental_opts.module_store = &persistent_store;
        incremental_opts.compiled_cache = &async_data.compiled_cache;
        // Watcher-driven mtime cache (Issue #1727 §3): changed 집합을 graph 에 넘겨
        // 나머지 모듈 stat 을 skip 한다. detect 단계에서 이미 content hash 필터링까지
        // 통과한 `touched` 를 그대로 재사용 — StringHashMap 포인터라 복사 없음.
        incremental_opts.changed_files = &touched;
        // Lazy sourcemap (Issue #1727 Phase B): initial build 와 동일 경로 유지. cache 키
        // 일치 필수 — initial 에서 lazy=true 로 put 된 엔트리가 rebuild 에서 hit 해야 함.
        if (bundle_opts.dev_mode and bundle_opts.sourcemap.enable) incremental_opts.sourcemap.lazy = true;
        // dev_mode + collect_module_codes 인 incremental rebuild 는 풀 bundle output 을
        // 다시 concat 할 필요가 없다 — RN HMR client 는 dev_codes 만 사용. wall 시간이
        // emit_concat (~38ms) + emit_sourcemap_finalize (~19ms) 를 절감한다.
        if (bundle_opts.dev_mode and bundle_opts.collect_module_codes) incremental_opts.skip_bundle_output = true;
        var rebundler = Bundler.initWithResolveCache(allocator, incremental_opts, &persistent_resolve_cache);
        defer rebundler.deinit();

        var rebuild_result = rebundler.bundle() catch |err| {
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

        async_data.compiled_cache.logStats("");

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
                    // lazy 는 `rebuild_result.sourcemap == null` 이라 helper 안에서 자동 skip.
                    // eager + `emit_disk_sourcemap=false` 도 skip — bungae 처럼 dev server 가
                    // 직접 lazy 라우트를 제공하는 경우.
                    writeSourcemapFile(allocator, bundle_opts.output_filename, rebuild_result.sourcemap, async_data.emit_disk_sourcemap);
                } else |_| {}
            }
        }

        // Lazy sourcemap (Issue #1727): rebuild 산출 builder 들을 handle 로 swap.
        // 이전 rebuild 의 builder 는 `swapSourceMapCache` 내부에서 free.
        if (incremental_opts.sourcemap.lazy) {
            const mut_codes: []types_mod.ModuleDevCode = if (rebuild_result.module_dev_codes) |codes|
                @constCast(codes)
            else
                &.{};
            async_data.sm_cache.swap(native_alloc, rebuild_result.sourcemap_builder, mut_codes);
            rebuild_result.sourcemap_builder = null;
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
        var delta_timer = std.time.Timer.start() catch null;
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
                // 재파싱된 모듈의 path 집합 — cache-hit 모듈의 phantom update 필터용.
                // canonical-name 배정이 rebuild 간 비결정적으로 움직여, 소스가 안 변한
                // 모듈의 emit 결과도 cache 와 달라져 HMR payload 에 섞여 들어오면
                // runtime 의 `__zntc_apply_update` 가 hot-accept 없는 모듈 (React 내부
                // 등) 에 대해 `__zntc_reload` 를 호출해 첫 rebuild 가 full reload 로
                // 끝나는 문제가 있었다 (#번개 실측). reparsed_paths 가 있으면 그
                // 교집합만 업데이트로 올린다.
                var reparsed_set: std.StringHashMap(void) = .init(allocator);
                defer reparsed_set.deinit();
                if (rebuild_result.reparsed_paths) |paths| {
                    for (paths) |p| reparsed_set.put(p, {}) catch {};
                }
                const use_reparsed_filter = reparsed_set.count() > 0;

                // 단일 패스: 캐시와 비교하여 변경된 모듈만 수집
                var update_list: std.ArrayList(WatchRebuildEvent.ModuleUpdate) = .empty;
                for (dev_codes) |dc| {
                    const cached = module_code_cache.get(dc.id);
                    if (cached == null or !std.mem.eql(u8, cached.?, dc.code)) {
                        // 재파싱 목록이 있을 때만 필터 적용. 첫 증분 빌드 이후 캐시가
                        // 안정화되면 자연히 줄어들므로 후속 rebuild 에선 필터가 무해.
                        if (use_reparsed_filter and !reparsed_set.contains(dc.id)) continue;

                        const id_copy = allocator.dupe(u8, dc.id) catch continue;
                        const code_copy = allocator.dupe(u8, dc.code) catch {
                            allocator.free(id_copy);
                            continue;
                        };
                        const map_copy: ?[]const u8 = if (dc.map) |m|
                            (allocator.dupe(u8, m) catch null)
                        else
                            null;
                        update_list.append(allocator, .{ .id = id_copy, .code = code_copy, .map = map_copy }) catch {
                            allocator.free(id_copy);
                            allocator.free(code_copy);
                            if (map_copy) |m| allocator.free(m);
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
        const delta_ns: u64 = if (delta_timer) |*t| t.read() else 0;
        const total_ns: u64 = if (total_timer) |*t| t.read() else 0;

        const nsToMs = bundler_mod.BundleResult.nsToMs;
        event.phase_durations = .{
            // 기본 phase — BundleTimings 기반 (profile 비활성에서도 항상 측정).
            // 필드 이름과 실제 값이 정확히 일치.
            .detect_ms = nsToMs(detect_ns),
            .graph_ms = nsToMs(rebuild_result.timings.graph_ns),
            .link_ms = nsToMs(rebuild_result.timings.link_ns),
            .shake_ms = nsToMs(rebuild_result.timings.shake_ns),
            .emit_ms = nsToMs(rebuild_result.timings.emit_ns),
            .delta_ms = nsToMs(delta_ns),
            .total_ms = nsToMs(total_ns),

            // Sub-phase — profile 활성 시에만 의미있는 값. 비활성이면 0.
            // graph/link/shake 는 기본 phase 와 동일 의미라 중복 노출 안 함.
            .scan_ms = nsToMs(profile_mod.totalNs(.scan)),
            .parse_ms = nsToMs(profile_mod.totalNs(.parse)),
            .resolve_ms = nsToMs(profile_mod.totalNs(.resolve)),
            .semantic_ms = nsToMs(profile_mod.totalNs(.semantic)),
            .transform_ms = nsToMs(profile_mod.totalNs(.transform)),
            .codegen_ms = nsToMs(profile_mod.totalNs(.codegen)),
            .metadata_ms = nsToMs(profile_mod.totalNs(.metadata)),

            // Graph / Emit sub-phase — bundler.zig 내부 단계 분해.
            .graph_build_ms = nsToMs(profile_mod.totalNs(.graph_build)),
            .graph_worker_ms = nsToMs(profile_mod.totalNs(.graph_worker)),
            .graph_discover_ms = nsToMs(profile_mod.totalNs(.graph_discover)),
            .graph_finalize_ms = nsToMs(profile_mod.totalNs(.graph_finalize)),
            .emit_polyfill_ms = nsToMs(profile_mod.totalNs(.emit_polyfill)),
            .emit_refresh_ms = nsToMs(profile_mod.totalNs(.emit_refresh)),
            .emit_output_ms = nsToMs(profile_mod.totalNs(.emit_output)),
            .emit_metafile_ms = nsToMs(profile_mod.totalNs(.emit_metafile)),
            .emit_css_ms = nsToMs(profile_mod.totalNs(.emit_css)),
            .emit_prelude_ms = nsToMs(profile_mod.totalNs(.emit_prelude)),
            .emit_module_pass_ms = nsToMs(profile_mod.totalNs(.emit_module_pass)),
            .emit_concat_ms = nsToMs(profile_mod.totalNs(.emit_concat)),
            .emit_sourcemap_finalize_ms = nsToMs(profile_mod.totalNs(.emit_sourcemap_finalize)),
        };
        event.reparsed_modules = rebuild_result.reparsed_modules;

        // rebuild 이벤트 전송
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }

        // Issue #1223 Phase 1: diff 기반 재-싱크.
        // 모듈 경로가 변하지 않으면 kqueue/inotify 갱신 없이 기존 상태 재사용.
        // 삭제된 모듈의 content_hash 엔트리도 함께 정리하여 무한 증가 방지.
        var desired: std.StringHashMap(void) = .init(allocator);
        defer desired.deinit();
        if (bundle_opts.entry_points.len > 0) {
            desired.put(bundle_opts.entry_points[0], {}) catch {};
        }
        if (rebuild_result.module_paths) |paths| {
            for (paths) |p| desired.put(p, {}) catch {};
        }

        // stale 엔트리 제거 — 워처와 해시 캐시 양쪽에서.
        {
            var stale: std.ArrayList([]const u8) = .empty;
            defer stale.deinit(allocator);
            var hit = tracked.keyIterator();
            while (hit.next()) |k| {
                if (!desired.contains(k.*)) stale.append(allocator, k.*) catch {};
            }
            for (stale.items) |k| tracked.removePath(k);
        }

        // 추가된 경로만 addPath + 해시. 기존 경로는 kqueue/inotify에 이미 등록됨.
        var dit = desired.keyIterator();
        while (dit.next()) |pkey| {
            if (tracked.contains(pkey.*)) continue;
            _ = tracked.addPath(pkey.*, false);
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

/// handle.getBundleSourceMap() — 번들 전체 sourcemap JSON 을 lazy 생성해 반환.
/// handle 에 캐시된 `latest_bundle_sm` builder 가 있으면 `generateJSON` 을 호출해 V3 JSON
/// 문자열을 NAPI string 으로 돌려준다. sourcemap 비활성/미캐시/stop 후에는 null.
/// `sm_mutex` 로 rebuild swap 및 다른 getter 호출과 직렬화 (builder.buf 재진입 금지).
fn napiWatchGetBundleSourceMap(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 0;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, null, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get this");
    }

    const async_data = unwrapNapi(WatchAsyncData, env, this) orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    async_data.sm_cache.mutex.lock();
    defer async_data.sm_cache.mutex.unlock();

    const builder = async_data.sm_cache.bundle orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    const json = builder.generateJSON(async_data.options.output_filename) catch |err| {
        return throwError(env, @errorName(err));
    };

    var js_str: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, json.ptr, json.len, &js_str) != c.napi_ok) {
        return throwError(env, "failed to create string");
    }
    return js_str;
}

/// handle.getHmrSourceMap(moduleId) — per-module sourcemap JSON 을 lazy 생성해 반환.
/// 최신 rebuild 에서 수집된 모듈별 builder 중 `moduleId` 에 해당하는 것을 찾아 `generateJSON`.
/// 모듈이 최신 rebuild 에 포함되지 않았거나 sourcemap 비활성이면 null.
fn napiWatchGetHmrSourceMap(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "getHmrSourceMap requires moduleId argument");

    const async_data = unwrapNapi(WatchAsyncData, env, this) orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    const module_id = getStringArg(env, argv[0], native_alloc) orelse return throwError(env, "moduleId is empty");
    defer native_alloc.free(module_id);

    async_data.sm_cache.mutex.lock();
    defer async_data.sm_cache.mutex.unlock();

    const builder = async_data.sm_cache.modules.get(module_id) orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    const json = builder.generateJSON(module_id) catch |err| {
        return throwError(env, @errorName(err));
    };

    var js_str: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, json.ptr, json.len, &js_str) != c.napi_ok) {
        return throwError(env, "failed to create string");
    }
    return js_str;
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
        .compiled_cache = bundler_mod.CompiledOutputCache.init(native_alloc),
    };

    // watchFolders/watchInclude/watchExclude 파싱 (parseBuildOptions 바깥에서 수집)
    inline for (.{
        .{ "watchFolders", "watch_roots" },
        .{ "watchInclude", "watch_include" },
        .{ "watchExclude", "watch_exclude" },
    }) |pair| {
        if (getObjectStringArray(env, argv[0], pair[0], native_alloc)) |arr| {
            const ok = blk: {
                for (arr) |s| async_data.owned_strings.append(native_alloc, s) catch break :blk false;
                async_data.owned_string_arrays.append(native_alloc, arr) catch break :blk false;
                break :blk true;
            };
            if (!ok) {
                native_alloc.destroy(async_data);
                return throwError(env, "OutOfMemory");
            }
            @field(async_data.*, pair[1]) = arr;
        }
    }

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
        _ = c.napi_create_string_utf8(env, "zntc_watch_plugin", "zntc_watch_plugin".len, &resource_name_str);
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
    // `emitDiskSourcemap` 옵션 (기본 true) — bungae 등 lazy 라우트를 갖춘 dev server 는
    // false 로 보내 rebuild 경로의 `.map` 디스크 I/O 를 완전히 제거한다.
    async_data.emit_disk_sourcemap = getObjectBool(env, argv[0], "emitDiskSourcemap", true);

    // onReady 콜백 추출
    const on_ready_fn = getNamedProperty(env, argv[0], "onReady");

    // onRebuild 콜백 추출
    const on_rebuild_fn = getNamedProperty(env, argv[0], "onRebuild");

    // onReady TSFN 생성
    {
        var resource_name: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zntc_watch_ready", "zntc_watch_ready".len, &resource_name);
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
        _ = c.napi_create_string_utf8(env, "zntc_watch_rebuild", "zntc_watch_rebuild".len, &resource_name);
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

    // Lazy sourcemap getter 2 개 추가 (Issue #1727 Phase B).
    // dev server (bungae 등) 가 `/bundle.js.map` / `/hmr-map/:id` 요청받으면 호출.
    var get_bundle_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "getBundleSourceMap", "getBundleSourceMap".len, napiWatchGetBundleSourceMap, null, &get_bundle_fn);
    _ = c.napi_set_named_property(env, js_handle, "getBundleSourceMap", get_bundle_fn);

    var get_hmr_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "getHmrSourceMap", "getHmrSourceMap".len, napiWatchGetHmrSourceMap, null, &get_hmr_fn);
    _ = c.napi_set_named_property(env, js_handle, "getHmrSourceMap", get_hmr_fn);

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
    _ = c.napi_create_function(env, "createTsconfigCache", "createTsconfigCache".len, napiCreateTsconfigCache, null, &ctc_fn);
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
    _ = c.napi_create_function(env, "benchmark", "benchmark".len, napiBenchmark, null, &bench_fn);
    _ = c.napi_set_named_property(env, exports, "benchmark", bench_fn);

    return exports;
}

// ─── benchmark 함수 (CLI `zntc bench` 의 NAPI 대응) ───

/// benchmark(optionsObj) → { phases: { <name>: { mean_ms, median_ms, p95_ms, p99_ms, min_ms, max_ms, stddev_ms, samples } } }
///
/// optionsObj:
/// - source: string (source code, 또는)
/// - file: string (파일 경로)
/// - filename: string (source 와 함께, 확장자 감지용)
/// - phases: string[] (측정할 category 목록, required)
/// - iterations: number (default 100)
/// - warmup: number (default 10)
fn napiBenchmark(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "benchmark requires an options object");

    const opts_obj = argv[0];

    // source or file
    var arena = std.heap.ArenaAllocator.init(native_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const filename = getObjectString(env, opts_obj, "filename", arena_alloc) orelse
        arena_alloc.dupe(u8, "input.js") catch return throwError(env, "OutOfMemory");

    const source_owned: []const u8 = blk: {
        if (getObjectString(env, opts_obj, "source", arena_alloc)) |s| break :blk s;
        if (getObjectString(env, opts_obj, "file", arena_alloc)) |path| {
            const loaded = std.fs.cwd().readFileAlloc(arena_alloc, path, 100 * 1024 * 1024) catch {
                return throwError(env, "benchmark: cannot read file");
            };
            break :blk loaded;
        }
        return throwError(env, "benchmark requires 'source' or 'file' option");
    };

    // phases
    const phase_names = getObjectStringArray(env, opts_obj, "phases", arena_alloc) orelse
        return throwError(env, "benchmark requires 'phases' (string array)");
    if (phase_names.len == 0) return throwError(env, "benchmark: 'phases' must be non-empty");

    var phase_cats: std.ArrayList(profile_mod.Category) = .empty;
    defer phase_cats.deinit(arena_alloc);
    for (phase_names) |name| {
        const cat = profile_mod.Category.fromString(name) orelse {
            return throwError(env, "benchmark: unknown phase name");
        };
        phase_cats.append(arena_alloc, cat) catch return throwError(env, "OutOfMemory");
    }

    const iterations = getObjectUint32(env, opts_obj, "iterations", 100);
    const warmup = getObjectUint32(env, opts_obj, "warmup", 10);
    if (iterations == 0) return throwError(env, "benchmark: 'iterations' must be >= 1");

    // Benchmark 실행
    const Ctx = struct {
        source: []const u8,
        filename: []const u8,
        fn run(a: std.mem.Allocator, raw_ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            var r = transpile_mod.transpileWithCallback(a, self.source, self.filename, .{}, null) catch return;
            r.deinit(a);
        }
    };
    var ctx: Ctx = .{ .source = source_owned, .filename = filename };
    var samples = bench_mod.runBenchmark(arena_alloc, phase_cats.items, iterations, warmup, Ctx.run, &ctx) catch {
        return throwError(env, "benchmark: runner failed");
    };
    defer samples.deinit(arena_alloc);

    // 결과 객체 구성: { phases: { <name>: PhaseStats-flat } }
    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) return throwError(env, "failed to create result");

    var js_phases: c.napi_value = undefined;
    _ = c.napi_create_object(env, &js_phases);
    _ = c.napi_set_named_property(env, js_result, "phases", js_phases);

    for (phase_names, 0..) |name, i| {
        const stats = bench_mod.PhaseStats.fromSamples(samples.per_phase[i].items);
        var js_stats: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_stats);
        setDoubleProp(env, js_stats, "mean_ms", stats.meanMs());
        setDoubleProp(env, js_stats, "median_ms", stats.medianMs());
        setDoubleProp(env, js_stats, "p95_ms", stats.p95Ms());
        setDoubleProp(env, js_stats, "p99_ms", stats.p99Ms());
        setDoubleProp(env, js_stats, "min_ms", stats.minMs());
        setDoubleProp(env, js_stats, "max_ms", stats.maxMs());
        setDoubleProp(env, js_stats, "stddev_ms", stats.stddevMs());

        var js_samples: c.napi_value = undefined;
        _ = c.napi_create_uint32(env, @intCast(stats.samples), &js_samples);
        _ = c.napi_set_named_property(env, js_stats, "samples", js_samples);

        var key_buf: [128]u8 = undefined;
        if (name.len >= key_buf.len) continue;
        @memcpy(key_buf[0..name.len], name);
        key_buf[name.len] = 0;
        _ = c.napi_set_named_property(env, js_phases, @ptrCast(&key_buf), js_stats);
    }

    return js_result;
}
