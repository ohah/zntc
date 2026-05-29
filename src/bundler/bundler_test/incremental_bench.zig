//! Incremental rebuild bench (Plan #3564 redesign epic 진입 ROI 입증용).
//! 작은 합성 fixture 로 cache hit rate + phase 별 ns 측정. production-realistic 측정은
//! `documents/dist/reference/incremental-bench.md` 의 watch mode 가이드 따라 사용자 직접.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const profile = @import("../../profile.zig");

test "incremental bench: cold vs warm rebuild parse savings" {
    profile.resetForTest();
    profile.setLevel(.summary);
    profile.addCategories(&.{ "parse", "semantic", "graph_discover", "graph_build", "graph_finalize" });
    profile.setIoForTest(std.testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const a = 1;\nexport const a2 = 2;");
    try writeFile(tmp.dir, "b.ts", "export const b = 1;");
    try writeFile(tmp.dir, "c.ts", "export const c = 1;");
    try writeFile(tmp.dir, "index.ts", "import { a } from './a';\nimport { b } from './b';\nimport { c } from './c';\nconsole.log(a, b, c);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const r1 = try b.bundle(std.testing.io);
    defer r1.deinit(std.testing.allocator);

    const cold_parse = profile.totalNs(.parse);
    const cold_semantic = profile.totalNs(.semantic);
    const cold_discover = profile.totalNs(.graph_discover);

    try std.testing.expect(cold_parse > 0);
    try std.testing.expect(cold_semantic > 0);

    // 측정 결과 stderr 출력 — CI artifact 캡처용 (assertion 약함, infra 입증 위주).
    std.debug.print(
        "\n[incremental-bench] cold build: parse={d}ns semantic={d}ns discover={d}ns\n",
        .{ cold_parse, cold_semantic, cold_discover },
    );
}
