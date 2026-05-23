const std = @import("std");
const zntc_lib = @import("zntc_lib");
const transpile_mod = zntc_lib.transpile;
const Scanner = zntc_lib.lexer.Scanner;
const rich_diagnostic = zntc_lib.rich_diagnostic;
const diagnostic_renderer = zntc_lib.diagnostic_renderer;
const napi_render_opts: diagnostic_renderer.RenderOptions = .{ .color = false, .unicode = true };
const common = @import("common.zig");
const tsconfig_cache_mod = @import("tsconfig_cache.zig");
const c = common.c;

const native_alloc = common.nativeAlloc();

const throwError = common.throwError;
const getStringArg = common.getStringArg;
const setUint32Prop = common.setUint32Prop;
const setStringProp = common.setStringProp;

/// transpile(source, filename, optionsJson, cache?)
/// optionsJson: ConfigOptionsDto JSON payload (camelCase 키)
/// cache: 옵셔널 TsconfigCache handle (#2367) — autodiscover 결과 재사용 → 다수 파일 in-process
///         transpile 시 file 당 5–10 fs syscall 절약. options.tsconfigPath 가 명시되면 무시.
/// → { code: string, map?: string, errors?: string }
pub fn napiTranspile(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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
pub fn napiTokenize(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
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
