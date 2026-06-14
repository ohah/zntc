//! Shared NAPI helpers for the `@zntc/core` native entry.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cDefine("NAPI_VERSION", "8");
    @cInclude("node_api.h");
});

pub const NullableStringPair = struct { []const u8, ?[]const u8 };

// ── NAPI 공용 allocator (#dev-leak-investigation) ─────────────────────────
// debug 빌드: DebugAllocator → process 종료 시 atexit 으로 leak 리포트(stack
// trace 포함) 를 stderr 로 dump. RSS 폭증의 root site 식별이 목적이므로 영구
// 변경이 아닌 임시 측정 인프라다.
// release 빌드: c_allocator 그대로 (overhead 0, 기존 동작 유지).
//
// 모든 NAPI 파일이 `common.nativeAlloc()` 1개 인스턴스를 공유해야 cross-file
// alloc/free (예: watch.zig 가 transpile_entry 결과 free) 시 false leak 이
// 안 뜬다.
//
// `backing_allocator = c_allocator` 명시 (default = page_allocator 대신).
// page_allocator backing 은 size_class 마다 fresh page (macOS ≥64KB, Linux 4KB-
// 1MB) 점유 → small-alloc 다양성 시 RSS 인플레이션이 측정 시그널을 왜곡
// (#dev-leak-investigation PR #3695 review MEDIUM). c_allocator (libc malloc)
// 는 baseline c_allocator release 빌드와 동일 backing — Debug vs Release delta
// 가 GPA overhead 보다 진짜 leak signal 을 더 잘 노출.
//
// **`backing_allocator_zeroes = false` 필수**: Config default = `true` 가
// "backing 이 zero page 를 준다" 가정하고 DebugAllocator 의 `usedBits` /
// `requestedSizes` zero-pass 를 스킵한다 (stdlib debug_allocator.zig:793-796).
// 그러나 `c_allocator` (libc malloc/posix_memalign) 는 zero-fill 보장 없음 →
// usedBits[1..]/requestedSizes[*] garbage → false-positive double-free panic
// 또는 phantom leak. stdlib 자체 테스트 `debug_allocator.zig:1287-1292` 가
// 동일 non-page backing 패턴에 이 flag 를 false 로 명시.
var debug_gpa: std.heap.DebugAllocator(.{
    .stack_trace_frames = 16,
    .backing_allocator_zeroes = false,
}) = .{
    .backing_allocator = std.heap.c_allocator,
};

pub fn nativeAlloc() std.mem.Allocator {
    if (comptime builtin.mode == .Debug) return debug_gpa.allocator();
    return std.heap.c_allocator;
}

// ── NAPI 전역 io (0.16) ───────────────────────────────────────────────────
// NAPI 는 juicy main(std.process.Init) 이 없어 io 를 받을 수 없다. 모듈 로드
// 시 1회 std.Io.Threaded 인스턴스를 만들고 io() 로 공유한다 (프로세스 1개
// 이벤트 루프 모델). bundler 내부 병렬(Io.Group)은 이 풀의 async_limit 사용.
// register(메인 스레드, 다른 호출 전) 에서 init → race-free.
var g_threaded: ?std.Io.Threaded = null;

/// register 에서 1회 호출. 이미 init 됐으면 무시(idempotent).
pub fn initIo() void {
    if (g_threaded != null) return;
    g_threaded = std.Io.Threaded.init(nativeAlloc(), .{});
}

/// 모든 NAPI 진입점이 bundler/fs 작업에 쓸 공유 io. initIo 선행 필수.
pub fn io() std.Io {
    return g_threaded.?.io();
}

/// #4004: 빌드 직전 --jobs(JS `options.jobs`)를 공유 io 의 async_limit 에 반영.
/// g_threaded 가 *Threaded 를 소유하므로 setAsyncLimit(Threaded.mutex 보호) 가능.
/// ⚠️ 공유 전역 io 라 동시 in-flight 빌드가 서로 다른 jobs 면 마지막 setter 값을
/// 공유한다(메모리 안전 — mutex 보호, determinism #3564 무관 — byte-identical).
/// jobs=0(미지정): high-core 면 vnode open 경합 회피로 총 8 스레드 cap, 아니면 기본(cpu-1)
/// 유지(asyncLimitForJobs). 명시값은 그대로 존중.
pub fn setJobs(max_threads: u32) void {
    if (@import("zntc_lib").bundler.asyncLimitForJobs(max_threads)) |lim| {
        if (g_threaded) |*t| t.setAsyncLimit(lim);
    }
}

// ── NAPI 환경변수 스냅샷 (0.16) ───────────────────────────────────────────
// std.process.getEnvVarOwned 제거 → libc environ(std.c.environ) 으로 Map 을
// 만들어 env_flag 에 등록. Map 은 프로세스 수명 동안 유지(deinit 안 함).
var g_env_map: ?std.process.Environ.Map = null;

/// register 에서 1회 호출 — libc environ 을 env_flag 로 등록.
pub fn captureEnvironFromLibc() void {
    if (g_env_map != null) return;
    // Block 은 OS 별 comptime 타입: Windows=GlobalBlock(use_global→PEB), POSIX=PosixBlock(slice).
    const block: std.process.Environ.Block = if (builtin.os.tag == .windows)
        .{ .use_global = true }
    else blk: {
        const c_environ = std.c.environ;
        var env_count: usize = 0;
        while (c_environ[env_count] != null) : (env_count += 1) {}
        break :blk .{ .slice = @ptrCast(c_environ[0..env_count :null]) };
    };
    g_env_map = std.process.Environ.createMap(.{ .block = block }, nativeAlloc()) catch return;
    @import("zntc_lib").env_flag.captureEnviron(&g_env_map.?);
}

/// NAPI env cleanup hook (signature: `fn (?*anyopaque) callconv(.c) void`).
///
/// **Linux 호환성 fix (이전 `extern fn atexit` 에서 전환)**: Linux dynamic
/// shared library (`.node`) 는 libc `atexit` symbol 을 dlopen 시 resolve 안
/// 함 → `Error: undefined symbol: atexit` 으로 ERR_DLOPEN_FAILED. macOS
/// dynamic linker 는 자동 resolve 하지만 Linux ld 는 crt symbol 을 dynamic
/// link 안 함. `napi_add_env_cleanup_hook` 은 NAPI 표준 API — 양쪽 환경
/// 모두 호환. (Linux x86_64 + libc + DebugAllocator 의 더 깊은 호환성 문제는
/// Zig stdlib issue #25025 — 0.16.0 milestone fix. issue #1514 참고.)
///
/// `detectLeaks()` (debug_allocator.zig:449) 는 leak stack trace 만 stderr 에
/// dump 하고 state 유지 → 동시 in-flight alloc/free 가 후속에 진행해도 안전.
/// 단, detectLeaks 자체가 `self.buckets` / `self.large_allocations` 를 lock
/// 없이 iterate → 동시 alloc/free 가 mutate 하면 torn pointer read / iterator
/// desync 위험. `mutex.tryLock` 으로 best-effort serialize: worker 가
/// mid-alloc 이면 skip (leak dump 일부 손실) → deadlock 보다 안전.
fn dumpLeaksOnEnvCleanup(_: ?*anyopaque) callconv(.c) void {
    if (comptime builtin.mode != .Debug) return;
    if (debug_gpa.mutex.tryLock()) {
        defer debug_gpa.mutex.unlock();
        _ = debug_gpa.detectLeaks();
    }
    // large_allocations HashMap 자체는 leak (deinit 만 free) — process 종료
    // 직전이라 OS 가 회수.
}

/// `napi_register_module_v1` 의 중복 호출 race 방지 atomic flag. Node
/// `worker_threads` / Vitest `pool='threads'` 등 한 process 안에서 다중 isolate
/// 가 같은 .node 를 load 시 module init 이 동시에 호출될 수 있고, 공유 static
/// 인 이 flag 의 non-atomic read+write 면 둘 다 false 관찰 → 둘 다 cleanup hook
/// 등록 → env destroy 시 `dumpLeaksOnEnvCleanup` 두 번 호출 → 첫 deinit 가
/// `self.* = undefined` 로 GPA 무효화 후 두 번째 deinit 가 undefined memory
/// deref → segfault. `.acq_rel` swap 으로 하나의 caller 만 등록 진입 보장.
var leak_dump_registered: std.atomic.Value(bool) = .init(false);

/// `napi_register_module_v1` 에서 1회 호출 (env 인자 전달). Node env (isolate)
/// destroy 시 cleanup hook 이 `detectLeaks` 호출 → stack trace 포함 leak
/// 리포트를 stderr 로 dump. process 정상 종료 시 env 도 destroy 되므로 동등.
pub fn registerLeakDump(env: c.napi_env) void {
    if (comptime builtin.mode != .Debug) return;
    if (leak_dump_registered.swap(true, .acq_rel)) return;
    _ = c.napi_add_env_cleanup_hook(env, &dumpLeaksOnEnvCleanup, null);
}

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
    return getStringArgImpl(env, value, alloc, false);
}

/// `getStringArg` 와 동일하나 빈 문자열(`''`)을 유효 입력으로 허용한다 — null 은 napi 실패/비-string
/// 만 의미. transpile/tokenize 의 source 처럼 빈 입력이 정당한(빈 출력) 경우에 쓴다. (#4320)
pub fn getStringArgAllowEmpty(env: c.napi_env, value: c.napi_value, alloc: std.mem.Allocator) ?[]const u8 {
    return getStringArgImpl(env, value, alloc, true);
}

fn getStringArgImpl(env: c.napi_env, value: c.napi_value, alloc: std.mem.Allocator, allow_empty: bool) ?[]const u8 {
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, value, null, 0, &len) != c.napi_ok) return null;
    if (len == 0) return if (allow_empty) (alloc.dupe(u8, "") catch null) else null;
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

/// D105: lazy seed 경로 목록 → JS `[{ pathHash, path }]` 배열을 만들어 반환한다.
/// `pathHash` = `truncate(u32, Wyhash(0, path))` 8-hex — chunk.zig `lazy_path_hash` /
/// chunks.zig `chunkPlaceholderStem` 과 동일 공식이라, dev 서버가 요청 청크 URL
/// (`<stem>-<pathHash>.js`)의 hash 로 seed 를 역참조(JS 에서 Wyhash 재구현 없이)한다.
/// 같은 path 중복은 제거(graph.lazy_seeds 가 중복 보유 가능). **build()/watch() 결과 빌더
/// 공용** — Wyhash 공식을 한 곳에만 둬 두 경로 간 drift 차단.
pub fn buildLazySeedsJs(env: c.napi_env, paths: []const []const u8) c.napi_value {
    var js_seeds: c.napi_value = undefined;
    _ = c.napi_create_array(env, &js_seeds);
    var out_idx: u32 = 0;
    for (paths, 0..) |path, i| {
        var dup = false;
        for (paths[0..i]) |prev| if (std.mem.eql(u8, prev, path)) {
            dup = true;
            break;
        };
        if (dup) continue;

        var js_seed: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_seed);

        var hash_buf: [8]u8 = undefined;
        const h: u32 = @truncate(std.hash.Wyhash.hash(0, path));
        _ = std.fmt.bufPrint(&hash_buf, "{x:0>8}", .{h}) catch unreachable;
        var js_hash: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, &hash_buf, hash_buf.len, &js_hash);
        _ = c.napi_set_named_property(env, js_seed, "pathHash", js_hash);

        var js_path: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, path.ptr, path.len, &js_path);
        _ = c.napi_set_named_property(env, js_seed, "path", js_path);

        _ = c.napi_set_element(env, js_seeds, out_idx, js_seed);
        out_idx += 1;
    }
    return js_seeds;
}

/// `alloc(T, len)` 후 일부 element 만 채운 채 `result[0..count]` 를 반환하면
/// caller 가 그대로 free 시 alloc-size(`len`) vs free-size(`count`) mismatch
/// (`getStringArg` 와 동일 root cause). 정확히 `count` 길이로 줄여 반환한다.
/// 1차 시도 `alloc.realloc` (대부분 in-place shrink); 실패 시 새 alloc + memcpy
/// + 옛 free fallback. element 값 (slice 등 sub-alloc) 은 그대로 보존된다.
///
/// **OOM 시 `result` 미 free** — caller 가 `catch` 로 받아 element-specific
/// inner cleanup (element 가 owned sub-alloc 보유 시) 후 `alloc.free(result)`
/// 호출 책임. 이전 design 은 OOM 시 outer 만 free 하고 inner element 누수 —
/// PR #3691 review max 의 잔여 finding (rare 지만 contract 정확성).
pub fn shrinkSlice(comptime T: type, alloc: std.mem.Allocator, result: []T, count: usize) std.mem.Allocator.Error![]T {
    if (count == result.len) return result;
    if (alloc.realloc(result, count)) |shrunk| return shrunk else |_| {
        // realloc 실패 (희박) → 새 alloc + memcpy + 옛 free. 새 alloc 도 실패
        // 시 OOM error 반환 (result 유지, caller 가 cleanup).
        const shrunk = try alloc.alloc(T, count);
        @memcpy(shrunk, result[0..count]);
        alloc.free(result);
        return shrunk;
    }
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
    return shrinkSlice([]const u8, alloc, result, count) catch {
        for (result[0..count]) |s| alloc.free(s);
        alloc.free(result);
        return null;
    };
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
    return shrinkSlice([2][]const u8, alloc, result, count) catch {
        for (result[0..count]) |pair| {
            alloc.free(pair[0]);
            alloc.free(pair[1]);
        }
        alloc.free(result);
        return null;
    };
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
    return shrinkSlice(NullableStringPair, alloc, result, count) catch {
        for (result[0..count]) |pair| {
            alloc.free(pair[0]);
            if (pair[1]) |v| alloc.free(v);
        }
        alloc.free(result);
        return null;
    };
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
