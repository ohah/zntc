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
const zts_lib = @import("zts_lib");
const transpile_mod = zts_lib.transpile;
const TranspileOptions = transpile_mod.TranspileOptions;
const Scanner = zts_lib.lexer.Scanner;
const Diagnostic = zts_lib.diagnostic.Diagnostic;
const OwnedDiagnostic = zts_lib.diagnostic.OwnedDiagnostic;
const rich_diagnostic = zts_lib.rich_diagnostic;
const diagnostic_renderer = zts_lib.diagnostic_renderer;
const compat = zts_lib.transformer.transformer.TransformOptions.compat;

/// Bun 스타일 crash report: WASM에는 signal이 없지만 panic은 여전히 터질 수 있다.
/// 호스트 콘솔(WASI stderr)로 배너 + 이슈 URL 출력.
pub const panic = @import("zts_lib").crash_handler.panic;

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

const wasm_render_opts: diagnostic_renderer.RenderOptions = .{ .color = false, .unicode = true };

/// 진단 목록을 렌더링해 last_error_buf에 저장한다. Diagnostic(파서 콜백)과
/// OwnedDiagnostic(transpile 성공 반환 시 시맨틱 에러) 양쪽 호출자 공용.
fn bufferDiagnostics(
    source: []const u8,
    file_path: []const u8,
    line_offsets: []const u32,
    diagnostics: anytype,
) void {
    if (diagnostics.len == 0) return;
    const source_info: rich_diagnostic.SourceInfo = .{ .source = source, .line_offsets = line_offsets };
    var buf: std.ArrayList(u8) = .empty;
    const writer = buf.writer(wasm_alloc);
    diagnostic_renderer.renderAll(writer, diagnostics, source_info, file_path, wasm_render_opts) catch {};
    if (buf.items.len > 0) {
        if (last_error_buf) |old| wasm_alloc.free(old);
        last_error_buf = buf.toOwnedSlice(wasm_alloc) catch null;
    }
}

/// 파서 콜백 — 파서/시맨틱 에러를 last_error_buf에 저장.
fn formatErrors(source: []const u8, file_path: []const u8, scanner: *const Scanner, errors: []const Diagnostic) void {
    bufferDiagnostics(source, file_path, scanner.line_offsets.items, errors);
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

const decodeFlags = transpile_mod.decodeFlags;

/// 소스 코드를 트랜스파일한다.
///
/// opts_json: TranspileOptionsDto JSON payload (ptr+len). camelCase 키. 빈 문자열이면 기본값.
///
/// 반환값: packed u64 (상위 32비트: 포인터, 하위 32비트: 길이, 0=에러)
export fn transpile(
    src_ptr: u32,
    src_len: u32,
    file_ptr: u32,
    file_len: u32,
    opts_json_ptr: u32,
    opts_json_len: u32,
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

    // JSON 옵션 파싱은 arena에 위임 — 파싱 결과의 문자열 수명을 트랜스파일 끝까지 유지.
    var opts_arena = std.heap.ArenaAllocator.init(wasm_alloc);
    defer opts_arena.deinit();
    const opts_alloc = opts_arena.allocator();

    const opts_json: []const u8 = if (opts_json_ptr != 0 and opts_json_len > 0)
        @as([*]const u8, @ptrFromInt(opts_json_ptr))[0..opts_json_len]
    else
        "{}";

    const options = transpile_mod.optionsFromJson(opts_alloc, opts_json) catch {
        setError("invalid options JSON");
        return 0;
    };

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

    // 시맨틱 에러는 result와 함께 반환된다 (tsc 호환). JS는 get_error_ptr로 조회.
    if (result.diagnostics.len > 0) {
        bufferDiagnostics(source, file_path, result.line_offsets, result.diagnostics);
    }

    // 소스맵이 있으면 코드 뒤에 구분자(\0)와 소스맵을 붙여서 반환.
    // sourcemap 없는 경로는 result.code 포인터만 JS로 ownership transfer하고
    // 나머지(diagnostics/line_offsets)는 여기서 해제해야 누수가 없다.
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
    } else blk: {
        // code만 JS로 넘기고 부가 버퍼는 해제.
        for (result.diagnostics) |d| d.deinit(wasm_alloc);
        if (result.diagnostics.len > 0) wasm_alloc.free(result.diagnostics);
        if (result.line_offsets.len > 0) wasm_alloc.free(result.line_offsets);
        break :blk result.code;
    };

    // Zig slice의 `.ptr`은 len==0일 때 undefined로 허용되며, wasm_allocator는 이 경우 sentinel
    // 포인터(예: 0xFFFFFFFF)를 리턴한다. 그대로 packed u64에 실어 JS로 넘기면
    // i64 ↔ BigInt sign-extension을 거쳐 outPtr=-1이 되고 `new Uint8Array(buffer, -1, 0)`가
    // RangeError를 던진다. 빈 출력은 성공 경로에서도 합법(예: type-only 파일)이므로
    // ptr을 0으로 표준화하여 JS가 `{code:""}`로 해석하게 한다.
    const ptr: u32 = if (output.len == 0) 0 else @intFromPtr(output.ptr);
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
