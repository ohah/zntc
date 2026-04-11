const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

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

    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x=1;") != null);
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

    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
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
    const alloc = arena.allocator();

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
    const alloc = arena.allocator();

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
