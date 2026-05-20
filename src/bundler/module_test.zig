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
    // dynamic-only 미방문 모듈은 모두 exec_index = maxInt(u32) — 동률 처리에서
    // stable sort 가 input 순(= module_index) 보존하던 비결정성 차단 검증.
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
