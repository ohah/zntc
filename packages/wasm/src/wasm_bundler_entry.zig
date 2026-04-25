//! ZTS WASM bundler 진입점 (#1885 Phase 2/3).
//!
//! wasm32-wasip1-threads 타겟용 — bundler 전용. transpile-only 빌드 (wasm_entry.zig)
//! 와 분리해서 brower 호환성/번들 사이즈 트레이드오프 분리.

const std = @import("std");
const zts_lib = @import("zts_lib");
const bundler_mod = zts_lib.bundler;
const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;
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
/// v3 — build_chunks export 추가, BuildOptionsJson 에 codeSplitting/preserveModules.
export fn bundler_version() u32 {
    return 3;
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
};

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
}

/// build() — VFS entry path + 옵션 JSON 으로 bundler.bundle() 호출.
/// options_json_ptr=0 이면 기본 옵션 (esm/browser).
///
/// ABI: 반환 packed u64 (ptr<<32 | len), 0 = error 또는 빈 출력. caller (JS) 가
/// 결과 dealloc 책임. 옵션 JSON 파싱 실패는 silent — 기본 옵션으로 진행 (best effort).
///
/// 단일 파일 모드 전용 — code splitting / preserve modules 는 build_chunks 사용.
export fn build(
    entry_path_ptr: u32,
    entry_path_len: u32,
    options_json_ptr: u32,
    options_json_len: u32,
) u64 {
    if (entry_path_ptr == 0 or entry_path_len == 0) return 0;
    const entry_path: []const u8 = @as([*]const u8, @ptrFromInt(entry_path_ptr))[0..entry_path_len];

    // arena 일괄 해제 — Bundler/BundleResult 내부 자료구조 모두 arena_alloc 소유.
    // CLAUDE.md "Arena 안 리소스 개별 deinit 금지" 패턴.
    var arena = std.heap.ArenaAllocator.init(wasm_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const entry_dupe = arena_alloc.dupe(u8, entry_path) catch return 0;
    const entry_points: []const []const u8 = &.{entry_dupe};

    var options: BundleOptions = .{
        .entry_points = entry_points,
        .format = .esm,
        .platform = .browser,
    };
    applyOptionsJson(arena_alloc, &options, options_json_ptr, options_json_len);

    var bundler = Bundler.init(arena_alloc, options);
    const result = bundler.bundle() catch return 0;

    // 단일 entry / 비-splitting 경로: result.output 사용 (outputs 는 code-splitting 시).
    const code = result.output;
    if (code.len == 0) return 0;

    // arena.deinit() 후에도 caller (JS) 가 읽도록 wasm_alloc 으로 별도 dupe.
    const out = wasm_alloc.dupe(u8, code) catch return 0;
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
    if (entry_path_ptr == 0 or entry_path_len == 0) return 0;
    const entry_path: []const u8 = @as([*]const u8, @ptrFromInt(entry_path_ptr))[0..entry_path_len];

    var arena = std.heap.ArenaAllocator.init(wasm_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const entry_dupe = arena_alloc.dupe(u8, entry_path) catch return 0;
    const entry_points: []const []const u8 = &.{entry_dupe};

    var options: BundleOptions = .{
        .entry_points = entry_points,
        .format = .esm,
        .platform = .browser,
    };
    applyOptionsJson(arena_alloc, &options, options_json_ptr, options_json_len);

    var bundler = Bundler.init(arena_alloc, options);
    const result = bundler.bundle() catch return 0;

    // 단일 파일 모드 / 비-splitting 시엔 result.output 한 개를 wrap. code splitting /
    // preserve modules 시엔 result.outputs 의 모든 chunk.
    const Pair = struct { path: []const u8, code: []const u8 };
    var chunks: []Pair = undefined;
    if (result.outputs) |outs| {
        chunks = arena_alloc.alloc(Pair, outs.len) catch return 0;
        for (outs, 0..) |o, i| chunks[i] = .{ .path = o.path, .code = o.contents };
    } else {
        if (result.output.len == 0) return 0;
        chunks = arena_alloc.alloc(Pair, 1) catch return 0;
        chunks[0] = .{ .path = "bundle.js", .code = result.output };
    }

    // JSON 직렬화 — std.json.Stringify 의 *Io.Writer 요구가 ArrayList writer 와 호환
    // 안 돼 직접 escape 처리 (간단한 schema라 외부 의존 회피).
    var buf: std.ArrayList(u8) = .empty;
    buf.append(arena_alloc, '[') catch return 0;
    for (chunks, 0..) |c, i| {
        if (i != 0) buf.append(arena_alloc, ',') catch return 0;
        buf.appendSlice(arena_alloc, "{\"path\":") catch return 0;
        appendJsonString(arena_alloc, &buf, c.path) catch return 0;
        buf.appendSlice(arena_alloc, ",\"code\":") catch return 0;
        appendJsonString(arena_alloc, &buf, c.code) catch return 0;
        buf.append(arena_alloc, '}') catch return 0;
    }
    buf.append(arena_alloc, ']') catch return 0;

    // arena.deinit() 후에도 caller 가 읽도록 wasm_alloc 으로 dupe.
    const out = wasm_alloc.dupe(u8, buf.items) catch return 0;
    const out_ptr: u32 = @intCast(@intFromPtr(out.ptr));
    const out_len: u32 = @intCast(out.len);
    return (@as(u64, out_ptr) << 32) | @as(u64, out_len);
}
