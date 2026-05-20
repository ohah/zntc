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

test "multi-format: single esm equals multi[esm,cjs].esm (byte-identical)" {
    // 회귀 게이트: 동일 fixture 를 (1) single format=esm 으로 빌드 vs (2) multi
    // output=[esm,cjs] 로 빌드 — ESM 결과가 byte-identical 이어야 함. multi-emit 의
    // setEmitFormat/resetEmitTransients invariant 가 single 경로와 동등 동작 보장.
    const source = "export const x = 42;\nexport function add(a, b) { return a + b; }\nconsole.log(x);";

    var tmp_single = std.testing.tmpDir(.{});
    defer tmp_single.cleanup();
    try writeFile(tmp_single.dir, "index.ts", source);
    const entry_single = try absPath(&tmp_single, "index.ts");
    defer std.testing.allocator.free(entry_single);

    var b_single = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry_single},
        .format = .esm,
    });
    defer b_single.deinit();
    const r_single = try b_single.bundle();
    defer r_single.deinit(std.testing.allocator);

    var tmp_multi = std.testing.tmpDir(.{});
    defer tmp_multi.cleanup();
    try writeFile(tmp_multi.dir, "index.ts", source);
    const entry_multi = try absPath(&tmp_multi, "index.ts");
    defer std.testing.allocator.free(entry_multi);

    var b_multi = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry_multi},
        .output = &.{
            .{ .format = .esm },
            .{ .format = .cjs },
        },
    });
    defer b_multi.deinit();
    const r_multi = try b_multi.bundle();
    defer r_multi.deinit(std.testing.allocator);

    // single 의 output == multi 의 ESM (첫 entry, result.output 으로 move 된 상태).
    try std.testing.expectEqualStrings(r_single.output, r_multi.output);
}

test "multi-format: order invariant — [esm,cjs] vs [cjs,esm] produces same per-format outputs" {
    // 순서 무관: output 배열의 순서만 바꿔도 각 format 의 결과는 동일.
    // setEmitFormat 의 reset 이 transient state 를 정확히 cleanup 함을 보장.
    const source = "export const greet = (n) => `hi ${n}`;\nconsole.log(greet('a'));";

    var tmp_ab = std.testing.tmpDir(.{});
    defer tmp_ab.cleanup();
    try writeFile(tmp_ab.dir, "index.ts", source);
    const entry_ab = try absPath(&tmp_ab, "index.ts");
    defer std.testing.allocator.free(entry_ab);

    var b_ab = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry_ab},
        .output = &.{ .{ .format = .esm }, .{ .format = .cjs } },
    });
    defer b_ab.deinit();
    const r_ab = try b_ab.bundle();
    defer r_ab.deinit(std.testing.allocator);

    var tmp_ba = std.testing.tmpDir(.{});
    defer tmp_ba.cleanup();
    try writeFile(tmp_ba.dir, "index.ts", source);
    const entry_ba = try absPath(&tmp_ba, "index.ts");
    defer std.testing.allocator.free(entry_ba);

    var b_ba = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry_ba},
        .output = &.{ .{ .format = .cjs }, .{ .format = .esm } },
    });
    defer b_ba.deinit();
    const r_ba = try b_ba.bundle();
    defer r_ba.deinit(std.testing.allocator);

    // [esm,cjs] 의 esm (= r_ab.output, 첫 entry) == [cjs,esm] 의 esm (= r_ba.outputs_by_format[1].output, 두 번째 entry)
    try std.testing.expectEqualStrings(r_ab.output, r_ba.outputs_by_format.?[1].output);
    // [esm,cjs] 의 cjs (= r_ab.outputs_by_format[1].output, 두 번째 entry) == [cjs,esm] 의 cjs (= r_ba.output, 첫 entry)
    try std.testing.expectEqualStrings(r_ab.outputs_by_format.?[1].output, r_ba.output);
}

test "multi-format: memory safety — repeated multi-emit no leak" {
    // std.testing.allocator 는 leak 시 test fail. 3회 반복 multi-emit 후 누수 없음 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;\nexport default x;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .output = &.{ .{ .format = .esm }, .{ .format = .cjs } },
        });
        defer b.deinit();
        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(result.outputs_by_format != null);
    }
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
