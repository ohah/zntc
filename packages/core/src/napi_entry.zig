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

/// Bun 스타일 crash report: NAPI addon에서 panic이 터지면 Node 프로세스 전체가
/// 죽는다 — 그 전에 ZTS 배너 + 이슈 URL을 찍어 사용자가 신고하기 쉽게 한다.
pub const panic = zts_lib.crash_handler.panic;
const transpile_mod = zts_lib.transpile;
const rich_diagnostic = zts_lib.rich_diagnostic;
const diagnostic_renderer = zts_lib.diagnostic_renderer;
const napi_render_opts: diagnostic_renderer.RenderOptions = .{ .color = false, .unicode = true };
const bundler_mod = zts_lib.bundler;
const Bundler = bundler_mod.Bundler;
const TrackedFileSet = zts_lib.server.TrackedFileSet;
const profile_mod = zts_lib.profile;
const bench_mod = zts_lib.bench;

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
    evts: []const zts_lib.server.ChangeEvent,
) void {
    for (evts) |e| {
        if (set.contains(e.path)) continue;
        const dup = alloc.dupe(u8, e.path) catch continue;
        set.put(dup, {}) catch alloc.free(dup);
    }
}
const BundleOptions = bundler_mod.BundleOptions;
const Platform = zts_lib.codegen.codegen.Platform;
const JsxRuntime = zts_lib.codegen.codegen.JsxRuntime;
const EmitFormat = bundler_mod.emitter.EmitOptions.Format;
const SourceMap = zts_lib.codegen.sourcemap;
const types_mod = zts_lib.bundler.types;
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

// ─── transpile 함수 ───

/// transpile(source, filename, optionsJson)
/// optionsJson: TranspileOptionsDto JSON payload (camelCase 키)
/// → { code: string, map?: string, errors?: string }
fn napiTranspile(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 3;
    var argv: [3]c.napi_value = undefined;
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
        native_alloc.dupe(u8, "input.ts") catch {
        return throwError(env, "OutOfMemory");
    };
    defer native_alloc.free(filename);

    // optionsJson (선택) + 파싱된 문자열의 수명을 위한 arena
    var opts_arena = std.heap.ArenaAllocator.init(native_alloc);
    defer opts_arena.deinit();
    const opts_alloc = opts_arena.allocator();

    const opts_json: []const u8 = if (argc > 2) (getStringArg(env, argv[2], opts_alloc) orelse "{}") else "{}";

    const options = transpile_mod.optionsFromJson(opts_alloc, opts_json) catch {
        return throwError(env, "invalid options JSON");
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

/// bool 필드의 tri-state 조회 — 키가 없으면 null, 있으면 실제 값.
/// tsconfig 머지 시 "JS 가 명시적으로 false" 와 "JS 가 생략" 을 구분하기 위해 사용.
fn getObjectBoolOptional(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8) ?bool {
    const val = getNamedProperty(env, obj, key) orelse return null;
    var result: bool = false;
    if (c.napi_get_value_bool(env, val, &result) != c.napi_ok) return null;
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
/// 빈 배열은 명시적으로 빈 slice 반환 (caller 가 "0개" 와 "invalid" 를 구분 가능).
fn parseStringArray(env: c.napi_env, val: c.napi_value, alloc: std.mem.Allocator) ?[]const []const u8 {
    var is_array: bool = false;
    _ = c.napi_is_array(env, val, &is_array);
    if (!is_array) return null;
    var len: u32 = 0;
    _ = c.napi_get_array_length(env, val, &len);
    if (len == 0) return alloc.alloc([]const u8, 0) catch return null;
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

/// fallback 옵션용 — 값이 boolean false이면 null 저장, 문자열이면 그대로. 그 외엔 스킵.
fn getObjectKeyValuePairsWithNullable(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[]struct { []const u8, ?[]const u8 } {
    const val = getNamedProperty(env, obj, key) orelse return null;

    var prop_names: c.napi_value = undefined;
    if (c.napi_get_property_names(env, val, &prop_names) != c.napi_ok) return null;
    var len: u32 = 0;
    _ = c.napi_get_array_length(env, prop_names, &len);
    if (len == 0) return null;

    const Pair = struct { []const u8, ?[]const u8 };
    const result = alloc.alloc(Pair, len) catch return null;
    var count: u32 = 0;
    for (0..len) |i| {
        var prop_key: c.napi_value = undefined;
        if (c.napi_get_element(env, prop_names, @intCast(i), &prop_key) != c.napi_ok) continue;
        const k = getStringArg(env, prop_key, alloc) orelse continue;

        var prop_val: c.napi_value = undefined;
        if (c.napi_get_property(env, val, prop_key, &prop_val) != c.napi_ok) {
            alloc.free(k);
            continue;
        }
        var val_type: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, prop_val, &val_type);

        if (val_type == c.napi_boolean) {
            var b: bool = false;
            _ = c.napi_get_value_bool(env, prop_val, &b);
            // false만 의미 있음 (빈 모듈). true는 "기본값"으로 해석 — 스킵.
            if (b) {
                alloc.free(k);
                continue;
            }
            result[count] = .{ k, null };
            count += 1;
        } else {
            const v = getStringArg(env, prop_val, alloc) orelse {
                alloc.free(k);
                continue;
            };
            result[count] = .{ k, v };
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

    const HookType = enum { resolveId, load, transform, renderChunk, generateBundle, astFunction, resolveContext };

    const PluginResponse = struct {
        resolved_path: ?[]const u8 = null,
        is_external: bool = false,
        /// 빈 모듈로 처리 (Metro `{ type: 'empty' }`, webpack `false` 폴백 매핑용).
        /// resolveId가 `{ disabled: true }` 반환 시 ZTS가 `module.exports = {}` 처리.
        is_disabled: bool = false,
        code: ?[]const u8 = null,
        /// AST plugin: 제거할 디렉티브 이름
        strip_directive: ?[]const u8 = null,
        /// AST plugin: 함수 뒤에 삽입할 코드 문자열 배열
        trailing_code: ?[]const []const u8 = null,
        /// require.context: 매칭된 파일 경로 목록 (#1579 Phase 2.5).
        /// JS plugin 의 onResolveContext 가 반환한 `{ context: string[] }` 의 string[] 부분.
        /// outer slice = native_alloc 소유 (graph 가 free), inner string = JS lifetime.
        context_matches: ?[]const []const u8 = null,
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
        resp.is_disabled = getObjectBool(env, js_result, "disabled", false);
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
        // require.context 응답 파싱: { context: string[] } (#1579 Phase 2.5)
        if (getNamedProperty(env, js_result, "context")) |ctx_val| {
            resp.context_matches = parseStringArray(env, ctx_val, native_alloc);
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
            .resolveContext => "resolveContext",
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

        // disabled: 빈 모듈로 처리. path는 식별용 — resolved_path 또는 specifier 그대로.
        // Metro `{ type: 'empty' }` 매핑, webpack `resolve.fallback: false`와 동등.
        if (resp.is_disabled) {
            const id_path = resp.resolved_path orelse specifier;
            return .{
                .path = alloc.dupe(u8, id_path) catch return error.OutOfMemory,
                .module_type = .javascript,
                .disabled = true,
            };
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

    /// JSON string field 인코딩 — `"` `\` 와 control char escape.
    fn appendJsonString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
        try buf.append(alloc, '"');
        for (s) |ch| switch (ch) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => if (ch < 0x20) {
                var hex: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{ch}) catch unreachable;
                try buf.appendSlice(alloc, written);
            } else {
                try buf.append(alloc, ch);
            },
        };
        try buf.append(alloc, '"');
    }

    /// `Plugin.resolveContext` wrapper — JS dispatcher 의 onResolveContext 호출. (#1579 Phase 2.5)
    /// 5개 인자 (dir, recursive, filter, flags, importer) 를 JSON 으로 직렬화해 arg1 에 전달.
    /// JS 결과 `{ context: string[] }` 를 PluginResponse.context_matches 로 받음.
    fn pluginResolveContext(
        ctx: ?*anyopaque,
        dir: []const u8,
        recursive: bool,
        filter_pattern: ?[]const u8,
        filter_flags: ?[]const u8,
        importer: []const u8,
        alloc: std.mem.Allocator,
    ) PluginError!?[]const []const u8 {
        const self: *NapiPlugin = @ptrCast(@alignCast(ctx.?));

        // JSON 직렬화: { dir, recursive, filter?, flags?, importer }
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(native_alloc);
        json_buf.append(native_alloc, '{') catch return null;
        json_buf.appendSlice(native_alloc, "\"dir\":") catch return null;
        appendJsonString(&json_buf, native_alloc, dir) catch return null;
        json_buf.appendSlice(native_alloc, ",\"recursive\":") catch return null;
        json_buf.appendSlice(native_alloc, if (recursive) "true" else "false") catch return null;
        if (filter_pattern) |fp| {
            json_buf.appendSlice(native_alloc, ",\"filter\":") catch return null;
            appendJsonString(&json_buf, native_alloc, fp) catch return null;
        }
        if (filter_flags) |ff| {
            json_buf.appendSlice(native_alloc, ",\"flags\":") catch return null;
            appendJsonString(&json_buf, native_alloc, ff) catch return null;
        }
        json_buf.appendSlice(native_alloc, ",\"importer\":") catch return null;
        appendJsonString(&json_buf, native_alloc, importer) catch return null;
        json_buf.append(native_alloc, '}') catch return null;

        const resp = self.callHookFull(.resolveContext, json_buf.items, null, null) orelse return null;
        defer if (resp.context_matches) |m| native_alloc.free(m);
        // inner string 들도 native_alloc 소유 (parseStringArray 가 dupe 함). 함께 free.
        defer if (resp.context_matches) |m| {
            for (m) |s| native_alloc.free(s);
        };

        const matches = resp.context_matches orelse return null;

        // caller (graph) allocator 로 dupe — outer slice + inner strings.
        // ImportRecord.context_matches 의 contract 에 맞춰: outer 는 graph 가 free,
        // inner 는 plugin 책임 (여기선 NapiPlugin 이 alloc 했으므로 함께 graph alloc 으로).
        const out = alloc.alloc([]const u8, matches.len) catch return null;
        for (matches, 0..) |s, i| {
            out[i] = alloc.dupe(u8, s) catch {
                // 부분 실패: 이미 할당한 것들 free 후 null 반환
                for (out[0..i]) |prev| alloc.free(prev);
                alloc.free(out);
                return null;
            };
        }
        return out;
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
            .resolveContext = pluginResolveContext,
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

// ─── NapiManualChunksResolver: `manualChunks(id)` JS 함수 브리지 (#1027 Phase 2) ───
// Rollup manualChunks 동일 시그니처. 모듈당 1회 sync 호출 (pre-pass 에서 수집).
// worker thread 에서 call → tsfn 으로 main dispatch → condvar 대기 → 결과 반환.
// NapiPlugin 의 축약 버전 (1 hook, no filter, sync only, promise 불필요).

const NapiManualChunksResolver = struct {
    tsfn: c.napi_threadsafe_function,

    const CallContext = struct {
        id: []const u8,
        result: ?[]const u8 = null,
        ready: bool = false,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
    };

    /// threadsafe function 의 call_js 콜백 (main thread).
    fn callJsCallback(env: c.napi_env, js_callback: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const ctx: *CallContext = @ptrCast(@alignCast(data.?));

        var js_id: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, ctx.id.ptr, ctx.id.len, &js_id);

        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);

        var js_result: c.napi_value = undefined;
        const args = [_]c.napi_value{js_id};
        if (c.napi_call_function(env, js_undefined, js_callback, 1, &args, &js_result) != c.napi_ok) {
            // JS exception 은 uncaught 로 전파되기 전에 clear — 번들 중단 방지.
            // manualChunks 가 throw 하면 해당 모듈은 null (auto 분배) 로 취급.
            var is_pending: bool = false;
            _ = c.napi_is_exception_pending(env, &is_pending);
            if (is_pending) {
                var exception: c.napi_value = undefined;
                _ = c.napi_get_and_clear_last_exception(env, &exception);
            }
            signalResult(ctx, null);
            return;
        }

        // null / undefined / string 만 허용. Promise 등 object 는 에러로 간주 (null).
        var vtype: c.napi_valuetype = undefined;
        _ = c.napi_typeof(env, js_result, &vtype);
        if (vtype != c.napi_string) {
            signalResult(ctx, null);
            return;
        }

        // UTF-8 길이 측정 → 할당 → 복사. CallContext.result 는 native_alloc 소유.
        var len: usize = 0;
        _ = c.napi_get_value_string_utf8(env, js_result, null, 0, &len);
        const buf = native_alloc.alloc(u8, len) catch {
            signalResult(ctx, null);
            return;
        };
        var written: usize = 0;
        _ = c.napi_get_value_string_utf8(env, js_result, buf.ptr, len + 1, &written);
        signalResult(ctx, buf[0..written]);
    }

    fn signalResult(ctx: *CallContext, result: ?[]const u8) void {
        ctx.mutex.lock();
        ctx.result = result;
        ctx.ready = true;
        ctx.cond.signal();
        ctx.mutex.unlock();
    }

    /// Zig resolver 인터페이스 — `ManualChunksResolveFn` 과 동일 시그니처.
    /// worker thread 에서 호출됨. JS 호출 후 동기 대기.
    fn resolve(ctx_ptr: ?*anyopaque, id: []const u8) ?[]const u8 {
        const self: *NapiManualChunksResolver = @ptrCast(@alignCast(ctx_ptr.?));
        var call_ctx = CallContext{ .id = id };

        if (c.napi_call_threadsafe_function(self.tsfn, &call_ctx, c.napi_tsfn_blocking) != c.napi_ok) {
            return null;
        }

        call_ctx.mutex.lock();
        while (!call_ctx.ready) call_ctx.cond.wait(&call_ctx.mutex);
        call_ctx.mutex.unlock();

        return call_ctx.result;
    }

    fn deinit(self: *NapiManualChunksResolver) void {
        _ = c.napi_release_threadsafe_function(self.tsfn, c.napi_tsfn_release);
        native_alloc.destroy(self);
    }
};

/// JS 함수 값 → NapiManualChunksResolver 생성 + BundleOptions 에 설치.
/// 성공 시 resolver 포인터 반환 (caller 가 deinit 책임), 실패 시 null.
fn installManualChunksResolver(
    env: c.napi_env,
    fn_val: c.napi_value,
    opts: *BundleOptions,
) ?*NapiManualChunksResolver {
    const resolver = native_alloc.create(NapiManualChunksResolver) catch return null;
    resolver.* = .{ .tsfn = undefined };

    var resource_name: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, "zts_manual_chunks", "zts_manual_chunks".len, &resource_name);
    if (c.napi_create_threadsafe_function(
        env,
        fn_val,
        null,
        resource_name,
        0, // unlimited queue
        1, // initial thread count
        null,
        null,
        @ptrCast(resolver),
        NapiManualChunksResolver.callJsCallback,
        &resolver.tsfn,
    ) != c.napi_ok) {
        native_alloc.destroy(resolver);
        return null;
    }

    opts.manual_chunks_resolver = NapiManualChunksResolver.resolve;
    opts.manual_chunks_ctx = @ptrCast(resolver);
    return resolver;
}

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
                const directive_text: ?[]const u8 = if (first.tag == .directive) blk: {
                    const t = api.transformer.ast.getText(first.span);
                    break :blk if (t.len >= 2) t[1 .. t.len - 1] else null;
                } else if (first.tag == .expression_statement) blk: {
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
        while (pi < func.params.len) : (pi += 1) {
            if (pi > 0) try buf.append(alloc, ',');
            const param_raw = api.transformer.ast.extra_data.items[func.params.start + pi];
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
/// `metadata_ms`) 는 `ZTS_PROFILE=<cat>` / `BUNGAE_HMR_PROFILE=1` / `BundleOptions.profile`
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

    // ── Sub-phase (ZTS_PROFILE=<cat> 활성 시에만 값 기록) ──
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
                // Sub-phase (ZTS_PROFILE=<cat> 활성 시 의미있는 값, 아니면 0).
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
    tracked: *zts_lib.server.TrackedFileSet,
    count: *usize,
) void {
    const Ctx = struct { tracked: *zts_lib.server.TrackedFileSet, count: *usize };
    const visit = struct {
        fn f(ctx: Ctx, full_path: []const u8) bool {
            if (ctx.tracked.addPath(full_path, true)) ctx.count.* += 1;
            return false;
        }
    }.f;
    zts_lib.server.watch_scan.scanRoot(
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
        const first_events = tracked.waitForChanges(watch_poll_timeout_ms) catch &[_]zts_lib.server.ChangeEvent{};
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
        // mask 와 level 은 유지 (`ZTS_PROFILE=hmr` 등의 활성 상태는 보존).
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
                // runtime 의 `__zts_apply_update` 가 hot-accept 없는 모듈 (React 내부
                // 등) 에 대해 `__zts_reload` 를 호출해 첫 rebuild 가 full reload 로
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

    var ptr: ?*anyopaque = null;
    if (c.napi_unwrap(env, this, &ptr) != c.napi_ok or ptr == null) {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    }
    const async_data: *WatchAsyncData = @ptrCast(@alignCast(ptr.?));

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

    var ptr: ?*anyopaque = null;
    if (c.napi_unwrap(env, this, &ptr) != c.napi_ok or ptr == null) {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    }
    const async_data: *WatchAsyncData = @ptrCast(@alignCast(ptr.?));

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

    // debug: 활성화할 디버그 로그 카테고리 목록 (ZTS_DEBUG env 와 합집합).
    const debug_categories = getObjectStringArray(env, opts_obj, "debug", native_alloc);
    if (debug_categories) |cats| {
        for (cats) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, cats)) return null;
    }

    // profile / profileLevel / profileFormat: 프로세스 전역 `profile` 모듈 상태를 조작.
    // JS 에서 \{ profile: ["parse", "transform"], profileLevel: "detailed", profileFormat: "json" \}
    // 식으로 전달. env (ZTS_PROFILE) 와 합집합. CLI `--profile=...` 와 동일한 의미.
    if (getObjectStringArray(env, opts_obj, "profile", native_alloc)) |cats| {
        for (cats) |s| if (!trackStr(owned_strings, s)) return null;
        if (!trackArr(owned_string_arrays, cats)) return null;
        profile_mod.addCategories(cats);
    }
    if (getObjectString(env, opts_obj, "profileLevel", native_alloc)) |lvl| {
        defer native_alloc.free(lvl);
        if (profile_mod.Level.fromString(lvl)) |parsed| {
            profile_mod.setLevel(parsed);
        }
    }
    // profileFormat 은 NAPI 반환 포맷 결정 — BundleOptions 에 별도 필드로 저장 (아래).

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
    // assetRegistry: string (경로), null/undefined (플랫폼 프리셋 결정), false (명시적 off).
    // false를 구분하기 위해 boolean 타입을 별도 체크.
    const asset_registry: ?[]const u8 = blk: {
        if (getNamedProperty(env, opts_obj, "assetRegistry")) |v| {
            var t: c.napi_valuetype = undefined;
            _ = c.napi_typeof(env, v, &t);
            if (t == c.napi_boolean) {
                var b: bool = false;
                _ = c.napi_get_value_bool(env, v, &b);
                if (!b) break :blk null; // false → off (RN preset도 덮음)
            } else if (t == c.napi_string) {
                const s = getStringArg(env, v, native_alloc) orelse break :blk null;
                if (!trackStr(owned_strings, s)) return null;
                break :blk s;
            }
        }
        // 미지정 + RN 플랫폼 → 기본 경로. 그 외 → null.
        if (platform == .react_native) {
            break :blk bundler_mod.RN_DEFAULT_ASSET_REGISTRY;
        }
        break :blk null;
    };

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

    // alias: { "from": "to" } → []AliasEntry (tsconfig paths 는 tsconfig 로드 후 아래에서 append).
    const alias_pairs = getObjectKeyValuePairs(env, opts_obj, "alias", native_alloc);
    var alias_list: std.ArrayList(bundler_mod.types.AliasEntry) = .empty;
    if (alias_pairs) |pairs| {
        defer native_alloc.free(pairs);
        for (pairs) |pair| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (!trackStr(owned_strings, pair[1])) return null;
            alias_list.append(native_alloc, .{ .from = pair[0], .to = pair[1] }) catch return null;
        }
    }

    // fallback: { "crypto": "crypto-browserify", "fs": false } → []FallbackEntry
    // 값이 `false`면 빈 모듈, 문자열이면 해당 specifier로 재해석.
    const fallback_pairs = getObjectKeyValuePairsWithNullable(env, opts_obj, "fallback", native_alloc);
    var fallback_entries: []const bundler_mod.types.FallbackEntry = &.{};
    if (fallback_pairs) |pairs| {
        const fbs = native_alloc.alloc(bundler_mod.types.FallbackEntry, pairs.len) catch return null;
        for (pairs, 0..) |pair, idx| {
            if (!trackStr(owned_strings, pair[0])) return null;
            if (pair[1]) |v| if (!trackStr(owned_strings, v)) return null;
            fbs[idx] = .{ .from = pair[0], .to = pair[1] };
        }
        native_alloc.free(pairs);
        fallback_entries = fbs;
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
    // JS side (browserslist 해석 등)에서 미리 계산한 unsupported bitmask가 있으면 우선.
    // 0이면 미설정으로 간주 — 어차피 unsupported=0은 esnext와 동일해서 target 기반 경로로 fallback해도 결과 동일.
    const unsupported_override = getObjectUint32(env, opts_obj, "unsupported", 0);
    const unsupported: compat.UnsupportedFeatures = if (unsupported_override != 0)
        @bitCast(unsupported_override)
    else if (target_str) |s|
        if (std.meta.stringToEnum(compat.ESTarget, s)) |t| compat.fromESTarget(t) else .{}
    else
        .{};

    const outfile = ownStr(env, opts_obj, "outfile", owned_strings);
    const outbase = ownStr(env, opts_obj, "outbase", owned_strings);
    const tsconfig_raw = ownStr(env, opts_obj, "tsconfigRaw", owned_strings);
    const tsconfig_path_js = ownStr(env, opts_obj, "tsconfigPath", owned_strings);

    // tsconfig.json 로드 + 머지 — JS 옵션이 명시적으로 설정된 필드가 있으면 그게 우선.
    // 머지 규칙은 `src/tsconfig_merge.zig` 의 공용 helper 에 위임 — transpile.zig / main.zig 와 일관.
    // JS 가 tsconfigPath 를 주지 않았으면 entry 디렉토리에서 상위로 자동 탐색 (esbuild/vite 스타일).
    const TsConfig = @import("zts_lib").config.TsConfig;
    const tsconfig_merge = @import("zts_lib").tsconfig_merge;
    var tsconfig_holder: TsConfig = .{};
    var autodiscovered_dir: ?[]const u8 = null;
    defer if (autodiscovered_dir) |d| native_alloc.free(d);
    const tsconfig_path_opt: ?[]const u8 = tsconfig_path_js orelse blk: {
        // entry 가 하나라도 있으면 그 디렉토리 기준, 없으면 CWD 기준으로 탐색.
        const start_dir: []const u8 = if (entries.len > 0)
            std.fs.path.dirname(entries[0]) orelse "."
        else
            ".";
        autodiscovered_dir = TsConfig.findTsconfigUpward(native_alloc, start_dir) catch null;
        break :blk autodiscovered_dir;
    };
    if (tsconfig_path_opt) |p| {
        tsconfig_holder = TsConfig.loadFromPath(native_alloc, p) catch TsConfig{};
    }
    defer tsconfig_holder.deinit();

    const merged_tsconfig = tsconfig_merge.merge(&tsconfig_holder, .{
        .experimental_decorators = getObjectBoolOptional(env, opts_obj, "experimentalDecorators"),
        .emit_decorator_metadata = getObjectBoolOptional(env, opts_obj, "emitDecoratorMetadata"),
        .use_define_for_class_fields = getObjectBoolOptional(env, opts_obj, "useDefineForClassFields"),
        .verbatim_module_syntax = getObjectBoolOptional(env, opts_obj, "verbatimModuleSyntax"),
    });
    const experimental_decorators_eff = merged_tsconfig.experimental_decorators;
    const emit_decorator_metadata_eff = merged_tsconfig.emit_decorator_metadata;
    const use_define_for_class_fields_eff = merged_tsconfig.use_define_for_class_fields;
    const verbatim_module_syntax_eff = merged_tsconfig.verbatim_module_syntax;

    const alias_entries: []const bundler_mod.types.AliasEntry = alias_list.toOwnedSlice(native_alloc) catch return null;

    // tsconfig paths → resolver 의 ts_paths 로 전달 (alias 와 독립 경로).
    // TS 스펙대로 wildcard anywhere + 다중 후보 순차 시도를 resolver 가 담당.
    var ts_path_entries: []const @import("zts_lib").config.TsConfig.PathEntry = &.{};
    if (tsconfig_path_opt != null and tsconfig_holder.paths.len > 0) {
        const lib_config = @import("zts_lib").config;
        const dir_for_join = lib_config.tsconfigDirFromPath(tsconfig_path_opt.?);
        if (lib_config.resolveTsPaths(native_alloc, dir_for_join, &tsconfig_holder)) |resolved| {
            // target.prefix 로 join 된 절대 경로들을 tracker 에 등록 — opts 수명 동안 살아있도록.
            if (resolved.owned_strings.len > 0) {
                for (resolved.owned_strings) |s| if (!trackStr(owned_strings, s)) return null;
                if (!trackArr(owned_string_arrays, resolved.owned_strings)) return null;
            }
            ts_path_entries = resolved.entries;
            // entries 슬라이스와 각 entry.targets 슬라이스도 tracker 에 등록할 수 없으므로
            // 직접 추적. (TsConfig.PathEntry slice 들은 native_alloc 소유이며 NAPI cleanup 에서 해제되지 않음)
            // 메모리 leak 방지를 위해 process lifetime 동안 유지 — NAPI 진입점은 single-shot 이라 허용.
        } else |_| {}
    }

    const out_extension_js = ownStr(env, opts_obj, "outExtension", owned_strings);
    const source_root = ownStr(env, opts_obj, "sourceRoot", owned_strings);
    const root_dir = ownStr(env, opts_obj, "rootDir", owned_strings);
    const preserve_modules_root = ownStr(env, opts_obj, "preserveModulesRoot", owned_strings);

    // legalComments: "none" | "inline" | "eof" | "linked"
    const legal_str = getObjectString(env, opts_obj, "legalComments", native_alloc);
    if (legal_str) |s| if (!trackStr(owned_strings, s)) return null;
    const legal_comments: bundler_mod.types.LegalComments = if (legal_str) |s|
        if (std.mem.eql(u8, s, "none")) .none else if (std.mem.eql(u8, s, "inline")) .@"inline" else if (std.mem.eql(u8, s, "eof")) .eof else if (std.mem.eql(u8, s, "linked")) .linked else .default
    else
        .default;

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

    // blockList: string[] (JS 쪽에서 RegExp는 .source로 변환해서 전달)
    const block_list = getObjectStringArray(env, opts_obj, "blockList", native_alloc);
    if (block_list) |arr| {
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
        .debug = debug_categories orelse &.{},
        .define = define_entries,
        .alias = alias_entries,
        .ts_paths = ts_path_entries,
        .fallback = fallback_entries,
        .block_list = blk: {
            const user = block_list orelse &.{};
            if (platform == .react_native) {
                const merged = std.mem.concat(native_alloc, []const u8, &.{ bundler_mod.RN_DEFAULT_BLOCK_LIST, user }) catch return null;
                if (!trackArr(owned_string_arrays, merged)) return null;
                break :blk merged;
            }
            break :blk user;
        },
        .minify_whitespace = if (minify) true else getObjectBool(env, opts_obj, "minifyWhitespace", false),
        .minify_identifiers = if (minify) true else getObjectBool(env, opts_obj, "minifyIdentifiers", false),
        .minify_syntax = if (minify) true else getObjectBool(env, opts_obj, "minifySyntax", false),
        .code_splitting = getObjectBool(env, opts_obj, "splitting", false),
        .sourcemap = .{
            .enable = getObjectBool(env, opts_obj, "sourcemap", false),
            .debug_ids = getObjectBool(env, opts_obj, "sourcemapDebugIds", false),
            .sources_content = getObjectBool(env, opts_obj, "sourcesContent", true),
            .source_root = source_root,
            // lazy 는 PR #2 에서 NAPI watch 세션에 한정해 true 로 설정.
        },
        .tree_shaking = getObjectBool(env, opts_obj, "treeShaking", true),
        .scope_hoist = getObjectBool(env, opts_obj, "scopeHoist", true),
        .metafile = getObjectBool(env, opts_obj, "metafile", false),
        .keep_names = getObjectBool(env, opts_obj, "keepNames", false),
        .shim_missing_exports = getObjectBool(env, opts_obj, "shimMissingExports", false),
        .flow = getObjectBool(env, opts_obj, "flow", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.flow),
        .jsx_in_js = getObjectBool(env, opts_obj, "jsxInJs", false) or (platform == .react_native and bundler_mod.RN_BOOL_PRESET.jsx_in_js),
        .charset_utf8 = getObjectBool(env, opts_obj, "charsetUtf8", false),
        .use_define_for_class_fields = use_define_for_class_fields_eff,
        .experimental_decorators = experimental_decorators_eff,
        .emit_decorator_metadata = emit_decorator_metadata_eff,
        .verbatim_module_syntax = verbatim_module_syntax_eff,
        .banner_js = banner_js,
        .footer_js = footer_js,
        .global_name = global_name,
        .public_path = public_path orelse "",
        .entry_names = entry_names orelse "[name]",
        .chunk_names = chunk_names orelse "[name]-[hash]",
        .asset_names = asset_names orelse "[name]-[hash]",
        .asset_registry = asset_registry,
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
        .legal_comments = legal_comments,
        .preserve_modules = getObjectBool(env, opts_obj, "preserveModules", false),
        .preserve_modules_root = preserve_modules_root,
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
    // ZTS_DEBUG env 를 프로세스 시작 시 1회 파싱해 mask 초기화.
    // 개별 build/watch 호출마다 BundleOptions.debug 로 카테고리 추가 가능.
    @import("zts_lib").debug_log.initFromEnv(native_alloc);

    // ZTS_PROFILE / ZTS_PROFILE_LEVEL 도 동일하게 1회 파싱. 개별 build 호출마다
    // `BundleOptions.profile` / `profileLevel` 로 추가 가능.
    profile_mod.initFromEnv(native_alloc);

    // BUNGAE_HMR_PROFILE=1 호환 — 번개의 기존 HMR profile 토글을 새 인프라로 매핑.
    // 내부적으로 ZTS_PROFILE=hmr 과 동등.
    if (std.process.getEnvVarOwned(native_alloc, "BUNGAE_HMR_PROFILE")) |v| {
        defer native_alloc.free(v);
        if (v.len > 0 and !std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false")) {
            profile_mod.addFromCsv("hmr");
        }
    } else |_| {}

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

    var bench_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "benchmark", "benchmark".len, napiBenchmark, null, &bench_fn);
    _ = c.napi_set_named_property(env, exports, "benchmark", bench_fn);

    return exports;
}

// ─── benchmark 함수 (CLI `zts bench` 의 NAPI 대응) ───

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
        arena_alloc.dupe(u8, "input.ts") catch return throwError(env, "OutOfMemory");

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

fn setDoubleProp(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, value: f64) void {
    var v: c.napi_value = undefined;
    _ = c.napi_create_double(env, value, &v);
    _ = c.napi_set_named_property(env, obj, key, v);
}
