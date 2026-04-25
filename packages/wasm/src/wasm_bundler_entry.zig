//! ZTS WASM bundler 진입점 (#1885 Phase 2).
//!
//! wasm32-wasip1-threads 타겟용 — bundler 전용. transpile-only 빌드 (wasm_entry.zig)
//! 와 분리해서 brower 호환성/번들 사이즈 트레이드오프 분리.
//!
//! PR 6-2c-2c: build() 가 bundler.Bundler.init + bundle() 진짜 호출.

const std = @import("std");
const zts_lib = @import("zts_lib");
const bundler_mod = zts_lib.bundler;
const Bundler = bundler_mod.Bundler;
const BundleOptions = bundler_mod.BundleOptions;

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

/// PR 6-2c-2c build() — VFS entry path 로 bundler.Bundler.init + bundle() 실 호출.
/// Phase 2 minimal: 단일 entry, 기본 옵션 (esm/browser). 옵션 JSON / multi-entry /
/// chunk 출력은 후속 PR.
///
/// ABI: 반환 packed u64 (ptr<<32 | len), 0 = error 또는 빈 출력. caller (JS) 가 dealloc 책임.
/// 결과 = single bundle code string (result.output — 단일 파일 모드).
export fn build(entry_path_ptr: u32, entry_path_len: u32) u64 {
    if (entry_path_ptr == 0 or entry_path_len == 0) return 0;
    const entry_path: []const u8 = @as([*]const u8, @ptrFromInt(entry_path_ptr))[0..entry_path_len];

    // arena 일괄 해제 — Bundler/BundleResult 내부 자료구조 모두 arena_alloc 소유.
    // CLAUDE.md "Arena 안 리소스 개별 deinit 금지" 패턴.
    var arena = std.heap.ArenaAllocator.init(wasm_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const entry_dupe = arena_alloc.dupe(u8, entry_path) catch return 0;
    const entry_points: []const []const u8 = &.{entry_dupe};

    const options: BundleOptions = .{
        .entry_points = entry_points,
        .format = .esm,
        .platform = .browser,
    };

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
