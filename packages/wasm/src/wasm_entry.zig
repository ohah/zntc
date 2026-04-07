//! ZTS WASM 진입점
//!
//! wasm32-wasi 타겟용 진입점. transpile 함수만 export하여
//! 브라우저/Node.js에서 TypeScript → JavaScript 변환을 수행한다.
//!
//! JS 래퍼가 다음 순서로 호출:
//!   1. alloc(len) → 메모리 확보, 포인터 반환
//!   2. WASM memory에 소스 문자열 복사
//!   3. transpile(...) → 결과 (packed u64)
//!   4. 결과 읽기 후 dealloc()으로 해제

const std = @import("std");
const transpile_mod = @import("zts_lib").transpile;
const TranspileOptions = transpile_mod.TranspileOptions;
const Scanner = @import("zts_lib").lexer.Scanner;
const Diagnostic = @import("zts_lib").diagnostic.Diagnostic;
const compat = @import("zts_lib").transformer.transformer.TransformOptions.compat;

/// WASM에서는 wasm_allocator 사용 (memory.grow 기반)
const wasm_alloc = std.heap.wasm_allocator;

/// 마지막 에러 메시지를 저장하는 전역 버퍼
var last_error_buf: ?[]const u8 = null;

fn setError(msg: []const u8) void {
    if (last_error_buf) |old| wasm_alloc.free(old);
    last_error_buf = wasm_alloc.dupe(u8, msg) catch null;
}

fn clearError() void {
    if (last_error_buf) |old| wasm_alloc.free(old);
    last_error_buf = null;
}

/// 파서/시맨틱 에러를 SWC/tsc 스타일로 포맷하여 last_error_buf에 저장.
/// 형식: "<file>:<line>:<col>: error: <message>\n  <line_num> | <source_line>\n    | <caret>"
fn formatErrors(source: []const u8, file_path: []const u8, scanner: *const Scanner, errors: []const Diagnostic) void {
    if (errors.len == 0) return;
    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(wasm_alloc);
    // 첫 번째 에러만 표시 — 후속 에러는 복구 과정의 노이즈인 경우가 많음
    formatSingleError(writer, source, file_path, scanner, errors[0]) catch return;
    if (buf.items.len > 0) {
        if (last_error_buf) |old| wasm_alloc.free(old);
        last_error_buf = buf.toOwnedSlice(wasm_alloc) catch null;
    }
}

fn formatSingleError(writer: anytype, source: []const u8, file_path: []const u8, scanner: *const Scanner, err: Diagnostic) !void {
    const lc = scanner.getLineColumn(err.span.start);
    const line_num = lc.line + 1;
    const col_num = lc.column + 1;

    // 에러 헤더: "file:line:col: error: message"
    const kind_label: []const u8 = switch (err.kind) {
        .parse => "error",
        .semantic => "error[semantic]",
    };
    if (err.found) |found| {
        try writer.print("{s}:{d}:{d}: {s}: Expected '{s}' but found '{s}'\n", .{ file_path, line_num, col_num, kind_label, err.message, found });
    } else {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, line_num, col_num, kind_label, err.message });
    }

    // 해당 줄 텍스트 추출
    const line_start = if (lc.line < scanner.line_offsets.items.len) scanner.line_offsets.items[lc.line] else 0;
    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') {
        line_end += 1;
    }
    const line_text = source[line_start..line_end];

    // 소스 줄 출력
    try writer.print("  {d} | {s}\n", .{ line_num, line_text });

    // 캐럿 위치 출력
    var num_width: usize = 0;
    var n = line_num;
    while (n > 0) : (n /= 10) {
        num_width += 1;
    }
    var i: usize = 0;
    while (i < num_width + 2) : (i += 1) try writer.writeByte(' ');
    try writer.writeAll("| ");
    i = 0;
    while (i < lc.column) : (i += 1) {
        if (line_start + i < source.len and source[line_start + i] == '\t')
            try writer.writeByte('\t')
        else
            try writer.writeByte(' ');
    }
    const err_len = if (err.span.end > err.span.start)
        @min(err.span.end - err.span.start, line_end - (line_start + lc.column))
    else
        1;
    i = 0;
    while (i < err_len) : (i += 1) try writer.writeByte('^');
    try writer.writeByte('\n');
}

fn readStr(ptr: u32, len: u32) []const u8 {
    if (ptr == 0 or len == 0) return "";
    return @as([*]const u8, @ptrFromInt(ptr))[0..len];
}

// ─── Export 함수 ───

/// WASM linear memory에 len 바이트를 할당하고 포인터를 반환한다.
export fn alloc(len: u32) u32 {
    const slice = wasm_alloc.alloc(u8, len) catch return 0;
    return @intFromPtr(slice.ptr);
}

/// 이전에 alloc()으로 할당한 메모리를 해제한다.
export fn dealloc(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const slice: [*]u8 = @ptrFromInt(ptr);
    wasm_alloc.free(slice[0..len]);
}

/// 트랜스파일 옵션 플래그 (비트마스크)
///
///   bit 0:  sourcemap
///   bit 1:  minify_whitespace
///   bit 2:  minify_identifiers
///   bit 3:  minify_syntax
///   bit 4:  jsx_runtime (automatic)
///   bit 5:  jsx_dev (automatic-dev)
///   bit 6:  drop_console
///   bit 7:  drop_debugger
///   bit 8:  ascii_only
///   bit 9:  flow
///   bit 10: experimental_decorators
///   bit 11: emit_decorator_metadata
///   bit 12-13: module_format (00=esm, 01=cjs)
///   bit 14-15: quote_style (00=double, 01=single, 10=preserve)
///   bit 16: use_define_for_class_fields (1=true, 기본값 true)
///   bit 17: charset_utf8
///   bit 18-19: platform (00=browser, 01=node, 10=neutral, 11=react-native)
///   bit 20: jsx_in_js
///   bit 21: sourcemap_debug_ids
///   bit 22: sources_content (1=true, 기본값 true)
fn decodeFlags(flags: u32) TranspileOptions {
    return .{
        .sourcemap = flags & (1 << 0) != 0,
        .minify_whitespace = flags & (1 << 1) != 0,
        .minify_identifiers = flags & (1 << 2) != 0,
        .minify_syntax = flags & (1 << 3) != 0,
        .jsx_runtime = if (flags & (1 << 5) != 0)
            .automatic_dev
        else if (flags & (1 << 4) != 0)
            .automatic
        else
            .classic,
        .drop_console = flags & (1 << 6) != 0,
        .drop_debugger = flags & (1 << 7) != 0,
        .ascii_only = flags & (1 << 8) != 0,
        .flow = flags & (1 << 9) != 0,
        .experimental_decorators = flags & (1 << 10) != 0,
        .emit_decorator_metadata = flags & (1 << 11) != 0,
        .module_format = switch ((flags >> 12) & 0x3) {
            0 => .esm,
            1 => .cjs,
            else => .esm,
        },
        .quote_style = switch ((flags >> 14) & 0x3) {
            0 => .double,
            1 => .single,
            2 => .preserve,
            else => .double,
        },
        .use_define_for_class_fields = flags & (1 << 16) != 0,
        .charset_utf8 = flags & (1 << 17) != 0,
        .platform = switch ((flags >> 18) & 0x3) {
            0 => .browser,
            1 => .node,
            2 => .neutral,
            3 => .react_native,
            else => .browser,
        },
        .jsx_in_js = flags & (1 << 20) != 0,
        .sourcemap_debug_ids = flags & (1 << 21) != 0,
        .sources_content = flags & (1 << 22) != 0,
    };
}

/// 소스 코드를 트랜스파일한다.
///
/// flags: 비트마스크 옵션 (decodeFlags 참고)
/// unsupported: UnsupportedFeatures packed u32 (ES 다운레벨링 타겟)
/// 문자열 옵션: jsx_factory, jsx_fragment, jsx_import_source (ptr+len 쌍)
///
/// 반환값: packed u64 (상위 32비트: 포인터, 하위 32비트: 길이, 0=에러)
export fn transpile(
    src_ptr: u32,
    src_len: u32,
    file_ptr: u32,
    file_len: u32,
    flags: u32,
    unsupported: u32,
    jsx_factory_ptr: u32,
    jsx_factory_len: u32,
    jsx_fragment_ptr: u32,
    jsx_fragment_len: u32,
    jsx_import_source_ptr: u32,
    jsx_import_source_len: u32,
) u64 {
    clearError();

    if (src_ptr == 0 or src_len == 0) {
        setError("empty source");
        return 0;
    }

    const source: []const u8 = @as([*]const u8, @ptrFromInt(src_ptr))[0..src_len];
    const file_path: []const u8 = if (file_ptr != 0 and file_len > 0)
        @as([*]const u8, @ptrFromInt(file_ptr))[0..file_len]
    else
        "input.ts";

    var options = decodeFlags(flags);

    // UnsupportedFeatures는 packed struct(u32) — 직접 bitcast
    options.unsupported = @bitCast(unsupported);

    // 문자열 옵션 (빈 문자열이면 기본값 유지)
    const factory = readStr(jsx_factory_ptr, jsx_factory_len);
    if (factory.len > 0) options.jsx_factory = factory;
    const fragment = readStr(jsx_fragment_ptr, jsx_fragment_len);
    if (fragment.len > 0) options.jsx_fragment = fragment;
    const import_source = readStr(jsx_import_source_ptr, jsx_import_source_len);
    if (import_source.len > 0) options.jsx_import_source = import_source;

    var result = transpile_mod.transpileWithCallback(wasm_alloc, source, file_path, options, &formatErrors) catch |err| {
        // formatErrors 콜백이 이미 상세 메시지를 last_error_buf에 저장했을 수 있음.
        // 콜백이 호출되지 않았거나 메시지가 비어있으면 에러 종류만 표시.
        if (last_error_buf == null) {
            const msg: []const u8 = switch (err) {
                error.ParseError => "ParseError",
                error.SemanticError => "SemanticError",
                error.TransformError => "TransformError",
                error.CodegenError => "CodegenError",
                error.OutOfMemory => "OutOfMemory",
            };
            setError(msg);
        }
        return 0;
    };

    // 소스맵이 있으면 코드 뒤에 구분자(\0)와 소스맵을 붙여서 반환
    const output = if (result.sourcemap) |sm| blk: {
        const total = result.code.len + 1 + sm.len;
        const combined = wasm_alloc.alloc(u8, total) catch {
            setError("OutOfMemory");
            result.deinit(wasm_alloc);
            return 0;
        };
        @memcpy(combined[0..result.code.len], result.code);
        combined[result.code.len] = 0;
        @memcpy(combined[result.code.len + 1 ..], sm);
        result.deinit(wasm_alloc);
        break :blk combined;
    } else result.code;

    const ptr: u32 = @intFromPtr(output.ptr);
    const len: u32 = @intCast(output.len);
    return (@as(u64, ptr) << 32) | @as(u64, len);
}

/// 마지막 에러 메시지의 포인터를 반환한다.
export fn get_error_ptr() u32 {
    if (last_error_buf) |buf| return @intFromPtr(buf.ptr);
    return 0;
}

/// 마지막 에러 메시지의 길이를 반환한다.
export fn get_error_len() u32 {
    if (last_error_buf) |buf| return @intCast(buf.len);
    return 0;
}
