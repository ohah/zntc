//! ZTS WASM bundler 진입점 (#1885 Phase 2).
//!
//! wasm32-wasip1-threads 타겟용 — bundler 전용. transpile-only 빌드 (wasm_entry.zig)
//! 와 분리해서 brower 호환성/번들 사이즈 트레이드오프 분리.
//!
//! Phase 2 PR 6-2a 단계: 컴파일 검증만. build() export 는 PR 6-2c.

const std = @import("std");
const zts_lib = @import("zts_lib");

pub const panic = zts_lib.crash_handler.panic;

const wasm_alloc = std.heap.wasm_allocator;

// 컴파일 검증용 — bundler 가 wasm32-wasip1-threads 환경에서 link 가능한지 확인.
// PR 6-2c 에서 진짜 build() 호출 + 인자/결과 ABI 구현.
export fn bundler_version() u32 {
    // Phase 2 의 ABI version stub — 호스트 측 호환성 체크용.
    return 1;
}
