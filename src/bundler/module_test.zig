const std = @import("std");
const module = @import("module.zig");
const Module = module.Module;

// ============================================================
// Tests
// ============================================================

test "Module: init defaults" {
    const m = Module.init(@enumFromInt(0), "src/index.ts");
    try std.testing.expectEqual(Module.State.reserved, m.state);
    try std.testing.expectEqual(std.math.maxInt(u32), m.exec_index);
    try std.testing.expectEqual(@as(u32, 0), m.cycle_group);
    try std.testing.expect(m.side_effects);
    try std.testing.expect(m.ast == null);
    try std.testing.expectEqual(@as(usize, 0), m.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.importers.items.len);
}

test "Module: state transitions" {
    var m = Module.init(@enumFromInt(0), "test.ts");
    defer m.deinit(std.testing.allocator);

    try std.testing.expectEqual(Module.State.reserved, m.state);
    m.state = .parsing;
    try std.testing.expectEqual(Module.State.parsing, m.state);
    m.state = .ready;
    try std.testing.expectEqual(Module.State.ready, m.state);
}

test "bundleOrderLessThan: exec_index 동률 시 path 사전순" {
    // exec_index 동률(초기값 maxInt(u32))에서 stable sort 가 input 순(= module_index)을
    // 보존하던 비결정성을 path 사전순 tie-break 로 차단하는지 검증.
    //
    // ⚠️ 예전 주석은 "dynamic-only 미방문 모듈은 모두 maxInt 라 항상 동률" 이라고 썼는데,
    // #4520 부터는 `import()` 전용 모듈도 DFS 루트가 되어 **진짜 exec_index 를 받는다**
    // (그전엔 방출 순서가 의존성 역순이라 TDZ 였다). 그래서 동률은 이제 "DFS 가 아직
    // 방문하지 않은 모듈"(external/미해결 등)에서만 생긴다 — tie-break 자체는 그대로 필요하다.
    var a = Module.init(@enumFromInt(0), "z/last.ts");
    var b = Module.init(@enumFromInt(1), "a/first.ts");
    // exec_index 동률 (default maxInt)
    try std.testing.expectEqual(a.exec_index, b.exec_index);
    // path 사전순 — a/first.ts 가 z/last.ts 보다 우선
    try std.testing.expect(Module.bundleOrderLessThan({}, &b, &a));
    try std.testing.expect(!Module.bundleOrderLessThan({}, &a, &b));
}

test "bundleOrderLessThan: exec_index 우선 (path 사전순 무시)" {
    var a = Module.init(@enumFromInt(0), "a/first.ts");
    var b = Module.init(@enumFromInt(1), "z/last.ts");
    a.exec_index = 10;
    b.exec_index = 5;
    // a 의 path 가 사전순 앞이지만 exec_index 가 더 커서 b 가 우선
    try std.testing.expect(Module.bundleOrderLessThan({}, &b, &a));
}
