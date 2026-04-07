//! ZTS WASM 진입점
//!
//! wasm32-wasi 타겟용 진입점. transpile 함수만 export하여
//! 브라우저/Node.js에서 TypeScript → JavaScript 변환을 수행한다.
//!
//! JS 래퍼가 다음 순서로 호출:
//!   1. alloc(len) → 메모리 확보, 포인터 반환
//!   2. WASM memory에 소스 문자열 복사
//!   3. transpile(src_ptr, src_len, file_ptr, file_len, flags) → 결과 (packed u64)
//!   4. 결과 읽기 후 dealloc()으로 해제

const std = @import("std");
const transpile_mod = @import("zts_lib").transpile;
const TranspileOptions = transpile_mod.TranspileOptions;

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

// ─── Export 함수 ───

/// WASM linear memory에 len 바이트를 할당하고 포인터를 반환한다.
/// JS 래퍼가 소스 문자열을 WASM 메모리에 쓸 때 사용.
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
/// JS 래퍼에서 옵션을 u32 비트마스크로 인코딩:
///   bit 0:  sourcemap
///   bit 1:  minify_whitespace
///   bit 2:  minify_identifiers
///   bit 3:  minify_syntax
///   bit 4:  jsx_runtime (0=classic, 1=automatic)
///   bit 5:  jsx_dev (automatic-dev)
///   bit 6:  drop_console
///   bit 7:  drop_debugger
///   bit 8:  ascii_only
///   bit 9:  flow
///   bit 10: experimental_decorators
///   bit 11: emit_decorator_metadata
///   bit 12-13: module_format (00=esm, 01=cjs)
///   bit 14-15: quote_style (00=double, 01=single, 10=preserve)
fn decodeOptions(flags: u32) TranspileOptions {
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
    };
}

/// 소스 코드를 트랜스파일한다.
///
/// 반환값: packed u64
///   - 상위 32비트: 출력 문자열 포인터
///   - 하위 32비트: 출력 문자열 길이
///   - 0이면 에러 (get_error_ptr/get_error_len으로 에러 메시지 조회)
///
/// 호출 후 반환된 포인터는 dealloc()으로 해제해야 한다.
export fn transpile(
    src_ptr: u32,
    src_len: u32,
    file_ptr: u32,
    file_len: u32,
    flags: u32,
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

    const options = decodeOptions(flags);

    var result = transpile_mod.transpile(wasm_alloc, source, file_path, options) catch |err| {
        const msg: []const u8 = switch (err) {
            error.ParseError => "ParseError",
            error.SemanticError => "SemanticError",
            error.TransformError => "TransformError",
            error.CodegenError => "CodegenError",
            error.OutOfMemory => "OutOfMemory",
        };
        setError(msg);
        return 0;
    };

    // 소스맵이 있으면 코드 뒤에 구분자(\0)와 소스맵을 붙여서 반환
    // JS 래퍼에서 \0으로 split
    const output = if (result.sourcemap) |sm| blk: {
        const total = result.code.len + 1 + sm.len;
        const combined = wasm_alloc.alloc(u8, total) catch {
            setError("OutOfMemory");
            result.deinit(wasm_alloc);
            return 0;
        };
        @memcpy(combined[0..result.code.len], result.code);
        combined[result.code.len] = 0; // null separator
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
