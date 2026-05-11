const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking dead statement import reference tests
// ============================================================

test "TreeShaking: dead statement references don't keep upstream module (#1551)" {
    // svelte/store readable 누수 재현:
    //   entry → barrel의 readable만 사용. barrel 내 unused_fn이 runtime를 참조.
    //   unused_fn은 statement-level DCE로 제거되지만 AST에 참조가 남아
    //   processModuleImports의 reference_count > 0 판정에 의해 runtime이
    //   가짜 used로 마킹되는 문제(#1551). #1558 Step 3+4에서 BFS fixpoint 통합 +
    //   live_mod_idx로 정정 (reachable statement 안의 import만 used로 마킹).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const UPSTREAM_MARKER = "RUNTIME_LEAKED";
        \\export const UPSTREAM_B = "B_LEAKED";
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { UPSTREAM_MARKER, UPSTREAM_B } from './runtime';
        \\export function readable(v: number) { return { value: v }; }
        \\export function unused_fn() {
        \\  return UPSTREAM_MARKER + UPSTREAM_B;
        \\}
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { readable } from './barrel';
        \\console.log(readable(42).value);
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RUNTIME_LEAKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_LEAKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unused_fn") == null);
}

test "TreeShaking: dead statement import chain 2 hops removed (#1551)" {
    // 2-hop 체인: entry → mid. mid는 live export + dead export.
    // dead 함수 안에서만 runtime 참조 — 체인 전체가 제거되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const RUNTIME_TWO_HOP_MARKER = "LEAKED_TWO_HOP";
    );
    try writeFile(tmp.dir, "mid.ts",
        \\import { RUNTIME_TWO_HOP_MARKER } from './runtime';
        \\export function used_mid(n: number) { return n * 2; }
        \\export function dead_mid() { return RUNTIME_TWO_HOP_MARKER; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_mid } from './mid';
        \\console.log(used_mid(21));
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "used_mid") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LEAKED_TWO_HOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_mid") == null);
}

test "TreeShaking: live statement preserves upstream module (#1551 anti-regression)" {
    // 반대 케이스: runtime import가 live 함수에서 참조되면 runtime 모듈은 보존.
    // 보호 모듈 집합(alias 타겟)이 정상 동작하는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const RUNTIME_LIVE = "RUNTIME_STILL_NEEDED";
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { RUNTIME_LIVE } from './runtime';
        \\export function hello() { return RUNTIME_LIVE; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { hello } from './barrel';
        \\console.log(hello());
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RUNTIME_STILL_NEEDED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}
