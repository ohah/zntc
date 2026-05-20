//! Multi-format emit sanity tests (epic 진행 중).

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "multi-format: esm + cjs single path produces both outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 42;\nconsole.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .output = &.{
            .{ .format = .esm },
            .{ .format = .cjs },
        },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.outputs_by_format != null);
    try std.testing.expectEqual(@as(usize, 2), result.outputs_by_format.?.len);
    try std.testing.expectEqual(types.Format.esm, result.outputs_by_format.?[0].format);
    try std.testing.expectEqual(types.Format.cjs, result.outputs_by_format.?[1].format);
    // 첫 entry 의 output 은 result.output 으로 move — by[0].output 은 빈 슬라이스.
    try std.testing.expectEqual(@as(usize, 0), result.outputs_by_format.?[0].output.len);
    try std.testing.expect(result.output.len > 0);
    // 두 번째 entry 는 정상 보유.
    try std.testing.expect(result.outputs_by_format.?[1].output.len > 0);
}

test "multi-format: dev_mode rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .output = &.{
            .{ .format = .esm },
            .{ .format = .cjs },
        },
    });
    defer b.deinit();

    const result = b.bundle();
    try std.testing.expectError(error.MultiFormatRequiresSinglePath, result);
}
