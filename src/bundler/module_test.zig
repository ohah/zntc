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

test "Module: addDependency bidirectional" {
    const alloc = std.testing.allocator;
    var modules: [2]Module = .{
        Module.init(@enumFromInt(0), "a.ts"),
        Module.init(@enumFromInt(1), "b.ts"),
    };
    defer modules[0].deinit(alloc);
    defer modules[1].deinit(alloc);

    // A depends on B
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);

    // A.dependencies에 B가 있어야 함
    try std.testing.expectEqual(@as(usize, 1), modules[0].dependencies.items.len);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(modules[0].dependencies.items[0]));

    // B.importers에 A가 있어야 함 (역방향)
    try std.testing.expectEqual(@as(usize, 1), modules[1].importers.items.len);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(modules[1].importers.items[0]));
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

test "Module: addDependency with none index — no-op" {
    const alloc = std.testing.allocator;
    var modules: [1]Module = .{Module.init(@enumFromInt(0), "a.ts")};
    defer modules[0].deinit(alloc);

    try modules[0].addDependency(alloc, .none, &modules);
    try std.testing.expectEqual(@as(usize, 0), modules[0].dependencies.items.len);
}

test "Module: addDependency with out-of-bounds index — no-op" {
    const alloc = std.testing.allocator;
    var modules: [1]Module = .{Module.init(@enumFromInt(0), "a.ts")};
    defer modules[0].deinit(alloc);

    try modules[0].addDependency(alloc, @enumFromInt(99), &modules);
    try std.testing.expectEqual(@as(usize, 0), modules[0].dependencies.items.len);
}
