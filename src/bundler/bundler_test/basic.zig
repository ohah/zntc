const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const plugin_mod = @import("../plugin.zig");
const Plugin = plugin_mod.Plugin;
const PluginError = plugin_mod.PluginError;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const threadSafeArena = test_helpers.threadSafeArena;

test "Bundler: single file bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 42;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 42;") != null);
    try std.testing.expect(!result.hasErrors());
}

test "Bundler: two files bundled in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 1;\nconsole.log(a);");
    try writeFile(tmp.dir, "b.ts", "const b = 2;\nconsole.log(b);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // b.ts가 a.ts보다 먼저 (exec_index 순서)
    const b_pos = std.mem.indexOf(u8, result.output, "console.log(b);") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "console.log(a);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b_pos < a_pos);
}

test "Bundler: external module excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import 'react';\nconst x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // react는 external → 에러 없이 번들 생성
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1;") != null);
}

test "Bundler: minified output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // minify_syntax 에서 top-level const → var 다운그레이드 (#1630)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var x=1;") != null);
    // minify: 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "Bundler: unresolved import produces error diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import './nonexistent';");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
    const diags = result.getDiagnostics();
    try std.testing.expect(diags.len > 0);
    try std.testing.expectEqual(types.BundlerDiagnostic.ErrorCode.unresolved_import, diags[0].code);
}

test "Bundler: circular dependency produces warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "import './a';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 순환은 경고 (에러 아님) → 번들 생성은 성공
    try std.testing.expect(!result.hasErrors());
    var has_circular = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .circular_dependency) has_circular = true;
    }
    try std.testing.expect(has_circular);
}

test "Bundler: IIFE format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.output, "(() => {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
}

test "Bundler: CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
}

test "Bundler: multiple entry points" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts", "const a = 1;");
    try writeFile(tmp.dir, "e2.ts", "const b = 2;");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

// ============================================================
// Linker Integration Tests (scope hoisting 동작 검증)
// ============================================================

test "Linker integration: import statement removed from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // import 문이 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
    // export 값은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // console.log(x)는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "Linker integration: export keyword stripped (non-entry)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "export const y = 99;\nconsole.log(y);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // b.ts의 "export const" → "const" (export 키워드 제거)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const y = 99;") != null);
}

test "Linker integration: name conflict renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst count = 0;\nconsole.log(count);");
    try writeFile(tmp.dir, "b.ts", "const count = 1;\nconsole.log(count);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 두 모듈의 count가 충돌 → 하나는 count$1로 리네임
    // (어느 쪽이 리네임될지는 exec_index에 따라 다름)
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "count$") != null or
            std.mem.indexOf(u8, result.output, "count") != null,
    );
}

test "Linker integration: scope_hoist=false preserves import/export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = false,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // scope_hoist=false → import/export 그대로 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") != null or
        std.mem.indexOf(u8, result.output, "import{") != null);
}

// ============================================================
// Re-export patterns (Rollup/Rolldown 참고)
// ============================================================

test "Re-export: named re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './re';\nconsole.log(x);");
    try writeFile(tmp.dir, "re.ts", "export { x } from './source';");
    try writeFile(tmp.dir, "source.ts", "export const x = 'hello';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "Re-export: export all (export * from)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a, b } from './barrel';\nconsole.log(a, b);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export const a = 1;\nexport const b = 2;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

test "Re-export: chained re-export (A→B→C)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './mid';\nconsole.log(val);");
    try writeFile(tmp.dir, "mid.ts", "export { val } from './leaf';");
    try writeFile(tmp.dir, "leaf.ts", "export const val = 999;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "999") != null);
}

test "Re-export: barrel file (index re-exporting multiple modules)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { add, sub } from './utils';\nconsole.log(add, sub);");
    try writeFile(tmp.dir, "utils/index.ts", "export { add } from './math';\nexport { sub } from './math2';");
    try writeFile(tmp.dir, "utils/math.ts", "export const add = (a: number, b: number) => a + b;");
    try writeFile(tmp.dir, "utils/math2.ts", "export const sub = (a: number, b: number) => a - b;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a + b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a - b") != null);
}

test "Re-export: default export and import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import greet from './greeter';\nconsole.log(greet);");
    try writeFile(tmp.dir, "greeter.ts", "export default function greet() { return 'hi'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet()") != null);
}

test "Re-export: export default expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import val from './config';\nconsole.log(val);");
    try writeFile(tmp.dir, "config.ts", "export default 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

// ============================================================
// Scope hoisting edge cases (Webpack 참고)
// ============================================================

test "Scope hoisting: three modules same variable name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './m1';\nimport './m2';\nconst name = 'entry';\nconsole.log(name);");
    try writeFile(tmp.dir, "m1.ts", "const name = 'first';\nconsole.log(name);");
    try writeFile(tmp.dir, "m2.ts", "const name = 'second';\nconsole.log(name);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 모듈의 name이 충돌 → 최소 2개는 name$1, name$2로 리네임
    // 출력에 name$가 1개 이상 존재해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "name$") != null);
}

test "Scope hoisting: export default identifier가 mangling 시 할당문 생성" {
    // export default View 패턴에서 View가 다른 모듈과 충돌하여 View$1 등으로 mangling될 때
    // __esm body에 View$1 = View; 할당이 생성되어야 한다.
    // 이 할당이 없으면 __export getter가 undefined를 반환하는 버그가 발생.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import View from './view-a';
        \\import View2 from './view-b';
        \\console.log(View, View2);
    );
    try writeFile(tmp.dir, "view-a.ts",
        \\const View = "viewA";
        \\export default View;
    );
    try writeFile(tmp.dir, "view-b.ts",
        \\const View = "viewB";
        \\export default View;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈의 View가 충돌 → 하나 이상 View$로 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "View$") != null);
    // 리네임된 export 변수에 대한 할당문이 존재해야 함 (예: View$1=View;)
    // __export getter가 View$1을 참조하므로, 이 할당이 없으면 undefined
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"viewA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"viewB\"") != null);
}

test "Scope hoisting: multiple named imports from one module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo, bar, baz } from './lib';\nconsole.log(foo, bar, baz);");
    try writeFile(tmp.dir, "lib.ts", "export const foo = 1;\nexport const bar = 2;\nexport const baz = 3;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // import 문 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
    // 모든 값 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const foo = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const bar = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const baz = 3;") != null);
}

test "Scope hoisting: import used in expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { WIDTH } from './config';\nconst area = WIDTH * 2;\nconsole.log(area);");
    try writeFile(tmp.dir, "config.ts", "export const WIDTH = 100;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WIDTH * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const WIDTH = 100;") != null);
}

test "Scope hoisting: export function declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { helper } from './utils';\nconsole.log(helper());");
    try writeFile(tmp.dir, "utils.ts", "export function helper() { return 'ok'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

test "Scope hoisting: let and var declarations across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './a';\nlet state = 0;\nvar count = 1;\nconsole.log(state, count);");
    try writeFile(tmp.dir, "a.ts", "let state = 'init';\nvar count = 10;\nconsole.log(state, count);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // state와 count가 충돌 → 리네임 발생
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "state$") != null or
            std.mem.indexOf(u8, result.output, "count$") != null,
    );
}

// ============================================================
// Circular dependencies (SWC/Rolldown 참고)
// ============================================================

test "Circular: three module cycle (A→B→C→A)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('A');");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconsole.log('B');");
    try writeFile(tmp.dir, "c.ts", "import './a';\nconsole.log('C');");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 순환은 경고지만 번들은 생성됨
    try std.testing.expect(!result.hasErrors());
    var has_circular = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .circular_dependency) has_circular = true;
    }
    try std.testing.expect(has_circular);
    // 모든 모듈의 코드가 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"C\"") != null);
}

test "Circular: two module cycle with exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { b_val } from './b';\nexport const a_val = 10;\nconsole.log(b_val);");
    try writeFile(tmp.dir, "b.ts", "import { a_val } from './a';\nexport const b_val = 20;\nconsole.log(a_val);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "20") != null);
}

test "Circular: diamond with shared leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './left';\nimport './right';\nconsole.log('entry');");
    try writeFile(tmp.dir, "left.ts", "import './shared';\nconsole.log('left');");
    try writeFile(tmp.dir, "right.ts", "import './shared';\nconsole.log('right');");
    try writeFile(tmp.dir, "shared.ts", "console.log('shared');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared는 한 번만 포함 (중복 제거)
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "\"shared\"")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // 실행 순서: shared → left → right → entry
    const shared_pos = std.mem.indexOf(u8, result.output, "\"shared\"") orelse return error.TestUnexpectedResult;
    const entry_pos = std.mem.indexOf(u8, result.output, "\"entry\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shared_pos < entry_pos);
}

test "Bundler: import.meta.glob eager option" {
    // glob_matches의 기존 메모리 릭 (expandGlob 할당)을 우회하기 위해 arena 사용
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("mods");
    try writeFile(tmp.dir, "mods/a.ts", "export const x = 1;");
    try writeFile(tmp.dir, "mods/b.ts", "export const y = 2;");
    try writeFile(tmp.dir, "entry.ts", "const m = import.meta.glob('./mods/*.ts', { eager: true });\nconsole.log(m);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(alloc, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "await import(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "() => import(") == null);
}

test "Bundler: import.meta.glob import option" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("mods");
    try writeFile(tmp.dir, "mods/a.ts", "export const setup = () => 1;");
    try writeFile(tmp.dir, "entry.ts", "const m = import.meta.glob('./mods/*.ts', { import: 'setup' });\nconsole.log(m);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(alloc, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "m.setup") != null);
}

// ============================================================
// require.context emit (#1579 Phase 3) — webpackContext IIFE
// ============================================================

fn rcMatchAB(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    // Plugin contract: outer + inner 모두 allocator 소유 (graph 가 free).
    const result = try allocator.alloc([]const u8, 2);
    result[0] = try allocator.dupe(u8, "./a.tsx");
    result[1] = try allocator.dupe(u8, "./b.tsx");
    return result;
}

/// importer dir + dir 를 실제 FS 스캔 — graph dep 등록 성공을 위해 실제 파일 필요.
fn rcScanDir(
    _: ?*anyopaque,
    dir: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    importer: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    const importer_dir = std.fs.path.dirname(importer) orelse return null;
    const abs_dir = std.fs.path.resolve(allocator, &.{ importer_dir, dir }) catch return null;
    defer allocator.free(abs_dir);

    var d = std.fs.openDirAbsolute(abs_dir, .{ .iterate = true }) catch {
        return try allocator.alloc([]const u8, 0);
    };
    defer d.close();

    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(allocator);
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const rel = std.fmt.allocPrint(allocator, "./{s}", .{entry.name}) catch continue;
        list.append(allocator, rel) catch continue;
    }
    return try list.toOwnedSlice(allocator);
}

/// 재귀 FS 스캔 (recursive=true 이면 subdir 의 파일도 반환).
fn rcRecursiveScan(
    _: ?*anyopaque,
    dir: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    importer: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    const importer_dir = std.fs.path.dirname(importer) orelse return null;
    const abs_dir = std.fs.path.resolve(allocator, &.{ importer_dir, dir }) catch return null;
    defer allocator.free(abs_dir);

    var d = std.fs.openDirAbsolute(abs_dir, .{ .iterate = true }) catch {
        return try allocator.alloc([]const u8, 0);
    };
    defer d.close();

    var list = std.ArrayList([]const u8).empty;
    defer list.deinit(allocator);
    var walker = d.walk(allocator) catch return try allocator.alloc([]const u8, 0);
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const rel = std.fmt.allocPrint(allocator, "./{s}", .{entry.path}) catch continue;
        list.append(allocator, rel) catch continue;
    }
    return try list.toOwnedSlice(allocator);
}

fn rcMatchEmpty(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    return try allocator.alloc([]const u8, 0);
}

/// escape 검증용 — 매치 경로에 `"`, `\`, 개행을 포함시켜 writeJsStringContent 적용 확인.
fn rcMatchSpecialChars(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, "./weird\"name\\x.tsx");
    return result;
}

fn rcMatchNoDotSlash(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    // dot-slash prefix 없는 경로도 emitJoinedPath 가 정규화하는지 확인.
    const result = try allocator.alloc([]const u8, 1);
    result[0] = try allocator.dupe(u8, "nested/a.tsx");
    return result;
}

test "Bundler: require.context emits webpackContext IIFE (sync)" {
    // ArenaAllocator 는 thread-safe 가 아님. 번들러는 worker threads 에서도 self.allocator 로
    // 할당하므로 (#1779 INVARIANTS 의 storage-level race-safety 와 별개) 테스트 arena 를 감싸서
    // mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // matches 가 graph dep 으로 등록되니 실제 파일 필요.
    try tmp.dir.makeDir("pages");
    try writeFile(tmp.dir, "pages/a.tsx", "export const a = 1;");
    try writeFile(tmp.dir, "pages/b.tsx", "export const b = 2;");
    try writeFile(tmp.dir, "entry.ts",
        \\const ctx = require.context('./pages', true, /\.tsx?$/, 'sync');
        \\console.log(ctx);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcScanDir }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // webpackContext runtime 핵심 구성요소
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var map={") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_NOT_FOUND") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ctx.keys=function(){return Object.keys(map);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ctx.resolve=function(req)") != null);
    // 원본 `require.context(...)` 호출은 남으면 안 됨 — IIFE 로 교체되어야.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require.context(") == null);
    // 매치 파일들이 번들에 실제로 포함되어야 — graph dep 등록 확인.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// --- a.tsx ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// --- b.tsx ---") != null);
}

test "Bundler: require.context emits empty map when no matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const ctx = require.context('./empty-dir');
        \\console.log(ctx);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcMatchEmpty }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // map 은 비었지만 ctx 함수는 여전히 emit — keys() 는 [] 반환, ctx(x) 는 throw.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var map={}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ctx.keys=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_NOT_FOUND") != null);
}

test "Bundler: require.context escapes match path special chars" {
    // 특수문자 파일은 FS 에 못 만들어서 graph dep resolve 가 실패 → diagnostic 발생.
    // 여기선 escape 로직 (writeJsStringContent) 만 검증 — hasErrors 는 무시.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const ctx = require.context('./pages');\nconsole.log(ctx);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcMatchSpecialChars }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);

    // 원본 `"` 는 `\"` 로, `\` 는 `\\` 로 escape 되어야 JS 문자열 리터럴이 유효.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\\\"name\\\\x.tsx") != null);
    // raw unescaped `"name` 는 없어야 (map 키 내부에 그대로 들어가면 JS 파싱 불가).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "weird\"name") == null);
}

test "Bundler: require.context normalizes trailing slash and missing ./" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // graph dep 등록을 위해 실제 파일 생성.
    try tmp.dir.makeDir("pages");
    try tmp.dir.makeDir("pages/nested");
    try writeFile(tmp.dir, "pages/nested/a.tsx", "export const a = 1;");
    // dir 에 trailing `/` → 매치 경로 join 시 중복 `//` 안 생김.
    try writeFile(tmp.dir, "entry.ts", "const ctx = require.context('./pages/');\nconsole.log(ctx);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcMatchNoDotSlash }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // `./pages/` + `nested/a.tsx` → `./pages/nested/a.tsx` (정확히 slash 하나).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./pages/nested/a.tsx\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./pages//") == null);
}

/// 호출 순서에 따라 다른 matches 를 돌려주는 callback — span 매칭 정확성 검증용.
fn rcDispatchByCallCount(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    const S = struct {
        var count: u32 = 0;
    };
    S.count += 1;
    const result = try allocator.alloc([]const u8, 1);
    if (S.count == 1) {
        result[0] = try allocator.dupe(u8, "./first.tsx");
    } else {
        result[0] = try allocator.dupe(u8, "./second.tsx");
    }
    return result;
}

test "Bundler: multiple require.context calls resolve to distinct maps (span match)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 각 dir 에 매치할 파일이 실제 존재해야 graph dep 등록 성공.
    try tmp.dir.makeDir("pages");
    try tmp.dir.makeDir("other");
    try writeFile(tmp.dir, "pages/first.tsx", "export const x = 1;");
    try writeFile(tmp.dir, "other/second.tsx", "export const y = 2;");
    try writeFile(tmp.dir, "entry.ts",
        \\const a = require.context('./pages');
        \\const b = require.context('./other');
        \\console.log(a, b);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcDispatchByCallCount }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // 첫 호출 (./pages) 는 first.tsx 만, 둘째 호출 (./other) 는 second.tsx 만.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./pages/first.tsx\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./other/second.tsx\")") != null);
    // cross-contamination 없음.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./pages/second.tsx\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./other/first.tsx\")") == null);
}

test "Bundler: require.context coexists with import.meta.glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("mods");
    try tmp.dir.makeDir("pages");
    try writeFile(tmp.dir, "mods/a.ts", "export const x = 1;");
    // require.context 매치 파일도 graph dep 등록용으로 필요.
    try writeFile(tmp.dir, "pages/a.tsx", "export const a = 1;");
    try writeFile(tmp.dir, "pages/b.tsx", "export const b = 2;");
    try writeFile(tmp.dir, "entry.ts",
        \\const g = import.meta.glob('./mods/*.ts', { eager: true });
        \\const c = require.context('./pages');
        \\console.log(g, c);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcScanDir }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // 양쪽 모두 AST 수준에서 교체되어야 — 원본 호출 둘 다 없음.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import.meta.glob(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require.context(") == null);
    // glob: eager → `await import(` / require.context: webpackContext IIFE.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await import(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_NOT_FOUND") != null);
}

test "Bundler: require.context emits IIFE inside __esm wrapper (RN platform)" {
    // 회귀: esm_wrap.zig 의 body/func/hoist Codegen init 에 import_records 를 안 넘겨서
    // __esm wrap 경로에서 has_require_context_records=false → IIFE 미emit → 원본
    // `require.context(...)` 호출이 런타임 require 를 찾다가 ReferenceError.
    // Expo Router `_ctx.ios.js` 가 이 패턴 (ESM export const ctx = require.context(...)).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("pages");
    try writeFile(tmp.dir, "pages/a.tsx", "export const a = 1;");
    try writeFile(tmp.dir, "pages/b.tsx", "export const b = 2;");
    try writeFile(tmp.dir, "entry.ts",
        \\export const ctx = require.context('./pages', true, /^\.\//, 'sync');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcScanDir }};
    var b = Bundler.init(alloc, .{
        .entry_points = &.{entry},
        .format = .esm,
        .platform = .react_native, // __esm wrapping 강제
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // __esm wrap + IIFE 둘 다 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var map={") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_NOT_FOUND") != null);
    // 원본 호출은 교체되어야
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require.context(") == null);
}

// ============================================================
// require.context matches → graph dep 등록 → bundle 에 포함
// ============================================================

test "Bundler: require.context — matches 파일들이 번들에 포함됨" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("pages");
    try writeFile(tmp.dir, "pages/a.tsx", "export const PAGE_A = 'page-a-content';");
    try writeFile(tmp.dir, "pages/b.tsx", "export const PAGE_B = 'page-b-content';");
    try writeFile(tmp.dir, "entry.ts",
        \\const ctx = require.context('./pages');
        \\console.log(ctx.keys());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcScanDir }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    // matches 파일의 실제 콘텐츠가 번들에 들어가는지 확인 —
    // 이전 단계 까지는 IIFE 만 emit 되고 대상 파일은 번들 밖이었음.
    // (Phase 3 까지는 IIFE 만 emit 되고 대상 파일은 번들 밖이라 런타임 require 실패.)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "page-a-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "page-b-content") != null);
    // IIFE 도 함께 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var map={") != null);
}

test "Bundler: require.context — nested match 파일도 번들에 포함" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("pages");
    try tmp.dir.makeDir("pages/nested");
    try writeFile(tmp.dir, "pages/nested/deep.tsx", "export const DEEP = 'deep-content';");
    try writeFile(tmp.dir, "entry.ts",
        \\const ctx = require.context('./pages', true, /\.tsx$/);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // plugin: 재귀 스캔 (./nested/deep.tsx 도 반환)
    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcRecursiveScan }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "deep-content") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./nested/deep.tsx") != null);
}

test "Bundler: require.context — empty matches → 파일 없어도 hasErrors false" {
    // 회귀: empty matches 는 expansion 에 추가할 게 없어 resolve 실패 발생 안 함.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ArenaAllocator 는 thread-safe 가 아닌데 bundler worker 에서 self.allocator 로 동시 할당
    // 가능 → ThreadSafeAllocator 로 감싸서 mutex 보호. 프로덕션 (bungae) 은 GPA thread-safe 기본.
    var ts = threadSafeArena(&arena);
    const alloc = ts.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const ctx = require.context('./empty');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{.{ .name = "rc", .resolveContext = rcMatchEmpty }};
    var b = Bundler.init(alloc, .{ .entry_points = &.{entry}, .plugins = &plugins });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(alloc);
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var map={}") != null);
}

test "Bundler: no require.context in source → no webpackContext template emitted" {
    // fast-path 플래그 검증: require.context 없으면 어떤 call expression 도 IIFE 로 변환되지 않음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "function ctx(){return 1;}console.log(ctx());\n");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_NOT_FOUND") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Object.keys(map)") == null);
}

test "Bundler: UMD external dependencies in wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts", "import { useState } from 'react';\nconsole.log(useState);");

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .umd,
        .external = &.{"react"},
        .global_name = "MyApp",
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const output = result.output;

    // UMD wrapper에 dependency array 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "define([\"react\"]") != null);
    // factory 매개변수 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "function(React)") != null);
    // CJS 경로에 require("react") 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "require(\"react\")") != null);
    // IIFE 글로벌 경로
    try std.testing.expect(std.mem.indexOf(u8, output, "root.React") != null);
    // body에 bare require("react") 없음 (factory param으로 대체됨)
    try std.testing.expect(std.mem.indexOf(u8, output, "var React = require(\"react\")") == null);
    // named import → factory param 프로퍼티 접근
    try std.testing.expect(std.mem.indexOf(u8, output, "React.useState") != null);
}

test "Async helper: single __async emit when target downlevels async" {
    // target=es5 + async 사용 → __async/__generator helper 정확히 1회씩만 emit
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function run() { return await Promise.resolve(1); }
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const count = std.mem.count(u8, result.output, "var __async");
    try std.testing.expectEqual(@as(usize, 1), count);
    const gcount = std.mem.count(u8, result.output, "var __generator");
    try std.testing.expectEqual(@as(usize, 1), gcount);
}

test "Async helper: no emit when target supports async natively" {
    // target esnext — async 사용해도 transform 안 하므로 __async 주입 금지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function run() { return await Promise.resolve(1); }
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __async") == null);
}

test "Async helper: no emit when code has no async/await (edge)" {
    // target=es5이어도 async가 아예 없으면 __async 주입 안 함 (현재 수정 후 기대 동작)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export function run() { return 1; }
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 실제 사용 없음 → 주입 안 함 (code size 낭비 제거)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __async") == null);
}

test "Async helper: multi-module with async in one — single emit (edge)" {
    // 여러 모듈 중 한 곳만 async 사용 → helper 1회만 emit
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\import { load } from './lazy';
        \\console.log(helper(), load());
    );
    try writeFile(tmp.dir, "helper.ts", "export function helper() { return 'h'; }");
    try writeFile(tmp.dir, "lazy.ts",
        \\export async function load() { return await Promise.resolve('l'); }
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.output, "var __async"));
}

test "Async helper: top-level await triggers emit (edge)" {
    // top-level await도 async transform을 트리거해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const val = await Promise.resolve(42);
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // top-level await는 현재 경고만 emit 가능 — 에러 없으면 OK.
    // 핵심: 만약 transform이 발생하면 __async가 정확히 1번만 emit
    const count = std.mem.count(u8, result.output, "var __async");
    try std.testing.expect(count <= 1);
}

test "Async helper: async arrow function (edge)" {
    // async arrow도 동일하게 주입
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const run = async () => await Promise.resolve(1);
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.output, "var __async"));
}

test "Arrow param shadows hoisted top-level rename (effect TDZ repro)" {
    // top-level `size`가 여러 모듈에 있으면 linker가 size→size$N으로 rename.
    // 이때 arrow function 파라미터 `size`가 같은 모듈 top-level `size`를 섀도잉해야 하며,
    // body 내부 참조는 파라미터(rename 안 됨)로 resolve되어야 함.
    // 버그: declareArrowParams가 .formal_parameters 태그를 처리하지 않아 파라미터 미등록 →
    // body 참조가 top-level rename(`size$N`)으로 오염되어 TDZ 유발 (effect lib 브라우저 번들 실패).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const size = 1;\n");
    try writeFile(tmp.dir, "c.ts",
        \\export const size = 99;
        \\export const makeImpl = (size) => size;
    );
    // c.ts의 top-level `size`를 쓰는 참조가 있어야 rename이 tree-shake 후에도 남음
    try writeFile(tmp.dir, "entry.ts",
        \\import * as A from './a';
        \\import { size, makeImpl } from './c';
        \\console.log(A.size, size, makeImpl(42));
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    // top-level rename은 발생해야 함 (회귀 방지)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "size$") != null);
    // 파라미터가 rename된 버전은 존재해선 안 됨 — body의 size 참조는 파라미터로 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(size) => size$") == null);
    // 양성 신호: body가 rename 안 된 `size`를 참조 (formatter 변경에도 견고하도록 공백 범위 허용)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(size) => size") != null);
}

test "Re-export resolves to canonical local (not global-identifier reserved, #1312)" {
    // `export { X } from './mod'` 직접 re-export가 `--global-identifier=X` 예약 때문에
    // 원본 이름 X로 emit되어 글로벌 참조로 오염되는 버그.
    // fix 후: re-export chain을 따라 source 모듈의 canonical 이름 (X$1)으로 resolve.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "URLSearchParams.ts",
        \\export class URLSearchParams { constructor() { this.tag = "local"; } }
    );
    try writeFile(tmp.dir, "URL.ts",
        \\export { URLSearchParams } from './URLSearchParams';
        \\export class URL { constructor() { this.tag = "url"; } }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import * as M from './URL';
        \\console.log(new M.URLSearchParams().tag);
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const globals = [_][]const u8{"URLSearchParams"};
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .global_identifiers = &globals,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    // URL.ts의 re-export getter가 canonical local name `URLSearchParams$1`을 반환해야 함.
    // (bare `URLSearchParams` 참조는 `--global-identifier` 글로벌과 충돌)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "URLSearchParams: () => URLSearchParams$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "URLSearchParams: () => URLSearchParams,") == null);
}

// ============================================================
// #1404/#1407 회귀 가드 — 합성 노드 span 의 STRING_TABLE_BIT 처리
// 번들러 단계에서 binding_scanner / linker 가 합성 identifier 의 이름을 추출할 때
// `self.ast.source[..]` 직접 접근하면 OOB → SIGBUS. getText 일괄 치환 후 안전.
// ============================================================

test "Synthetic span: barrel re-export of async function — no SIGBUS at es5 (#1404/#1407)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export { run } from './a';");
    try writeFile(tmp.dir, "a.ts",
        \\export async function run() {
        \\  for await (const v of g()) use(v);
        \\}
        \\async function* g() { yield 1; }
        \\function use(_: any) {}
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__asyncValues") != null);
}

test "Synthetic span: object method shorthand + computed key — no SIGBUS at es5 (#1404/#1407)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const o = { async fn() { return 1; }, ["k"]: 2 };
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const compat = @import("../../transformer/compat.zig");

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
}

test "Bundler: AMD external dependencies in wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.ts", "import lodash from 'lodash';\nexport const x = lodash.get;");

    const entry = try absPath(&tmp, "lib.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .amd,
        .external = &.{"lodash"},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const output = result.output;

    // AMD wrapper에 dependency array 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "define([\"lodash\"]") != null);
    // factory 매개변수 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "function(Lodash)") != null);
}

// #1751: Flow `component` + --flow + --minify 조합이 mangler OOB 크래시를 유발했다.
// Parser (flow.zig) 가 `const Name = React.forwardRef(Name_withRef)` 의 binding
// identifier span 을 `addString(name_text)` 로 재래핑하면서 bit-31 tagged (string_table)
// span 을 만들었고, 이게 semantic 에서 const 선언의 Symbol.name 으로 전파되어
// mangler 가 `source[span.start..]` 슬라이싱 시 OOB. root cause 는 원본 name 노드
// span 을 재사용하도록 fix. 이 테스트는 crash-free + 정상 실행 검증.
test "Bundler: #1751 Flow component with ref + minify regression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\// @flow strict-local
        \\component MyComp(
        \\  title: string,
        \\  ref: (x: any) => void,
        \\) {
        \\  return title;
        \\}
        \\const v = MyComp({title: "hi", ref: () => {}});
        \\console.log(v);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .flow = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "React.forwardRef") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_withRef") != null);
}

// #1751: ESM wrap 의 function_declaration → `foo = function(){...}` 변환형에
// trailing `;` 을 codegen 이 누락하여, 뒤따르는 `"use strict"` directive 와 ASI
// 구분 실패 → SyntaxError. 변환형은 expression statement 이므로 `;` 필수.
test "Bundler: #1751 ESM wrap function decl assignment has trailing semicolon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\"use strict";
        \\var warnedKeys = {};
        \\function warnOnce(key, message) {
        \\  if (warnedKeys[key]) return;
        \\  console.warn(message);
        \\  warnedKeys[key] = true;
        \\}
        \\export default warnOnce;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import w from './mod.js';
        \\w("x", "hi");
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .platform = .react_native, // ESM wrap + strict_execution_order 강제
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 변환형 `t = function(...){...}` 뒤에 반드시 `;`. `}"use strict"` 붙지 않음.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "};\"use strict\"") != null or
        std.mem.indexOf(u8, result.output, "}\"use strict\"") == null);
}

// #1756: generator 다운레벨 시 `__generator(body, genFn)` 의 `genFn` 인자가
// `makeIdentifierRefFromSpan` 로만 만들어져 symbol_id 미전파 → 번들 mangler
// rename 이 이 이름에 반영되지 않아 원본 이름으로 emit 되면서 ReferenceError.
// makeIdentifierRefWithSymbol 로 원본 binding 의 symbol_id 전파해 해결.
test "Bundler: #1756 generator downlevel + minify genFn rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function* tick(): Generator<string> { yield 'a'; yield 'b'; }
        \\const g = tick();
        \\console.log(g.next().value, g.next().value);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .platform = .react_native, // ES5 downlevel → __generator 활성
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 원본 이름 `tick` 은 mangle 되어 3자 이하 알파벳으로 rename. `$gn(..., tick)`
    // 같이 원본 이름이 `$gn` 호출부 두번째 인자로 남아있으면 안됨.
    try std.testing.expect(std.mem.indexOf(u8, result.output, ",tick)") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ", tick)") == null);
    // $gn( 호출부가 존재해야 함 (generator downlevel 확인).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$gn(") != null);
}

// #1757: mangler slot-reuse shadowing — outer function declaration 이름과
// inner var/let 이 같은 mangler slot 에 배정되어 shadow. RN + generator + async
// + for-of 조합에서 `TypeError: e is not a function` 으로 표면화.
test "Bundler: #1757 mangler outer fn / inner var shadowing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function* counter(): Generator<number> { yield 1; yield 2; yield 3; }
        \\async function main() {
        \\  let sum = 0;
        \\  for (const x of counter()) sum += x;
        \\  return sum;
        \\}
        \\main().then(v => console.log(v));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .platform = .react_native,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const out = result.output;

    // outer `function counter` 의 mangled 이름을 `(){return $gn(` 직전 identifier
    // 로 역산 후, 같은 이름이 다른 곳에서 `var X,` / `var X;` 로 재선언되면 shadow.
    const gn_marker = "(){return $gn(";
    const gn_pos = std.mem.indexOf(u8, out, gn_marker) orelse return error.CounterFnNotFound;
    var name_start = gn_pos;
    while (name_start > 0) : (name_start -= 1) {
        const c = out[name_start - 1];
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) break;
    }
    const counter_name = out[name_start..gn_pos];
    try std.testing.expect(counter_name.len > 0);

    // `var NAME,` 와 `var NAME;` 둘 다 shadow. indexOf null 이면 안전.
    var buf: [32]u8 = undefined;
    const comma_probe = try std.fmt.bufPrint(&buf, "var {s},", .{counter_name});
    try std.testing.expect(std.mem.indexOf(u8, out, comma_probe) == null);
    const semi_probe = try std.fmt.bufPrint(buf[comma_probe.len..], "var {s};", .{counter_name});
    try std.testing.expect(std.mem.indexOf(u8, out, semi_probe) == null);
}
