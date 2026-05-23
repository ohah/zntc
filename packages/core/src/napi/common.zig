//! Shared NAPI helpers for the `@zntc/core` native entry.

const std = @import("std");

pub const c = @cImport({
    @cDefine("NAPI_VERSION", "8");
    @cInclude("node_api.h");
});

pub const NullableStringPair = struct { []const u8, ?[]const u8 };

pub fn throwError(env: c.napi_env, msg: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, null, msg);
    return null;
}

/// JS object 의 native pointer (napi_wrap 결과) 를 안전하게 추출.
/// `napi_unwrap` 실패 / null pointer 시 null — caller 가 throw / fallback 결정.
pub inline fn unwrapNapi(comptime T: type, env: c.napi_env, value: c.napi_value) ?*T {
    var ptr: ?*anyopaque = null;
    if (c.napi_unwrap(env, value, &ptr) != c.napi_ok) return null;
    const p = ptr orelse return null;
    return @ptrCast(@alignCast(p));
}

/// JS string 인자를 Zig 슬라이스로 추출. 빈 문자열이면 null 반환.
///
/// NAPI 가 NUL terminator 를 끝에 쓰므로 `len+1` 임시 alloc 이 필요하지만, 반환
/// slice 는 NUL 미포함 `actual` 바이트라 그대로 free 하면 alloc(len+1) vs
/// free(actual) size mismatch — Zig `Allocator` API contract 위반. 현재
/// `c_allocator` (NAPI 기본) 는 free 시 size 인자를 무시해 silent 통과하지만,
/// `DebugAllocator` / arena / page 등 size-tracking allocator 로 전환하는 순간
/// invalid-free panic. 정확 크기로 `dupe` 후 임시 buf 즉시 free 해 contract 준수.
pub fn getStringArg(env: c.napi_env, value: c.napi_value, alloc: std.mem.Allocator) ?[]const u8 {
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, null, 0, &len) != c.napi_ok) return null;
    if (len == 0) return null;
    const tmp = alloc.alloc(u8, len + 1) catch return null;
    defer alloc.free(tmp);
    var actual: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, tmp.ptr, len + 1, &actual) != c.napi_ok) {
        return null;
    }
    return alloc.dupe(u8, tmp[0..actual]) catch null;
}

pub fn getNamedProperty(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8) ?c.napi_value {
    var val: c.napi_value = undefined;
    if (c.napi_get_named_property(env, obj, key, &val) != c.napi_ok) return null;
    // undefined/null 체크
    var val_type: c.napi_valuetype = undefined;
    _ = c.napi_typeof(env, val, &val_type);
    if (val_type == c.napi_undefined or val_type == c.napi_null) return null;
    return val;
}

pub fn getObjectBool(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, default_val: bool) bool {
    const val = getNamedProperty(env, obj, key) orelse return default_val;
    var result: bool = default_val;
    _ = c.napi_get_value_bool(env, val, &result);
    return result;
}

/// bool 필드의 tri-state 조회 — 키가 없으면 null, 있으면 실제 값.
/// tsconfig 머지 시 "JS 가 명시적으로 false" 와 "JS 가 생략" 을 구분하기 위해 사용.
pub fn getObjectBoolOptional(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8) ?bool {
    const val = getNamedProperty(env, obj, key) orelse return null;
    var result: bool = false;
    if (c.napi_get_value_bool(env, val, &result) != c.napi_ok) return null;
    return result;
}

pub fn getObjectUint32(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, default_val: u32) u32 {
    const val = getNamedProperty(env, obj, key) orelse return default_val;
    var result: u32 = default_val;
    _ = c.napi_get_value_uint32(env, val, &result);
    return result;
}

pub fn getObjectString(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[]const u8 {
    const val = getNamedProperty(env, obj, key) orelse return null;
    return getStringArg(env, val, alloc);
}

/// plugin onLoad 의 `contents` 가 string 일 수도 있고 Uint8Array/Buffer 일 수도 있음.
/// 후자는 binary-safe (PNG/JPG 등 raw bytes 가 utf-8 invalid 일 수 있음). (#2157 follow-up)
/// - string: utf-8 디코드된 byte slice 그대로 (빈 string 도 valid — `loader: 'empty'` 등)
/// - Node.js Buffer: napi_is_buffer 로 먼저 확인 (V8 Uint8Array subclass 지만 공식 API 분리)
/// - Uint8Array typed array: byteLength 만큼 raw bytes 복사
/// - 그 외 type 또는 missing: null
pub fn getObjectBytes(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[]const u8 {
    const val = getNamedProperty(env, obj, key) orelse return null;
    var ty: c.napi_valuetype = undefined;
    if (c.napi_typeof(env, val, &ty) != c.napi_ok) return null;
    if (ty == c.napi_string) {
        var len: usize = 0;
        if (c.napi_get_value_string_utf8(env, val, null, 0, &len) != c.napi_ok) return null;
        if (len == 0) {
            return alloc.alloc(u8, 0) catch null;
        }
        // NUL terminator 용 +1 임시 alloc → 실제 byte 수 (NUL 제외) 로 dupe.
        // (`getStringArg` 와 동일 이유 — size-mismatch leak 회피.)
        const tmp = alloc.alloc(u8, len + 1) catch return null;
        defer alloc.free(tmp);
        var actual: usize = 0;
        if (c.napi_get_value_string_utf8(env, val, tmp.ptr, len + 1, &actual) != c.napi_ok) {
            return null;
        }
        return alloc.dupe(u8, tmp[0..actual]) catch null;
    }
    // Node.js Buffer: napi_is_buffer 가 권위 있음. 일부 런타임에서 napi_is_typedarray 가
    // false 일 가능성 있어 별도 처리.
    var is_buffer: bool = false;
    if (c.napi_is_buffer(env, val, &is_buffer) == c.napi_ok and is_buffer) {
        var byte_len: usize = 0;
        var data_ptr: ?*anyopaque = null;
        if (c.napi_get_buffer_info(env, val, &data_ptr, &byte_len) != c.napi_ok) return null;
        return copyBytesOrEmpty(alloc, data_ptr, byte_len);
    }
    // Uint8Array / Uint8ClampedArray: raw bytes 복사. 다른 typed array (Int8Array/Float32Array 등)
    // 는 silent reject — plugin 작성 실수 시 contents missing 으로 표면화.
    var is_typed: bool = false;
    if (c.napi_is_typedarray(env, val, &is_typed) != c.napi_ok or !is_typed) return null;
    var ta_type: c.napi_typedarray_type = undefined;
    var byte_len: usize = 0;
    var data_ptr: ?*anyopaque = null;
    if (c.napi_get_typedarray_info(env, val, &ta_type, &byte_len, &data_ptr, null, null) != c.napi_ok) return null;
    if (ta_type != c.napi_uint8_array and ta_type != c.napi_uint8_clamped_array) return null;
    return copyBytesOrEmpty(alloc, data_ptr, byte_len);
}

fn copyBytesOrEmpty(alloc: std.mem.Allocator, data_ptr: ?*anyopaque, byte_len: usize) ?[]const u8 {
    if (byte_len == 0) {
        return alloc.alloc(u8, 0) catch null;
    }
    const src_ptr: [*]const u8 = @ptrCast(data_ptr orelse return null);
    const out = alloc.alloc(u8, byte_len) catch return null;
    @memcpy(out, src_ptr[0..byte_len]);
    return out;
}

/// `alloc(T, len)` 후 일부 element 만 채운 채 `result[0..count]` 를 반환하면
/// caller 가 그대로 free 시 alloc-size(`len`) vs free-size(`count`) mismatch
/// (`getStringArg` 와 동일 root cause). 정확히 `count` 길이로 줄여 반환한다.
/// 1차 시도 `alloc.realloc` (대부분 in-place shrink); 실패 시 새 alloc + memcpy
/// + 옛 free fallback. element 값 (slice 등 sub-alloc) 은 그대로 보존된다.
fn shrinkSlice(comptime T: type, alloc: std.mem.Allocator, result: []T, count: usize) ?[]T {
    if (count == result.len) return result;
    return alloc.realloc(result, count) catch blk: {
        const shrunk = alloc.alloc(T, count) catch {
            alloc.free(result);
            return null;
        };
        @memcpy(shrunk, result[0..count]);
        alloc.free(result);
        break :blk shrunk;
    };
}

pub fn getObjectStringArray(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[]const []const u8 {
    const val = getNamedProperty(env, obj, key) orelse return null;
    return parseStringArray(env, val, alloc);
}

/// JS 배열 값을 문자열 슬라이스로 변환. (key 없이 직접 배열 값을 받는 버전)
/// 빈 배열은 명시적으로 빈 slice 반환 (caller 가 "0개" 와 "invalid" 를 구분 가능).
pub fn parseStringArray(env: c.napi_env, val: c.napi_value, alloc: std.mem.Allocator) ?[]const []const u8 {
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
    return shrinkSlice([]const u8, alloc, result, count);
}

/// JS 객체의 키-값 쌍을 [2][]const u8 배열로 추출. { "key": "value", ... }
pub fn getObjectKeyValuePairs(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, alloc: std.mem.Allocator) ?[][2][]const u8 {
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
    return shrinkSlice([2][]const u8, alloc, result, count);
}

/// fallback 옵션용 — 값이 boolean false이면 null 저장, 문자열이면 그대로. 그 외엔 스킵.
pub fn getObjectKeyValuePairsWithNullable(
    env: c.napi_env,
    obj: c.napi_value,
    key: [*:0]const u8,
    alloc: std.mem.Allocator,
) ?[]NullableStringPair {
    const val = getNamedProperty(env, obj, key) orelse return null;

    var prop_names: c.napi_value = undefined;
    if (c.napi_get_property_names(env, val, &prop_names) != c.napi_ok) return null;
    var len: u32 = 0;
    _ = c.napi_get_array_length(env, prop_names, &len);
    if (len == 0) return null;

    const result = alloc.alloc(NullableStringPair, len) catch return null;
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
    return shrinkSlice(NullableStringPair, alloc, result, count);
}

pub fn setDoubleProp(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, value: f64) void {
    var v: c.napi_value = undefined;
    _ = c.napi_create_double(env, value, &v);
    _ = c.napi_set_named_property(env, obj, key, v);
}

pub fn setUint32Prop(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, value: u32) void {
    var v: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, value, &v);
    _ = c.napi_set_named_property(env, obj, key, v);
}

pub fn setStringProp(env: c.napi_env, obj: c.napi_value, key: [*:0]const u8, value: []const u8) void {
    var v: c.napi_value = undefined;
    _ = c.napi_create_string_utf8(env, value.ptr, value.len, &v);
    _ = c.napi_set_named_property(env, obj, key, v);
}
