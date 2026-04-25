//! ZTS WASM bundler 진입점 (#1885 Phase 2/3).
//!
//! wasm32-wasip1-threads 타겟용 — bundler 전용. transpile-only 빌드 (wasm_entry.zig)
//! 와 분리해서 brower 호환성/번들 사이즈 트레이드오프 분리.

const std = @import("std");
const zts_lib = @import("zts_lib");
const bundler_mod = zts_lib.bundler;
const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
const BundleResult = bundler_mod.bundler_core.BundleResult;
const Format = bundler_mod.types.Format;
const Platform = bundler_mod.Platform;

pub const panic = zts_lib.crash_handler.panic;

// Zig 0.15 의 wasm_allocator 는 multi-threaded 미지원 (page_allocator 도 내부 wasm_allocator
// 사용) — wasi-musl 의 c_allocator (thread-safe malloc) 사용. JS 측은 wasi_snapshot_preview1
// 의 모든 fn 을 stub 으로 제공.
const wasm_alloc = std.heap.c_allocator;

// wasi-musl libc 가 `main` 심볼 강제 — entry=.disabled (reactor 모드) 와 충돌.
// 미호출 stub 으로 link 통과.
pub fn main() void {}

/// Bundler ABI version. host 가 호환성 체크용.
/// v6 — last_error_message_get 출력이 ZTS 표준 진단 형식 (`× <message> [ZTS####]
/// + hint`). 새 ZTS 에러 코드: splitting_requires_esm_format, invalid_entry_path.
export fn bundler_version() u32 {
    return 6;
}

/// JS 측이 entry path 등 입력 메모리 확보용.
export fn alloc(len: u32) u32 {
    if (len == 0) return 0;
    const slice = wasm_alloc.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(slice.ptr));
}

export fn dealloc(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const slice: [*]u8 = @ptrFromInt(ptr);
    wasm_alloc.free(slice[0..len]);
}

// ─── 마지막 에러 메시지 (build / build_chunks 가 0 반환 시 host 가 조회) ───

/// 마지막 에러 메시지 — wasm_alloc 소유. 새 메시지 setLastError 시 이전 free.
/// single-threaded JS bridge 가정 (wasm instance per page).
/// 형식: ZTS 표준 진단 (`× <message> [<tag>]\n  hint: <suggestion>`).
/// 사용자 친화 (영문 error name 직접 노출 X). #1965.
var last_error_msg: ?[]u8 = null;

fn clearLastError() void {
    if (last_error_msg) |m| {
        wasm_alloc.free(m);
        last_error_msg = null;
    }
}

/// 형식화된 에러 메시지 작성. `× <message> [<tag>]` (+ optional `\n  hint: <hint>`).
/// tag 는 ZTS error code (`ZTS####`) 또는 internal Zig error name (fallback).
fn setLastErrorDiag(message: []const u8, tag: []const u8, hint: ?[]const u8) void {
    clearLastError();
    if (hint) |h| {
        last_error_msg = std.fmt.allocPrint(
            wasm_alloc,
            "× {s} [{s}]\n  hint: {s}",
            .{ message, tag, h },
        ) catch null;
    } else {
        last_error_msg = std.fmt.allocPrint(
            wasm_alloc,
            "× {s} [{s}]",
            .{ message, tag },
        ) catch null;
    }
}

/// 단순 메시지 — tag 없는 경우 (alloc 실패 등 internal).
fn setLastError(msg: []const u8) void {
    clearLastError();
    last_error_msg = std.fmt.allocPrint(wasm_alloc, "× {s}", .{msg}) catch null;
}

const error_codes = zts_lib.error_codes;
const ErrorCode = error_codes.Code;

/// Zig error → ZTS error code 매핑. 알려진 케이스는 ZTS#### 코드 + message + help
/// 노출. unknown 은 Zig error name fallback.
fn setLastErrorFromZigError(err: anyerror) void {
    const name = @errorName(err);
    const mapped: ?ErrorCode = if (std.mem.eql(u8, name, "CodeSplittingRequiresESM"))
        .splitting_requires_esm_format
    else if (std.mem.eql(u8, name, "InvalidEntryModule") or std.mem.eql(u8, name, "InvalidPath"))
        .invalid_entry_path
    else if (std.mem.eql(u8, name, "ModuleNotFound"))
        .unresolved_import
    else if (std.mem.eql(u8, name, "JsonParseError"))
        .json_parse_error
    else
        null;

    if (mapped) |code| {
        setLastErrorDiag(code.message(), code.format(), code.help());
        return;
    }

    // ZTS 코드 미매핑 — Zig error name 직접 노출 (디버깅 fallback).
    if (std.mem.eql(u8, name, "OutOfMemory")) {
        setLastErrorDiag("메모리 부족", name, null);
    } else if (std.mem.eql(u8, name, "NameTooLong")) {
        setLastErrorDiag("경로가 너무 깁니다", name, null);
    } else {
        setLastErrorDiag("번들링 실패", name, null);
    }
}

/// 최근 build/build_chunks 실패 시 에러 메시지 조회. 반환 packed u64 (ptr<<32 | len).
/// 0 = no error. caller 는 dealloc 호출 금지 (wasm 내부 buffer).
export fn last_error_message_get() u64 {
    const m = last_error_msg orelse return 0;
    if (m.len == 0) return 0;
    const out_ptr: u32 = @intCast(@intFromPtr(m.ptr));
    const out_len: u32 = @intCast(m.len);
    return (@as(u64, out_ptr) << 32) | @as(u64, out_len);
}

// ─── 옵션 JSON 파싱 ───

/// JSON 옵션 스키마 — JS bridge 의 BundleOptionsInput 와 동기. 모든 필드 optional —
/// 누락 시 BundleOptions 기본값 적용. 미지원 필드는 ignore_unknown_fields 로 무시.
const BuildOptionsJson = struct {
    format: ?[]const u8 = null,
    platform: ?[]const u8 = null,
    external: ?[]const []const u8 = null,
    minifyWhitespace: ?bool = null,
    minifyIdentifiers: ?bool = null,
    minifySyntax: ?bool = null,
    /// build_chunks 에서만 의미 있음. true 면 dynamic import / 공유 모듈을 별도 chunk 로 분리.
    codeSplitting: ?bool = null,
    /// build_chunks 에서만 의미 있음. true 면 모듈 1개 = 출력 1개 (rollup preserveModules).
    preserveModules: ?bool = null,
    /// transpile 계열 옵션 — 각 모듈 transform 단계에 적용 (Phase 3 PR D).
    /// target → unsupported bitmask. JS 측에서 packages/shared 의 targetToUnsupported() 로 변환 후 전달.
    unsupported: ?u32 = null,
    /// "classic" | "automatic" | "automatic-dev"
    jsx: ?[]const u8 = null,
    jsxFactory: ?[]const u8 = null,
    jsxFragment: ?[]const u8 = null,
    jsxImportSource: ?[]const u8 = null,
    flow: ?bool = null,
    jsxInJs: ?bool = null,
    experimentalDecorators: ?bool = null,
    emitDecoratorMetadata: ?bool = null,
    useDefineForClassFields: ?bool = null,
    charsetUtf8: ?bool = null,
    keepNames: ?bool = null,
    sourcemap: ?bool = null,
};

fn parseJsxRuntime(s: []const u8) ?@import("zts_lib").codegen.codegen.JsxRuntime {
    if (std.mem.eql(u8, s, "classic")) return .classic;
    if (std.mem.eql(u8, s, "automatic")) return .automatic;
    if (std.mem.eql(u8, s, "automatic-dev") or std.mem.eql(u8, s, "automatic_dev")) return .automatic_dev;
    return null;
}

fn parseFormat(s: []const u8) ?Format {
    if (std.mem.eql(u8, s, "esm")) return .esm;
    if (std.mem.eql(u8, s, "cjs")) return .cjs;
    if (std.mem.eql(u8, s, "iife")) return .iife;
    if (std.mem.eql(u8, s, "umd")) return .umd;
    if (std.mem.eql(u8, s, "amd")) return .amd;
    return null;
}

fn parsePlatform(s: []const u8) ?Platform {
    if (std.mem.eql(u8, s, "browser")) return .browser;
    if (std.mem.eql(u8, s, "node")) return .node;
    if (std.mem.eql(u8, s, "neutral")) return .neutral;
    if (std.mem.eql(u8, s, "react_native") or std.mem.eql(u8, s, "react-native")) return .react_native;
    return null;
}

/// JSON string literal 을 buf 에 직접 escape 처리해 추가 ("\"" 포함). RFC8259 §7
/// 의 control char + quote + backslash escape. 외부 std.json.Stringify 의 *Io.Writer
/// 요구가 ArrayList 와 호환 안 돼 작은 schema 직접 처리.
fn appendJsonString(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        0x08 => try buf.appendSlice(a, "\\b"),
        0x0c => try buf.appendSlice(a, "\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => {
            var hex: [6]u8 = undefined;
            const slice = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(a, slice);
        },
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

/// options_json 을 파싱해 BundleOptions 의 일부 필드를 채운다. base 는 entry_points
/// 설정된 기본값 (esm/browser). caller 가 entry_points 등 비-옵션 필드 미리 세팅.
fn applyOptionsJson(
    arena_alloc: std.mem.Allocator,
    base: *BundleOptions,
    options_json_ptr: u32,
    options_json_len: u32,
) void {
    if (options_json_ptr == 0 or options_json_len == 0) return;
    const json_bytes: []const u8 = @as([*]const u8, @ptrFromInt(options_json_ptr))[0..options_json_len];
    const parsed = std.json.parseFromSlice(
        BuildOptionsJson,
        arena_alloc,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch return;
    const o = parsed.value;
    if (o.format) |s| if (parseFormat(s)) |f| {
        base.format = f;
    };
    if (o.platform) |s| if (parsePlatform(s)) |p| {
        base.platform = p;
    };
    if (o.external) |list| base.external = list;
    if (o.minifyWhitespace) |b| base.minify_whitespace = b;
    if (o.minifyIdentifiers) |b| base.minify_identifiers = b;
    if (o.minifySyntax) |b| base.minify_syntax = b;
    if (o.codeSplitting) |b| base.code_splitting = b;
    if (o.preserveModules) |b| base.preserve_modules = b;

    // transpile 계열 옵션 — 각 모듈 transform 단계 적용.
    if (o.unsupported) |bits| base.unsupported = @bitCast(bits);
    if (o.jsx) |s| if (parseJsxRuntime(s)) |r| {
        base.jsx_runtime = r;
    };
    if (o.jsxFactory) |s| base.jsx_factory = s;
    if (o.jsxFragment) |s| base.jsx_fragment = s;
    if (o.jsxImportSource) |s| base.jsx_import_source = s;
    if (o.flow) |b| base.flow = b;
    if (o.jsxInJs) |b| base.jsx_in_js = b;
    if (o.experimentalDecorators) |b| base.experimental_decorators = b;
    if (o.emitDecoratorMetadata) |b| base.emit_decorator_metadata = b;
    if (o.useDefineForClassFields) |b| base.use_define_for_class_fields = b;
    if (o.charsetUtf8) |b| base.charset_utf8 = b;
    if (o.keepNames) |b| base.keep_names = b;
    if (o.sourcemap) |b| base.sourcemap.enable = b;
}

/// bundle() 결과의 fatal diagnostic 첫 번째를 last_error_msg 로 캡처 (있으면).
/// ZTS 표준 형식: `× [path: ]<message> [<code>][\n  hint: <suggestion>]`.
/// caller 가 직후 arena.deinit 해도 메시지는 wasm_alloc 으로 dupe 되어 안전.
fn captureDiagnostic(result: *const BundleResult) void {
    const diags = result.diagnostics orelse return;
    for (diags) |d| {
        if (d.severity != .@"error") continue;
        clearLastError();
        const tag_name = @tagName(d.code);
        last_error_msg = if (d.file_path.len > 0 and d.suggestion != null)
            std.fmt.allocPrint(wasm_alloc, "× {s}: {s} [{s}]\n  hint: {s}", .{ d.file_path, d.message, tag_name, d.suggestion.? }) catch null
        else if (d.file_path.len > 0)
            std.fmt.allocPrint(wasm_alloc, "× {s}: {s} [{s}]", .{ d.file_path, d.message, tag_name }) catch null
        else if (d.suggestion) |s|
            std.fmt.allocPrint(wasm_alloc, "× {s} [{s}]\n  hint: {s}", .{ d.message, tag_name, s }) catch null
        else
            std.fmt.allocPrint(wasm_alloc, "× {s} [{s}]", .{ d.message, tag_name }) catch null;
        return;
    }
}

/// build() — VFS entry path + 옵션 JSON 으로 bundler.bundle() 호출.
/// options_json_ptr=0 이면 기본 옵션 (esm/browser).
///
/// ABI: 반환 packed u64 (ptr<<32 | len), 0 = error 또는 빈 출력. caller (JS) 가
/// 결과 dealloc 책임. 옵션 JSON 파싱 실패는 silent — 기본 옵션으로 진행 (best effort).
/// 실패 시 last_error_message_get 으로 의미 있는 메시지 조회 가능.
///
/// 단일 파일 모드 전용 — code splitting / preserve modules 는 build_chunks 사용.
export fn build(
    entry_path_ptr: u32,
    entry_path_len: u32,
    options_json_ptr: u32,
    options_json_len: u32,
) u64 {
    clearLastError();
    if (entry_path_ptr == 0 or entry_path_len == 0) {
        const code = ErrorCode.invalid_entry_path;
        setLastErrorDiag(code.message(), code.format(), code.help());
        return 0;
    }
    const entry_path: []const u8 = @as([*]const u8, @ptrFromInt(entry_path_ptr))[0..entry_path_len];

    // arena 일괄 해제 — Bundler/BundleResult 내부 자료구조 모두 arena_alloc 소유.
    // CLAUDE.md "Arena 안 리소스 개별 deinit 금지" 패턴.
    var arena = std.heap.ArenaAllocator.init(wasm_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const entry_dupe = arena_alloc.dupe(u8, entry_path) catch {
        setLastError("alloc 실패 (entry path dupe)");
        return 0;
    };
    const entry_points: []const []const u8 = &.{entry_dupe};

    var options: BundleOptions = .{
        .entry_points = entry_points,
        .format = .esm,
        .platform = .browser,
    };
    applyOptionsJson(arena_alloc, &options, options_json_ptr, options_json_len);

    var bundler = Bundler.init(arena_alloc, options);
    const result = bundler.bundle() catch |err| {
        setLastErrorFromZigError(err);
        return 0;
    };

    // diagnostics 가 있으면 fatal 메시지 캡처 (출력은 있어도 의미 있는 에러 노출).
    captureDiagnostic(&result);

    // 단일 entry / 비-splitting 경로: result.output 사용 (outputs 는 code-splitting 시).
    const code = result.output;
    if (code.len == 0) {
        if (last_error_msg == null) {
            clearLastError();
            last_error_msg = std.fmt.allocPrint(
                wasm_alloc,
                "× entry \"{s}\" 가 빈 출력을 반환했습니다",
                .{entry_path},
            ) catch null;
        }
        return 0;
    }

    // arena.deinit() 후에도 caller (JS) 가 읽도록 wasm_alloc 으로 별도 dupe.
    const out = wasm_alloc.dupe(u8, code) catch {
        setLastError("alloc 실패 (output dupe)");
        return 0;
    };
    const out_ptr: u32 = @intCast(@intFromPtr(out.ptr));
    const out_len: u32 = @intCast(out.len);
    return (@as(u64, out_ptr) << 32) | @as(u64, out_len);
}

/// build_chunks() — multi-output 번들 결과를 JSON 배열로 반환.
/// 형식: `[{"path":"<chunk-path>","code":"<chunk-content>"}, ...]`
///
/// `code_splitting=true` 또는 `preserve_modules=true` 옵션 시 result.outputs 의
/// 모든 chunk 를 직렬화. 단일 파일 모드일 땐 result.output 한 개를 path="bundle.js"
/// 로 wrap — caller (JS) 가 시그니처 분기 없이 항상 array 받도록.
///
/// ABI: 반환 packed u64 (ptr<<32 | len), 0 = error. caller dealloc 책임.
export fn build_chunks(
    entry_path_ptr: u32,
    entry_path_len: u32,
    options_json_ptr: u32,
    options_json_len: u32,
) u64 {
    clearLastError();
    if (entry_path_ptr == 0 or entry_path_len == 0) {
        const code = ErrorCode.invalid_entry_path;
        setLastErrorDiag(code.message(), code.format(), code.help());
        return 0;
    }
    const entry_path: []const u8 = @as([*]const u8, @ptrFromInt(entry_path_ptr))[0..entry_path_len];

    var arena = std.heap.ArenaAllocator.init(wasm_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const entry_dupe = arena_alloc.dupe(u8, entry_path) catch {
        setLastError("alloc 실패 (entry path dupe)");
        return 0;
    };
    const entry_points: []const []const u8 = &.{entry_dupe};

    var options: BundleOptions = .{
        .entry_points = entry_points,
        .format = .esm,
        .platform = .browser,
    };
    applyOptionsJson(arena_alloc, &options, options_json_ptr, options_json_len);

    var bundler = Bundler.init(arena_alloc, options);
    const result = bundler.bundle() catch |err| {
        setLastErrorFromZigError(err);
        return 0;
    };

    captureDiagnostic(&result);

    // 단일 파일 모드 / 비-splitting 시엔 result.output 한 개를 wrap. code splitting /
    // preserve modules 시엔 result.outputs 의 모든 chunk.
    const Pair = struct { path: []const u8, code: []const u8 };
    var chunks: []Pair = undefined;
    if (result.outputs) |outs| {
        chunks = arena_alloc.alloc(Pair, outs.len) catch {
            setLastError("alloc 실패 (chunks array)");
            return 0;
        };
        for (outs, 0..) |o, i| chunks[i] = .{ .path = o.path, .code = o.contents };
    } else {
        if (result.output.len == 0) {
            if (last_error_msg == null) {
            clearLastError();
            last_error_msg = std.fmt.allocPrint(
                wasm_alloc,
                "× entry \"{s}\" 가 빈 출력을 반환했습니다",
                .{entry_path},
            ) catch null;
        }
            return 0;
        }
        chunks = arena_alloc.alloc(Pair, 1) catch {
            setLastError("alloc 실패 (chunks array)");
            return 0;
        };
        chunks[0] = .{ .path = "bundle.js", .code = result.output };
    }

    // JSON 직렬화 — std.json.Stringify 의 *Io.Writer 요구가 ArrayList writer 와 호환
    // 안 돼 직접 escape 처리 (간단한 schema라 외부 의존 회피).
    var buf: std.ArrayList(u8) = .empty;
    buf.append(arena_alloc, '[') catch {
        setLastError("alloc 실패 (json buf)");
        return 0;
    };
    for (chunks, 0..) |c, i| {
        if (i != 0) buf.append(arena_alloc, ',') catch {
            setLastError("alloc 실패 (json buf)");
            return 0;
        };
        buf.appendSlice(arena_alloc, "{\"path\":") catch {
            setLastError("alloc 실패 (json buf)");
            return 0;
        };
        appendJsonString(arena_alloc, &buf, c.path) catch {
            setLastError("alloc 실패 (json buf)");
            return 0;
        };
        buf.appendSlice(arena_alloc, ",\"code\":") catch {
            setLastError("alloc 실패 (json buf)");
            return 0;
        };
        appendJsonString(arena_alloc, &buf, c.code) catch {
            setLastError("alloc 실패 (json buf)");
            return 0;
        };
        buf.append(arena_alloc, '}') catch {
            setLastError("alloc 실패 (json buf)");
            return 0;
        };
    }
    buf.append(arena_alloc, ']') catch {
        setLastError("alloc 실패 (json buf)");
        return 0;
    };

    // arena.deinit() 후에도 caller 가 읽도록 wasm_alloc 으로 dupe.
    const out = wasm_alloc.dupe(u8, buf.items) catch {
        setLastError("alloc 실패 (output dupe)");
        return 0;
    };
    const out_ptr: u32 = @intCast(@intFromPtr(out.ptr));
    const out_len: u32 = @intCast(out.len);
    return (@as(u64, out_ptr) << 32) | @as(u64, out_len);
}
