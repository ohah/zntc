//! ZNTC Bundler — pipeline phase 정의
//!
//! `ModuleGraph` 의 mutation 은 엄격히 순차적인 phase 경계 안에서 일어난다.
//! mutation 자체는 graph/*.zig 내부 메서드가 `moduleAtMut` 로 수행하며, worker
//! race-safety 는 type 강제(accessor)가 아니라 아래 구조로 확보한다
//! (규약 전체는 docs/INVARIANTS.md):
//!   1. StableSegmentedList — append 해도 기존 `*Module` 포인터가 영구 유효
//!   2. phase 순차 join — parse worker 를 전부 join 한 뒤에만 resolve/link 진입
//!   3. worker 규약 — worker 는 자기 ModuleIndex 의 module 만 mutate
//!
//! `ModulePhase` 는 그 phase 경계를 명시하는 문서용 enum 이다.

const std = @import("std");

/// Module mutation 이 일어나는 pipeline phase. 엄격히 순차적이다.
/// - init: addModule (슬롯 예약, 한 번)
/// - parse: 파일 읽기 + AST/semantic 구축. worker thread, 자기 module 만 write
/// - resolve: import specifier → module index 매칭. main thread
/// - link: exec_index/cycle_group/dev_id 부여. main thread, single-pass
/// - emit: 코드 생성. read-only
pub const ModulePhase = enum {
    init,
    parse,
    resolve,
    link,
    emit,
};

test "ModulePhase enum has 5 variants" {
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(ModulePhase).@"enum".fields.len);
}
