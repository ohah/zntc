const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking inner graph and write-liveness tests
// ============================================================

test {
    _ = @import("inner_graph_declarations.zig");
    _ = @import("inner_graph_export_writes.zig");
    _ = @import("inner_graph_scope_writes.zig");
    _ = @import("inner_graph_write_edges.zig");
}

test "TreeShaking: innerGraph prunes unused pure entry locals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const used = "INNER_GRAPH_USED_CONST";
        \\const unused = "INNER_GRAPH_UNUSED_CONST";
        \\function usedFn() { return "INNER_GRAPH_USED_FN"; }
        \\function unusedFn() { return "INNER_GRAPH_UNUSED_FN"; }
        \\console.log(used, usedFn());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_USED_CONST") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_USED_FN") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_UNUSED_CONST") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_UNUSED_FN") == null);
}

test "TreeShaking: --pure callee hints prune unused exact and wildcard calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const used = makeUsed("PURE_USED_CALL");
        \\const unused = makeUnused("PURE_UNUSED_CALL");
        \\const element = React.createElement("div", { title: "PURE_REACT_CALL" });
        \\const prop = PropTypes.string.isRequired("PURE_WILDCARD_CALL");
        \\React.cloneElement("PURE_NONMATCHING_MEMBER_CALL");
        \\console.log(used);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
        .pure = &.{ "makeUnused", "React.createElement", "PropTypes.*" },
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_USED_CALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_UNUSED_CALL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_REACT_CALL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_WILDCARD_CALL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_NONMATCHING_MEMBER_CALL") != null);
}

test "TreeShaking: innerGraph preserves entry side-effect initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const unused = sideEffect();
        \\console.log("INNER_GRAPH_ENTRY");
        \\function sideEffect() {
        \\  console.log("INNER_GRAPH_SIDE_EFFECT_INIT");
        \\  return 1;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_EFFECT_INIT") != null);
}

test "TreeShaking: innerGraph preserves entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const publicValue = "INNER_GRAPH_PUBLIC_EXPORT";
        \\const privateUnused = "INNER_GRAPH_PRIVATE_UNUSED";
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_PUBLIC_EXPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_PRIVATE_UNUSED") == null);
}
