const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking dynamic import, class-static, and size edge tests
// ============================================================

test "TreeShaking: dynamic import target module is preserved (#1260)" {
    // import("./foo") 로만 참조되는 모듈은 정적 import_binding이 없어도
    // 반드시 번들/출력에 포함되어야 한다. 정적 분석에서 제거되면 런타임에 모듈을
    // 찾을 수 없어 깨진다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const m = await import('./lazy');
        \\  return m.unique_lazy_export_token();
        \\}
    );
    try writeFile(tmp.dir, "lazy.ts",
        \\export function unique_lazy_export_token() { return "LAZY_OK_MARKER"; }
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
    // lazy.ts의 export가 tree-shake로 제거되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_OK_MARKER") != null);
}

test "TreeShaking: class with impure static field via getter access preserved (#1261)" {
    // esbuild 방식: 클래스가 미참조로 보여도 static field initializer가 impure면 보존.
    // 현재 purity.zig는 static field impurity를 이미 판정하나, 회귀 방지용 테스트.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function sideMarker() { console.log("SIDE_FIELD_INIT"); return 1; }
        \\export class Unused {
        \\  static x = sideMarker();
        \\}
    );

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
    // sideMarker() 호출이 static field로 래핑되어 있어도 side-effect이므로 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_FIELD_INIT") != null);
}

test "TreeShaking: pure static field in unused class is removed (#1261 companion)" {
    // 반대로 pure한 static field만 있는 미사용 class는 제거되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\export class Unused {
        \\  static x = 42;
        \\  static y = "PURE_FIELD_MARKER";
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_FIELD_MARKER") == null);
}

test "TreeShaking: dynamic import transitive dependency preserved (#1260 edge)" {
    // import("./lazy") → lazy.ts가 re-export from './deep'인 경우
    // deep.ts의 export도 보존되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const m = await import('./lazy');
        \\  return m.token();
        \\}
    );
    try writeFile(tmp.dir, "lazy.ts", "export { token } from './deep';");
    try writeFile(tmp.dir, "deep.ts",
        \\export function token() { return "DEEP_TRANSITIVE_MARKER"; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEEP_TRANSITIVE_MARKER") != null);
}

test "TreeShaking: dynamic import deep chain (3 levels) preserved (#1260 edge)" {
    // entry -> dyn import a -> static b -> static c — c의 export가 reached
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const a = await import('./a');
        \\  return a.chain();
        \\}
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { fromB } from './b';
        \\export function chain() { return fromB(); }
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { fromC } from './c';
        \\export function fromB() { return fromC(); }
    );
    try writeFile(tmp.dir, "c.ts",
        \\export function fromC() { return "CHAIN_LEVEL3_MARKER"; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CHAIN_LEVEL3_MARKER") != null);
}

test "TreeShaking: dynamic + static import of same module coexist (#1260 edge)" {
    // 동일 모듈이 static import와 dynamic import로 동시 참조될 때
    // 둘 다 올바르게 동작하고 중복 번들되지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { eager } from './shared';
        \\export async function mix() {
        \\  const m = await import('./shared');
        \\  return eager() + m.lazy();
        \\}
    );
    try writeFile(tmp.dir, "shared.ts",
        \\export function eager() { return "EAGER_MARKER"; }
        \\export function lazy() { return "LAZY_MARKER"; }
        \\export function unused() { return "UNUSED_MARKER"; }
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
    // dynamic import는 전체 export 보존이므로 unused도 남아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EAGER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_MARKER") != null);
}

test "TreeShaking: dynamic import with non-static specifier does not protect (#1260 edge)" {
    // import(variable) 처럼 정적 해석 불가한 경우 resolved가 none이므로
    // 보호 대상 아님 — 미참조 모듈은 정상적으로 tree-shake되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './a';
        \\declare const name: string;
        \\export async function load() {
        \\  const m = await import(/* non-static */ name as string);
        \\  return (m as any).x;
        \\}
        \\console.log(used());
    );
    try writeFile(tmp.dir, "a.ts", "export function used() { return 'A_USED'; }");
    try writeFile(tmp.dir, "b.ts",
        \\export function unused() { return "B_UNRELATED_MARKER"; }
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
    // b.ts는 참조 자체가 없으므로 원래부터 번들에 없음 — 정상 제거 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_UNRELATED_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A_USED") != null);
}

test "TreeShaking: class static block side-effect preserved (#1261 edge)" {
    // static initialization block도 side-effect로 간주되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function marker() { console.log("STATIC_BLOCK_MARKER"); return 1; }
        \\export class Unused {
        \\  static { marker(); }
        \\}
    );

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "STATIC_BLOCK_MARKER") != null);
}

test "TreeShaking: size regression — 1-of-N named imports (#1262)" {
    // 10개 export 중 1개만 import 시 나머지 9개는 제거되어야 한다.
    // 회귀 시 번들 크기가 threshold 초과로 실패.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn5 } from './lib';
        \\console.log(fn5());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function fn0() { return "PAYLOAD_0"; }
        \\export function fn1() { return "PAYLOAD_1"; }
        \\export function fn2() { return "PAYLOAD_2"; }
        \\export function fn3() { return "PAYLOAD_3"; }
        \\export function fn4() { return "PAYLOAD_4"; }
        \\export function fn5() { return "PAYLOAD_5"; }
        \\export function fn6() { return "PAYLOAD_6"; }
        \\export function fn7() { return "PAYLOAD_7"; }
        \\export function fn8() { return "PAYLOAD_8"; }
        \\export function fn9() { return "PAYLOAD_9"; }
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
    // 사용된 fn5만 남고 나머지 9개는 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PAYLOAD_5") != null);
    for ([_][]const u8{ "PAYLOAD_0", "PAYLOAD_1", "PAYLOAD_2", "PAYLOAD_3", "PAYLOAD_4", "PAYLOAD_6", "PAYLOAD_7", "PAYLOAD_8", "PAYLOAD_9" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
}

test "TreeShaking: size regression — deep re-export chain only used exports (#1262)" {
    // barrel → a,b,c → 각각 2개씩 export. entry는 a.used만. 나머지 5개 제거.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_a } from './barrel';
        \\console.log(used_a());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used_a, unused_a } from './a';
        \\export { used_b, unused_b } from './b';
        \\export { used_c, unused_c } from './c';
    );
    try writeFile(tmp.dir, "a.ts",
        \\export function used_a() { return "USED_A_MARKER"; }
        \\export function unused_a() { return "UNUSED_A_MARKER"; }
    );
    try writeFile(tmp.dir, "b.ts",
        \\export function used_b() { return "USED_B_MARKER"; }
        \\export function unused_b() { return "UNUSED_B_MARKER"; }
    );
    try writeFile(tmp.dir, "c.ts",
        \\export function used_c() { return "USED_C_MARKER"; }
        \\export function unused_c() { return "UNUSED_C_MARKER"; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_A_MARKER") != null);
    for ([_][]const u8{ "UNUSED_A_MARKER", "USED_B_MARKER", "UNUSED_B_MARKER", "USED_C_MARKER", "UNUSED_C_MARKER" }) |m| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, m) == null);
    }
}
