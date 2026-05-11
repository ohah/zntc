const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking integration tests
// ============================================================

test {
    _ = @import("tree_shake/cjs.zig");
    _ = @import("tree_shake/inner_graph.zig");
    _ = @import("tree_shake/lazy_barrel.zig");
    _ = @import("tree_shake/edge_cases.zig");
    _ = @import("tree_shake/re_exports.zig");
}

test "TreeShaking: unused side_effects=false module excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts imports only b. c.ts is imported by b but side_effects=false + nobody uses c's exports.
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");
    try writeFile(tmp.dir, "c.ts", "export const dead_code = 'should not appear';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // Bundler를 직접 사용하면 c.ts는 graph에 없음 (a.ts가 import하지 않으므로).
    // tree-shaking은 graph에 있는데 아무도 사용하지 않는 모듈을 제거.
    // 실제 테스트: b.ts가 c.ts를 import하지만 c.ts의 export를 사용하지 않는 경우.
    try writeFile(tmp.dir, "b.ts", "import './c';\nexport const x = 42;");

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // x는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // c.ts는 pure code만 있으므로 auto-pure 감지로 side_effects=false → 제외됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_code") == null);
}

test "TreeShaking: tree_shaking=false preserves all modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1;") != null);
}

test "TreeShaking: entry point exports preserved in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const a = 1;\nexport const b = 2;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 진입점의 모든 export가 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

test "TreeShaking: only used exports from dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { used } from './b'; console.log(used);");
    try writeFile(tmp.dir, "b.ts", "export const used = 'yes'; export const unused = 'no';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // used는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
    // unused는 statement-level tree-shaking으로 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no\"") == null);
}

test "TreeShaking: re-export chain dependency included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "TreeShaking: side-effect-only import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './polyfill';\nconst x = 1;");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.myPolyfill = true;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill.ts는 side_effects=true (기본) → 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "myPolyfill") != null);
}

test "TreeShaking: side-effect-only CJS import emits require call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import './cjs.js';\nconsole.log('entry');");
    try writeFile(tmp.dir, "cjs.js", "module.exports = {}; globalThis.cjsSideEffectImport = true;");

    const entry = try absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cjsSideEffectImport") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjs();") != null);
}

test "TreeShaking: runBeforeMain import-only root preserves side-effect dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log('entry');");
    try writeFile(tmp.dir, "prelude.ts", "import './polyfill';");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.runBeforeMainPolyfill = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const prelude = try absPath(&tmp, "prelude.ts");
    defer std.testing.allocator.free(prelude);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .run_before_main = &.{prelude},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "runBeforeMainPolyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_prelude") != null);
}

// ============================================================
// @__PURE__ annotation tests
// ============================================================

test "@__PURE__: annotation preserved in call expression output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: annotation preserved with #__PURE__ syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* #__PURE__ */ bar();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: annotation on new expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ new Foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: no annotation when not present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@__PURE__") == null);
}

test "@__PURE__: annotation not emitted in minify mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@__PURE__") == null);
}

test "@__PURE__: applies to first call only in chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // /* @__PURE__ */ a().b() → @__PURE__는 a()에만, b()에는 적용 안 됨
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ a().b();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // @__PURE__가 정확히 1번만 출력
    const output = result.output;
    const first = std.mem.indexOf(u8, output, "/* @__PURE__ */");
    try std.testing.expect(first != null);
    // 두 번째가 없어야 함
    if (first) |pos| {
        try std.testing.expect(std.mem.indexOf(u8, output[pos + 15 ..], "/* @__PURE__ */") == null);
    }
}

test "@__PURE__: preserved across modules in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { create } from './b'; const x = /* @__PURE__ */ create();");
    try writeFile(tmp.dir, "b.ts", "export function create() { return {}; }");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// package.json sideEffects integration tests
// ============================================================

test "sideEffects: package.json sideEffects=false auto-applied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './node_modules/mypkg/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{"name":"mypkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/mypkg/index.js", "export const x = 1; console.log('should be removed');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "should be removed") == null);
}

test "sideEffects: package.json sideEffects=true keeps module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/polyfill/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/polyfill/package.json",
        \\{"name":"polyfill","sideEffects":true}
    );
    try writeFile(tmp.dir, "node_modules/polyfill/index.js", "globalThis.polyfilled = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "polyfilled") != null);
}

test "sideEffects: no package.json field keeps default true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/nopkg/index.js';");
    try writeFile(tmp.dir, "node_modules/nopkg/package.json",
        \\{"name":"nopkg"}
    );
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "console.log('included');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "included") != null);
}

// ============================================================
// @__NO_SIDE_EFFECTS__ tests
// ============================================================

test "@__NO_SIDE_EFFECTS__: function flag preserved in bundle output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // @__NO_SIDE_EFFECTS__ 함수를 import해서 호출
    try writeFile(tmp.dir, "entry.ts",
        \\import { create } from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function create") != null);
    // cross-module @__NO_SIDE_EFFECTS__ 전파: import한 함수의 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: call to annotated function auto-pure in single file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ function create() { return {}; }
        \\const x = create();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // create() 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: function expression variant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\const make = /* @__NO_SIDE_EFFECTS__ */ function() { return {}; };
        \\const x = make();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // make() 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: cross-module re-export chain" {
    // a.ts → b.ts (re-export) → c.ts (원본 @__NO_SIDE_EFFECTS__)
    // a.ts에서 호출 시 /* @__PURE__ */ 출력되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { create } from './re-export';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "re-export.ts", "export { create } from './lib';");
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: cross-module multiple imports" {
    // 여러 함수 중 하나만 @__NO_SIDE_EFFECTS__ — 해당 호출만 pure
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { pure, impure } from './lib';
        \\const a = pure();
        \\const b = impure();
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ export function pure() { return 1; }
        \\export function impure() { return 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // pure() 호출에만 /* @__PURE__ */ 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
    // /* @__PURE__ */ 는 1번만 나와야 함 (impure() 호출에는 없음)
    const first = std.mem.indexOf(u8, result.output, "/* @__PURE__ */").?;
    const second = std.mem.indexOf(u8, result.output[first + 1 ..], "/* @__PURE__ */");
    try std.testing.expect(second == null);
}

test "@__NO_SIDE_EFFECTS__: cross-module default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import create from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export default function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: no false positive on normal import" {
    // @__NO_SIDE_EFFECTS__ 없는 함수는 pure 마킹 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { normal } from './lib';
        \\const x = normal();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "export function normal() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // /* @__PURE__ */ 가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") == null);
}

test "@__NO_SIDE_EFFECTS__: export default async function" {
    // async 키워드가 @__NO_SIDE_EFFECTS__ 전파를 끊지 않는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import create from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export default async function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: export async function (named)" {
    // export async function도 @__NO_SIDE_EFFECTS__ 전파됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchData } from './lib';
        \\const x = fetchData();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export async function fetchData() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: single-file async function" {
    // 단일 파일에서도 async function @__NO_SIDE_EFFECTS__ 동작 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ async function create() { return {}; }
        \\const x = create();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// Integration: real-world patterns
// ============================================================

test "Integration: barrel file tree-shaking with sideEffects=false" {
    // barrel index에서 하나만 import → sideEffects=false면 미사용 모듈 제거
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "barrel/a.ts", "export const used = 'a';");
    try writeFile(tmp.dir, "barrel/b.ts", "export const unused = 'b';");
    try writeFile(tmp.dir, "barrel/package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // used가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    // sideEffects=false이므로 b.ts가 미사용 → 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"b\"") == null);
}

test "Integration: lazy barrel skips empty direct re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export { value } from './real';");
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_USED';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips multiple direct re-export sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b } from './barrel';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './a';
        \\export { b } from './b';
    );
    try writeFile(tmp.dir, "a.ts", "export const a = 'LAZY_BARREL_A';");
    try writeFile(tmp.dir, "b.ts", "export const b = 'LAZY_BARREL_B';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips default-as-named direct re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export { default as value } from './real';");
    try writeFile(tmp.dir, "real.ts", "export default 'LAZY_BARREL_DEFAULT';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_DEFAULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips export-star re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "barrel.ts", "export * from './source';");
    try writeFile(tmp.dir, "source.ts",
        \\export function used() { return 'LAZY_BARREL_STAR_USED'; }
        \\export function unused() { return 'LAZY_BARREL_STAR_UNUSED'; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_STAR_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_STAR_UNUSED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips export-star module with unused ambiguous names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { onlyA } from './barrel';
        \\console.log(onlyA);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './a';
        \\export * from './b';
    );
    try writeFile(tmp.dir, "a.ts",
        \\export const onlyA = 'LAZY_BARREL_ONLY_A';
        \\export const shared = 'LAZY_BARREL_SHARED_A';
    );
    try writeFile(tmp.dir, "b.ts",
        \\export const onlyB = 'LAZY_BARREL_ONLY_B';
        \\export const shared = 'LAZY_BARREL_SHARED_B';
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_ONLY_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_ONLY_B") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_SHARED_A") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_SHARED_B") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips local named import re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { value } from './real';
        \\export { value };
    );
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_LOCAL_IMPORT';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_IMPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips local default import re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import value from './real';
        \\export { value };
    );
    try writeFile(tmp.dir, "real.ts", "export default 'LAZY_BARREL_LOCAL_DEFAULT';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_DEFAULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips local re-export with explicit extensions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { tsValue } from './barrel.ts';
        \\import { jsValue } from './js-barrel.js';
        \\console.log(tsValue, jsValue);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { tsValue } from './real.ts';
        \\export { tsValue };
    );
    try writeFile(tmp.dir, "real.ts", "export const tsValue = 'LAZY_BARREL_EXPLICIT_TS';");
    try writeFile(tmp.dir, "js-barrel.js",
        \\import { jsValue } from './real.js';
        \\export { jsValue };
    );
    try writeFile(tmp.dir, "real.js", "export const jsValue = 'LAZY_BARREL_EXPLICIT_JS';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_EXPLICIT_TS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_EXPLICIT_JS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "js-barrel.js") == null);
}

test "Integration: lazy barrel skips local re-export with side-effect import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import './side';
        \\import { value } from './real';
        \\export { value };
    );
    try writeFile(tmp.dir, "side.ts", "console.log('LAZY_BARREL_LOCAL_SIDE_EFFECT');");
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_LOCAL_SIDE_VALUE';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_SIDE_EFFECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_SIDE_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel does not skip side-effectful re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\console.log('BARREL_SIDE_EFFECT');
        \\export { value } from './real';
    );
    try writeFile(tmp.dir, "real.ts", "export const value = 'SIDE_EFFECT_BARREL_USED';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_EFFECT_BARREL_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "BARREL_SIDE_EFFECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") != null);
}

test "Integration: lazy barrel does not skip namespace re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ns } from './barrel';
        \\console.log(ns.value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export * as ns from './real';");
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_NAMESPACE';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_NAMESPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") != null);
}

test "Integration: lazy barrel does not skip local namespace re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ns } from './barrel';
        \\console.log(ns.value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import * as ns from './real';
        \\export { ns };
    );
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_LOCAL_NAMESPACE';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_NAMESPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") != null);
}

test "Integration: lazy barrel skips auto-pure package-default re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export { value } from './real';");
    try writeFile(tmp.dir, "real.ts", "export const value = 'PACKAGE_DEFAULT_BARREL';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PACKAGE_DEFAULT_BARREL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: barrel file without sideEffects keeps all" {
    // sideEffects 필드 없으면 보수적으로 전부 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "lib/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "lib/a.ts", "export const used = 'a';");
    try writeFile(tmp.dir, "lib/b.ts",
        \\console.log('b side effect');
        \\export const unused = 'b';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    // sideEffects 없으므로 b.ts의 side effect 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "b side effect") != null);
}

test "Integration: diamond re-export resolves to same symbol" {
    // 같은 원본 symbol을 두 경로로 import → 선언이 한 번만 존재해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { shared as a } from './path-a';
        \\import { shared as b } from './path-b';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "path-a.ts", "export { shared } from './original';");
    try writeFile(tmp.dir, "path-b.ts", "export { shared } from './original';");
    try writeFile(tmp.dir, "original.ts", "export const shared = 'original';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared 선언이 한 번만 존재해야 함 (중복 불가)
    const first = std.mem.indexOf(u8, result.output, "\"original\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, result.output[first + 1 ..], "\"original\"") == null);
}

test "Integration: class extends across module boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Derived } from './derived';
        \\const d = new Derived();
        \\console.log(d.greet());
    );
    try writeFile(tmp.dir, "derived.ts",
        \\import { Base } from './base';
        \\export class Derived extends Base {
        \\  greet() { return super.greet() + ' world'; }
        \\}
    );
    try writeFile(tmp.dir, "base.ts",
        \\export class Base {
        \\  greet() { return 'hello'; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // scope hoisting 후에도 extends Base 참조가 유효해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extends Base") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Base") != null);
    // Base가 Derived보다 먼저 선언 (exec_index 순)
    const base_pos = std.mem.indexOf(u8, result.output, "class Base") orelse return error.TestUnexpectedResult;
    const derived_pos = std.mem.indexOf(u8, result.output, "class Derived") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_pos < derived_pos);
}

test "Integration: default and named re-export combined" {
    // default + named를 re-export하고 import — lodash-es/rxjs 패턴
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import theDefault, { named } from './re-export';
        \\console.log(theDefault, named);
    );
    try writeFile(tmp.dir, "re-export.ts", "export { default, named } from './lib';");
    try writeFile(tmp.dir, "lib.ts",
        \\export default function lib() { return 'default'; }
        \\export const named = 'named';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named\"") != null);
}

test "Integration: side-effect order with export star" {
    // export * 순서가 원본 import 순서와 일치해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { util } from './barrel';
        \\console.log(util);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './init';
        \\export * from './utils';
    );
    try writeFile(tmp.dir, "init.ts",
        \\console.log('1-init');
        \\export const init = true;
    );
    try writeFile(tmp.dir, "utils.ts",
        \\console.log('2-utils');
        \\export const util = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // init.ts가 utils.ts보다 먼저 실행 (import 순서)
    const init_pos = std.mem.indexOf(u8, result.output, "1-init") orelse return error.TestUnexpectedResult;
    const utils_pos = std.mem.indexOf(u8, result.output, "2-utils") orelse return error.TestUnexpectedResult;
    try std.testing.expect(init_pos < utils_pos);
}

test "Integration: deeply nested barrel re-exports" {
    // 3단 barrel: entry → barrel1 → barrel2 → lib
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { deep } from './barrel1';
        \\console.log(deep);
    );
    try writeFile(tmp.dir, "barrel1.ts", "export { deep } from './barrel2';");
    try writeFile(tmp.dir, "barrel2.ts", "export { deep } from './lib';");
    try writeFile(tmp.dir, "lib.ts", "export const deep = 'found';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"found\"") != null);
}

test "Integration: mixed default/named import from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import App, { version, config } from './app';
        \\console.log(App, version, config);
    );
    try writeFile(tmp.dir, "app.ts",
        \\export default class App { name = 'app'; }
        \\export const version = '1.0';
        \\export const config = { debug: true };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class App") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "debug") != null);
}

test "sideEffects: side-effect-only import to ESM module under __esm wrap invokes init (#1193)" {
    // Reanimated `layoutReanimation/index.ts`: `import './animationsManager'` +
    // `export * from './animationBuilder'`. animationsManager.ts는 ESM 모듈이며
    // RN 플랫폼에서 __esm 래핑된다. barrel(index.ts) factory body가 side-effect
    // import 대상의 init 함수를 호출하지 않으면 top-level side-effect가 실행되지
    // 않아 `global.LayoutAnimationsManager` 할당 누락 → UI Hermes SIGABRT.
    //
    // 주의: sideeffect 모듈이 CJS로 감지되면 기존 body rewrite가 require를 호출
    // 하므로 버그가 드러나지 않는다. .ts + export를 포함해 ESM으로 만들어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "pkg/index.ts",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "pkg/values.ts",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "pkg/sideeffect.ts",
        \\export {};
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // side-effect 본문이 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sideEffectRan") != null);

    // barrel(index.ts) init 함수 안에서 sideeffect ESM init이 호출되어야 한다.
    const index_init_start = std.mem.indexOf(u8, result.output, "var init_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    try std.testing.expect(std.mem.indexOf(u8, index_init_block, "init_sideeffect()") != null);
}

test "sideEffects: CJS side-effect import must not be duplicated in barrel init (#1193)" {
    // #1193 fix 후속: CJS 타겟은 body rewrite가 이미 require_xxx()를 주입하므로
    // side-effect import 전용 preamble 루프는 ESM 타겟만 처리해야 한다.
    // 중복 호출은 side-effect가 두 번 실행되는 동작 회귀를 일으킬 수 있음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./sideeffect.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "node_modules/pkg/values.js",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "node_modules/pkg/sideeffect.js",
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const index_init_start = std.mem.indexOf(u8, result.output, "var init_pkg_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    const count = std.mem.count(u8, index_init_block, "require_pkg_sideeffect()");
    try std.testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// UserDefined sideEffects lock — rolldown DeterminedSideEffects::UserDefined parity
// ============================================================

test "sideEffects: UserDefined lock — package.json sideEffects array MUST NOT be overridden by auto-purity" {
    // React-native-worklets의 lib/module/index.js는 top-level에서 init() 호출 (side-effect).
    // 근데 `import` + `function_call()`만 있는 파일은 ZNTC auto-purity 로직이 "pure"로 오판할 수도.
    // package.json의 sideEffects 배열에 명시된 파일은 auto-purity가 덮어쓰면 안 됨.
    // 이 테스트는 해당 regression을 방지한다 (#1193 root cause).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./runtime-init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './runtime-init';
        \\export const x = 1;
    );
    // runtime-init.js는 top-level에서 globalInit() 호출.
    // 호출 자체는 auto-purity 기준으로 "pure"로 보일 수 있지만 (function call on unknown binding),
    // sideEffects array에 명시됐으므로 반드시 보존되어야 한다.
    try writeFile(tmp.dir, "node_modules/pkg/runtime-init.js",
        \\import { globalInit } from './helper';
        \\globalInit();
    );
    try writeFile(tmp.dir, "node_modules/pkg/helper.js",
        \\export function globalInit() { globalThis.__runtimeInitialized = true; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // runtime-init.js body가 번들에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, result.output, "globalInit()") != null);
    // 게다가 top-level init 경로에서 실행 가능해야 한다 — 단순 정의 외에 호출 라인이 있어야 함
    // (RN 플랫폼에서는 __esm wrap의 factory body에 globalInit() 있어야)
    const has_call = std.mem.count(u8, result.output, "globalInit()") >= 2;
    try std.testing.expect(has_call);
}

test "sideEffects: UserDefined lock — sideEffects:false module stays tree-shakable even if complex" {
    // 반대 방향 회귀: sideEffects:false는 auto-purity와 일치 — lock이 잘못 걸리면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/lib';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/lib/package.json",
        \\{"name":"lib","main":"./index.js","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/lib/index.js",
        \\export const x = 1;
        \\export const unused = 2;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1") != null);
}

test "sideEffects: UserDefined lock — auto-purity does not flip package.json true to false" {
    // `sideEffects: true` (array 아님)도 user_defined 설정.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './node_modules/preserve';
    );
    try writeFile(tmp.dir, "node_modules/preserve/package.json",
        \\{"name":"preserve","sideEffects":true}
    );
    // body는 pure literal만 — auto-purity가 보면 "pure"라고 판단할 텍스트.
    try writeFile(tmp.dir, "node_modules/preserve/index.js",
        \\const PURE_CONST = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sideEffects:true로 명시된 순수 module도 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "sideEffects: UserDefined lock — pattern matched file preserved even in node_modules with other pure modules" {
    // react-native-worklets 실제 구조 흉내: sideEffects에 특정 파일만 나열.
    // 매치되는 파일의 top-level call은 보존, 매치 안 되는 pure 파일은 tree-shake.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { api } from './node_modules/worklets';
        \\console.log(api);
    );
    try writeFile(tmp.dir, "node_modules/worklets/package.json",
        \\{"name":"worklets","main":"./index.js","sideEffects":["./index.js","./init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/worklets/index.js",
        \\import { init } from './init';
        \\import { api } from './api';
        \\init();
        \\export { api };
    );
    try writeFile(tmp.dir, "node_modules/worklets/init.js",
        \\export function init() { globalThis.__workletsReady = true; }
    );
    try writeFile(tmp.dir, "node_modules/worklets/api.js",
        \\export const api = 'ok';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // index.js의 `init();` call이 번들에 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init()") != null);
    // api 사용도 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ok\"") != null or
        std.mem.indexOf(u8, result.output, "'ok'") != null);
}

test "TreeShaking: post-declaration assignment to top-level var is preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { make } from './lib';
        \\console.log(make());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\var _self;
        \\class Box {
        \\  static spawn() { return new _self(); }
        \\  tag() { return 'POST_DECL_ASSIGN_TAG'; }
        \\}
        \\_self = Box;
        \\export function make() { return Box.spawn().tag(); }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_self = Box") != null);
}

test "TreeShaking: function-body writer of mutable let does not pull function in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { untrack } from './runtime';
        \\console.log(untrack(() => 1));
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\import { HEAVY_DEP_BODY_TAG } from './heavy';
        \\export let untracking = false;
        \\export function untrack(fn) {
        \\  const prev = untracking;
        \\  untracking = true;
        \\  try { return fn(); } finally { untracking = prev; }
        \\}
        \\export function update_reaction() {
        \\  untracking = false;
        \\  return HEAVY_DEP_BODY_TAG;
        \\}
    );
    try writeFile(tmp.dir, "heavy.ts", "export const HEAVY_DEP_BODY_TAG = 'WRITER_OVERFIRE_HEAVY_MARKER';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "untrack") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "update_reaction") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WRITER_OVERFIRE_HEAVY_MARKER") == null);
}

test "TreeShaking: top-level writer kept, function-body writer dropped on shared let" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { read } from './lib';
        \\console.log(read());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\import { HEAVY_DEAD_BODY_TAG } from './heavy';
        \\export let x = 1;
        \\x = 2;
        \\export function read() { return x; }
        \\function dead_fn() { x = 999; return HEAVY_DEAD_BODY_TAG; }
    );
    try writeFile(tmp.dir, "heavy.ts", "export const HEAVY_DEAD_BODY_TAG = 'MIXED_WRITER_HEAVY_MARKER';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_fn") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MIXED_WRITER_HEAVY_MARKER") == null);
}

test "TreeShaking: dead function-body writer does not cascade through transitive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { readable } from './store';
        \\console.log(readable());
    );
    try writeFile(tmp.dir, "store.ts",
        \\import { untrack } from './runtime';
        \\export function readable() { return untrack(() => 42); }
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\import { effect_helper } from './effects';
        \\export let untracking = false;
        \\export function untrack(fn) {
        \\  const prev = untracking; untracking = true;
        \\  try { return fn(); } finally { untracking = prev; }
        \\}
        \\export function update_effect(e) {
        \\  untracking = false;
        \\  return effect_helper(e);
        \\}
    );
    try writeFile(tmp.dir, "effects.ts",
        \\import { SOURCE_CASCADE_TAG } from './sources';
        \\export function effect_helper(e) { return SOURCE_CASCADE_TAG + e; }
    );
    try writeFile(tmp.dir, "sources.ts", "export const SOURCE_CASCADE_TAG = 'CASCADE_SHOULD_DROP_MARKER';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CASCADE_SHOULD_DROP_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "effect_helper") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "update_effect") == null);
}

test "TreeShaking: compound/update writers inside function body are not writer-edged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { read } from './lib';
        \\console.log(read());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\import { HEAVY_COMPOUND_TAG } from './heavy';
        \\export let counter = 0;
        \\export function read() { return counter; }
        \\function dead_inc() { counter += 1; counter++; return HEAVY_COMPOUND_TAG; }
    );
    try writeFile(tmp.dir, "heavy.ts", "export const HEAVY_COMPOUND_TAG = 'COMPOUND_WRITER_DROP_MARKER';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_inc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPOUND_WRITER_DROP_MARKER") == null);
}

test "TreeShaking: class extends call expression preserved (#1261 edge)" {
    // class Foo extends getBase() — extends call은 side-effect이므로 보존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function getBase() { console.log("EXTENDS_CALL_MARKER"); return class {}; }
        \\export class Unused extends getBase() {}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXTENDS_CALL_MARKER") != null);
}

test "#1291 실제 증상: \"use strict\" + non-simple params 있는 모듈이 graph에서 스킵됨" {
    // 실제 이슈 재현: backend.js 같은 webpack UMD 번들이 내부 함수에
    // `"use strict"` + destructuring params 조합을 가질 때 parser가 validation 에러를
    // 내고 graph.zig가 모듈 전체를 스킵 → require 참조가 생기지만 정의는 없음.
    //
    // SyntaxError지만 V8/Hermes 런타임은 실행하므로 번들러는 경고로 처리해야 함
    // (esbuild/rollup 동일 정책).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\function foo({ a, b }) {
        \\    "use strict";
        \\    return a + b;
        \\}
        \\module.exports = foo;
    );
    try writeFile(tmp.dir, "entry.js",
        \\const foo = require('./lib.js');
        \\console.log(foo({ a: 1, b: 2 }));
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib = __commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = foo") != null);
}

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

// kysely 회귀 #2052: TS interface-only 가 strip 후 빈 `export {}` 만 남고, post-transform
// AST 에서 transformer 가 그 marker 까지 drop 하면 refresh 가 exports_kind 를 `.none` 으로
// 강등 → markEsmCjsHybrid Pass 2 가 implicit CJS 로 승격 → resolveOrCjsFallback 이 첫 번째
// `export *` source 의 빈 CJS wrapper 를 모든 named import 의 source 로 stick 시킴 →
// 실제 정의가 있는 다음 `export *` 는 walk 안 되어 dummy-driver.js 가 tree-shake 된다.
test "TreeShaking: export * chain through TS-stripped empty source still resolves named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Bar } from './barrel';
        \\console.log(new Bar().tag());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './empty';
        \\export * from './real';
    );
    try writeFile(tmp.dir, "empty.ts",
        \\export {};
    );
    try writeFile(tmp.dir, "real.ts",
        \\export class Bar {
        \\  tag() { return 'EXPORT_STAR_CHAIN_KEPT'; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXPORT_STAR_CHAIN_KEPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Bar") != null);
}

// cheerio 회귀 #2051: namespace import (`import * as ns from 'cjslib'`) 의 모든 소비자가
// tree-shake 로 사라졌는데 ImportBinding 자체는 살아 있어 linker 가 `var ns =
// __toESM(require_X(), 1)` 를 emit. 그러나 해당 CJS wrapper 는 모듈 미포함이라 정의되지
// 않아 `require_X is not defined` ReferenceError. preamble emit 도 같이 drop 해야 한다.
test "TreeShaking: namespace import preamble dropped when target excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used());
    );
    // lib.js 가 namespace 로 cjslib 을 import 하지만, 소비자 (`heavy`) 는 entry 에서 안 쓴다.
    try writeFile(tmp.dir, "lib.js",
        \\import * as cjslib from './cjslib.cjs';
        \\export function used() { return 'NS_TARGET_DROP_USED'; }
        \\export function heavy() { return cjslib.bar(); }
    );
    try writeFile(tmp.dir, "cjslib.cjs",
        \\'use strict';
        \\exports.bar = function() { return 'NS_TARGET_DROP_HEAVY'; };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_USED") != null);
    // heavy() 는 사용 안 하므로 cjslib + 본문 모두 prune 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_HEAVY") == null);
    // `var X = __toESM(require_cjslib_cjs(), 1)` 같은 orphan preamble 이 남으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjslib") == null);
}

test "TreeShaking: CJS default import member access seeds only used export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './react-like.cjs';
        \\console.log(React.createElement());
    );
    try writeFile(tmp.dir, "react-like.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_MEMBER_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_MEMBER_UNUSED'; };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_MEMBER_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_MEMBER_UNUSED") == null);
}

test "TreeShaking: CJS default import value escape keeps all exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './react-like.cjs';
        \\console.log(typeof React);
    );
    try writeFile(tmp.dir, "react-like.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_ESCAPE_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_ESCAPE_KEPT'; };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_ESCAPE_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_ESCAPE_KEPT") != null);
}

test "TreeShaking: CJS default member access follows module.exports require proxy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './index.cjs';
        \\console.log(React.createElement());
    );
    try writeFile(tmp.dir, "index.cjs",
        \\'use strict';
        \\{
        \\  module.exports = require('./react-production.cjs');
        \\}
    );
    try writeFile(tmp.dir, "react-production.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_PROXY_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_PROXY_UNUSED'; };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_PROXY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_PROXY_UNUSED") == null);
}

// ============================================================
// #2398 — RN-platform .esm wrap 환경에서 barrel re-export DCE
// ============================================================

test "TreeShaking #2398: RN .esm wrap + sideEffects:false barrel drops unused re-exports" {
    // graph.zig:2510 의 RN preset 이 모든 ESM 모듈을 .esm wrap → 종전엔 lodash-es 처럼
    // 명시적 sideEffects:false 패키지조차 unused re-export 가 전부 번들에 들어가던
    // 회귀. 본 fix 후 user-declared pure 모듈은 정밀 DCE 가능해야 함.
    // findPackageDirPath 가 node_modules 위치 기준이라 fixture 도 동일 구조.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as unused1 } from './unused1.js';
        \\export { default as unused2 } from './unused2.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'USED_FN_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused1.js", "export default function unused1() { return 'UNUSED_FN1_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused2.js", "export default function unused2() { return 'UNUSED_FN2_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FN_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_FN1_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_FN2_BODY") == null);
}

test "TreeShaking #2398: RN .esm wrap + sideEffects 미명시는 conservative 보존 (회귀 가드)" {
    // RN core 처럼 `package.json sideEffects` 필드 없는 모듈은 본 fix 가
    // 종전 보수 동작 유지. user-declared pure 가 아니면 .esm wrap StmtInfo 빌드도
    // 안 하고 evaluation effect 로 간주해 init ordering 깨지지 않도록 안전판.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as helper } from './helper.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'USED_FN'; }");
    try writeFile(tmp.dir, "node_modules/pkg/helper.js", "export default function helper() { return 'HELPER_FN'; }");
    // package.json sideEffects 미명시 (필드 없는 형태) → conservative
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\"}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FN") != null);
    // sideEffects 미명시 → 종전 동작 그대로 helper 도 보존 (보수)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HELPER_FN") != null);
}

test "TreeShaking #2398: RN .esm wrap + sideEffects:false barrel 50개 re-export 스케일" {
    // lodash-es 와 가까운 형태 reproduce. 종전엔 50개 fn body 가 모두 번들에 들어
    // 갔지만 (107KB) 본 fix 후 1 개만 남아야 함. 작은 fixture 에선 발견 안 되던
    // scale-induced 회귀 (예: bitset 크기, O(N²) 폭주) 까지 catch.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // entry — 50개 중 fn0 만 사용
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn0 } from 'pkg';
        \\console.log(fn0());
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    // 50 개 default-as-named re-export 의 barrel — 향후 카운트 늘려도 overflow 없도록 dynamic.
    var barrel_buf: std.ArrayList(u8) = .empty;
    defer barrel_buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "export {{ default as fn{d} }} from './fn{d}.js';\n", .{ i, i });
        try barrel_buf.appendSlice(std.testing.allocator, line);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "node_modules/pkg/fn{d}.js", .{i});
        var body_buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "export default function fn{d}() {{ return 'FN_BODY_{d}_MARKER'; }}\n", .{ i, i });
        try writeFile(tmp.dir, name, body);
    }
    try writeFile(tmp.dir, "node_modules/pkg/index.js", barrel_buf.items);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "FN_BODY_0_MARKER") != null);
    // 49개 unused 모두 drop 검증 (n=1..49)
    var j: usize = 1;
    while (j < 50) : (j += 1) {
        var marker_buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "FN_BODY_{d}_MARKER", .{j});
        try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
}

test "TreeShaking #2398: RN .esm wrap + side-effect import 는 본문 보존" {
    // sideEffects 패턴 매칭으로 setup.js 만 side_effects=true 인 케이스. setup.js 가
    // evaluation effect 로 잡혀 보존되어야 함. metadata.zig:438 의 새 `continue` 가드가
    // legitimate init 호출까지 끊지 않는지 회귀 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { val } from 'pkg';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './setup.js';
        \\export { val } from './val.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/setup.js", "globalThis.__SETUP_RAN__ = 'SIDE_EFFECT_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/val.js", "export const val = 'VAL_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": [\"./setup.js\"]}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VAL_MARKER") != null);
    // setup.js 는 sideEffects pattern 매칭 → 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_EFFECT_MARKER") != null);
}

test "TreeShaking #2398: RN require() 가 .esm wrap target namespace 전체 보존" {
    // markAllExportsUsed 가 .cjs 뿐 아니라 .esm wrap target 에도 적용되는지 검증.
    // 본 fix 전에는 .esm 의 StmtInfo 부재로 자동 보존됐던 동작인데, 본 fix 가
    // StmtInfo 빌드를 활성화하면서 명시 마킹 필요. 빠지면 require() 결과 객체의
    // 일부 property 가 undefined 가 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lib = require('pkg');
        \\console.log(lib.a, lib.b, lib.c);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const a = 'A_MARKER';
        \\export const b = 'B_MARKER';
        \\export const c = 'C_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require() namespace 접근 → 모든 export 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "C_MARKER") != null);
}

test "TreeShaking #2398: RN namespace import (`import * as ns`) 가 .esm wrap pure pkg 의 모든 export 보존" {
    // require() 와 대칭 — `import * as ns` 도 어떤 property 가 읽힐지 정적 분석 불가
    // 하므로 namespace 사용 시 모든 export 가 살아야 함. tree_shaker 의 namespace 경로
    // (registerNamespaceRewrites 등) 가 .esm wrap 에도 markAllExportsUsed 적용해야
    // 일부 property 가 undefined 가 되는 회귀 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as ns from 'pkg';
        \\const key = (Math.random() > 0.5) ? 'a' : 'b';
        \\console.log(ns[key], ns.c);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const a = 'NS_A_MARKER';
        \\export const b = 'NS_B_MARKER';
        \\export const c = 'NS_C_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace 객체로 사용 → static analysis 불가능 → 보수적으로 모두 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_A_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_B_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_C_MARKER") != null);
}
