//! ZTS WASM bundler 진입점 (#1885 Phase 2).
//!
//! wasm32-wasip1-threads 타겟용 — bundler 전용. transpile-only 빌드 (wasm_entry.zig)
//! 와 분리해서 brower 호환성/번들 사이즈 트레이드오프 분리.
//!
//! PR 6-2c-1: minimal build() — JS bridge (zts_fs callback round-trip) 검증.
//! 실제 bundler.bundle() 호출은 PR 6-2c-2.

const std = @import("std");
const zts_lib = @import("zts_lib");
const fs = zts_lib.bundler.fs;

pub const panic = zts_lib.crash_handler.panic;

// Zig 0.15 의 wasm_allocator 는 multi-threaded 미지원 (page_allocator 도 내부 wasm_allocator
// 사용) — wasi-musl 의 c_allocator (thread-safe malloc) 사용. JS 측은 wasi_snapshot_preview1
// 의 모든 fn 을 stub 으로 제공.
const wasm_alloc = std.heap.c_allocator;

// wasi-musl libc 가 `main` 심볼 강제 — entry=.disabled (reactor 모드) 와 충돌.
// 미호출 stub 으로 link 통과.
pub fn main() void {}

/// Bundler ABI version. host 가 호환성 체크용.
export fn bundler_version() u32 {
    return 1;
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

/// PR 6-2c-1 minimal build() — VFS entry path 받아 fs.readFile 통과 (zts_fs callback)
/// → contents 직접 반환 (echo). bundler.bundle() 호출은 PR 6-2c-2.
///
/// ABI: 반환 packed u64 (ptr<<32 | len), 0 = error. caller (JS) 가 dealloc 책임.
export fn build(entry_path_ptr: u32, entry_path_len: u32) u64 {
    if (entry_path_ptr == 0 or entry_path_len == 0) return 0;
    const entry_path: []const u8 = @as([*]const u8, @ptrFromInt(entry_path_ptr))[0..entry_path_len];

    const loaded = fs.readFile(wasm_alloc, entry_path, 100 * 1024 * 1024) catch return 0;
    const out_ptr: u32 = @intCast(@intFromPtr(loaded.contents.ptr));
    const out_len: u32 = @intCast(loaded.contents.len);
    return (@as(u64, out_ptr) << 32) | @as(u64, out_len);
}
