//! Metro/RN project root discovery helpers for ModuleGraph.

const std = @import("std");
const fs = @import("../fs.zig");

/// 디렉토리에서 위로 올라가며 첫 `package.json` 위치를 찾는다.
/// Metro/RN CLI의 projectRoot 자동 감지와 동일 — 모노레포의 packages/app/처럼
/// entry가 깊은 곳에 있어도 그 패키지의 루트를 정확히 찾아낸다. 발견 못 하면
/// caller 입력(start_dir)을 fallback으로 반환.
/// 반환 slice는 입력 start_dir의 prefix이므로 caller가 free하지 않는다.
pub fn findProjectRoot(alloc: std.mem.Allocator, io: std.Io, start_dir: []const u8) ![]const u8 {
    var dir: []const u8 = start_dir;
    while (dir.len > 0) {
        const candidate = try std.fs.path.join(alloc, &.{ dir, "package.json" });
        defer alloc.free(candidate);
        if (fs.access(io, candidate)) |_| {
            return dir;
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len == dir.len) break; // 루트 (e.g. "/")
        dir = parent;
    }
    return start_dir;
}

const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "findProjectRoot: 일반 npm — src/index.ts → root는 package.json 위치" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{}");
    try writeFile(tmp.dir, "src/index.ts", "");

    const start = try absPath(&tmp, "src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, ".");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}

test "findProjectRoot: npm workspace — packages/app/index.ts → app의 package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"workspaces\": [\"packages/*\"]}");
    try writeFile(tmp.dir, "packages/app/package.json", "{\"name\": \"app\"}");
    try writeFile(tmp.dir, "packages/app/index.ts", "");

    const start = try absPath(&tmp, "packages/app");
    defer std.testing.allocator.free(start);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(start, root);
}

test "findProjectRoot: pnpm workspace — packages/app/src/index.ts → app의 package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "pnpm-workspace.yaml", "packages:\n  - 'packages/*'\n");
    try writeFile(tmp.dir, "package.json", "{}");
    try writeFile(tmp.dir, "packages/app/package.json", "{\"name\": \"app\"}");
    try writeFile(tmp.dir, "packages/app/src/index.ts", "");

    const start = try absPath(&tmp, "packages/app/src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, "packages/app");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}

test "findProjectRoot: bun workspace — packages/app/src/index.ts → app의 package.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"workspaces\": [\"packages/*\"]}");
    try writeFile(tmp.dir, "bun.lockb", "");
    try writeFile(tmp.dir, "packages/app/package.json", "{\"name\": \"app\"}");
    try writeFile(tmp.dir, "packages/app/src/index.ts", "");

    const start = try absPath(&tmp, "packages/app/src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, "packages/app");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}

test "findProjectRoot: yarn pnp — .pnp.cjs + package.json 단일 패키지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{}");
    try writeFile(tmp.dir, ".pnp.cjs", "");
    try writeFile(tmp.dir, ".yarnrc.yml", "nodeLinker: pnp\n");
    try writeFile(tmp.dir, "src/index.ts", "");

    const start = try absPath(&tmp, "src");
    defer std.testing.allocator.free(start);
    const expected = try absPath(&tmp, ".");
    defer std.testing.allocator.free(expected);

    const root = try findProjectRoot(std.testing.allocator, start);
    try std.testing.expectEqualStrings(expected, root);
}
