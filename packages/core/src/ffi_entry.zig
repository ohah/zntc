//! ZTS FFI 진입점
//!
//! 네이티브 공유 라이브러리(.dylib/.so) 타겟용 진입점.
//! bun:ffi 등에서 직접 로드하여 in-process로 트랜스파일을 수행한다.
//!
//! 호출 순서:
//!   1. zts_transpile(src_ptr, src_len, file_ptr, file_len, flags) → result_ptr (null이면 에러)
//!   2. zts_result_len() → 결과 길이
//!   3. 결과 읽기 후 zts_free_result()로 해제

const std = @import("std");
const transpile_mod = @import("zts_lib").transpile;
const TranspileOptions = transpile_mod.TranspileOptions;

/// 네이티브 dylib에서는 c_allocator 사용 (page_allocator는 dylib에서 불안정)
const native_alloc = std.heap.c_allocator;

/// 마지막 결과/에러를 저장하는 전역 상태
var last_result: ?[]const u8 = null;
var last_error: ?[]const u8 = null;

fn freeResult() void {
    if (last_result) |old| native_alloc.free(old);
    last_result = null;
}

fn freeError() void {
    if (last_error) |old| native_alloc.free(old);
    last_error = null;
}

const decodeFlags = transpile_mod.decodeFlags;

/// 소스 코드를 트랜스파일한다.
///
/// 성공 시 결과 포인터 반환, 실패 시 null 반환.
/// 결과 길이는 zts_result_len()으로 조회.
/// 에러 메시지는 zts_error_ptr() + zts_error_len()으로 조회.
fn readStr(p: ?[*]const u8, len: u32) []const u8 {
    if (p) |valid| {
        if (len > 0) return valid[0..len];
    }
    return "";
}

export fn zts_transpile(
    src_ptr: ?[*]const u8,
    src_len: u32,
    file_ptr: ?[*]const u8,
    file_len: u32,
    flags: u32,
    unsupported: u32,
    jsx_factory_ptr: ?[*]const u8,
    jsx_factory_len: u32,
    jsx_fragment_ptr: ?[*]const u8,
    jsx_fragment_len: u32,
    jsx_import_source_ptr: ?[*]const u8,
    jsx_import_source_len: u32,
) ?[*]const u8 {
    freeResult();
    freeError();

    const source = if (src_ptr) |p| p[0..src_len] else {
        last_error = native_alloc.dupe(u8, "empty source") catch null;
        return null;
    };
    if (src_len == 0) {
        last_error = native_alloc.dupe(u8, "empty source") catch null;
        return null;
    }

    const file_path = if (file_ptr) |p|
        if (file_len > 0) p[0..file_len] else "input.ts"
    else
        "input.ts";

    var options = decodeFlags(flags);

    // UnsupportedFeatures (ES 다운레벨링 타겟)
    options.unsupported = @bitCast(unsupported);

    // 문자열 옵션
    const factory = readStr(jsx_factory_ptr, jsx_factory_len);
    if (factory.len > 0) options.jsx_factory = factory;
    const fragment = readStr(jsx_fragment_ptr, jsx_fragment_len);
    if (fragment.len > 0) options.jsx_fragment = fragment;
    const import_source = readStr(jsx_import_source_ptr, jsx_import_source_len);
    if (import_source.len > 0) options.jsx_import_source = import_source;

    var result = transpile_mod.transpile(native_alloc, source, file_path, options) catch |err| {
        const msg: []const u8 = switch (err) {
            error.ParseError => "ParseError",
            error.SemanticError => "SemanticError",
            error.TransformError => "TransformError",
            error.CodegenError => "CodegenError",
            error.OutOfMemory => "OutOfMemory",
        };
        last_error = native_alloc.dupe(u8, msg) catch null;
        return null;
    };

    // 결과를 native_alloc 소유의 메모리로 복사 (transpile 내부는 arena 사용)
    const output = if (result.sourcemap) |sm| blk: {
        const total = result.code.len + 1 + sm.len;
        const combined = native_alloc.alloc(u8, total) catch {
            last_error = native_alloc.dupe(u8, "OutOfMemory") catch null;
            result.deinit(native_alloc);
            return null;
        };
        @memcpy(combined[0..result.code.len], result.code);
        combined[result.code.len] = 0;
        @memcpy(combined[result.code.len + 1 ..], sm);
        result.deinit(native_alloc);
        break :blk combined;
    } else blk: {
        // code를 native_alloc으로 복사 후 원본 해제
        const copy = native_alloc.dupe(u8, result.code) catch {
            last_error = native_alloc.dupe(u8, "OutOfMemory") catch null;
            result.deinit(native_alloc);
            return null;
        };
        result.deinit(native_alloc);
        break :blk copy;
    };

    last_result = output;
    return output.ptr;
}

/// 마지막 트랜스파일 결과의 길이를 반환한다.
export fn zts_result_len() u32 {
    return if (last_result) |r| @intCast(r.len) else 0;
}

/// 마지막 에러 메시지의 포인터를 반환한다.
export fn zts_error_ptr() ?[*]const u8 {
    return if (last_error) |e| e.ptr else null;
}

/// 마지막 에러 메시지의 길이를 반환한다.
export fn zts_error_len() u32 {
    return if (last_error) |e| @intCast(e.len) else 0;
}

/// 마지막 결과 메모리를 해제한다.
export fn zts_free_result() void {
    freeResult();
    freeError();
}
