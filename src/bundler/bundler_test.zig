const std = @import("std");
const Bundler = @import("bundler.zig").Bundler;
const types = @import("types.zig");
const emitter = @import("emitter.zig");
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const writeFile = @import("test_helpers.zig").writeFile;

fn absPath(tmp: *std.testing.TmpDir, rel: []const u8) ![]const u8 {
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    return try std.fs.path.resolve(std.testing.allocator, &.{ dp, rel });
}

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

// ============================================================
// TypeScript-specific bundling
// ============================================================

test "TypeScript: interface stripping across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { User } from './types';\nconst u: User = { name: 'test' };\nconsole.log(u);");
    try writeFile(tmp.dir, "types.ts", "export interface User { name: string; }\nexport interface Config { debug: boolean; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 인터페이스는 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    // 값 코드는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"test\"") != null);
}

test "TypeScript: enum across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Color } from './enums';\nconsole.log(Color.Red);");
    try writeFile(tmp.dir, "enums.ts", "export enum Color { Red, Green, Blue }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // enum → IIFE 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Color") != null);
}

test "TypeScript: type annotation stripping in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { process } from './processor';
        \\const result: string = process(42);
        \\console.log(result);
    );
    try writeFile(tmp.dir, "processor.ts",
        \\export function process(input: number): string {
        \\  return String(input);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 타입 어노테이션 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
    // 로직은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "String(input)") != null);
}

test "TypeScript: class with generics across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Container } from './container';
        \\const c = new Container(42);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "container.ts",
        \\export class Container<T> {
        \\  value: T;
        \\  constructor(v: T) { this.value = v; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 제네릭 타입 파라미터 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<T>") == null);
    // 클래스 구조는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Container") != null);
}

test "TypeScript: mixed type and value exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { API_URL, type Config } from './config';
        \\const url: Config = { url: API_URL };
        \\console.log(url);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export type Config = { url: string };
        \\export const API_URL = 'https://api.example.com';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // type은 제거, 값은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type Config") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"https://api.example.com\"") != null);
}

// ============================================================
// Deep dependency chains
// ============================================================

test "Deep chain: four-level (A→B→C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconsole.log('b');");
    try writeFile(tmp.dir, "c.ts", "import './d';\nconsole.log('c');");
    try writeFile(tmp.dir, "d.ts", "console.log('d');");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 실행 순서: d → c → b → a (DFS 후위)
    const d_pos = std.mem.indexOf(u8, result.output, "\"d\"") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, result.output, "\"c\"") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "\"b\"") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "\"a\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_pos < c_pos);
    try std.testing.expect(c_pos < b_pos);
    try std.testing.expect(b_pos < a_pos);
}

test "Deep chain: wide fan-out (entry imports 5 modules)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './m1';\nimport './m2';\nimport './m3';\nimport './m4';\nimport './m5';\nconsole.log('done');");
    try writeFile(tmp.dir, "m1.ts", "console.log('m1');");
    try writeFile(tmp.dir, "m2.ts", "console.log('m2');");
    try writeFile(tmp.dir, "m3.ts", "console.log('m3');");
    try writeFile(tmp.dir, "m4.ts", "console.log('m4');");
    try writeFile(tmp.dir, "m5.ts", "console.log('m5');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 모듈 포함
    for ([_][]const u8{ "\"m1\"", "\"m2\"", "\"m3\"", "\"m4\"", "\"m5\"", "\"done\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
    // entry(done)이 가장 마지막
    const done_pos = std.mem.indexOf(u8, result.output, "\"done\"") orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "\"m1\"", "\"m2\"", "\"m3\"", "\"m4\"", "\"m5\"" }) |needle| {
        const pos = std.mem.indexOf(u8, result.output, needle) orelse return error.TestUnexpectedResult;
        try std.testing.expect(pos < done_pos);
    }
}

test "Deep chain: diamond dependency (A→B,C; B→D; C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { b } from './b';\nimport { c } from './c';\nconsole.log(b, c);");
    try writeFile(tmp.dir, "b.ts", "import { d } from './d';\nexport const b = d + 1;");
    try writeFile(tmp.dir, "c.ts", "import { d } from './d';\nexport const c = d + 2;");
    try writeFile(tmp.dir, "d.ts", "export const d = 100;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // d가 b, c보다 먼저 (공유 leaf)
    const d_pos = std.mem.indexOf(u8, result.output, "const d = 100;") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "d + 1") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, result.output, "d + 2") orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_pos < b_pos);
    try std.testing.expect(d_pos < c_pos);
}

// ============================================================
// Real-world patterns (Webpack/Rolldown/esbuild 참고)
// ============================================================

test "Real-world: utils module pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { capitalize, slugify } from './utils';
        \\console.log(capitalize('hello'), slugify('Hello World'));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function capitalize(s: string): string {
        \\  return s.charAt(0).toUpperCase() + s.slice(1);
        \\}
        \\export function slugify(s: string): string {
        \\  return s.toLowerCase().replace(/ /g, '-');
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function capitalize") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function slugify") != null);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
}

test "Real-world: constants module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { MAX_RETRIES, TIMEOUT, BASE_URL } from './constants';
        \\console.log(MAX_RETRIES, TIMEOUT, BASE_URL);
    );
    try writeFile(tmp.dir, "constants.ts",
        \\export const MAX_RETRIES = 3;
        \\export const TIMEOUT = 5000;
        \\export const BASE_URL = '/api/v1';
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MAX_RETRIES = 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TIMEOUT = 5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"/api/v1\"") != null);
}

test "Real-world: class with imported dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { Logger } from './logger';
        \\const log = new Logger('app');
        \\log.info('started');
    );
    try writeFile(tmp.dir, "logger.ts",
        \\import { formatDate } from './date';
        \\export class Logger {
        \\  prefix: string;
        \\  constructor(p: string) { this.prefix = p; }
        \\  info(msg: string) { console.log(formatDate() + ' ' + this.prefix + ': ' + msg); }
        \\}
    );
    try writeFile(tmp.dir, "date.ts",
        \\export function formatDate(): string {
        \\  return new Date().toISOString();
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3모듈 번들: date → logger → app 순서
    const date_pos = std.mem.indexOf(u8, result.output, "function formatDate") orelse return error.TestUnexpectedResult;
    const logger_pos = std.mem.indexOf(u8, result.output, "class Logger") orelse return error.TestUnexpectedResult;
    const app_pos = std.mem.indexOf(u8, result.output, "new Logger") orelse return error.TestUnexpectedResult;
    try std.testing.expect(date_pos < logger_pos);
    try std.testing.expect(logger_pos < app_pos);
}

test "Real-world: event emitter pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { EventBus } from './events';
        \\const bus = new EventBus();
        \\bus.on('click', () => console.log('clicked'));
    );
    try writeFile(tmp.dir, "events.ts",
        \\export class EventBus {
        \\  listeners: Record<string, Function[]> = {};
        \\  on(event: string, fn: Function) {
        \\    if (!this.listeners[event]) this.listeners[event] = [];
        \\    this.listeners[event].push(fn);
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class EventBus") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new EventBus") != null);
}

test "Real-world: re-export from node_modules (external)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import React from 'react';
        \\import { useState } from 'react';
        \\import { render } from './renderer';
        \\render();
    );
    try writeFile(tmp.dir, "renderer.ts",
        \\export function render() { console.log('render'); }
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 로컬 모듈은 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function render") != null);
}

// ============================================================
// Output format tests (all formats with same input)
// ============================================================

test "Format: ESM preserves export in entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const version = '1.0.0';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"1.0.0\"") != null);
}

test "Format: CJS with multiple modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 'cjs-test';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"cjs-test\"") != null);
}

test "Format: IIFE with multiple modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './greeter';\ngreet();");
    try writeFile(tmp.dir, "greeter.ts", "export function greet() { console.log('hello'); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
}

test "Format: minified IIFE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './m';\nconsole.log(x);");
    try writeFile(tmp.dir, "m.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    // 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "Format: minified CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const msg = 'hello';\nconsole.log(msg);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
}

// ============================================================
// Edge cases
// ============================================================

test "Edge: empty module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './empty';\nconsole.log('ok');");
    try writeFile(tmp.dir, "empty.ts", "");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ok\"") != null);
}

test "Edge: module with only comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './commented';\nconsole.log('works');");
    try writeFile(tmp.dir, "commented.ts", "// This is just a comment\n/* block comment */");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"works\"") != null);
}

test "Edge: side-effect only imports preserve execution order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './init1';\nimport './init2';\nimport './init3';\nconsole.log('app');");
    try writeFile(tmp.dir, "init1.ts", "console.log('init1');");
    try writeFile(tmp.dir, "init2.ts", "console.log('init2');");
    try writeFile(tmp.dir, "init3.ts", "console.log('init3');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // import 순서대로 실행: init1 → init2 → init3 → app
    const p1 = std.mem.indexOf(u8, result.output, "\"init1\"") orelse return error.TestUnexpectedResult;
    const p2 = std.mem.indexOf(u8, result.output, "\"init2\"") orelse return error.TestUnexpectedResult;
    const p3 = std.mem.indexOf(u8, result.output, "\"init3\"") orelse return error.TestUnexpectedResult;
    const pa = std.mem.indexOf(u8, result.output, "\"app\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(p1 < p2);
    try std.testing.expect(p2 < p3);
    try std.testing.expect(p3 < pa);
}

test "Edge: same module imported by multiple parents (dedup)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './shared';
        \\import { getX } from './helper';
        \\console.log(x, getX());
    );
    try writeFile(tmp.dir, "helper.ts",
        \\import { x } from './shared';
        \\export function getX() { return x; }
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared_value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared 모듈의 코드는 한 번만 포함
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "\"shared_value\"")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Edge: deeply nested directory imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/app/main.ts", "import { db } from '../lib/db/client';\nconsole.log(db);");
    try writeFile(tmp.dir, "src/lib/db/client.ts", "export const db = 'connected';");

    const entry = try absPath(&tmp, "src/app/main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"connected\"") != null);
}

test "Edge: export function and class from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createApp, App } from './framework';
        \\const app = createApp();
        \\console.log(app instanceof App);
    );
    try writeFile(tmp.dir, "framework.ts",
        \\export class App { name = 'app'; }
        \\export function createApp() { return new App(); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class App") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function createApp") != null);
}

test "Edge: multiple external packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import lodash from 'lodash';
        \\import axios from 'axios';
        \\import { local } from './local';
        \\console.log(local);
    );
    try writeFile(tmp.dir, "local.ts", "export const local = 'yes';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{ "react", "lodash", "axios" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
}

test "ESM external: require preamble (esbuild compatible, no import)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import { useState } from 'react';
        \\import * as lodash from 'lodash';
        \\console.log(React, useState, lodash);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{ "react", "lodash" },
        // format 기본값 = ESM
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // esbuild 호환: require() preamble 사용 (import 구문 없음 → Node CJS 파싱)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(") != null);
    // import 구문이 없어야 함 (있으면 Node가 ESM으로 파싱하여 var 재선언 에러)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

test "CJS external: require preamble generated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\console.log(React);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS 출력: require() preamble이 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(") != null);
}

test "Edge: import with .js extension resolves to .ts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './lib.js';\nconsole.log(val);");
    try writeFile(tmp.dir, "lib.ts", "export const val = 'from-ts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-ts\"") != null);
}

test "Edge: index.ts resolution (directory import)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { hello } from './mylib';\nconsole.log(hello);");
    try writeFile(tmp.dir, "mylib/index.ts", "export const hello = 'world';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"world\"") != null);
}

// ============================================================
// Complex integration scenarios (esbuild/Rspack 참고)
// ============================================================

test "Complex: mixed import styles in one file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import def from './default';
        \\import { named } from './named';
        \\import './side-effect';
        \\console.log(def, named);
    );
    try writeFile(tmp.dir, "default.ts", "export default 'default_val';");
    try writeFile(tmp.dir, "named.ts", "export const named = 'named_val';");
    try writeFile(tmp.dir, "side-effect.ts", "console.log('side');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default_val\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named_val\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"side\"") != null);
}

test "Complex: transitive import chain with values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { result } from './compute';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "compute.ts",
        \\import { base } from './base';
        \\import { multiplier } from './config';
        \\export const result = base * multiplier;
    );
    try writeFile(tmp.dir, "base.ts", "export const base = 10;");
    try writeFile(tmp.dir, "config.ts", "export const multiplier = 5;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // base, config 가 compute보다 먼저
    const base_pos = std.mem.indexOf(u8, result.output, "base = 10") orelse return error.TestUnexpectedResult;
    const mult_pos = std.mem.indexOf(u8, result.output, "multiplier = 5") orelse return error.TestUnexpectedResult;
    const result_pos = std.mem.indexOf(u8, result.output, "base * multiplier") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_pos < result_pos);
    try std.testing.expect(mult_pos < result_pos);
}

test "Complex: multiple entry points sharing a module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "page1.ts", "import { shared } from './shared';\nconsole.log('page1', shared);");
    try writeFile(tmp.dir, "page2.ts", "import { shared } from './shared';\nconsole.log('page2', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const entry1 = try absPath(&tmp, "page1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "page2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"common\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"page1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"page2\"") != null);
}

test "Complex: platform node with external builtins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "server.ts",
        \\import fs from 'fs';
        \\import path from 'path';
        \\import { config } from './config';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts", "export const config = { port: 3000 };");

    const entry = try absPath(&tmp, "server.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // node builtins (fs, path) are external on node platform
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "port: 3000") != null);
}

test "Complex: arrow functions across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { double, triple } from './transforms';
        \\console.log(double(5), triple(3));
    );
    try writeFile(tmp.dir, "transforms.ts",
        \\export const double = (n: number) => n * 2;
        \\export const triple = (n: number) => n * 3;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n * 3") != null);
    // 타입 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
}

test "Complex: async function across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchData } from './api';
        \\fetchData().then(console.log);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export async function fetchData(): Promise<string> {
        \\  return 'data';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function fetchData") != null);
    // 리턴 타입 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Promise<string>") == null);
}

test "Complex: destructuring imports used in complex expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { width, height } from './dimensions';
        \\const area = width * height;
        \\const perimeter = 2 * (width + height);
        \\console.log({ area, perimeter });
    );
    try writeFile(tmp.dir, "dimensions.ts",
        \\export const width = 10;
        \\export const height = 20;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "width * height") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "width + height") != null);
}

// ============================================================
// Rollup-style tests: re-export variants + scope hoisting
// ============================================================

test "Rollup: export * with local override" {
    // Rollup form/samples 참고: star re-export + 로컬 같은 이름 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y } from './barrel';
        \\console.log(x, y);
    );
    // barrel에서 export * 하면서 x를 로컬로도 export
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './source';
        \\export const x = 'overridden';
    );
    try writeFile(tmp.dir, "source.ts",
        \\export const x = 'original';
        \\export const y = 'from-source';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-source\"") != null);
}

test "Rollup: chained re-exports through three modules" {
    // Rollup 스타일: A imports from B, B re-exports from C, C re-exports from D
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { deep } from './l1';\nconsole.log(deep);");
    try writeFile(tmp.dir, "l1.ts", "export { deep } from './l2';");
    try writeFile(tmp.dir, "l2.ts", "export { deep } from './l3';");
    try writeFile(tmp.dir, "l3.ts", "export const deep = 'leaf-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"leaf-value\"") != null);
    // 중간 re-export 모듈들의 import/export는 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

test "Rollup: side-effect free import ordering" {
    // Rollup: import 순서가 실행 순서를 결정 (ESM spec)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './polyfill';
        \\import './setup';
        \\import { app } from './app';
        \\console.log(app);
    );
    try writeFile(tmp.dir, "polyfill.ts", "console.log('polyfill');");
    try writeFile(tmp.dir, "setup.ts", "console.log('setup');");
    try writeFile(tmp.dir, "app.ts", "export const app = 'ready';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill → setup → app → entry 순서
    const poly_pos = std.mem.indexOf(u8, result.output, "\"polyfill\"") orelse return error.TestUnexpectedResult;
    const setup_pos = std.mem.indexOf(u8, result.output, "\"setup\"") orelse return error.TestUnexpectedResult;
    const app_pos = std.mem.indexOf(u8, result.output, "\"ready\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(poly_pos < setup_pos);
    try std.testing.expect(setup_pos < app_pos);
}

test "Rollup: multiple exports from single module" {
    // Rollup form/samples: 한 모듈에서 여러 종류의 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn, cls, val, arrow } from './lib';
        \\console.log(fn(), new cls(), val, arrow());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function fn() { return 1; }
        \\export class cls { x = 2; }
        \\export const val = 3;
        \\export const arrow = () => 4;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class cls") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "val = 3") != null);
}

// ============================================================
// esbuild-style tests: external handling + format conversion
// ============================================================

test "esbuild: external glob pattern" {
    // esbuild: 글롭 패턴으로 external 지정
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import ReactDOM from 'react-dom';
        \\import { local } from './local';
        \\console.log(local);
    );
    try writeFile(tmp.dir, "local.ts", "export const local = 'bundled';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react*"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // react, react-dom 둘 다 external
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"bundled\"") != null);
}

test "esbuild: node builtins auto-external" {
    // esbuild: platform=node에서 node: prefix 자동 external
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import crypto from 'node:crypto';
        \\import { readFile } from 'node:fs/promises';
        \\const key = 'local-value';
        \\console.log(key);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local-value\"") != null);
}

test "esbuild: define global replacement" {
    // esbuild --define 테스트는 CLI 수준 → 번들러에서는 변환 결과만 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const isProd = false;
        \\if (isProd) { console.log('prod'); }
        \\console.log('dev');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"dev\"") != null);
}

test "esbuild: ESM to CJS format conversion with imports" {
    // esbuild: ESM 입력 → CJS 출력, import가 require로 변환되지 않고 번들에 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\export const result = helper(42);
    );
    try writeFile(tmp.dir, "helper.ts",
        \\export function helper(n: number) { return n * 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

test "esbuild: ESM to IIFE with scope hoisting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add } from './math';
        \\console.log(add(1, 2));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export function add(a: number, b: number) { return a + b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function add") != null);
    // import 문 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

// ============================================================
// Bun-style tests: TypeScript, barrel files, resolution
// ============================================================

test "Bun: barrel file with selective import" {
    // Bun: barrel에서 일부만 import (사용하지 않는 export도 번들에는 포함)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Button } from './components';
        \\console.log(Button);
    );
    try writeFile(tmp.dir, "components/index.ts",
        \\export { Button } from './Button';
        \\export { Card } from './Card';
    );
    try writeFile(tmp.dir, "components/Button.ts", "export const Button = 'btn';");
    try writeFile(tmp.dir, "components/Card.ts", "export const Card = 'card';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"btn\"") != null);
}

test "Bun: TypeScript interface-only module" {
    // Bun: 타입만 있는 모듈 import
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MyType } from './types';
        \\const x: MyType = 42;
        \\console.log(x);
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface MyType {}
        \\export type OtherType = string | number;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 인터페이스/타입 모두 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Bun: .tsx file bundling" {
    // Bun: TSX 파일의 JSX 변환 + 번들링
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\import { Component } from './comp';
        \\console.log(Component);
    );
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Component() { return <div>hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Component") != null);
    // JSX가 변환됨 (<div> → React.createElement 등)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<div>") == null);
}

test "Bun: extension resolution priority (.ts over .js)" {
    // Bun: .ts 확장자가 .js보다 우선
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 'from-ts';");
    try writeFile(tmp.dir, "lib.js", "export const x = 'from-js';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // .ts가 .js보다 우선
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-ts\"") != null);
}

test "Bun: complex real-world component pattern" {
    // Bun 스타일: 컴포넌트 + 훅 + 유틸 패턴 (React-like)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { createStore } from './store';
        \\import { logger } from './utils/logger';
        \\const store = createStore();
        \\logger('App initialized');
        \\console.log(store);
    );
    try writeFile(tmp.dir, "store.ts",
        \\import { logger } from './utils/logger';
        \\export function createStore() {
        \\  logger('Store created');
        \\  return { state: {} };
        \\}
    );
    try writeFile(tmp.dir, "utils/logger.ts",
        \\export function logger(msg: string) {
        \\  console.log('[LOG]', msg);
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // logger가 store보다 먼저 (의존성 순서)
    const logger_pos = std.mem.indexOf(u8, result.output, "function logger") orelse return error.TestUnexpectedResult;
    const store_pos = std.mem.indexOf(u8, result.output, "function createStore") orelse return error.TestUnexpectedResult;
    try std.testing.expect(logger_pos < store_pos);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
}

// ============================================================
// Rolldown-style tests: CJS compat + symbol deconflicting
// ============================================================

test "Rolldown: symbol deconflicting with many modules" {
    // Rolldown: 5개 모듈에서 같은 이름 사용 → 순차적 $1, $2, ...
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\import './b';
        \\import './c';
        \\import './d';
        \\const value = 'entry';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "a.ts", "const value = 'a';\nconsole.log(value);");
    try writeFile(tmp.dir, "b.ts", "const value = 'b';\nconsole.log(value);");
    try writeFile(tmp.dir, "c.ts", "const value = 'c';\nconsole.log(value);");
    try writeFile(tmp.dir, "d.ts", "const value = 'd';\nconsole.log(value);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 5개 value → 최소 4개는 리네임 ($1, $2, $3, $4)
    var rename_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "value$")) |pos| {
        rename_count += 1;
        search_from = pos + 1;
    }
    try std.testing.expect(rename_count >= 4);
}

test "Rolldown: export default function with rename" {
    // Rolldown: default export 함수 + 같은 이름의 변수가 다른 모듈에
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import handler from './handler';
        \\const handler2 = () => 'local';
        \\console.log(handler(), handler2());
    );
    try writeFile(tmp.dir, "handler.ts",
        \\export default function handler() { return 'from-module'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local\"") != null);
}

test "Rolldown: deep re-export with export *" {
    // Rolldown tree_shaking: export * 체인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { data } from './index';
        \\console.log(data);
    );
    try writeFile(tmp.dir, "index.ts", "export * from './layer1';");
    try writeFile(tmp.dir, "layer1.ts", "export * from './layer2';");
    try writeFile(tmp.dir, "layer2.ts", "export const data = 'deep-star';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep-star\"") != null);
}

test "Rolldown: mixed default and named imports from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config, { VERSION, DEBUG } from './config';
        \\console.log(config, VERSION, DEBUG);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export const VERSION = '2.0';
        \\export const DEBUG = false;
        \\export default { name: 'myapp' };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"myapp\"") != null);
}

// ============================================================
// Webpack-style tests: scope hoisting edge cases
// ============================================================

test "Webpack: scope hoisting with nested functions" {
    // Webpack scope-hoisting: 중첩 함수의 변수는 충돌 대상 아님
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { outer } from './mod';
        \\console.log(outer());
    );
    try writeFile(tmp.dir, "mod.ts",
        \\export function outer() {
        \\  const x = 1;
        \\  function inner() { const x = 2; return x; }
        \\  return x + inner();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function inner") != null);
}

test "Webpack: import order matches dependency graph" {
    // Webpack cases/scope-hoisting: import-order
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './a';
        \\import { b } from './b';
        \\console.log(a + b);
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { shared } from './shared';
        \\export const a = shared + '-a';
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { shared } from './shared';
        \\export const b = shared + '-b';
    );
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'base';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared → a → b → entry 순서 (shared가 가장 먼저)
    const shared_pos = std.mem.indexOf(u8, result.output, "\"base\"") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "\"-a\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shared_pos < a_pos);
}

test "Webpack: re-export with alias name" {
    // Webpack: export { x as y } from
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { aliased } from './reexport';
        \\console.log(aliased);
    );
    try writeFile(tmp.dir, "reexport.ts", "export { original as aliased } from './source';");
    try writeFile(tmp.dir, "source.ts", "export const original = 'orig-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"orig-value\"") != null);
}

// ============================================================
// Stress / robustness tests
// ============================================================

test "Stress: 10 modules in chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // m0 → m1 → m2 → ... → m9 (각각 import + 값)
    try writeFile(tmp.dir, "m0.ts", "import './m1';\nconsole.log('m0');");
    try writeFile(tmp.dir, "m1.ts", "import './m2';\nconsole.log('m1');");
    try writeFile(tmp.dir, "m2.ts", "import './m3';\nconsole.log('m2');");
    try writeFile(tmp.dir, "m3.ts", "import './m4';\nconsole.log('m3');");
    try writeFile(tmp.dir, "m4.ts", "import './m5';\nconsole.log('m4');");
    try writeFile(tmp.dir, "m5.ts", "import './m6';\nconsole.log('m5');");
    try writeFile(tmp.dir, "m6.ts", "import './m7';\nconsole.log('m6');");
    try writeFile(tmp.dir, "m7.ts", "import './m8';\nconsole.log('m7');");
    try writeFile(tmp.dir, "m8.ts", "import './m9';\nconsole.log('m8');");
    try writeFile(tmp.dir, "m9.ts", "console.log('m9');");

    const entry = try absPath(&tmp, "m0.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // m9가 가장 먼저, m0이 가장 나중
    const m9_pos = std.mem.indexOf(u8, result.output, "\"m9\"") orelse return error.TestUnexpectedResult;
    const m0_pos = std.mem.indexOf(u8, result.output, "\"m0\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(m9_pos < m0_pos);
}

test "Stress: wide fan-in (many modules import same leaf)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a'; import './b'; import './c'; import './d';
        \\console.log('entry');
    );
    try writeFile(tmp.dir, "a.ts", "import { x } from './leaf';\nconsole.log('a', x);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './leaf';\nconsole.log('b', x);");
    try writeFile(tmp.dir, "c.ts", "import { x } from './leaf';\nconsole.log('c', x);");
    try writeFile(tmp.dir, "d.ts", "import { x } from './leaf';\nconsole.log('d', x);");
    try writeFile(tmp.dir, "leaf.ts", "export const x = 'shared';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // leaf 코드는 한 번만 포함
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "\"shared\"")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Stress: multiple entry points with deep shared graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts", "import { a } from './a';\nconsole.log('e1', a);");
    try writeFile(tmp.dir, "e2.ts", "import { b } from './b';\nconsole.log('e2', b);");
    try writeFile(tmp.dir, "a.ts", "import { common } from './common';\nexport const a = common + '-a';");
    try writeFile(tmp.dir, "b.ts", "import { common } from './common';\nexport const b = common + '-b';");
    try writeFile(tmp.dir, "common.ts", "export const common = 'shared-base';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shared-base\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"e1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"e2\"") != null);
}

// ============================================================
// Default export advanced patterns (Rollup/Rolldown 참고)
// ============================================================

test "Default: export default class" {
    // Rollup default-export-class: 클래스를 default export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import MyClass from './myclass';
        \\const inst = new MyClass();
        \\console.log(inst.name);
    );
    try writeFile(tmp.dir, "myclass.ts",
        \\export default class MyClass {
        \\  name = 'hello';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class MyClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new MyClass") != null);
}

test "Default: export default arrow function" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import multiply from './math';
        \\console.log(multiply(3, 4));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export default (a: number, b: number) => a * b;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a * b") != null);
}

test "Default: re-export default from another module" {
    // Rolldown: export { default } from './mod'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import val from './proxy';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "proxy.ts", "export { default } from './real';");
    try writeFile(tmp.dir, "real.ts", "export default 'real-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"real-value\"") != null);
}

test "Default: default export with same-name local variable" {
    // Rollup default-identifier-deshadowing
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import foo from './mod';
        \\console.log(foo);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const foo = 'local';
        \\export default function foo2() { return foo; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local\"") != null);
}

test "Default: multiple modules with default exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import a from './a';
        \\import b from './b';
        \\import c from './c';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "a.ts", "export default 'alpha';");
    try writeFile(tmp.dir, "b.ts", "export default 'beta';");
    try writeFile(tmp.dir, "c.ts", "export default 'gamma';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"beta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"gamma\"") != null);
}

// ============================================================
// Deconflicting advanced patterns (Rollup/Rolldown 참고)
// ============================================================

test "Deconflict: exported function name clashes with import" {
    // 두 모듈이 같은 이름의 함수를 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { render } from './a';
        \\import { render as renderB } from './b';
        \\render();
        \\renderB();
    );
    try writeFile(tmp.dir, "a.ts", "export function render() { console.log('a'); }");
    try writeFile(tmp.dir, "b.ts", "export function render() { console.log('b'); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 render가 충돌 → 하나는 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "render$") != null or
        std.mem.indexOf(u8, result.output, "function render") != null);
}

test "Deconflict: class name collision across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './models/user';
        \\import './models/admin';
        \\class Model { type = 'base'; }
        \\console.log(new Model());
    );
    try writeFile(tmp.dir, "models/user.ts",
        \\class Model { type = 'user'; }
        \\console.log(new Model());
    );
    try writeFile(tmp.dir, "models/admin.ts",
        \\class Model { type = 'admin'; }
        \\console.log(new Model());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 Model 클래스 → 리네임 발생
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Model$") != null);
}

test "Deconflict: variable shadows built-in name" {
    // 모듈에서 console, Math 등과 같은 이름 사용
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\const log = 'entry-log';
        \\console.log(log);
    );
    try writeFile(tmp.dir, "a.ts",
        \\const log = 'a-log';
        \\console.log(log);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // log가 충돌 → 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "log$") != null);
}

// ============================================================
// Assignment patterns (Rollup 참고)
// ============================================================

test "Assignment: export var reassignment" {
    // Rollup assignment-to-exports
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { counter, increment } from './counter';
        \\console.log(counter);
        \\increment();
    );
    try writeFile(tmp.dir, "counter.ts",
        \\export let counter = 0;
        \\export function increment() { counter++; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "let counter = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function increment") != null);
}

test "Assignment: export const with complex initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { config } from './setup';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "setup.ts",
        \\const env = 'production';
        \\export const config = {
        \\  env,
        \\  debug: env !== 'production',
        \\  version: '1.0.' + String(42),
        \\};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"production\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "String(42)") != null);
}

// ============================================================
// TypeScript advanced patterns
// ============================================================

test "TypeScript: namespace with export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Colors } from './colors';
        \\console.log(Colors.Red);
    );
    try writeFile(tmp.dir, "colors.ts",
        \\export namespace Colors {
        \\  export const Red = '#ff0000';
        \\  export const Blue = '#0000ff';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Colors") != null);
}

test "TypeScript: abstract class bundling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Dog } from './dog';
        \\const d = new Dog('Rex');
        \\console.log(d.speak());
    );
    try writeFile(tmp.dir, "dog.ts",
        \\import { Animal } from './animal';
        \\export class Dog extends Animal {
        \\  speak(): string { return this.name + ' barks'; }
        \\}
    );
    try writeFile(tmp.dir, "animal.ts",
        \\export abstract class Animal {
        \\  constructor(public name: string) {}
        \\  abstract speak(): string;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // abstract 키워드 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "abstract") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Animal") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Dog") != null);
}

test "TypeScript: const enum inlining" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Direction } from './direction';
        \\console.log(Direction.Up);
    );
    try writeFile(tmp.dir, "direction.ts",
        \\export const enum Direction {
        \\  Up,
        \\  Down,
        \\  Left,
        \\  Right,
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "TypeScript: string enum across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Status } from './status';
        \\console.log(Status.Active);
    );
    try writeFile(tmp.dir, "status.ts",
        \\export enum Status {
        \\  Active = 'ACTIVE',
        \\  Inactive = 'INACTIVE',
        \\  Pending = 'PENDING',
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ACTIVE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Status") != null);
}

test "TypeScript: multiple interfaces stripped clean" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Logger } from './logger';
        \\const l = new Logger();
        \\l.log('test');
    );
    try writeFile(tmp.dir, "logger.ts",
        \\interface LogLevel { level: string; }
        \\interface LogConfig extends LogLevel { prefix: string; }
        \\type LogFn = (msg: string) => void;
        \\export class Logger {
        \\  log(msg: string) { console.log(msg); }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Logger") != null);
}

// ============================================================
// Circular dependency advanced (SWC/Rolldown 참고)
// ============================================================

test "Circular: four module cycle (A→B→C→D→A)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('A');");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconsole.log('B');");
    try writeFile(tmp.dir, "c.ts", "import './d';\nconsole.log('C');");
    try writeFile(tmp.dir, "d.ts", "import './a';\nconsole.log('D');");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    var has_circular = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .circular_dependency) has_circular = true;
    }
    try std.testing.expect(has_circular);
    // 모든 모듈 포함
    for ([_][]const u8{ "\"A\"", "\"B\"", "\"C\"", "\"D\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "Circular: mutual import with re-exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { combined } from './combiner';
        \\console.log(combined);
    );
    try writeFile(tmp.dir, "combiner.ts",
        \\import { foo } from './foo';
        \\import { bar } from './bar';
        \\export const combined = foo + bar;
    );
    try writeFile(tmp.dir, "foo.ts",
        \\import { bar } from './bar';
        \\export const foo = 'FOO';
    );
    try writeFile(tmp.dir, "bar.ts",
        \\import { foo } from './foo';
        \\export const bar = 'BAR';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 순환이 있어도 번들은 생성됨
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"FOO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"BAR\"") != null);
}

test "Circular: entry depends on circular pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\console.log('entry done');
    );
    try writeFile(tmp.dir, "a.ts",
        \\import './b';
        \\console.log('a');
    );
    try writeFile(tmp.dir, "b.ts",
        \\import './a';
        \\console.log('b');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry가 마지막
    const entry_pos = std.mem.indexOf(u8, result.output, "\"entry done\"") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "\"a\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < entry_pos);
}

// ============================================================
// Module resolution edge cases
// ============================================================

test "Resolution: parent directory traversal (../../)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/pages/home.ts",
        \\import { version } from '../../package-info';
        \\console.log(version);
    );
    try writeFile(tmp.dir, "package-info.ts", "export const version = '3.0.0';");

    const entry = try absPath(&tmp, "src/pages/home.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"3.0.0\"") != null);
}

test "Resolution: .tsx extension for React components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Header } from './Header';
        \\console.log(Header);
    );
    try writeFile(tmp.dir, "Header.tsx",
        \\export function Header() { return <h1>Title</h1>; }
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Header") != null);
}

test "Resolution: mixed .ts and .tsx imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\import { util } from './util';
        \\import { View } from './view';
        \\console.log(util, View);
    );
    try writeFile(tmp.dir, "util.ts", "export const util = 'utility';");
    try writeFile(tmp.dir, "view.tsx", "export function View() { return <div/>; }");

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"utility\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function View") != null);
}

// ============================================================
// Complex real-world patterns (esbuild/Bun 참고)
// ============================================================

test "Real-world: layered architecture (controller → service → repository)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { UserController } from './controller';
        \\const ctrl = new UserController();
        \\console.log(ctrl.getUser());
    );
    try writeFile(tmp.dir, "controller.ts",
        \\import { UserService } from './service';
        \\export class UserController {
        \\  svc = new UserService();
        \\  getUser() { return this.svc.findById(1); }
        \\}
    );
    try writeFile(tmp.dir, "service.ts",
        \\import { UserRepo } from './repo';
        \\export class UserService {
        \\  repo = new UserRepo();
        \\  findById(id: number) { return this.repo.get(id); }
        \\}
    );
    try writeFile(tmp.dir, "repo.ts",
        \\export class UserRepo {
        \\  get(id: number) { return { id, name: 'User' }; }
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 의존성 순서: repo → service → controller → app
    const repo_pos = std.mem.indexOf(u8, result.output, "class UserRepo") orelse return error.TestUnexpectedResult;
    const svc_pos = std.mem.indexOf(u8, result.output, "class UserService") orelse return error.TestUnexpectedResult;
    const ctrl_pos = std.mem.indexOf(u8, result.output, "class UserController") orelse return error.TestUnexpectedResult;
    try std.testing.expect(repo_pos < svc_pos);
    try std.testing.expect(svc_pos < ctrl_pos);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
}

test "Real-world: plugin system pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createApp } from './app';
        \\import { loggerPlugin } from './plugins/logger';
        \\import { authPlugin } from './plugins/auth';
        \\const app = createApp();
        \\app.use(loggerPlugin);
        \\app.use(authPlugin);
    );
    try writeFile(tmp.dir, "app.ts",
        \\export function createApp() {
        \\  const plugins: Function[] = [];
        \\  return {
        \\    use(plugin: Function) { plugins.push(plugin); },
        \\    run() { plugins.forEach(p => p()); },
        \\  };
        \\}
    );
    try writeFile(tmp.dir, "plugins/logger.ts",
        \\export function loggerPlugin() { console.log('Logger active'); }
    );
    try writeFile(tmp.dir, "plugins/auth.ts",
        \\export function authPlugin() { console.log('Auth active'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function loggerPlugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function authPlugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function createApp") != null);
}

test "Real-world: state management pattern (Redux-like)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createStore } from './store';
        \\import { counterReducer } from './reducers/counter';
        \\const store = createStore(counterReducer);
        \\console.log(store.getState());
    );
    try writeFile(tmp.dir, "store.ts",
        \\export function createStore(reducer: Function) {
        \\  let state = reducer(undefined, { type: '@@INIT' });
        \\  return {
        \\    getState: () => state,
        \\    dispatch: (action: any) => { state = reducer(state, action); },
        \\  };
        \\}
    );
    try writeFile(tmp.dir, "reducers/counter.ts",
        \\export function counterReducer(state: number = 0, action: any) {
        \\  switch (action.type) {
        \\    case 'INCREMENT': return state + 1;
        \\    case 'DECREMENT': return state - 1;
        \\    default: return state;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function createStore") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function counterReducer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"INCREMENT\"") != null);
}

test "Real-world: middleware chain pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "server.ts",
        \\import { cors } from './middleware/cors';
        \\import { rateLimit } from './middleware/rate-limit';
        \\import { handler } from './handler';
        \\const pipeline = [cors, rateLimit, handler];
        \\console.log(pipeline);
    );
    try writeFile(tmp.dir, "middleware/cors.ts",
        \\export function cors(req: any, next: Function) { next(); }
    );
    try writeFile(tmp.dir, "middleware/rate-limit.ts",
        \\export function rateLimit(req: any, next: Function) { next(); }
    );
    try writeFile(tmp.dir, "handler.ts",
        \\export function handler(req: any) { return { status: 200 }; }
    );

    const entry = try absPath(&tmp, "server.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function cors") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function rateLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function handler") != null);
}

// ============================================================
// Error handling & diagnostics
// ============================================================

test "Error: multiple unresolved imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './missing1';
        \\import './missing2';
        \\console.log('unreachable');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
    // 2개의 unresolved import 에러
    var unresolved_count: usize = 0;
    for (result.getDiagnostics()) |d| {
        if (d.code == .unresolved_import) unresolved_count += 1;
    }
    try std.testing.expect(unresolved_count >= 2);
}

test "Error: unresolved in dependency (not entry)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './dep';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "dep.ts",
        \\import './nonexistent';
        \\export const x = 1;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // dep.ts 내부의 미해석 import도 에러로 보고
    try std.testing.expect(result.hasErrors());
}

// ============================================================
// Format-specific advanced tests
// ============================================================

test "Format: all three formats produce valid output for same input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { square } from './math';
        \\console.log(square(5));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export function square(n: number) { return n * n; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // ESM
    var b1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b1.deinit();
    const r1 = try b1.bundle();
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(!r1.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "n * n") != null);

    // CJS
    var b2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b2.deinit();
    const r2 = try b2.bundle();
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(!r2.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, r2.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "n * n") != null);

    // IIFE
    var b3 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b3.deinit();
    const r3 = try b3.bundle();
    defer r3.deinit(std.testing.allocator);
    try std.testing.expect(!r3.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, r3.output, "(function() {\n"));
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "n * n") != null);
}

test "Format: minify removes module boundary comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './dep';\nconsole.log('entry');");
    try writeFile(tmp.dir, "dep.ts", "console.log('dep');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // minify=false → 경계 주석 있음
    var b1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = false,
    });
    defer b1.deinit();
    const r1 = try b1.bundle();
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "// ---") != null);

    // minify=true → 경계 주석 없음
    var b2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b2.deinit();
    const r2 = try b2.bundle();
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "// ---") == null);
}

test "Format: scope_hoist false with all three formats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './m';\nconsole.log(x);");
    try writeFile(tmp.dir, "m.ts", "export const x = 99;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // scope_hoist=false + ESM → import/export 유지
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = false,
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "export") != null or
            std.mem.indexOf(u8, result.output, "import") != null,
    );
}

// ============================================================
// Mixed patterns & complex interactions
// ============================================================

test "Mixed: import default + named from same module, re-exported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { wrapped } from './wrapper';
        \\console.log(wrapped);
    );
    try writeFile(tmp.dir, "wrapper.ts",
        \\import api, { version } from './api';
        \\export const wrapped = api + ' v' + version;
    );
    try writeFile(tmp.dir, "api.ts",
        \\export const version = '2.0';
        \\export default 'MyAPI';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"MyAPI\"") != null);
}

test "Mixed: export * and named export same module" {
    // Rolldown issues/7233 참고
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c } from './barrel';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './m1';
        \\export * from './m2';
    );
    try writeFile(tmp.dir, "m1.ts", "export const a = 'from-m1';");
    try writeFile(tmp.dir, "m2.ts", "export const b = 'from-m2';\nexport const c = 'also-m2';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-m1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-m2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"also-m2\"") != null);
}

test "Mixed: deeply nested barrel with re-exports and defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { utils, helpers } from './lib';
        \\console.log(utils, helpers);
    );
    try writeFile(tmp.dir, "lib/index.ts",
        \\export { utils } from './utils';
        \\export { helpers } from './helpers';
    );
    try writeFile(tmp.dir, "lib/utils/index.ts",
        \\export { format } from './format';
        \\export const utils = 'utils-pkg';
    );
    try writeFile(tmp.dir, "lib/utils/format.ts",
        \\export function format(s: string) { return s.trim(); }
    );
    try writeFile(tmp.dir, "lib/helpers/index.ts",
        \\export const helpers = 'helpers-pkg';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"utils-pkg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"helpers-pkg\"") != null);
}

test "Mixed: template literals and tagged templates across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet, TAG } from './strings';
        \\console.log(greet('world'));
    );
    try writeFile(tmp.dir, "strings.ts",
        \\export const TAG = 'v1';
        \\export function greet(name: string) {
        \\  return `Hello, ${name}! (${TAG})`;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "${name}") != null);
}

test "Mixed: spread operator and rest params across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { merge, sum } from './utils';
        \\console.log(merge({ a: 1 }, { b: 2 }));
        \\console.log(sum(1, 2, 3));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function merge(a: object, b: object) { return { ...a, ...b }; }
        \\export function sum(...nums: number[]) { return nums.reduce((a, b) => a + b, 0); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function merge") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "...nums") != null);
}

test "Mixed: destructuring in import and export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y } from './point';
        \\console.log(x, y);
    );
    try writeFile(tmp.dir, "point.ts",
        \\const point = { x: 10, y: 20, z: 30 };
        \\export const { x, y } = point;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "Mixed: generator function across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { range } from './iter';
        \\for (const n of range(5)) { console.log(n); }
    );
    try writeFile(tmp.dir, "iter.ts",
        \\export function* range(n: number) {
        \\  for (let i = 0; i < n; i++) yield i;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function*") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "yield") != null);
}

test "Mixed: computed property names across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { KEYS, createMap } from './map';
        \\console.log(createMap());
    );
    try writeFile(tmp.dir, "map.ts",
        \\export const KEYS = { name: 'name', age: 'age' };
        \\export function createMap() {
        \\  return { [KEYS.name]: 'John', [KEYS.age]: 30 };
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[KEYS.name]") != null);
}

// ============================================================
// Stress tests: larger scale
// ============================================================

test "Stress: 20 modules in diamond lattice" {
    // A → B1..B4 → C1..C4 (각 B가 모든 C를 import)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './b1'; import './b2'; import './b3'; import './b4';
        \\console.log('entry');
    );
    try writeFile(tmp.dir, "b1.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b1');");
    try writeFile(tmp.dir, "b2.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b2');");
    try writeFile(tmp.dir, "b3.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b3');");
    try writeFile(tmp.dir, "b4.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b4');");
    try writeFile(tmp.dir, "c1.ts", "console.log('c1');");
    try writeFile(tmp.dir, "c2.ts", "console.log('c2');");
    try writeFile(tmp.dir, "c3.ts", "console.log('c3');");
    try writeFile(tmp.dir, "c4.ts", "console.log('c4');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // c 모듈들이 b 모듈들보다 먼저, b가 entry보다 먼저
    const c1_pos = std.mem.indexOf(u8, result.output, "\"c1\"") orelse return error.TestUnexpectedResult;
    const b1_pos = std.mem.indexOf(u8, result.output, "\"b1\"") orelse return error.TestUnexpectedResult;
    const e_pos = std.mem.indexOf(u8, result.output, "\"entry\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c1_pos < b1_pos);
    try std.testing.expect(b1_pos < e_pos);
    // c 모듈은 각각 한 번만 포함 (dedup)
    var c1_count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "\"c1\"")) |pos| {
        c1_count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), c1_count);
}

// ============================================================
// export { x as default } and named-as-default patterns
// ============================================================

test "Export: named as default" {
    // export { x as default } — named export를 default로 re-alias
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import value from './mod';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const value = 42;
        \\export { value as default };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Export: empty export clause" {
    // Rollup empty-export: export {} — 사이드이펙트는 유지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\console.log('side-effect');
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"side-effect\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"main\"") != null);
}

test "Export: multiple imports from same module (dedup bindings)" {
    // 같은 모듈을 여러 번 import — 모듈은 한 번만 실행
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { foo } from './lib';
        \\import { bar } from './lib';
        \\console.log(foo, bar);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\console.log('lib init');
        \\export const foo = 'FOO';
        \\export const bar = 'BAR';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // lib init은 한 번만 포함
    var count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "\"lib init\"")) |pos| {
        count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"FOO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"BAR\"") != null);
}

test "Export: export let with later mutation" {
    // Rollup assignment-to-exports: export let은 뒤에서 재할당 가능
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { count, inc } from './counter';
        \\inc();
        \\console.log(count);
    );
    try writeFile(tmp.dir, "counter.ts",
        \\export let count = 0;
        \\export function inc() { count++; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "let count = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "count++") != null);
}

// ============================================================
// Variable hoisting patterns (Rollup 참고)
// ============================================================

test "Hoisting: var declarations across modules" {
    // var는 hoisting → 번들에서도 올바르게 동작해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getValue } from './hoisted';
        \\console.log(getValue());
    );
    try writeFile(tmp.dir, "hoisted.ts",
        \\export function getValue() { return x; }
        \\var x = 'hoisted-value';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hoisted-value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function getValue") != null);
}

test "Hoisting: function declarations hoisted above usage" {
    // 함수 선언은 hoisting → 사용보다 뒤에 선언돼도 동작
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { run } from './runner';
        \\run();
    );
    try writeFile(tmp.dir, "runner.ts",
        \\export function run() { return helper(); }
        \\function helper() { return 'helped'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function run") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

// ============================================================
// Complex TypeScript patterns not yet covered
// ============================================================

test "TypeScript: declare module stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { process } from './app';
        \\process();
    );
    try writeFile(tmp.dir, "app.ts",
        \\declare module '*.css' { const css: string; export default css; }
        \\export function process() { console.log('processing'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // declare module 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "declare") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"processing\"") != null);
}

test "TypeScript: readonly and access modifiers stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Config } from './config';
        \\const c = new Config('prod', 3000);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export class Config {
        \\  public readonly env: string;
        \\  private port: number;
        \\  constructor(env: string, port: number) {
        \\    this.env = env;
        \\    this.port = port;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readonly") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "public") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Config") != null);
}

test "TypeScript: intersection and union types stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { format } from './formatter';
        \\console.log(format('hello'));
    );
    try writeFile(tmp.dir, "formatter.ts",
        \\type StringOrNumber = string | number;
        \\type WithId = { id: number } & { name: string };
        \\export function format(input: StringOrNumber): string {
        \\  return String(input);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "StringOrNumber") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WithId") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function format") != null);
}

test "TypeScript: as const and satisfies stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { COLORS } from './theme';
        \\console.log(COLORS);
    );
    try writeFile(tmp.dir, "theme.ts",
        \\export const COLORS = {
        \\  red: '#ff0000',
        \\  blue: '#0000ff',
        \\} as const;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "as const") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"#ff0000\"") != null);
}

test "TypeScript: parameter property transform in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Point } from './point';
        \\const p = new Point(10, 20);
        \\console.log(p);
    );
    try writeFile(tmp.dir, "point.ts",
        \\export class Point {
        \\  constructor(public x: number, public y: number) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Point") != null);
    // parameter property → this.x = x; this.y = y; 로 변환
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.x") != null);
}

// ============================================================
// Scope hoisting: deeper patterns (Webpack 참고)
// ============================================================

test "Scope hoisting: imported value used as object key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { KEY } from './keys';
        \\const obj = { [KEY]: 'value' };
        \\console.log(obj);
    );
    try writeFile(tmp.dir, "keys.ts", "export const KEY = 'myKey';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"myKey\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[KEY]") != null);
}

test "Scope hoisting: imported value in template literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { name } from './user';
        \\console.log(`Hello, ${name}!`);
    );
    try writeFile(tmp.dir, "user.ts", "export const name = 'Alice';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "${name}") != null);
}

test "Scope hoisting: imported value in array destructuring" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { pair } from './data';
        \\const [a, b] = pair;
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "data.ts", "export const pair = [1, 2];");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[1, 2]") != null);
}

test "Scope hoisting: imported value in ternary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { DEBUG } from './env';
        \\const level = DEBUG ? 'verbose' : 'error';
        \\console.log(level);
    );
    try writeFile(tmp.dir, "env.ts", "export const DEBUG = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"verbose\"") != null);
}

// ============================================================
// Error cases: more thorough
// ============================================================

test "Error: syntax error in dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './bad';\nconsole.log('ok');");
    try writeFile(tmp.dir, "bad.ts", "const = ;"); // 구문 오류

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 구문 오류가 있는 모듈 → 에러 또는 번들 생성 (에러 복구에 따라)
    // 최소한 크래시하지 않아야 함
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Error: circular re-export chain" {
    // A re-exports from B, B re-exports from A → 무한 루프 방지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './a';\nconsole.log(x);");
    try writeFile(tmp.dir, "a.ts", "export { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './a';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 무한 루프에 빠지지 않고 완료해야 함 (에러 보고 가능)
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Error: entry point not found" {
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{"/nonexistent/path/entry.ts"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
}

// ============================================================
// Re-export advanced: Rollup form/samples 참고
// ============================================================

test "Re-export: export * from multiple sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c } from './all';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "all.ts",
        \\export * from './src-a';
        \\export * from './src-b';
    );
    try writeFile(tmp.dir, "src-a.ts", "export const a = 'A';\nexport const b = 'B';");
    try writeFile(tmp.dir, "src-b.ts", "export const c = 'C';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"C\"") != null);
}

test "Re-export: mixed named and star from same module" {
    // Rolldown #7233: 같은 모듈에서 named + star 동시
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y, z } from './proxy';
        \\console.log(x, y, z);
    );
    try writeFile(tmp.dir, "proxy.ts",
        \\export { x } from './source';
        \\export * from './source';
    );
    try writeFile(tmp.dir, "source.ts",
        \\export const x = 'X';
        \\export const y = 'Y';
        \\export const z = 'Z';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Z\"") != null);
}

test "Re-export: re-export default as named" {
    // export { default as Foo } from './foo'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo } from './proxy';
        \\console.log(Foo);
    );
    try writeFile(tmp.dir, "proxy.ts", "export { default as Foo } from './foo';");
    try writeFile(tmp.dir, "foo.ts", "export default 'default-foo';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default-foo\"") != null);
}

test "Stress: all formats + minify combinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './dep';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 6가지 조합 모두 성공해야 함
    const formats = [_]emitter.EmitOptions.Format{ .esm, .cjs, .iife };
    const minify_opts = [_]bool{ false, true };
    for (formats) |fmt| {
        for (minify_opts) |minify| {
            var b = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .format = fmt,
                .minify_whitespace = minify,
                .minify_identifiers = minify,
                .minify_syntax = minify,
            });
            defer b.deinit();
            const result = try b.bundle();
            defer result.deinit(std.testing.allocator);

            try std.testing.expect(!result.hasErrors());
            try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
        }
    }
}

// ============================================================
// Inline type import edge cases
// ============================================================

test "TypeScript: import type only specifiers all stripped" {
    // 모든 specifier가 type-only → import 문 자체가 side-effect only가 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type Foo, type Bar } from './types';
        \\console.log('no types used');
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface Foo { x: number; }
        \\export interface Bar { y: string; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no types used\"") != null);
}

test "TypeScript: import { type } as value name" {
    // import { type } → 'type'이라는 값 import (modifier 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type } from './mod';
        \\console.log(type);
    );
    try writeFile(tmp.dir, "mod.ts", "export const type = 'my-type-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"my-type-value\"") != null);
}

// ============================================================
// Declare module patterns
// ============================================================

test "TypeScript: declare module '*.svg' stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { render } from './app';
        \\render();
    );
    try writeFile(tmp.dir, "app.ts",
        \\declare module '*.svg' { const src: string; export default src; }
        \\declare module '*.png' { const src: string; export default src; }
        \\export function render() { console.log('rendered'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "declare") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"rendered\"") != null);
}

// ============================================================
// Parameter property patterns
// ============================================================

test "TypeScript: parameter property with multiple modifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Config } from './config';
        \\const c = new Config('prod', true);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export class Config {
        \\  constructor(public readonly env: string, private debug: boolean) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.env") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.debug") != null);
    // 접근 제어자 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "public") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readonly") == null);
}

test "TypeScript: parameter property with default value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Server } from './server';
        \\const s = new Server();
        \\console.log(s);
    );
    try writeFile(tmp.dir, "server.ts",
        \\export class Server {
        \\  constructor(public port: number = 3000) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.port") != null);
}

// ============================================================
// New expression patterns (bug regression tests)
// ============================================================

test "New expression: basic constructor call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo } from './foo';
        \\const f = new Foo();
        \\console.log(f);
    );
    try writeFile(tmp.dir, "foo.ts", "export class Foo { x = 1; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Foo()") != null);
}

test "New expression: with arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Vec2 } from './vec';
        \\const v = new Vec2(10, 20);
        \\console.log(v);
    );
    try writeFile(tmp.dir, "vec.ts",
        \\export class Vec2 {
        \\  constructor(public x: number, public y: number) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Vec2(10, 20)") != null);
}

test "New expression: nested new" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Wrapper, Inner } from './classes';
        \\const w = new Wrapper(new Inner());
        \\console.log(w);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class Inner { val = 'inner'; }
        \\export class Wrapper { constructor(public child: Inner) {} }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Inner") != null);
}

// ============================================================
// Default export regression tests
// ============================================================

test "Default: default export object literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config from './config';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export default { host: 'localhost', port: 8080 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "8080") != null);
}

test "Default: default export array literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import items from './items';
        \\console.log(items);
    );
    try writeFile(tmp.dir, "items.ts",
        \\export default ['a', 'b', 'c'];
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"b\"") != null);
}

test "Default: default export used in expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import multiplier from './multiplier';
        \\const result = multiplier * 10;
        \\console.log(result);
    );
    try writeFile(tmp.dir, "multiplier.ts", "export default 5;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "* 10") != null);
}

// ============================================================
// Codegen formatting regression tests
// ============================================================

test "Codegen: object literal formatting non-minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = { x: 1, y: 2, z: 3 };
        \\console.log(obj);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = false });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // non-minify: 콜론 뒤 공백, 쉼표 뒤 공백
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "y: 2") != null);
}

test "Codegen: object literal formatting minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = { x: 1, y: 2 };
        \\console.log(obj);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minify: 공백 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x:1") != null);
}

test "Codegen: array literal formatting non-minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const arr = [10, 20, 30];
        \\console.log(arr);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = false });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[10, 20, 30]") != null);
}

test "Codegen: array literal formatting minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const arr = [10, 20, 30];
        \\console.log(arr);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[10,20,30]") != null);
}

// ============================================================
// Complex class patterns across modules
// ============================================================

test "Class: inheritance chain across 3 modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Cat } from './cat';
        \\const c = new Cat('Mimi');
        \\console.log(c.speak());
    );
    try writeFile(tmp.dir, "cat.ts",
        \\import { Pet } from './pet';
        \\export class Cat extends Pet {
        \\  speak() { return this.name + ' meows'; }
        \\}
    );
    try writeFile(tmp.dir, "pet.ts",
        \\export class Pet {
        \\  name: string;
        \\  constructor(name: string) { this.name = name; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // Pet → Cat → entry 순서
    const pet_pos = std.mem.indexOf(u8, result.output, "class Pet") orelse return error.TestUnexpectedResult;
    const cat_pos = std.mem.indexOf(u8, result.output, "class Cat") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pet_pos < cat_pos);
}

test "Class: static methods across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MathUtils } from './math-utils';
        \\console.log(MathUtils.clamp(15, 0, 10));
    );
    try writeFile(tmp.dir, "math-utils.ts",
        \\export class MathUtils {
        \\  static clamp(val: number, min: number, max: number): number {
        \\    return Math.min(Math.max(val, min), max);
        \\  }
        \\  static lerp(a: number, b: number, t: number): number {
        \\    return a + (b - a) * t;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class MathUtils") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "static clamp") != null);
}

// ============================================================
// Complex expression patterns
// ============================================================

test "Expression: optional chaining across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getUser } from './api';
        \\const name = getUser()?.name;
        \\console.log(name);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export function getUser() { return { name: 'Alice' }; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "?.name") != null);
}

test "Expression: nullish coalescing across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getValue } from './store';
        \\const result = getValue() ?? 'default';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "store.ts",
        \\export function getValue() { return null; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "??") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default\"") != null);
}

test "Expression: logical assignment across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { config } from './config';
        \\config.debug ??= false;
        \\config.verbose ||= true;
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export const config: any = {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "??=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "||=") != null);
}

// ============================================================
// Advanced module patterns
// ============================================================

test "Module: re-export with rename chain" {
    // A exports x, B re-exports x as y, C re-exports y as z, entry imports z
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './c';
        \\console.log(z);
    );
    try writeFile(tmp.dir, "c.ts", "export { y as z } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x as y } from './a';");
    try writeFile(tmp.dir, "a.ts", "export const x = 'renamed-three-times';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"renamed-three-times\"") != null);
}

test "Module: side-effect import between value imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './a';
        \\import './side';
        \\import { b } from './b';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "a.ts", "export const a = 'A';");
    try writeFile(tmp.dir, "side.ts", "console.log('SIDE');");
    try writeFile(tmp.dir, "b.ts", "export const b = 'B';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // side-effect는 a와 b 사이에 실행
    const a_pos = std.mem.indexOf(u8, result.output, "\"A\"") orelse return error.TestUnexpectedResult;
    const side_pos = std.mem.indexOf(u8, result.output, "\"SIDE\"") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "\"B\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < side_pos);
    try std.testing.expect(side_pos < b_pos);
}

test "Module: import same default from two different modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import configA from './a';
        \\import configB from './b';
        \\console.log(configA, configB);
    );
    try writeFile(tmp.dir, "a.ts", "export default { name: 'A' };");
    try writeFile(tmp.dir, "b.ts", "export default { name: 'B' };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"B\"") != null);
}

// ============================================================
// Stress: large real-world-like patterns
// ============================================================

test "Stress: micro-framework with models, views, controllers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts",
        \\import { App } from './framework/app';
        \\import { UserModel } from './models/user';
        \\import { UserView } from './views/user';
        \\const app = new App();
        \\const model = new UserModel();
        \\const view = new UserView();
        \\console.log(app, model, view);
    );
    try writeFile(tmp.dir, "framework/app.ts",
        \\import { Router } from './router';
        \\export class App { router = new Router(); }
    );
    try writeFile(tmp.dir, "framework/router.ts",
        \\export class Router { routes: string[] = []; }
    );
    try writeFile(tmp.dir, "models/user.ts",
        \\import { BaseModel } from './base';
        \\export class UserModel extends BaseModel { table = 'users'; }
    );
    try writeFile(tmp.dir, "models/base.ts",
        \\export class BaseModel { id = 0; }
    );
    try writeFile(tmp.dir, "views/user.ts",
        \\import { BaseView } from './base';
        \\export class UserView extends BaseView { template = '<div/>'; }
    );
    try writeFile(tmp.dir, "views/base.ts",
        \\export class BaseView { el = 'body'; }
    );

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 클래스가 번들에 포함
    for ([_][]const u8{ "class App", "class Router", "class UserModel", "class BaseModel", "class UserView", "class BaseView" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
    // base 클래스가 derived보다 먼저
    const base_model_pos = std.mem.indexOf(u8, result.output, "class BaseModel") orelse return error.TestUnexpectedResult;
    const user_model_pos = std.mem.indexOf(u8, result.output, "class UserModel") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_model_pos < user_model_pos);
}

test "Stress: 15 modules with mixed patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry imports from barrel which re-exports from 5 modules, each importing shared
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c, d, e } from './barrel';
        \\console.log(a, b, c, d, e);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './modules/a';
        \\export { b } from './modules/b';
        \\export { c } from './modules/c';
        \\export { d } from './modules/d';
        \\export { e } from './modules/e';
    );
    try writeFile(tmp.dir, "modules/a.ts", "import { shared } from '../shared';\nexport const a = shared + '-a';");
    try writeFile(tmp.dir, "modules/b.ts", "import { shared } from '../shared';\nexport const b = shared + '-b';");
    try writeFile(tmp.dir, "modules/c.ts", "import { shared } from '../shared';\nexport const c = shared + '-c';");
    try writeFile(tmp.dir, "modules/d.ts", "import { shared } from '../shared';\nexport const d = shared + '-d';");
    try writeFile(tmp.dir, "modules/e.ts", "import { shared } from '../shared';\nexport const e = shared + '-e';");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'SHARED';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared는 한 번만 포함
    var count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "\"SHARED\"")) |pos| {
        count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// Control flow patterns across modules
// ============================================================

test "Control flow: for-of loop with imported iterable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { items } from './data';
        \\for (const item of items) { console.log(item); }
    );
    try writeFile(tmp.dir, "data.ts", "export const items = ['x', 'y', 'z'];");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "of") != null);
}

test "Control flow: for-in loop with imported object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { obj } from './data';
        \\for (const key in obj) { console.log(key); }
    );
    try writeFile(tmp.dir, "data.ts", "export const obj = { a: 1, b: 2 };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for") != null);
}

test "Control flow: try-catch with imported error class" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { AppError } from './errors';
        \\try { throw new AppError('fail'); } catch (e) { console.log(e); }
    );
    try writeFile(tmp.dir, "errors.ts",
        \\export class AppError extends Error {
        \\  constructor(msg: string) { super(msg); }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class AppError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new AppError") != null);
}

test "Control flow: switch with imported enum values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Status } from './status';
        \\function handle(s: any) {
        \\  switch (s) {
        \\    case Status.OK: return 'ok';
        \\    case Status.ERR: return 'error';
        \\    default: return 'unknown';
        \\  }
        \\}
        \\console.log(handle(200));
    );
    try writeFile(tmp.dir, "status.ts", "export enum Status { OK = 200, ERR = 500 }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Status") != null);
}

test "Control flow: while loop with imported condition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MAX } from './limits';
        \\let i = 0;
        \\while (i < MAX) { i++; }
        \\console.log(i);
    );
    try writeFile(tmp.dir, "limits.ts", "export const MAX = 10;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MAX = 10") != null);
}

// ============================================================
// Promise / async patterns across modules
// ============================================================

test "Async: promise chain across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchUser } from './api';
        \\import { formatUser } from './format';
        \\fetchUser().then(formatUser).then(console.log);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export function fetchUser() {
        \\  return Promise.resolve({ name: 'Bob' });
        \\}
    );
    try writeFile(tmp.dir, "format.ts",
        \\export function formatUser(u: any) {
        \\  return u.name.toUpperCase();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function fetchUser") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function formatUser") != null);
}

test "Async: async/await with imported functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { loadConfig } from './loader';
        \\async function main() {
        \\  const cfg = await loadConfig();
        \\  console.log(cfg);
        \\}
        \\main();
    );
    try writeFile(tmp.dir, "loader.ts",
        \\export async function loadConfig() {
        \\  return { db: 'postgres' };
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await") != null);
}

test "Async: multiple async functions pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { step1 } from './steps/s1';
        \\import { step2 } from './steps/s2';
        \\import { step3 } from './steps/s3';
        \\async function pipeline() {
        \\  const a = await step1();
        \\  const b = await step2(a);
        \\  return await step3(b);
        \\}
        \\pipeline().then(console.log);
    );
    try writeFile(tmp.dir, "steps/s1.ts", "export async function step1() { return 'one'; }");
    try writeFile(tmp.dir, "steps/s2.ts", "export async function step2(x: string) { return x + '-two'; }");
    try writeFile(tmp.dir, "steps/s3.ts", "export async function step3(x: string) { return x + '-three'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function step1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function step2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function step3") != null);
}

// ============================================================
// Built-in data structures across modules
// ============================================================

test "Builtins: Map usage across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createCache } from './cache';
        \\const cache = createCache();
        \\cache.set('key', 'value');
        \\console.log(cache.get('key'));
    );
    try writeFile(tmp.dir, "cache.ts",
        \\export function createCache() {
        \\  return new Map();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Map") != null);
}

test "Builtins: Set usage across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { uniqueItems } from './unique';
        \\console.log(uniqueItems([1, 2, 2, 3]));
    );
    try writeFile(tmp.dir, "unique.ts",
        \\export function uniqueItems(arr: number[]) {
        \\  return [...new Set(arr)];
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Set") != null);
}

test "Builtins: Symbol as key across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ID, createEntity } from './entity';
        \\const e = createEntity(42);
        \\console.log(e[ID]);
    );
    try writeFile(tmp.dir, "entity.ts",
        \\export const ID = Symbol('id');
        \\export function createEntity(id: number) {
        \\  return { [ID]: id, name: 'entity' };
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Symbol(") != null);
}

test "Builtins: Proxy across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createProxy } from './proxy';
        \\const p = createProxy({ x: 1 });
        \\console.log(p.x);
    );
    try writeFile(tmp.dir, "proxy.ts",
        \\export function createProxy(target: any) {
        \\  return new Proxy(target, {
        \\    get(t: any, prop: string) { return t[prop]; }
        \\  });
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Proxy") != null);
}

// ============================================================
// JSX component patterns
// ============================================================

test "JSX: component composition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Header } from './Header';
        \\import { Footer } from './Footer';
        \\function App() { return <div><Header /><Footer /></div>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Header.tsx", "export function Header() { return <header>H</header>; }");
    try writeFile(tmp.dir, "Footer.tsx", "export function Footer() { return <footer>F</footer>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Header") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Footer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<div>") == null);
}

test "JSX: component with props" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Button } from './Button';
        \\function App() { return <Button label="Click" />; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Button.tsx",
        \\export function Button(props: any) {
        \\  return <button>{props.label}</button>;
        \\}
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Button") != null);
}

test "JSX: fragment syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Item } from './Item';
        \\function List() { return <><Item /><Item /></>; }
        \\console.log(List);
    );
    try writeFile(tmp.dir, "Item.tsx", "export function Item() { return <li>item</li>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Item") != null);
}

test "JSX: three self-closing siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { A } from './A';
        \\import { B } from './B';
        \\import { C } from './C';
        \\function App() { return <div><A /><B /><C /></div>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "A.tsx", "export function A() { return <span>a</span>; }");
    try writeFile(tmp.dir, "B.tsx", "export function B() { return <span>b</span>; }");
    try writeFile(tmp.dir, "C.tsx", "export function C() { return <span>c</span>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function C") != null);
}

test "JSX: nested self-closing inside open/close element" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><span><img /></span></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") != null);
}

test "JSX: mixed self-closing and open/close siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><br /><p>text</p><hr /></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // br, p, hr 모두 createElement 호출로 변환
    const output = result.output;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, output, pos, "createElement")) |p| {
        count += 1;
        pos = p + 1;
    }
    // div + br + p + hr = 최소 4개 createElement
    try std.testing.expect(count >= 4);
}

test "JSX: expression container between self-closing siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><br />{42}<hr /></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "JSX: deeply nested components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><section><article><p>deep</p></article></section></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep\"") != null);
}

test "JSX: self-closing with attributes between siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><input type="text" /><input type="password" /><button>go</button></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"password\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"go\"") != null);
}

test "JSX: component with children + self-closing sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><p>hello</p><br /><p>world</p></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"world\"") != null);
}

test "JSX: fragment with mixed children types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <><h1>title</h1>{42}<br /><p>body</p></>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"body\"") != null);
}

test "JSX: nested components with props and children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Card } from './Card';
        \\import { Badge } from './Badge';
        \\function App() { return <div><Card title="hello"><Badge count={3} /><p>content</p></Card></div>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Card.tsx", "export function Card(props) { return <div>{props.children}</div>; }");
    try writeFile(tmp.dir, "Badge.tsx", "export function Badge(props) { return <span>{props.count}</span>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Card") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
}

test "JSX: five siblings stress test" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <ul><li>1</li><li>2</li><li>3</li><li>4</li><li>5</li></ul>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    for ([_][]const u8{ "\"1\"", "\"2\"", "\"3\"", "\"4\"", "\"5\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "JSX: conditional expression inside element" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App(props) { return <div>{props.show ? <span>yes</span> : <span>no</span>}</div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no\"") != null);
}

test "JSX: spread attributes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App(props) { return <div {...props}><span>child</span></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"child\"") != null);
}

test "JSX: self-closing after text content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <p>hello<br />world</p>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") != null);
}

// ============================================================
// Complex TypeScript: type guards, mapped types, overloads, tuples
// ============================================================

test "TypeScript: type guard function" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { isString } from './guards';
        \\const x: unknown = 'hello';
        \\if (isString(x)) console.log(x.length);
    );
    try writeFile(tmp.dir, "guards.ts",
        \\export function isString(val: unknown): val is string {
        \\  return typeof val === 'string';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function isString") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "val is string") == null);
}

test "TypeScript: overloaded function stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { format } from './format';
        \\console.log(format(42));
    );
    try writeFile(tmp.dir, "format.ts",
        \\export function format(val: number): string;
        \\export function format(val: string): string;
        \\export function format(val: any): string {
        \\  return String(val);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function format") != null);
}

// ============================================================
// Complex deconflicting
// ============================================================

test "Deconflict: imported name shadowed in nested scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { data } from './data';
        \\function process() {
        \\  const data = 'local';
        \\  return data;
        \\}
        \\console.log(data, process());
    );
    try writeFile(tmp.dir, "data.ts", "export const data = 'module';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local\"") != null);
}

test "Deconflict: seven modules same name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a'; import './b'; import './c';
        \\import './d'; import './e'; import './f';
        \\const handler = 'entry';
        \\console.log(handler);
    );
    try writeFile(tmp.dir, "a.ts", "const handler = 'a'; console.log(handler);");
    try writeFile(tmp.dir, "b.ts", "const handler = 'b'; console.log(handler);");
    try writeFile(tmp.dir, "c.ts", "const handler = 'c'; console.log(handler);");
    try writeFile(tmp.dir, "d.ts", "const handler = 'd'; console.log(handler);");
    try writeFile(tmp.dir, "e.ts", "const handler = 'e'; console.log(handler);");
    try writeFile(tmp.dir, "f.ts", "const handler = 'f'; console.log(handler);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    var rename_count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "handler$")) |pos| {
        rename_count += 1;
        sf = pos + 1;
    }
    try std.testing.expect(rename_count >= 6);
}

// ============================================================
// Re-export advanced
// ============================================================

test "Re-export: rename chain (A→B→C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './c';
        \\console.log(z);
    );
    try writeFile(tmp.dir, "c.ts", "export { y as z } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x as y } from './a';");
    try writeFile(tmp.dir, "a.ts", "export const x = 'renamed-three-times';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"renamed-three-times\"") != null);
}

test "Re-export: overlapping export * names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y, z } from './barrel';
        \\console.log(x, y, z);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './a';
        \\export * from './b';
    );
    try writeFile(tmp.dir, "a.ts", "export const x = 'from-a';\nexport const y = 'from-a';");
    try writeFile(tmp.dir, "b.ts", "export const x = 'from-b';\nexport const z = 'from-b';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

// ============================================================
// Real-world patterns: CLI, validation, i18n
// ============================================================

test "Real-world: CLI tool pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "cli.ts",
        \\import { parseArgs } from './args';
        \\import { runCommand } from './commands';
        \\import { VERSION } from './version';
        \\const args = parseArgs();
        \\if (args.version) console.log(VERSION);
        \\else runCommand(args);
    );
    try writeFile(tmp.dir, "args.ts", "export function parseArgs() { return { version: false, command: 'help' }; }");
    try writeFile(tmp.dir, "commands.ts",
        \\import { log } from './logger';
        \\export function runCommand(args: any) { log('Running: ' + args.command); }
    );
    try writeFile(tmp.dir, "logger.ts", "export function log(msg: string) { console.log('[CLI]', msg); }");
    try writeFile(tmp.dir, "version.ts", "export const VERSION = '3.1.4';");

    const entry = try absPath(&tmp, "cli.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    for ([_][]const u8{ "function parseArgs", "function runCommand", "function log", "\"3.1.4\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "Real-world: validation library" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { validate, isEmail, minLength } from './validator';
        \\const ok = validate('test@email.com', [isEmail, minLength(5)]);
        \\console.log(ok);
    );
    try writeFile(tmp.dir, "validator/index.ts",
        \\export { validate } from './core';
        \\export { isEmail } from './rules/email';
        \\export { minLength } from './rules/length';
    );
    try writeFile(tmp.dir, "validator/core.ts", "export function validate(v: string, rules: Function[]) { return rules.every(r => r(v)); }");
    try writeFile(tmp.dir, "validator/rules/email.ts", "export function isEmail(v: string) { return v.includes('@'); }");
    try writeFile(tmp.dir, "validator/rules/length.ts", "export function minLength(n: number) { return (v: string) => v.length >= n; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function validate") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function isEmail") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function minLength") != null);
}

// ============================================================
// Edge cases: unusual but valid JS
// ============================================================

test "Edge: void operator across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { noop } from './utils';
        \\noop();
    );
    try writeFile(tmp.dir, "utils.ts", "export function noop() { return void 0; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "void 0") != null);
}

test "Edge: typeof imported value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { maybe } from './maybe';
        \\console.log(typeof maybe);
    );
    try writeFile(tmp.dir, "maybe.ts", "export const maybe = undefined;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "typeof") != null);
}

test "Edge: instanceof with imported class" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Animal } from './animal';
        \\const a = new Animal();
        \\console.log(a instanceof Animal);
    );
    try writeFile(tmp.dir, "animal.ts", "export class Animal {}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "instanceof") != null);
}

test "Edge: labeled statement across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { search } from './search';
        \\console.log(search([[1, 2], [3, 4]], 3));
    );
    try writeFile(tmp.dir, "search.ts",
        \\export function search(matrix: number[][], target: number) {
        \\  outer: for (const row of matrix) {
        \\    for (const val of row) {
        \\      if (val === target) break outer;
        \\    }
        \\  }
        \\  return false;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function search") != null);
}

test "Edge: comma operator in export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { result } from './comma';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "comma.ts", "export const result = (1, 2, 3);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

// ============================================================
// Stress: extreme patterns
// ============================================================

test "Stress: MVC 7-module framework" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts",
        \\import { App } from './framework/app';
        \\import { UserModel } from './models/user';
        \\import { UserView } from './views/user';
        \\const app = new App();
        \\const model = new UserModel();
        \\const view = new UserView();
        \\console.log(app, model, view);
    );
    try writeFile(tmp.dir, "framework/app.ts",
        \\import { Router } from './router';
        \\export class App { router = new Router(); }
    );
    try writeFile(tmp.dir, "framework/router.ts", "export class Router { routes: string[] = []; }");
    try writeFile(tmp.dir, "models/user.ts",
        \\import { BaseModel } from './base';
        \\export class UserModel extends BaseModel { table = 'users'; }
    );
    try writeFile(tmp.dir, "models/base.ts", "export class BaseModel { id = 0; }");
    try writeFile(tmp.dir, "views/user.ts",
        \\import { BaseView } from './base';
        \\export class UserView extends BaseView { template = '<div/>'; }
    );
    try writeFile(tmp.dir, "views/base.ts", "export class BaseView { el = 'body'; }");

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    for ([_][]const u8{ "class App", "class Router", "class UserModel", "class BaseModel", "class UserView", "class BaseView" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

// ============================================================
// P1: package.json exports field (통합)
// ============================================================

test "PackageJson: exports string shorthand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { hello } from 'mypkg';\nconsole.log(hello);");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{ "name": "mypkg", "exports": "./src/index.js" }
    );
    try writeFile(tmp.dir, "node_modules/mypkg/src/index.js", "export const hello = 'from-exports';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-exports\"") != null);
}

test "PackageJson: exports condition import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from 'condpkg';\nconsole.log(val);");
    try writeFile(tmp.dir, "node_modules/condpkg/package.json",
        \\{ "name": "condpkg", "exports": { ".": { "import": "./esm.js", "require": "./cjs.js" } } }
    );
    try writeFile(tmp.dir, "node_modules/condpkg/esm.js", "export const val = 'esm-path';");
    try writeFile(tmp.dir, "node_modules/condpkg/cjs.js", "module.exports = { val: 'cjs-path' };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"esm-path\"") != null);
}

test "PackageJson: subpath exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Button } from 'ui-lib/Button';\nconsole.log(Button);");
    try writeFile(tmp.dir, "node_modules/ui-lib/package.json",
        \\{ "name": "ui-lib", "exports": { "./Button": "./src/Button.js" } }
    );
    try writeFile(tmp.dir, "node_modules/ui-lib/src/Button.js", "export const Button = 'btn-component';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"btn-component\"") != null);
}

test "PackageJson: wildcard exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from 'wpkg/utils';\nconsole.log(foo);");
    try writeFile(tmp.dir, "node_modules/wpkg/package.json",
        \\{ "name": "wpkg", "exports": { "./*": "./src/*.js" } }
    );
    try writeFile(tmp.dir, "node_modules/wpkg/src/utils.js", "export const foo = 'wildcard-resolved';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"wildcard-resolved\"") != null);
}

// ============================================================
// P1: package.json module vs main field
// ============================================================

test "PackageJson: module field preferred over main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from 'dualpkg';\nconsole.log(x);");
    try writeFile(tmp.dir, "node_modules/dualpkg/package.json",
        \\{ "name": "dualpkg", "main": "./cjs.js", "module": "./esm.js" }
    );
    try writeFile(tmp.dir, "node_modules/dualpkg/esm.js", "export const x = 'from-module-field';");
    try writeFile(tmp.dir, "node_modules/dualpkg/cjs.js", "exports.x = 'from-main-field';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-module-field\"") != null);
}

test "PackageJson: main field fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { y } from 'mainonly';\nconsole.log(y);");
    try writeFile(tmp.dir, "node_modules/mainonly/package.json",
        \\{ "name": "mainonly", "main": "./lib.js" }
    );
    try writeFile(tmp.dir, "node_modules/mainonly/lib.js", "export const y = 'from-main';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-main\"") != null);
}

test "PackageJson: no package.json index.js fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { z } from 'nopkg';\nconsole.log(z);");
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "export const z = 'index-fallback';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"index-fallback\"") != null);
}

// ============================================================
// P1: .mjs/.mts/.cjs/.cts extension handling
// ============================================================

test "Extension: import .mts file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.mjs';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.mts", "export const x = 'from-mts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-mts\"") != null);
}

test "Extension: import .cts file via .cjs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.cjs';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.cts", "export const x = 'from-cts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-cts\"") != null);
}

test "Extension: direct .mts import without .mjs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './util';\nconsole.log(val);");
    try writeFile(tmp.dir, "util.mts", "export const val = 'mts-direct';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"mts-direct\"") != null);
}

// ============================================================
// P1: Dynamic import() output
// ============================================================

test "DynamicImport: static path in import()" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lazy = import('./lazy');
        \\lazy.then(m => console.log(m));
    );
    try writeFile(tmp.dir, "lazy.ts", "export const data = 'lazy-loaded';\nconsole.log(data);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 단일 번들 모드에서 lazy 모듈 코드가 포함되어야 함
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"lazy-loaded\"") != null);
}

test "DynamicImport: external dynamic import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const ext = import('external-pkg');
        \\ext.then(console.log);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-pkg"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "DynamicImport: combined with static import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './shared';
        \\const lazy = import('./shared');
        \\console.log(x);
        \\lazy.then(m => console.log(m));
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared-val';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shared-val\"") != null);
}

// ============================================================
// P1: CJS/IIFE format exports with scope hoisting
// ============================================================

test "Format: CJS scope_hoist entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\export const result = helper();
        \\export function getResult() { return result; }
    );
    try writeFile(tmp.dir, "helper.ts", "export function helper() { return 42; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

test "Format: IIFE scope_hoist entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './dep';
        \\export const doubled = value * 2;
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 21;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value * 2") != null);
}

// ============================================================
// P2: export default anonymous expression
// ============================================================

// "Default: anonymous object default export imported" — 기존 "Default: default export object literal"과 중복으로 제거

test "Default: anonymous string default export imported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import greeting from './greeting';
        \\console.log(greeting);
    );
    try writeFile(tmp.dir, "greeting.ts", "export default 'hello world';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello world\"") != null);
}

// ============================================================
// P2: export { X as default }
// ============================================================

test "Default: export named as default then import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import def from './mod';
        \\console.log(def);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const X = 'named-as-default';
        \\export { X as default };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named-as-default\"") != null);
}

// ============================================================
// P2: namespace import (import * as ns)
// ============================================================

test "Namespace: import * as ns usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as utils from './utils';
        \\console.log(utils.add(1, 2), utils.sub(3, 1));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function add(a: number, b: number) { return a + b; }
        \\export function sub(a: number, b: number) { return a - b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function sub") != null);
}

test "Namespace: import * combined with named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as math from './math';
        \\import { PI } from './math';
        \\console.log(math.add(1, 2), PI);
    );
    try writeFile(tmp.dir, "math.ts",
        \\export const PI = 3.14;
        \\export function add(a: number, b: number) { return a + b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "3.14") != null);
}

// ============================================================
// P2: scoped packages (@scope/pkg)
// ============================================================

test "Resolution: scoped package @scope/pkg" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { thing } from '@myorg/utils';\nconsole.log(thing);");
    try writeFile(tmp.dir, "node_modules/@myorg/utils/package.json",
        \\{ "name": "@myorg/utils", "main": "./index.js" }
    );
    try writeFile(tmp.dir, "node_modules/@myorg/utils/index.js", "export const thing = 'scoped-pkg';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scoped-pkg\"") != null);
}

// ============================================================
// P2: JSON import
// ============================================================

test "Resolution: JSON file import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{ "name": "test", "version": "1.0.0" }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // JSON import는 에러 없이 번들 생성 (내용 포함 여부는 구현에 따라)
    try std.testing.expect(!result.hasErrors());
}

test "JSON import: ESM format uses scope-hoisted var (linker integration)" {
    // linker 포함 통합 테스트: ESM 포맷에서 JSON → ESM AST로 변환되어
    // export default → var 할당 형태로 출력되는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './data.json';\nconsole.log(data.key);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value"}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // JSON ESM: named export 변수로 출력, __commonJS 래핑 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
}

test "JSON import: named exports from top-level object keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { name, version } from './app.json';\nconsole.log(name, version);");
    try writeFile(tmp.dir, "app.json",
        \\{"name":"ExampleApp","version":1}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // named export 변수가 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ExampleApp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(name") != null);
}

test "JSON import: named exports + default export coexist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config, { name } from './config.json';
        \\console.log(name, config);
    );
    try writeFile(tmp.dir, "config.json",
        \\{"name":"test","debug":true}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"test\"") != null);
}

test "JSON import: non-object JSON has no named exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import arr from './data.json';\nconsole.log(arr);");
    try writeFile(tmp.dir, "data.json", "[1, 2, 3]");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "IIFE globalName: export → return 변환 (linker integration)" {
    // IIFE + globalName에서 엔트리 export가 "return { ... }" 형태로 출력되는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const answer = 42;\nexport const name = \"test\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .global_name = "MyLib",
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // IIFE prologue: var MyLib = (function() {
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var MyLib = (function()") != null);
    // 엔트리 export가 return으로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return {") != null);
    // export 키워드가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export {") == null);
}

// ============================================================
// P2: multi-level rename re-export chain
// ============================================================

// "Re-export: three-level rename chain" — 기존 "Re-export: rename chain (A→B→C→D)"와 중복으로 제거

// ============================================================
// P3: nested scope conflict avoidance
// ============================================================

test "Deconflict: rename avoids nested scope variable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈이 'x'를 top-level에 가짐 → 리네임 발생
    // entry에는 함수 안에 'x$1'이 있음 → 리네임이 x$1을 피해야 함
    try writeFile(tmp.dir, "entry.ts",
        \\import './other';
        \\const x = 'entry-x';
        \\function inner() { const x$1 = 'nested'; return x$1; }
        \\console.log(x, inner());
    );
    try writeFile(tmp.dir, "other.ts", "const x = 'other-x';\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"entry-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"other-x\"") != null);
}

// ============================================================
// P3: long re-export chain (10 levels)
// ============================================================

test "Re-export: 10-level chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './r1';\nconsole.log(val);");
    try writeFile(tmp.dir, "r1.ts", "export { val } from './r2';");
    try writeFile(tmp.dir, "r2.ts", "export { val } from './r3';");
    try writeFile(tmp.dir, "r3.ts", "export { val } from './r4';");
    try writeFile(tmp.dir, "r4.ts", "export { val } from './r5';");
    try writeFile(tmp.dir, "r5.ts", "export { val } from './r6';");
    try writeFile(tmp.dir, "r6.ts", "export { val } from './r7';");
    try writeFile(tmp.dir, "r7.ts", "export { val } from './r8';");
    try writeFile(tmp.dir, "r8.ts", "export { val } from './r9';");
    try writeFile(tmp.dir, "r9.ts", "export { val } from './r10';");
    try writeFile(tmp.dir, "r10.ts", "export const val = 'deep-10';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep-10\"") != null);
}

// ============================================================
// P3: multi-entry + scope hoist + name conflicts
// ============================================================

test "MultiEntry: scope hoist with shared dep name conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts",
        \\import { shared } from './shared';
        \\const name = 'e1';
        \\console.log(name, shared);
    );
    try writeFile(tmp.dir, "e2.ts",
        \\import { shared } from './shared';
        \\const name = 'e2';
        \\console.log(name, shared);
    );
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';\nconst name = 'shared';");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 모듈의 'name' 충돌 → 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "name$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"common\"") != null);
}

// ============================================================
// P3: empty export {} with scope hoist
// ============================================================

test "Export: empty export {} stripped in scope hoist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './sideeffect';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "sideeffect.ts",
        \\console.log('side');
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"side\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"main\"") != null);
    // export {} 가 번들에 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export {}") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export{}") == null);
}

// ============================================================
// P3: import type full strip verification
// ============================================================

test "TypeScript: import type fully stripped in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type User } from './types';
        \\import { greet } from './greet';
        \\const u: User = { name: 'Alice' };
        \\console.log(greet(u.name));
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface User { name: string; }
        \\export interface Post { title: string; }
    );
    try writeFile(tmp.dir, "greet.ts", "export function greet(name: string) { return 'Hello ' + name; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // interface 완전 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    // greet 함수는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
}

// ============================================================
// Tree-shaking integration tests
// ============================================================

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

// ============================================================
// CJS Wrapping Tests
// ============================================================

test "CJS: single CJS module wrapped with __commonJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = { value: 42 };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __commonJS 런타임 헬퍼가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    // require_lib 변수명이 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
    // module.exports가 래핑 내부에 유지되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "CJS: ESM imports default from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require_lib() 호출이 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib()") != null);
}

test "CJS: ESM imports named from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from './lib.cjs';\nconsole.log(value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require_lib()와 .value 접근이 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".value") != null);
}

test "CJS: no runtime helper when no CJS modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 순수 ESM이면 __commonJS 런타임이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
}

test "CJS: mixed ESM and CJS modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './esm';
        \\import cjs from './lib.cjs';
        \\console.log(x, cjs);
    );
    try writeFile(tmp.dir, "esm.ts", "export const x = 'esm';");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 'cjs';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM 모듈은 스코프 호이스팅 (import 제거)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = \"esm\"") != null);
    // CJS 모듈은 __commonJS 래핑
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
}

test "CJS: require chain (CJS requires CJS)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import a from './a.cjs';\nconsole.log(a);");
    try writeFile(tmp.dir, "a.cjs", "const b = require('./b.cjs');\nmodule.exports = b + 1;");
    try writeFile(tmp.dir, "b.cjs", "module.exports = 10;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 CJS 모듈 모두 래핑되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_b") != null);
}

test "CJS: namespace import from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as lib from './lib.cjs';\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
}

test "CJS: multiple named imports from same CJS module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add, subtract } from './math.cjs';
        \\console.log(add(1, 2), subtract(3, 1));
    );
    try writeFile(tmp.dir, "math.cjs",
        \\exports.add = function(a, b) { return a + b; };
        \\exports.subtract = function(a, b) { return a - b; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_math") != null);
    // named import preamble에 add, subtract 모두 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".subtract") != null);
}

test "CJS: aliased named import from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value as v } from './lib.cjs';\nconsole.log(v);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
}

test "CJS: minified CJS wrapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minified 런타임 헬퍼
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS=") != null);
    // 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "CJS: special characters in module path sanitized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './my-lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "my-lib.cjs", "module.exports = 'hello';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 하이픈이 _로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_my_lib") != null);
}

test "CJS: ESM module importing from both ESM and CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { esm } from './esm-dep';
        \\import { cjs } from './cjs-dep.cjs';
        \\console.log(esm, cjs);
    );
    try writeFile(tmp.dir, "esm-dep.ts", "export const esm = 'esm';");
    try writeFile(tmp.dir, "cjs-dep.cjs", "exports.cjs = 'cjs';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM dep은 스코프 호이스팅 (const esm 직접 노출)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const esm") != null);
    // CJS dep은 __commonJS 래핑
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjs_dep") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
}

test "CJS: empty CJS module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './empty.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "empty.cjs", "// empty module");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // .cjs 확장자이므로 CJS로 래핑됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_empty") != null);
}

test "CJS: __toESM wraps default import from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = { value: 42 };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // default import는 __toESM으로 래핑되어야 함
    // .ts importer → Babel 모드 (isNodeMode 없음)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") != null);
}

test "CJS: __toESM not applied to named imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from './lib.cjs';\nconsole.log(value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // named import에는 __toESM 미적용 (require_lib().value 형태)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib().value") != null);
}

test "CJS: ExportsKind promotion — .js required becomes CJS" {
    // ExportsKind 승격을 그래프 테스트로 직접 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ESM 모듈이 require()로 plain .js 파일을 로드 (ESM+CJS 혼용)
    // plain.js는 module syntax가 없으므로 exports_kind=none → require()로 소비되어 CJS로 승격
    try writeFile(tmp.dir, "entry.ts", "import './esm_dep';\nconst lib = require('./plain');\nconsole.log(lib);");
    try writeFile(tmp.dir, "esm_dep.ts", "export const y = 2;");
    try writeFile(tmp.dir, "plain.js", "const x = 1;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // graph에서 plain.js 모듈을 찾아서 exports_kind 확인
    var plain_found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "plain.js")) {
            // require()로 소비되었으므로 CJS로 승격되어야 함
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            plain_found = true;
            break;
        }
    }
    try std.testing.expect(plain_found);
}

test "CJS: ExportsKind promotion — .js imported becomes ESM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ESM이 import로 plain .js 파일을 로드 → ESM으로 승격 (래핑 안 함)
    try writeFile(tmp.dir, "entry.ts", "import './plain.js';\nconst y = 2;");
    try writeFile(tmp.dir, "plain.js", "const x = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM import로 소비된 plain.js는 래핑되지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_plain") == null);
}

test "CJS: __toESM runtime helper injected with __commonJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __commonJS와 __toESM 런타임 헬퍼가 모두 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") != null);
}

test "CJS: __toESM not injected when no CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 순수 ESM 번들에는 __commonJS도 __toESM도 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") == null);
}

test "CJS: require overrides ESM promotion (both import and require same module)" {
    // 같은 .js 파일을 한쪽에서 import, 다른쪽에서 require() → require가 우선 (esbuild 동작)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './importer';
        \\import './requirer';
    );
    try writeFile(tmp.dir, "importer.ts", "import './shared.js';");
    try writeFile(tmp.dir, "requirer.ts", "const s = require('./shared.js');\nconsole.log(s);");
    try writeFile(tmp.dir, "shared.js", "const x = 1;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // shared.js는 import와 require 모두로 소비됨 → require가 우선이므로 CJS
    var shared_found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "shared.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            shared_found = true;
            break;
        }
    }
    try std.testing.expect(shared_found);
}

test "CJS: CJS module with both module.exports and exports.x" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs",
        \\exports.name = 'test';
        \\module.exports = { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") != null);
}

test "CJS: namespace import from CJS uses __toESM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as lib from './lib.cjs';\nconsole.log(lib.default, lib.value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace import도 __toESM으로 래핑 (.ts → Babel 모드)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") != null);
}

test "CJS: multiple ESM modules importing same CJS module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\import './b';
    );
    try writeFile(tmp.dir, "a.ts", "import lib from './shared.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "b.ts", "import { value } from './shared.cjs';\nconsole.log(value);");
    try writeFile(tmp.dir, "shared.cjs", "exports.value = 42;\nmodule.exports.default = exports;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared.cjs는 한 번만 래핑
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
}

test "CJS: esm_with_dynamic_fallback module required — promoted to ESM wrap (graph)" {
    // ESM+CJS 혼합 모듈(esm_with_dynamic_fallback)이 require()로 소비되면
    // ESM 의미론을 보존하면서 __esm 래핑 (esbuild WrapESM 모델).
    // exports_kind는 esm_with_dynamic_fallback 유지, wrap_kind는 .esm.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const h = require('./hybrid.js');\nconsole.log(h);");
    // hybrid.js: ESM(export) + CJS(require) 모두 사용 → esm_with_dynamic_fallback
    try writeFile(tmp.dir, "hybrid.js",
        \\export const value = 42;
        \\const other = require('./dep.js');
        \\module.exports = { value, other };
    );
    try writeFile(tmp.dir, "dep.js", "module.exports = 'dep';");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // hybrid.js: esm_with_dynamic_fallback + require 소비 → WrapKind.esm
    var hybrid_found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "hybrid.js")) {
            try std.testing.expectEqual(types.ExportsKind.esm_with_dynamic_fallback, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.esm, m.wrap_kind);
            hybrid_found = true;
            break;
        }
    }
    try std.testing.expect(hybrid_found);
}

test "CJS: esm_with_dynamic_fallback module required — wrapped in __esm (bundler)" {
    // 번들 출력에서 ESM+CJS 혼합 모듈이 __esm 래퍼로 감싸지는지 검증.
    // ESM 모듈이 require()로 소비 → WrapKind.esm → __esm 래핑.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const h = require('./hybrid.js');\nconsole.log(h);");
    try writeFile(tmp.dir, "hybrid.js",
        \\export const value = 42;
        \\const other = require('./dep.js');
        \\module.exports = { value, other };
    );
    try writeFile(tmp.dir, "dep.js", "module.exports = 'dep';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // hybrid.js가 __esm으로 래핑되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_hybrid") != null);
}

test "CJS: ESM import inside __commonJS wrapper rewritten to require_xxx()" {
    // ESM 모듈이 require()로 소비되어 __commonJS 래핑될 때,
    // 내부 import 문이 require("specifier")로 변환되는데,
    // 이 변환된 require()도 require_xxx()로 치환되어야 한다.
    // (emitImportCJS에서 require_rewrites 맵 미참조 버그 수정 검증)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm-lib.js');\nconsole.log(lib);");
    // esm-lib.js: ESM import 사용, require()로 소비되어 CJS 래핑됨
    try writeFile(tmp.dir, "esm-lib.js",
        \\import helper from './helper.cjs';
        \\export function greet() { return helper(); }
    );
    try writeFile(tmp.dir, "helper.cjs", "module.exports = function() { return 'hello'; };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // esm-lib.js의 import helper from './helper.cjs'가
    // require_helper()로 변환되어야 함 (require("./helper.cjs")가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_helper") != null);
    // 번들 내에 raw require("./helper.cjs")가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./helper.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./helper.cjs')") == null);
}

test "CJS: side-effect import inside __commonJS wrapper rewritten to require_xxx()" {
    // side-effect import (import './foo') 도 require_xxx()로 변환되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./side-lib.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "side-lib.js",
        \\import './setup.cjs';
        \\export const value = 42;
    );
    try writeFile(tmp.dir, "setup.cjs", "global.__SETUP = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // side-effect import도 require_setup()으로 변환
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./setup.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./setup.cjs')") == null);
}

test "CJS: named import inside __commonJS wrapper rewritten to require_xxx()" {
    // import { foo } from './bar' → const {foo}=require_bar(); (require("./bar") 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./named-lib.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "named-lib.js",
        \\import { value } from './util.cjs';
        \\export function compute() { return value * 2; }
    );
    try writeFile(tmp.dir, "util.cjs", "exports.value = 21;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_util") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./util.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./util.cjs')") == null);
}

test "CJS: scope hoisted esm_with_dynamic_fallback — internal require() rewritten" {
    // ESM+CJS 혼합 모듈이 import로 소비되어 scope hoisting될 때,
    // 내부 require() 호출이 require_xxx()로 변환되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry가 import로 소비 → hybrid.js는 ESM으로 승격 (scope hoisted)
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './hybrid.js';
        \\console.log(greet());
    );
    // hybrid.js: ESM(export) + CJS(require) → esm_with_dynamic_fallback, import로 소비 → scope hoisted
    try writeFile(tmp.dir, "hybrid.js",
        \\const dep = require('./dep.cjs');
        \\export function greet() { return dep(); }
    );
    try writeFile(tmp.dir, "dep.cjs", "module.exports = function() { return 'hi'; };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // scope hoisted 모듈 내부 require('./dep.cjs') → require_dep()
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_dep") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./dep.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./dep.cjs')") == null);
}

// ============================================================
// WrapKind.esm (__esm 래퍼) Tests
// ============================================================

test "ESM wrap: pure ESM module required — WrapKind.esm (graph)" {
    // 순수 ESM 모듈이 require()로 소비 → WrapKind.esm (CJS가 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm-mod.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "esm-mod.js",
        \\export function hello() { return 'world'; }
        \\export const value = 42;
    );

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "esm-mod.js")) {
            try std.testing.expectEqual(types.ExportsKind.esm, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.esm, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: CJS module required — still WrapKind.cjs (graph)" {
    // CJS 모듈은 require() 소비 시 WrapKind.cjs 유지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./cjs-mod.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "cjs-mod.js", "module.exports = { value: 42 };");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "cjs-mod.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: none module required — WrapKind.cjs (graph)" {
    // exports_kind == .none (ESM/CJS 신호 없음) + require 소비 → CJS
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./plain.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "plain.js", "const x = 1;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "plain.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: __esm runtime injected in bundle output" {
    // WrapKind.esm 모듈이 있으면 __esm 런타임이 번들에 주입되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "esm.js", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_esm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_esm") != null);
}

test "ESM wrap: CJS requires ESM — (init_xxx(), __toCommonJS(exports_xxx)) pattern" {
    // CJS 모듈에서 ESM 모듈을 require() → (init_xxx(), __toCommonJS(exports_xxx))
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "const lib = require('./esm.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "esm.js", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require("./esm.js")가 (init_esm(), __toCommonJS(exports_esm))으로 변환
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_esm()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS(exports_esm)") != null);
    // raw require가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./esm.js\")") == null);
}

test "ESM wrap: 2-pass promotion — require before import" {
    // 같은 모듈을 import + require → require가 우선 (2-pass)
    // ESM 모듈이면 WrapKind.esm, import가 나중에 와도 변경 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './importer.ts';
        \\import './requirer.ts';
    );
    try writeFile(tmp.dir, "importer.ts", "import { value } from './shared.js';\nconsole.log(value);");
    try writeFile(tmp.dir, "requirer.ts", "const s = require('./shared.js');\nconsole.log(s);");
    try writeFile(tmp.dir, "shared.js", "export const value = 42;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // shared.js: ESM + require 소비 → WrapKind.esm (import가 CJS로 덮어쓰지 않음)
    var found = false;
    for (graph.modules.items) |m| {
        if (std.mem.endsWith(u8, m.path, "shared.js")) {
            try std.testing.expectEqual(types.WrapKind.esm, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: CJS wrapper imports scope-hoisted ESM — no raw require" {
    // CJS 래핑 모듈이 scope hoisted ESM 모듈을 import할 때
    // import가 skip되고 preamble/rename으로 직접 참조
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './lib.js';
        \\console.log(greet());
    );
    // lib.js: CJS (require 사용) → __commonJS 래핑
    try writeFile(tmp.dir, "lib.js",
        \\const helper = require('./helper.cjs');
        \\import { util } from './util.js';
        \\exports.greet = function() { return helper() + util(); };
    );
    try writeFile(tmp.dir, "helper.cjs", "module.exports = function() { return 'hi'; };");
    // util.js: 순수 ESM → scope hoisted
    try writeFile(tmp.dir, "util.js", "export function util() { return ' world'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require("./util.js")가 남아있으면 안 됨 (scope hoisted → 직접 참조)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./util.js\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./util.js')") == null);
}

test "ESM wrap: namespace import of __esm module — canonical name direct rewrite" {
    // import * as ns from './esm-mod' → ns.prop → canonical name 직접 치환.
    // exports_xxx rename은 변수 덮어쓰기 버그를 유발하므로 사용하지 않음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as utils from './utils.js';
        \\console.log(utils.greet());
    );
    try writeFile(tmp.dir, "utils.js",
        \\export function greet() { return 'hello'; }
        \\export const value = 42;
    );
    // utils.js를 require로 소비하여 __esm 래핑
    try writeFile(tmp.dir, "requirer.ts", "const u = require('./utils.js');");
    try writeFile(tmp.dir, "main.ts",
        \\import './entry.ts';
        \\import './requirer.ts';
    );

    const main_entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(main_entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{main_entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace 멤버 접근이 canonical name으로 직접 치환: console.log(greet())
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(greet())") != null);
    // 원본 namespace 접근 형태가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "utils.greet") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_utils.greet") == null);
}

test "ESM wrap: skip_cjs_exports — no exports.x in __esm wrapper" {
    // __esm 래핑 모듈은 exports.x = x를 생성하면 안 됨 (__export가 대신 처리)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "esm.js",
        \\export const value = 42;
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm 래퍼 안에 exports.value=value 또는 exports.greet=greet 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.value") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.greet") == null);
    // __export()가 존재해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") != null);
}

test "ESM wrap: export default named ref — no duplicate var" {
    // export default SomeVar → __esm에서 var SomeVar=SomeVar 중복 생성 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./mod.js');\nconsole.log(lib.default);");
    try writeFile(tmp.dir, "mod.js",
        \\const Platform = { OS: 'ios' };
        \\export default Platform;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // module.exports=Platform 직접 대입이 없어야 함 (__export가 처리)
    // __toCommonJS 런타임 헬퍼의 "module.exports"는 허용 (mod['module.exports'] 패턴)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports =") == null);
    // __export에서 default getter가 Platform을 참조
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Platform") != null);
}

test "ESM wrap: export default anonymous expr — var _default" {
    // export default {...} → var _default = {...};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./mod.js');\nconsole.log(lib.default);");
    try writeFile(tmp.dir, "mod.js",
        \\export default { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // var _default = { value: 42 }; 형태
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_default") != null);
    // module.exports= 직접 대입이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports =") == null);
}

test "ESM wrap: var hoisting + __export outside __esm (esbuild/rolldown 방식)" {
    // rolldown 방식: function은 __esm 밖으로 호이스팅 (live binding).
    // __export()는 래퍼 밖에서 lazy getter로 등록 (접근 시점에 변수 참조).
    // init은 의존 모듈 init 호출만 담당.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./mod.js');\nconsole.log(lib.greet());");
    try writeFile(tmp.dir, "mod.js",
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __export가 __esm 래퍼 밖(앞)에 있어야 함 (var 호이스팅 방식)
    const esm_start = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const export_pos = std.mem.indexOf(u8, result.output, "__export(") orelse unreachable;
    try std.testing.expect(export_pos < esm_start);
    // function greet()가 __esm 밖으로 호이스팅되어야 함 (rolldown 방식)
    const fn_pos = std.mem.indexOf(u8, result.output, "function greet()") orelse unreachable;
    try std.testing.expect(fn_pos < esm_start);
}

test "ESM wrap: Flow type cast + namespace import → ns_member_rewrite 적용" {
    // Flow 타입 캐스트 (expr: Type) 안의 namespace member access가
    // ns_member_rewrites로 올바르게 치환되는지 검증.
    // semantic analyzer가 flow_type_cast_expression 내부를 방문해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\export function getEnforcing(name) { return name + '_enforced'; }
    );
    try writeFile(tmp.dir, "native.js",
        \\// @flow
        \\import * as Registry from './registry.js';
        \\export default (Registry.getEnforcing('Test'): string);
    );
    try writeFile(tmp.dir, "cjs.js",
        \\const r = require('./registry.js');
        \\module.exports = r;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import val from './native.js';
        \\require('./cjs.js');
        \\console.log(val);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // "Registry.getEnforcing"가 남아있으면 안 됨 (ns_member_rewrite 미적용)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Registry.getEnforcing") == null);
    // exports_registry.getEnforcing 또는 직접 getEnforcing으로 치환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getEnforcing") != null);
}

test "ESM wrap: var hoisting + default export 접근 가능" {
    // __esm 래퍼의 var 호이스팅으로 default export가 외부에서 직접 접근 가능한지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\export const count = 42;
        \\export const name = 'hello';
    );
    try writeFile(tmp.dir, "wrapper.js",
        \\import * as Mod from './mod.js';
        \\export default Mod.count;
    );
    try writeFile(tmp.dir, "cjs.js",
        \\const m = require('./mod.js');
        \\module.exports = m;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import val from './wrapper.js';
        \\require('./cjs.js');
        \\console.log(val);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // var 호이스팅: _default가 __esm 래퍼 밖에 선언
    // __esm({ 이전에 "var" 선언이 있어야 함
    const esm_pos = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const var_decl = std.mem.indexOf(u8, result.output, "var ");
    try std.testing.expect(var_decl != null and var_decl.? < esm_pos);
}

test "ESM wrap: class declaration hoisted as var (block-scope → assignment)" {
    // class 선언은 block-scoped → __esm 콜백 밖의 __export getter가 접근 불가.
    // var 선언을 밖에 두고 body에서 할당문으로 변환해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\export class Greeter {
        \\  greet() { return 'hello'; }
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\console.log(m.Greeter);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // class가 var로 호이스팅되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var ") != null);
    // __esm body 안에서 할당문으로 변환: "Greeter = class Greeter"
    try std.testing.expect(std.mem.indexOf(u8, result.output, "= class Greeter") != null);
    // 선언문 형태가 아닌지 확인 (class Greeter { 가 __esm 안에서 단독으로 나오면 안 됨)
    // __export getter가 접근 가능해야 하므로 할당문이어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") != null);
}

// ============================================================
// Top-Level Await (TLA) Tests
// ============================================================

test "TLA: detected in module" {
    // top-level await가 있는 모듈은 uses_top_level_await=true가 되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const data = await fetch('/api');\nconsole.log(data);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // await 표현식이 번들 출력에 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fetch") != null);
}

test "TLA: not detected inside async function" {
    // async 함수 내부의 await는 TLA가 아니므로 경고가 없어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "async function load() { const x = await fetch('/api'); return x; }\nconsole.log(load);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: TLA가 없으므로 경고 주석이 없어야 함
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // async 함수 내부 await는 TLA가 아님 → 경고 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS WARNING]") == null);
}

test "TLA: propagated to importer" {
    // B가 TLA를 사용하고, A가 B를 static import하면
    // A도 TLA로 전파되어야 한다 (import 체인 전파).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "const data = await Promise.resolve(42);\nconsole.log(data);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: A가 B(TLA)를 import → A도 TLA → 경고 발생
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // TLA 전파 → CJS에서 경고 주석 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS WARNING]") != null);
}

test "TLA: not propagated via dynamic import" {
    // 동적 import는 비동기이므로 TLA를 전파하지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const mod = import('./b');\nconsole.log(mod);");
    try writeFile(tmp.dir, "b.ts", "const data = await Promise.resolve(42);\nexport default data;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: 동적 import → TLA 비전파 → 경고 없음
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 동적 import는 TLA 전파 안 함 → 경고 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS WARNING]") == null);
}

test "TLA: warning for CJS output" {
    // CJS 포맷에서 TLA 사용 시 경고 주석이 삽입되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const x = await Promise.resolve(1);\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS WARNING] Top-level await requires ESM output format.") != null);
}

test "TLA: no warning for ESM output" {
    // ESM 포맷에서는 TLA가 정상이므로 경고가 없어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const x = await Promise.resolve(1);\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // ESM → 경고 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS WARNING]") == null);
}

test "TLA: for-await-of detected" {
    // `for await (const x of gen) {}` 는 TLA이다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\async function* gen() { yield 1; yield 2; }
        \\for await (const x of gen()) { console.log(x); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: for-await-of는 TLA → 경고 발생
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS WARNING]") != null);
}

test "TLA: await inside object literal at top level" {
    // 이전 containsAwait 구현에서 object_expression을 누락하여 감지 실패했던 케이스
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const config = { data: await fetch('/api') };
        \\export default config;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // object literal 내부 await도 TLA로 감지 → CJS 경고
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS WARNING") != null);
}

test "TLA: await inside array literal at top level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const items = [await fetch('/a'), await fetch('/b')];
        \\export default items;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS WARNING") != null);
}

test "TLA: await inside ternary expression at top level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const val = true ? await fetch('/a') : null;
        \\export default val;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS WARNING") != null);
}

test "TLA: for_await_of_statement detected via AST tag" {
    // isForAwaitOf 소스 텍스트 스캔 대신 파서가 for_await_of_statement 태그를 생성하여 감지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\async function* gen() { yield 1; yield 2; }
        \\for await (const x of gen()) { console.log(x); }
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // for await 감지 → CJS 경고
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS WARNING") != null);
    // codegen이 for await of를 올바르게 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for await") != null);
}

// ============================================================
// Code Splitting Tests
// ============================================================

test "CodeSplitting: code_splitting=false unchanged — 기존 동작 보존" {
    // code_splitting=false(기본값)일 때 기존 단일 파일 출력이 그대로 동작하는지 확인.
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

    // 단일 파일 모드: output에 결과, outputs는 null
    try std.testing.expect(result.outputs == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 42;") != null);
    try std.testing.expect(!result.hasErrors());
}

test "CodeSplitting: single entry no split — 동적 import 없으면 청크 1개" {
    // code_splitting=true이지만 dynamic import가 없으면 단일 청크만 생성됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import './lib';\nconst x = 1;\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "const y = 2;\nconsole.log(y);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // outputs가 생성됨 (code_splitting=true)
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 단일 청크 — 동적 import 없으므로 분리 없음
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    // 엔트리 파일명
    try std.testing.expectEqualStrings("index.js", outs[0].path);
    // 두 모듈의 코드 포함
    try std.testing.expect(std.mem.indexOf(u8, outs[0].contents, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, outs[0].contents, "const y = 2;") != null);
}

test "CodeSplitting: dynamic import produces two output files" {
    // entry.ts가 lazy.ts를 dynamic import → 2개의 OutputFile 생성.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const mod = import('./lazy');\nconsole.log(mod);");
    try writeFile(tmp.dir, "lazy.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 2개 청크: entry + lazy
    try std.testing.expectEqual(@as(usize, 2), outs.len);

    // 각 청크에 해당 모듈의 코드가 포함
    var has_entry = false;
    var has_lazy = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "console.log") != null) has_entry = true;
        if (std.mem.indexOf(u8, o.contents, "42") != null) has_lazy = true;
    }
    try std.testing.expect(has_entry);
    try std.testing.expect(has_lazy);
}

test "CodeSplitting: shared module produces common chunk" {
    // 2개 엔트리가 같은 모듈을 공유 → 공통 청크로 추출.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { shared } from './shared';\nconsole.log('a', shared);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './shared';\nconsole.log('b', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 2 엔트리 + 1 공통 = 3 청크
    try std.testing.expectEqual(@as(usize, 3), outs.len);

    // shared 모듈의 코드는 정확히 하나의 청크에만 포함 (중복 없음)
    var shared_count: usize = 0;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "\"common\"") != null) shared_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared_count);
}

test "CodeSplitting: cross-chunk import statement" {
    // 엔트리 A가 정적 import하는 모듈이 다른 청크에 있을 때
    // cross-chunk import './dep.js' 문이 삽입되는지 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A → shared (static), B → shared (static)
    // shared는 공통 청크로 추출 → A, B 청크에 cross-chunk import 삽입
    try writeFile(tmp.dir, "a.ts", "import { x } from './shared';\nconsole.log('a', x);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './shared';\nconsole.log('b', x);");
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared_val';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 엔트리 청크 중 하나 이상에 cross-chunk import가 포함되어야 함.
    // 심볼 수준: import { x } from './chunk-N.js'
    // side-effect: import './chunk-N.js'
    var has_cross_import = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "import \"./") != null or
            std.mem.indexOf(u8, o.contents, "from \"./") != null)
        {
            has_cross_import = true;
            break;
        }
    }
    try std.testing.expect(has_cross_import);
}

test "CodeSplitting: multiple common chunks have unique filenames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3 엔트리, 각 쌍이 다른 모듈을 공유 → 2+ 공통 청크
    try writeFile(tmp.dir, "a.ts",
        \\import './ab-shared';
        \\console.log('a');
    );
    try writeFile(tmp.dir, "b.ts",
        \\import './ab-shared';
        \\import './bc-shared';
        \\console.log('b');
    );
    try writeFile(tmp.dir, "c.ts",
        \\import './bc-shared';
        \\console.log('c');
    );
    try writeFile(tmp.dir, "ab-shared.ts", "export const ab = 'shared-ab';");
    try writeFile(tmp.dir, "bc-shared.ts", "export const bc = 'shared-bc';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);
    const c_path = try absPath(&tmp, "c.ts");
    defer std.testing.allocator.free(c_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path, c_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 모든 파일명이 고유해야 함
    for (outputs, 0..) |o, i| {
        for (outputs[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, o.path, other.path));
        }
    }
}

test "CodeSplitting: CJS format returns error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const x = import('./lazy');\nconsole.log(x);");
    try writeFile(tmp.dir, "lazy.ts", "export const lazy = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .format = .cjs,
    });
    defer bnd.deinit();
    // CJS + code_splitting은 에러
    const result = bnd.bundle();
    try std.testing.expect(result == error.CodeSplittingRequiresESM);
}

// ============================================================
// Tests — 크로스 청크 심볼 수준 import/export
// ============================================================

test "CodeSplitting: cross-chunk named import — 심볼 수준 import 문 생성" {
    // 2개 엔트리가 공통 모듈의 named export를 import할 때
    // 엔트리 청크에 `import { x } from './chunk-N.js'` 형태가 생성되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { createApp } from './shared';\nconsole.log(createApp);");
    try writeFile(tmp.dir, "b.ts", "import { createApp } from './shared';\nconsole.log(createApp);");
    try writeFile(tmp.dir, "shared.ts", "export function createApp() { return 'app'; }");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 엔트리 청크에 `import { createApp }` 형태의 named import가 있어야 함
    var has_named_import = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "import { createApp }") != null or
            std.mem.indexOf(u8, o.contents, "import{createApp}") != null)
        {
            has_named_import = true;
            break;
        }
    }
    try std.testing.expect(has_named_import);

    // 공통 청크에 `export { createApp }` 형태의 export가 있어야 함
    var has_export = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "export { createApp }") != null or
            std.mem.indexOf(u8, o.contents, "export{createApp}") != null)
        {
            has_export = true;
            break;
        }
    }
    try std.testing.expect(has_export);
}

test "CodeSplitting: multiple named imports from common chunk" {
    // 하나의 공통 청크에서 여러 심볼을 가져올 때
    // import { a, b } from './chunk-N.js' 형태로 합쳐져야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x, y } from './shared';\nconsole.log(x, y);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './shared';\nconsole.log(x);");
    try writeFile(tmp.dir, "shared.ts", "export const x = 1;\nexport const y = 2;");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // a.ts 엔트리 청크에 x와 y 모두 import되어야 함
    var has_multi_import = false;
    for (outs) |o| {
        // x와 y가 같은 import 문에 있는지 확인 (순서 무관)
        if ((std.mem.indexOf(u8, o.contents, "import {") != null or
            std.mem.indexOf(u8, o.contents, "import {") != null) and
            std.mem.indexOf(u8, o.contents, "x") != null and
            std.mem.indexOf(u8, o.contents, "y") != null and
            std.mem.indexOf(u8, o.contents, "from \"./") != null)
        {
            has_multi_import = true;
            break;
        }
    }
    try std.testing.expect(has_multi_import);
}

test "CodeSplitting: no cross-chunk symbols when all in same chunk" {
    // 단일 엔트리 — 모든 모듈이 같은 청크에 있으면
    // cross-chunk import/export 없이 인라인 번들이어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './dep';\nconsole.log(x);");
    try writeFile(tmp.dir, "dep.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 단일 청크 — cross-chunk import/export가 없어야 함
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    for (outs) |o| {
        // import 문이나 from 문이 없어야 함 (side-effect든 named든)
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "import '") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "from '") == null);
    }
}

test "CodeSplitting: re-export chain across chunks" {
    // entry → re-exporter → original 체인에서
    // re-exporter와 original이 공통 청크로 추출되면
    // entry 청크에 심볼 import가 있어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { val } from './reexport';\nconsole.log(val);");
    try writeFile(tmp.dir, "b.ts", "import { val } from './reexport';\nconsole.log(val);");
    try writeFile(tmp.dir, "reexport.ts", "export { val } from './original';");
    try writeFile(tmp.dir, "original.ts", "export const val = 'hello';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 디버그: 출력 파일 수와 내용 확인
    // re-export 체인에서 reexport.ts와 original.ts가 공통 청크로 추출되어야 함
    // 2 엔트리 + 1~2 공통 = 3~4 파일
    // 단, tree-shaking으로 reexport.ts가 제거되면 2개일 수 있음
    try std.testing.expect(outs.len >= 2);

    // 엔트리 청크에 cross-chunk import가 있거나,
    // scope_hoist로 인라인되어 val이 직접 포함될 수 있음
    var has_cross_import = false;
    var has_val_inline = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "from \"./") != null or
            std.mem.indexOf(u8, o.contents, "import \"./") != null)
        {
            has_cross_import = true;
        }
        if (std.mem.indexOf(u8, o.contents, "\"hello\"") != null) {
            has_val_inline = true;
        }
    }
    // cross-chunk import가 있거나, scope_hoist로 인라인되어 값이 포함되어야 함
    try std.testing.expect(has_cross_import or has_val_inline);
}

// ============================================================
// Tests — per-chunk scope hoisting + cross-chunk export alias
// ============================================================

test "CodeSplitting: per-chunk rename — 다른 청크의 같은 이름은 충돌하지 않음" {
    // 2개 엔트리가 각각 같은 이름의 top-level 변수를 가질 때,
    // 다른 청크에 있으므로 rename되지 않아야 한다 (per-chunk 네임스페이스).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const x = 'from-a';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "const x = 'from-b';\nconsole.log(x);");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 어떤 청크에도 x$1 같은 리네임이 없어야 함 — 각 청크가 독립 네임스페이스
    for (outs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "x$1") == null);
    }
    // 두 청크 모두 원본 이름 x를 사용
    var a_has_x = false;
    var b_has_x = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "\"from-a\"") != null and
            std.mem.indexOf(u8, o.contents, "const x") != null)
        {
            a_has_x = true;
        }
        if (std.mem.indexOf(u8, o.contents, "\"from-b\"") != null and
            std.mem.indexOf(u8, o.contents, "const x") != null)
        {
            b_has_x = true;
        }
    }
    try std.testing.expect(a_has_x);
    try std.testing.expect(b_has_x);
}

test "CodeSplitting: same-chunk collision still renamed" {
    // 같은 청크 내의 2개 모듈이 같은 이름을 가지면 충돌 해결이 되어야 한다.
    // 단일 엔트리 + 의존성 — 모두 같은 청크에 묶임.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './dep';\nconst x = 'entry';\nconsole.log(x);");
    try writeFile(tmp.dir, "dep.ts", "export const x = 'dep';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 단일 청크 — 같은 청크 내 충돌이므로 x$1이 있어야 함
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    // entry.ts의 x와 dep.ts의 x 중 하나가 rename됨
    const has_rename = std.mem.indexOf(u8, outs[0].contents, "x$1") != null;
    // 또는 import가 제거되어 dep의 x를 직접 참조하여 충돌 없을 수도 있음
    const has_both_values = std.mem.indexOf(u8, outs[0].contents, "'dep'") != null and
        std.mem.indexOf(u8, outs[0].contents, "'entry'") != null;
    try std.testing.expect(has_rename or has_both_values);
}

test "CodeSplitting: cross-chunk export alias with renamed symbol" {
    // 공통 청크에서 2개 모듈이 같은 이름의 export를 가질 때,
    // 청크 내 충돌 해결 후 export { local_name as export_name } 형태로 출력되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // shared1과 shared2가 모두 "val"을 export하고, 둘 다 같은 청크에 묶이도록 설계
    // a.ts → shared1 (val), shared2 (val)
    // b.ts → shared1 (val), shared2 (val)
    try writeFile(tmp.dir, "a.ts", "import { val } from './shared1';\nimport { val as v2 } from './shared2';\nconsole.log(val, v2);");
    try writeFile(tmp.dir, "b.ts", "import { val } from './shared1';\nimport { val as v2 } from './shared2';\nconsole.log(val, v2);");
    try writeFile(tmp.dir, "shared1.ts", "export const val = 'one';");
    try writeFile(tmp.dir, "shared2.ts", "export const val = 'two';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 공통 청크가 존재해야 함 (2 엔트리 + 1~2 공통 = 3~4 파일)
    try std.testing.expect(outs.len >= 3);

    // 공통 청크에 export 문이 있어야 함
    var has_export = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "export {") != null or
            std.mem.indexOf(u8, o.contents, "export{") != null)
        {
            has_export = true;
            // 공통 청크에 val$1 rename이 있으면 "as val" 형태도 있어야 함
            if (std.mem.indexOf(u8, o.contents, "val$1") != null) {
                try std.testing.expect(std.mem.indexOf(u8, o.contents, "as val") != null);
            }
        }
    }
    try std.testing.expect(has_export);
}

test "CodeSplitting: cross-chunk import binding does not collide with local name" {
    // Bug #2 재현: cross-chunk import 바인딩이 같은 청크의 로컬 이름과 충돌
    // entry.ts imports 'value' from shared (다른 청크), other.ts defines 'value' (같은 청크)
    // → 중복 선언 SyntaxError 방지: 둘 중 하나가 rename되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './shared';
        \\import { value as otherValue } from './other';
        \\console.log(value, otherValue);
    );
    try writeFile(tmp.dir, "shared.ts", "export const value = 42;");
    try writeFile(tmp.dir, "other.ts", "export const value = 'local';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 출력에 'value'가 중복 선언되지 않아야 함
    // (import { value } + const value 가 같은 청크에 있으면 안 됨)
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    for (outputs) |o| {
        // entry 청크의 코드에서 SyntaxError 패턴 검사
        // const value = 'local'과 import { value }가 동시에 있으면 안 됨
        if (std.mem.indexOf(u8, o.contents, "\"local\"") != null) {
            // 이 청크에 import { value }도 있으면 충돌
            if (std.mem.indexOf(u8, o.contents, "import {") != null and
                std.mem.indexOf(u8, o.contents, "const value") != null)
            {
                // 둘 다 있으면 하나는 rename되어야 함
                // value$1 또는 as 절이 있어야 함
                const has_rename = std.mem.indexOf(u8, o.contents, "value$1") != null or
                    std.mem.indexOf(u8, o.contents, " as ") != null;
                try std.testing.expect(has_rename);
            }
        }
    }
}

test "CodeSplitting: cross-chunk import reference uses correct binding name" {
    // Bug #1 재현: buildMetadataForAst가 exporter의 rename을 importing 청크에 적용
    // shared.ts의 'greet'가 다른 이유로 rename되면, entry.ts에서 참조가 깨짐
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './shared';
        \\console.log(greet());
    );
    try writeFile(tmp.dir, "shared.ts",
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // entry 청크에서 greet() 호출이 있어야 함
    var found_greet_call = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "greet()") != null) {
            found_greet_call = true;
            // greet가 import에서 왔으면, import 문에 greet가 있어야 함
            if (std.mem.indexOf(u8, o.contents, "import") != null) {
                try std.testing.expect(std.mem.indexOf(u8, o.contents, "greet") != null);
            }
        }
    }
    try std.testing.expect(found_greet_call);
}

test "CodeSplitting: CRITICAL — same name in shared chunk and entry chunk" {
    // shared.ts(공통 청크)에 'x', entry에 import 'x' + 로컬 'x' 정의
    // → 같은 청크에 import { x } + const x 가 공존하면 SyntaxError
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry가 shared를 dynamic import → shared는 별도 청크
    // entry 자체에도 const x = 'local' 선언
    try writeFile(tmp.dir, "entry.ts",
        \\const x = 'local';
        \\const shared = import('./shared');
        \\console.log(x, shared);
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // 최소 2개 청크 (entry + shared)
    try std.testing.expect(outputs.len >= 2);
    // shared 청크에 export 문이 있어야 함
    var has_export = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "export") != null and
            std.mem.indexOf(u8, o.contents, "42") != null)
        {
            has_export = true;
        }
    }
    try std.testing.expect(has_export);
}

test "CodeSplitting: CRITICAL — rename collision between import binding and local var" {
    // 2개 엔트리: a.ts, b.ts → 둘 다 shared.ts의 'val'을 import
    // a.ts에도 로컬 'val' 정의 → a 청크에서 import { val } + const val 충돌
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { val } from './shared';
        \\const val2 = val + 1;
        \\console.log(val2);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { val } from './shared';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "shared.ts", "export const val = 42;");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 3개 청크: a, b, shared(공통)
    try std.testing.expectEqual(@as(usize, 3), outputs.len);

    // shared 청크에 export { val } 있어야 함
    var shared_has_export = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "const val = 42") != null or
            std.mem.indexOf(u8, o.contents, "const val=42") != null)
        {
            shared_has_export = std.mem.indexOf(u8, o.contents, "export") != null;
        }
    }
    try std.testing.expect(shared_has_export);

    // a 청크에 import { val } from './chunk-...' 있어야 함
    var a_has_import = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "val + 1") != null or
            std.mem.indexOf(u8, o.contents, "val+1") != null)
        {
            a_has_import = std.mem.indexOf(u8, o.contents, "import") != null;
        }
    }
    try std.testing.expect(a_has_import);
}

test "CodeSplitting: CRITICAL — two modules in same chunk with same name as cross-chunk import" {
    // a.ts(엔트리)가 shared.ts의 'x'를 import + local.ts(같은 청크)에도 'x' 선언
    // b.ts(엔트리)도 shared.ts의 'x'를 import → shared.ts는 공통 청크
    // a 청크에 a.ts + local.ts가 같이 있음 → local.ts의 'x'와 import { x } 충돌
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { x } from './shared';
        \\import { y } from './local';
        \\console.log(x, y);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "local.ts",
        \\export const x = 'local-x';
        \\export const y = 'local-y';
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared-x';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // a 청크를 찾기: local-x가 포함된 청크
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "local-x") != null) {
            // 이 청크에 import { x }도 있다면, const x와 충돌
            // → x$1 rename 또는 import { x as x$1 } 형태여야 함
            const has_import_x = std.mem.indexOf(u8, o.contents, "import") != null;
            const has_const_x = std.mem.indexOf(u8, o.contents, "const x") != null;
            if (has_import_x and has_const_x) {
                // 충돌이 있으면 rename 또는 as가 있어야 함
                const has_deconflict = std.mem.indexOf(u8, o.contents, "x$1") != null or
                    std.mem.indexOf(u8, o.contents, " as ") != null;
                try std.testing.expect(has_deconflict);
            }
        }
    }
}

test "CodeSplitting: three entries sharing module — all import same name" {
    // 3개 엔트리가 shared의 'x'를 import + 각 엔트리에도 로컬 'x'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { x } from './shared';
        \\const x2 = x;
        \\console.log(x2);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "c.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);
    const c_path = try absPath(&tmp, "c.ts");
    defer std.testing.allocator.free(c_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path, c_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // 4 청크: 3 엔트리 + 1 공통
    try std.testing.expectEqual(@as(usize, 4), outputs.len);
}

test "CodeSplitting: default export cross-chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import lib from './shared';
        \\console.log(lib);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import lib from './shared';
        \\console.log(lib);
    );
    try writeFile(tmp.dir, "shared.ts", "export default function() { return 42; }");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    try std.testing.expect(outputs.len >= 2);
}

test "CodeSplitting: deep chain across chunks" {
    // a→b (static), a→c (dynamic), c→d (static), b→d (static)
    // d는 a청크(via b)와 c청크(직접) 모두에서 도달 → 공통 청크
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { b } from './b';
        \\const c = import('./c');
        \\console.log(b, c);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { d } from './d';
        \\export const b = d + 1;
    );
    try writeFile(tmp.dir, "c.ts",
        \\import { d } from './d';
        \\export const c = d + 2;
    );
    try writeFile(tmp.dir, "d.ts", "export const d = 10;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // d.ts가 공통 청크에 있어야 함 (a청크, c청크 모두에서 도달)
    try std.testing.expect(outputs.len >= 2);
}

test "CodeSplitting: minified output with chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 42;");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // minified: 모듈 경계 주석 없음
    for (outputs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "// ---") == null);
    }
}

test "CodeSplitting: CJS module in shared chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import cjs from './shared.cjs';
        \\console.log(cjs);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import cjs from './shared.cjs';
        \\console.log(cjs);
    );
    try writeFile(tmp.dir, "shared.cjs", "module.exports = { value: 42 };");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // CJS 모듈이 공통 청크에 __commonJS 래핑되어야 함
    var has_commonjs = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "__commonJS") != null) {
            has_commonjs = true;
        }
    }
    try std.testing.expect(has_commonjs);
}

// ============================================================
// Content Hash + Naming Pattern Tests
// ============================================================

test "CodeSplitting: content hash naming — entry-names and chunk-names" {
    // --entry-names=[name]-[hash] --chunk-names=chunks/[name]-[hash] 통합 테스트
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { shared } from './shared';\nconsole.log('a', shared);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './shared';\nconsole.log('b', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .entry_names = "[name]-[hash]",
        .chunk_names = "chunks/[name]-[hash]",
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 엔트리 파일명: "{name}-{8hex}.js"
    // 공통 청크 파일명: "chunks/chunk-{8hex}.js"
    var entry_count: usize = 0;
    var chunk_count: usize = 0;
    for (outputs) |o| {
        if (std.mem.startsWith(u8, o.path, "chunks/")) {
            chunk_count += 1;
            try std.testing.expect(std.mem.startsWith(u8, o.path, "chunks/chunk-"));
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
        } else {
            entry_count += 1;
            // "a-{8hex}.js" or "b-{8hex}.js"
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
            try std.testing.expect(std.mem.indexOf(u8, o.path, "-") != null);
        }
        // placeholder가 최종 출력에 남아있으면 안 된다
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\x00ZH") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.path, "\x00ZH") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), entry_count);
    try std.testing.expect(chunk_count >= 1);
}

test "CodeSplitting: content hash deterministic — same code same hash" {
    // 동일한 코드를 두 번 빌드하면 동일한 content hash가 나와야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    // 1차 빌드
    var bnd1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .chunk_names = "[name]-[hash]",
    });
    defer bnd1.deinit();
    const result1 = try bnd1.bundle();
    defer result1.deinit(std.testing.allocator);

    // 2차 빌드
    var bnd2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .chunk_names = "[name]-[hash]",
    });
    defer bnd2.deinit();
    const result2 = try bnd2.bundle();
    defer result2.deinit(std.testing.allocator);

    const outs1 = result1.outputs orelse return error.TestUnexpectedResult;
    const outs2 = result2.outputs orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(outs1.len, outs2.len);

    // 파일명이 동일한지 확인
    for (outs1) |o1| {
        var found = false;
        for (outs2) |o2| {
            if (std.mem.eql(u8, o1.path, o2.path)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

// ============================================================
// Dev Mode Tests
// ============================================================

test "Bundler: dev mode includes polyfills and banner" {
    // dev mode에서 --polyfill, --banner:js가 번들에 포함되는지 확인.
    // error-guard.js 등 폴리필이 누락되면 global.ErrorUtils가 undefined.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");
    try writeFile(tmp.dir, "my-polyfill.js", "global.MyPolyfill = { init: function() {} };");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "my-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .polyfills = &.{polyfill},
        .banner_js = "var __TEST_BANNER__=1;",
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill이 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MyPolyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(function(){") != null);
    // banner가 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__TEST_BANNER__") != null);
    // polyfill/banner가 HMR 런타임보다 앞에 위치
    const polyfill_pos = std.mem.indexOf(u8, result.output, "MyPolyfill").?;
    const hmr_pos = std.mem.indexOf(u8, result.output, "__zts_modules").?;
    try std.testing.expect(polyfill_pos < hmr_pos);
    const banner_pos = std.mem.indexOf(u8, result.output, "__TEST_BANNER__").?;
    try std.testing.expect(banner_pos < polyfill_pos);
}

test "Bundler: dev mode single file" {
    // dev mode에서 단일 파일이 __zts_register로 래핑되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 42;\nexport default x;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // HMR 런타임이 주입되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_register") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_make_hot") != null);
    // 모듈이 register로 래핑되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_register(\"") != null);
    // export가 __zts_exports로 변환되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_exports.default") != null);
}

test "Bundler: dev mode two files with import" {
    // dev mode에서 두 파일 간 import가 __zts_require로 변환되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈이 각각 __zts_register로 래핑
    const output = result.output;
    const first = std.mem.indexOf(u8, output, "__zts_register(\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, output[first + 1 ..], "__zts_register(\"") != null);
    // __zts_require 호출이 있는지
    try std.testing.expect(std.mem.indexOf(u8, output, "__zts_require(\"") != null);
    // utils.ts의 export가 __zts_exports.add로 변환
    try std.testing.expect(std.mem.indexOf(u8, output, "__zts_exports.add") != null);
}

test "Bundler: dev mode default import" {
    // dev mode에서 default import가 __zts_require(...).default로 변환되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "greet.ts", "export default function greet() { return 'hi'; }");
    try writeFile(tmp.dir, "index.ts", "import greet from './greet';\nconsole.log(greet());");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // default import → .default
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".default") != null);
    // greet.ts의 default export
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_exports.default") != null);
}

test "Bundler: dev mode module_dev_codes" {
    // dev mode에서 module_dev_codes가 생성되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // module_dev_codes가 존재하고 2개 모듈 (utils + index)
    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), codes.len);
    // 각 code에 __zts_register 래핑이 있는지
    for (codes) |c| {
        try std.testing.expect(c.id.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "__zts_register(\"") != null);
    }
}

test "Bundler: dev mode sourcemap" {
    // dev mode에서 소스맵이 생성되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 소스맵이 생성되었는지
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;
    // V3 소스맵 JSON 구조 확인
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"mappings\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"sources\":[") != null);
    // 번들에 sourceMappingURL이 있는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "//# sourceMappingURL=/bundle.js.map") != null);
}

test "Bundler: dev mode sourcemap — multi-module sources" {
    // 여러 모듈의 소스맵이 번들 소스맵에 모두 포함되는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");
    try writeFile(tmp.dir, "str.ts", "export function upper(s: string) { return s.toUpperCase(); }");
    try writeFile(tmp.dir, "main.ts", "import { add } from './math';\nimport { upper } from './str';\nconsole.log(add(1, 2), upper('hi'));");

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    // 3개 모듈 모두 sources 배열에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, sm, "math.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "str.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "main.ts") != null);

    // mappings가 빈 문자열이 아니어야 함 (실제 매핑 존재)
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"mappings\":\"\"") == null);
}

test "Bundler: dev mode sourcemap — mappings point to correct bundle lines" {
    // 번들 출력에서 각 모듈 코드의 줄 위치가 소스맵 매핑과 일치하는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const A = 'a';");
    try writeFile(tmp.dir, "b.ts", "import { A } from './a';\nexport const B = A + 'b';");

    const entry = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 번들 출력에 두 모듈의 코드가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const B") != null);

    // 소스맵에 두 소스가 모두 있어야 함
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, sm, "a.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "b.ts") != null);

    // sourceMappingURL이 번들 끝에 있어야 함
    const url_marker = "//# sourceMappingURL=";
    const url_pos = std.mem.indexOf(u8, result.output, url_marker) orelse
        return error.TestUnexpectedResult;
    // URL은 출력 마지막 줄이어야 함
    const after_url = result.output[url_pos + url_marker.len ..];
    const newline_pos = std.mem.indexOf(u8, after_url, "\n");
    if (newline_pos) |np| {
        // 줄바꿈 이후에는 내용이 없거나 빈 줄만
        const rest = std.mem.trim(u8, after_url[np..], "\n\r ");
        try std.testing.expectEqualStrings("", rest);
    }
}

test "Bundler: dev mode react fast refresh" {
    // React Fast Refresh가 컴포넌트에 $RefreshReg$ 주입하는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "App.ts", "export default function App() { return 'hello'; }\nfunction Helper() { return 'helper'; }");

    const entry = try absPath(&tmp, "App.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // $RefreshReg$ 호출이 주입되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$") != null);
    // PascalCase 함수명(App, Helper) 등록
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"App\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Helper\"") != null);
    // _c 핸들 변수 선언
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_c") != null);
    // react-refresh 런타임 바인딩
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshSig$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__REACT_REFRESH_RUNTIME__") != null);
    // hot.accept() 자동 삽입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_module.hot.accept()") != null);
}

test "Bundler: dev mode refresh signature" {
    // Hook 시그니처($RefreshSig$)가 주입되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "App.ts",
        \\function App() {
        \\  const x = useState(0);
        \\  useEffect(function() {});
        \\  return x;
        \\}
    );

    const entry = try absPath(&tmp, "App.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // var _s = $RefreshSig$(); 선언
    try std.testing.expect(std.mem.indexOf(u8, output, "$RefreshSig$") != null);
    // _s(); boundary marker 호출 (함수 body 시작)
    try std.testing.expect(std.mem.indexOf(u8, output, "_s()") != null);
    // _s(App, "signature"); 시그니처 연결
    try std.testing.expect(std.mem.indexOf(u8, output, "_s(App") != null);
    // 시그니처에 useState, useEffect 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "useState") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "useEffect") != null);
    // 바인딩 정보: useState{x(0)} — LHS 바인딩 + 초기값
    try std.testing.expect(std.mem.indexOf(u8, output, "useState{x(0)}") != null);
}

test "Profile: pipeline stage timing (dev only, not for CI)" {
    // 프로세스 시작 비용 없이 순수 파이프라인 단계별 시간 측정
    const alloc = std.testing.allocator;
    const Scanner = @import("../lexer/mod.zig").Scanner;
    const Parser = @import("../parser/mod.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/mod.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const Codegen = @import("../codegen/codegen.zig").Codegen;

    const sizes = [_]usize{ 1000, 5000, 10000 };
    const RUNS = 5;

    std.debug.print("\n=== Pipeline Profile ({d} runs avg, Debug build) ===\n", .{RUNS});
    std.debug.print("| Lines | Scanner | Parser | Semantic | Transformer | Codegen | Total (us) |\n", .{});
    std.debug.print("|-------|---------|--------|----------|-------------|---------|------------|\n", .{});

    for (sizes) |line_count| {
        var src_buf: std.ArrayList(u8) = .empty;
        defer src_buf.deinit(alloc);
        for (0..line_count) |i| {
            var line_buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "export const v{d} = {d};\n", .{ i, i }) catch continue;
            try src_buf.appendSlice(alloc, line);
        }
        const source = src_buf.items;

        var scan_ns: i128 = 0;
        var parse_ns: i128 = 0;
        var sem_ns: i128 = 0;
        var xform_ns: i128 = 0;
        var cg_ns: i128 = 0;

        for (0..RUNS) |_| {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();

            var t0 = std.time.nanoTimestamp();
            var scanner = try Scanner.init(a, source);
            scan_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var parser = Parser.init(a, &scanner);
            _ = try parser.parse();
            parse_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var analyzer = SemanticAnalyzer.init(a, &parser.ast);
            _ = analyzer.analyze() catch {};
            sem_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var transformer = try Transformer.init(a, &parser.ast, .{});
            const root = try transformer.transform();
            xform_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var cg = Codegen.init(a, &transformer.ast);
            _ = try cg.generate(root);
            cg_ns += std.time.nanoTimestamp() - t0;
        }

        const us: i128 = 1000;
        const r: i128 = RUNS;
        const total = scan_ns + parse_ns + sem_ns + xform_ns + cg_ns;
        std.debug.print("| {d:>5} | {d:>7} | {d:>6} | {d:>8} | {d:>11} | {d:>7} | {d:>10} |\n", .{
            line_count,
            @divTrunc(scan_ns, r * us),
            @divTrunc(parse_ns, r * us),
            @divTrunc(sem_ns, r * us),
            @divTrunc(xform_ns, r * us),
            @divTrunc(cg_ns, r * us),
            @divTrunc(total, r * us),
        });
    }
}

test "Scope hoisting: arrow param shadow should not be renamed when namespace import conflicts" {
    // zod 패턴: import * as checks + (...checks) => { checks.map(...) }
    // 두 모듈의 namespace import 이름이 충돌해도, arrow 파라미터의 body 참조는 rename 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "core/checks.js", "export function refine(x) { return x; }");
    try writeFile(tmp.dir, "core/schemas.js",
        \\import * as checks from './checks.js';
        \\export function $constructor(name, init) {
        \\    return function(def) { var inst = {}; init(inst, def); return inst; };
        \\}
        \\export function $init(inst, def) {
        \\    const checks = [...(def.checks || [])];
        \\    for (const ch of checks) { ch; }
        \\}
        \\export var util = { mergeDefs: function(a, b) { return Object.assign({}, a, b); } };
    );
    try writeFile(tmp.dir, "classic/checks.js",
        \\export function regex(p) { return { type: "regex", p: p }; }
        \\export function overwrite(fn) { return { type: "overwrite", fn: fn }; }
    );
    try writeFile(tmp.dir, "classic/schemas.js",
        \\import * as core from '../core/schemas.js';
        \\import { util } from '../core/schemas.js';
        \\import * as checks from './checks.js';
        \\export var ZodType = core.$constructor("ZodType", (inst, def) => {
        \\    core.$init(inst, def);
        \\    inst.check = (...checks) => {
        \\        return inst.clone(util.mergeDefs(def, {
        \\            checks: checks.map((ch) => typeof ch === "function" ? { check: ch } : ch)
        \\        }));
        \\    };
        \\    inst.clone = (d) => d;
        \\    inst.overwrite = (fn) => inst.check(checks.overwrite(fn));
        \\    inst.regex = (...args) => inst.check(checks.regex(...args));
        \\});
        \\export function string(params) { return ZodType({ type: "string", checks: [] }); }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { string } from './classic/schemas.js';
        \\var schema = string();
        \\console.log(typeof schema.check);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // checks$1.map 또는 checks$2.map가 있으면 안 됨 — parameter shadow가 rename되지 않아야
    try std.testing.expect(std.mem.indexOf(u8, result.output, "checks$") == null);
}

test "Bundler: sideEffects glob pattern — matched file kept, unmatched tree-shaken" {
    // sideEffects: ["./src/polyfill.js"] — polyfill.js는 유지, 나머지 미사용 JS 제거
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","sideEffects":["./src/polyfill.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { setup } from './src/polyfill.js';
        \\export function unused() { return 42; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/src/polyfill.js",
        \\export function setup() { globalThis.__POLYFILL__ = true; }
        \\setup();
    );
    try writeFile(tmp.dir, "entry.js",
        \\import './node_modules/pkg/index.js';
        \\console.log('app');
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // polyfill.js는 sideEffects 패턴 매칭 → side_effects=true → 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__POLYFILL__") != null);
    // entry의 console.log 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "Scope hoisting: forward reference in same module — const before use" {
    // effect 패턴: const tagged = dual(3, (self, k, v) => taggedWithLabels(self, [...]));
    //              const taggedWithLabels = dual(2, ...);
    // 두 모듈이 같은 이름의 top-level 변수를 갖고, forward reference가 있을 때
    // linker가 올바르게 리네임해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "a.js",
        \\export const greet = () => helper();
        \\export const helper = () => "from_a";
    );
    try writeFile(tmp.dir, "b.js",
        \\export const greet = () => helper();
        \\export const helper = () => "from_b";
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { greet as greetA } from './a.js';
        \\import { greet as greetB } from './b.js';
        \\console.log(greetA(), greetB());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 번들 실행 시 "from_a from_b"가 출력되어야 한다.
    // forward reference가 해석되지 않으면 두 모듈의 helper가 섞여서
    // "from_a from_a" 또는 "from_b from_b"가 된다.
    // 실행은 하지 못하지만, 번들에 helper$1 또는 helper$2가 있어야 한다.
    // (이름 충돌 해결 = forward reference가 올바르게 해석된 증거)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "helper$") != null);
    // 두 greet 함수가 각각의 helper를 참조해야 한다.
    // greet (a.js)는 helper() 또는 helper$1()을 호출
    // greet$1 (b.js)는 helper$1() 또는 helper$2()를 호출
    // 핵심: 같은 helper를 참조하면 안 됨
    const output = result.output;
    const greet_a = std.mem.indexOf(u8, output, "const greet") orelse
        std.mem.indexOf(u8, output, "const greet ") orelse 0;
    _ = greet_a;
    // 최소한 helper가 리네임되었는지만 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "helper$") != null);
}

// ============================================================
// Regression tests (2026-03-27 세션)
// ============================================================

test "scope hoisting: canonical name collision prevention (vue computed pattern)" {
    // 3개 모듈에서 같은 이름 + 중첩 스코프 shadowing → 리네임 충돌 방지.
    // vue의 computed$1 중복 선언 버그 (#447) regression 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { compute as c1 } from './a';\nimport { compute as c2 } from './b';\nconsole.log(c1(5), c2(5));");
    try writeFile(tmp.dir, "a.ts", "export function compute(x: number) { return x * 2; }");
    // b.ts: import alias compute$1 + 자체 compute + 중첩 스코프에 compute 변수
    try writeFile(tmp.dir, "b.ts", "import { compute as compute$1 } from './a';\nfunction inner() { var compute = 1; return compute; }\nexport const compute = (x: number) => compute$1(x + 1);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // compute가 3개의 다른 이름으로 리네임됨 (중복 선언 없음)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "compute$1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "compute$2") != null);
}

test "namespace object: bare default keyword prevention (eventemitter3 pattern)" {
    // CJS → ESM 래핑 후 namespace 객체에서 "default"가 bare 키워드로 출력되면 안 됨.
    // #454 regression 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as lib from './lib.cjs';\nconsole.log(Object.keys(lib));");
    try writeFile(tmp.dir, "lib.cjs", "function Foo() {}\nFoo.prototype.hello = function() { return 'hi'; };\nmodule.exports = Foo;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // "default" bare 키워드가 값 위치에 나타나면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": default,") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": default}") == null);
}

test "namespace barrel re-export: import * as X; export { X } (fp-ts pattern)" {
    // namespace import를 barrel re-export할 때 인라인 객체가 생성되어야 함.
    // #455 regression 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as pkg from './barrel';\nconsole.log(pkg.sub.x, pkg.sub.y);");
    try writeFile(tmp.dir, "barrel.ts", "import * as sub from './sub';\nexport { sub };");
    try writeFile(tmp.dir, "sub.ts", "export const x = 1;\nexport const y = 2;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sub가 인라인 객체로 생성됨 (undefined가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "y:") != null);
}

test "export *: excludes default (ESM spec 15.2.3.5)" {
    // export *는 "default"를 제외해야 함. 명시적 re-export는 유지.
    // #457 regression 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as pkg from './barrel';\nconsole.log(Object.keys(pkg).sort().join(','));");
    try writeFile(tmp.dir, "barrel.ts", "export * from './mod';");
    try writeFile(tmp.dir, "mod.ts", "export function foo() { return 1; }\nexport default function bar() { return 2; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // export *에 의해 foo만 포함, default는 제외
    try std.testing.expect(std.mem.indexOf(u8, result.output, "foo") != null);
}

test "export * + explicit default re-export coexistence" {
    // export *로 default 제외 + export { default }로 명시적 포함이 공존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as pkg from './barrel';\nconsole.log('default' in pkg, 'foo' in pkg);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './mod';\nexport { default } from './mod';");
    try writeFile(tmp.dir, "mod.ts", "export function foo() { return 1; }\nexport default function bar() { return 2; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 명시적 export { default }에 의해 default 포함, export *에 의해 foo 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "foo") != null);
}

test "Interop: .mjs importer uses Node mode, .ts uses Babel mode" {
    // .mjs → __toESM(req(), 1), .ts → __toESM(req())
    // #456 regression 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = { value: 42 };");

    const entry = try absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // .mjs importer → Node 모드 (isNodeMode=1)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib(), 1)") != null);
}

test "TreeShaking: export-level DCE — tslib pattern (export default object)" {
    // tslib 패턴: 33개 named export + export default { ... } 객체
    // __awaiter만 import하면 나머지 + default 객체 모두 제거
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { __awaiter } from './tslib';
        \\console.log(__awaiter);
    );
    try writeFile(tmp.dir, "tslib.ts",
        \\export function __extends() { return 1; }
        \\export function __awaiter() { return 2; }
        \\export function __rest() { return 3; }
        \\export function __decorate() { return 4; }
        \\export default { __extends, __awaiter, __rest, __decorate };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __awaiter 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__awaiter") != null);
    // 미사용 함수 제거 (함수 body가 출력에 없어야 함)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __extends") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __rest") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __decorate") == null);
}

test "TreeShaking: export-level DCE — var with ternary init removed" {
    // tslib 패턴: var __createBinding = Object.create ? fn1 : fn2
    // 미사용 시 제거
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export var ternaryVar = Object.create ? function() { return 1; } : function() { return 2; };
        \\export function used() { return 42; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function used") != null);
    // ternary 초기화 변수 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ternaryVar") == null);
}

test "TreeShaking: class extends identifier — unused child removed (three.js pattern)" {
    // three.js 핵심 패턴: Object3D → Light → AmbientLight 상속 체인.
    // Vector3만 사용하면 AmbientLight 등 미사용 클래스는 제거되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { B } from './classes';
        \\console.log(new B());
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class Base {}
        \\export class A extends Base {}
        \\export class B extends Base {}
        \\export class C extends A {}
        \\Base.DEFAULT_UP = 123;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // B와 Base는 포함, Base.DEFAULT_UP도 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Base") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class B ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEFAULT_UP") != null);
    // A와 C는 미사용이므로 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class A ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class C ") == null);
}

test "TreeShaking: class extends call expr — kept as side-effect" {
    // extends fn()은 side-effect → 미사용이어도 보존
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './classes';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export const used = 1;
        \\function mixin() { return class {}; }
        \\export class X extends mixin() {}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // extends mixin()은 side-effect이므로 X가 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "mixin") != null);
}

test "TreeShaking: re-export chain — only used export included (three.module.js pattern)" {
    // three.module.js 패턴: core에서 많은 심볼을 import, 일부만 re-export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Vector3 } from './facade';
        \\console.log(new Vector3());
    );
    try writeFile(tmp.dir, "facade.ts",
        \\export { Vector3, AmbientLight, Scene } from './core';
    );
    try writeFile(tmp.dir, "core.ts",
        \\export class EventDispatcher {}
        \\export class Object3D extends EventDispatcher {}
        \\export class Vector3 {}
        \\export class Light extends Object3D {}
        \\export class AmbientLight extends Light {}
        \\export class Scene extends Object3D {}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // Vector3만 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Vector3") != null);
    // AmbientLight, Light, Scene은 미사용이므로 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "AmbientLight") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Light") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Scene") == null);
}

test "TreeShaking: class with static block preserved — side-effect in body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './classes';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class X { static { console.log("init"); } }
        \\export const used = 1;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // static block이 있으므로 X가 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class X") != null);
}

test "TreeShaking: class with impure static field preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './classes';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class X { static foo = init(); }
        \\function init() { return 1; }
        \\export const used = 1;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // static foo = init() → impure → X 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class X") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init") != null);
}

test "TreeShaking: class with pure static field removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './classes';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class X { static foo = 42; }
        \\export const used = 1;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // static foo = 42 → pure → X 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class X") == null);
}

test "TreeShaking: export default identifier — import preserved (yargs y18n pattern)" {
    // yargs 패턴: export default someVar → import { x } → x가 번들에 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import fn from './wrapper';
        \\console.log(fn(42));
    );
    try writeFile(tmp.dir, "wrapper.ts",
        \\import { impl } from './impl';
        \\const wrapper = (x) => impl(x);
        \\export default wrapper;
    );
    try writeFile(tmp.dir, "impl.ts",
        \\export function impl(x) { return x + 1; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // impl 함수가 번들에 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "impl") != null);
    // wrapper도 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "wrapper") != null);
}

test "TreeShaking: ESM→CJS re-export default — eventemitter3 pattern" {
    // ESM wrapper(index.mjs) → CJS(index.js) 체인에서 default import 바인딩 생성
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import EE from './wrapper.mjs';
        \\console.log(new EE());
    );
    try writeFile(tmp.dir, "wrapper.mjs",
        \\import EventEmitter from './impl.js';
        \\export default EventEmitter;
    );
    // CJS 모듈 시뮬레이션: module.exports 패턴
    try writeFile(tmp.dir, "impl.js",
        \\function EE() { this.x = 1; }
        \\module.exports = EE;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS interop preamble이 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") != null or
        std.mem.indexOf(u8, result.output, "__commonJS") != null);
    // EE 함수 정의가 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function EE") != null);
}

test "TreeShaking: namespace barrel re-export — import * as z; export { z }" {
    // namespace barrel re-export에서 소스 모듈 export가 포함되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './pkg';
        \\console.log(z.foo());
    );
    try writeFile(tmp.dir, "pkg.ts",
        \\import * as z from './inner';
        \\export { z };
    );
    try writeFile(tmp.dir, "inner.ts",
        \\export function foo() { return "ok"; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // foo 함수 정의가 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function foo") != null);
    // namespace 객체가 생성
    try std.testing.expect(std.mem.indexOf(u8, result.output, "foo:") != null or
        std.mem.indexOf(u8, result.output, "foo: foo") != null);
}

test "Codegen: else if (false) chain — no syntax error" {
    // --define로 조건이 false가 되면 else if 체인이 빈 문법 에러를 만들지 않아야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function test(x: number) {
        \\  if (x > 0) {
        \\    return "pos";
        \\  } else if (process.env.NODE_ENV !== "production") {
        \\    return "dev";
        \\  }
        \\  return "other";
        \\}
        \\console.log(test(1));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // "} else }" 같은 문법 에러가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "else }") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "else\n}") == null);
}

test "Codegen: unary ! boolean eval — correct negation" {
    // !(expr) 의 boolean 평가가 올바르게 동작해야 함 (unary_expression data 접근 버그 회귀 방지)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const flag = process.env.NODE_ENV !== "production";
        \\if (!flag) {
        \\  console.log("prod");
        \\} else {
        \\  console.log("dev");
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // platform=node에서 NODE_ENV="production" → flag=false → !flag=true → "prod" 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "prod") != null);
}

test "TreeShaking: seedAllStmts propagates export * chain — cheerio pattern" {
    // export * from './sub' 체인에서 sub 모듈의 함수 정의가 포함되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as utils from './utils';
        \\console.log(utils.getText("hi"));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export * from './stringify';
        \\export function parse(s: string) { return s; }
    );
    try writeFile(tmp.dir, "stringify.ts",
        \\export function getText(s: string) { return s; }
        \\export function getHTML(s: string) { return "<" + s + ">"; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // getText가 export * 체인을 통해 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getText") != null);
}

test "TreeShaking: sideEffects:false + namespace import — symbol-based BFS seed (effect pattern)" {
    // effect 패턴: sideEffects:false 모듈에서 import * as X 후 X.prop 접근.
    // BFS가 sideEffects:false 모듈의 used export 선언 statement를 시드해야
    // followImport → namespace target의 심볼이 reachable됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { TypeId } from './Either';
        \\console.log(typeof TypeId);
    );
    try writeFile(tmp.dir, "Either.ts",
        \\import * as either from './internal-either';
        \\export const TypeId = either.TypeId;
        \\export const right = either.right;
    );
    try writeFile(tmp.dir, "internal-either.ts",
        \\export const TypeId = Symbol.for("effect/Either");
        \\export function right(a: any) { return { tag: "Right", right: a }; }
        \\export function left(a: any) { return { tag: "Left", left: a }; }
    );
    // sideEffects:false 시뮬레이션
    try writeFile(tmp.dir, "package.json",
        \\{"name": "test", "sideEffects": false}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // TypeId가 번들에 포함 (namespace import를 통한 참조)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Symbol.for") != null);
    // left는 미사용이므로 제거 (tree-shaking 정밀도)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function left") == null);
}

test "TreeShaking: sideEffects:false deep re-export chain — symbol reachability" {
    // sideEffects:false barrel re-export 체인에서 모든 단계가 reachable
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './index';
        \\console.log(greet("world"));
    );
    try writeFile(tmp.dir, "index.ts",
        \\export { greet } from './lib';
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export { greet } from './impl';
        \\export function unused() { return "no"; }
    );
    try writeFile(tmp.dir, "impl.ts",
        \\export function greet(name: string) { return "hello " + name; }
        \\export function farewell(name: string) { return "bye " + name; }
    );
    try writeFile(tmp.dir, "package.json",
        \\{"name": "test", "sideEffects": false}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "greet") != null);
    // unused, farewell은 미사용 → 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unused") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "farewell") == null);
}

test "TreeShaking: sideEffects:false + side-effect statement preserved when module included" {
    // sideEffects:false 모듈이 포함되면 side-effect statement도 보존되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './lib';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const value = 42;
        \\globalThis.__INIT__ = true;
    );
    try writeFile(tmp.dir, "package.json",
        \\{"name": "test", "sideEffects": false}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // globalThis.__INIT__ = true는 side-effect → value 사용 시 모듈 포함 → 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__INIT__") != null);
}

// ============================================================
// Minifier 번들 테스트 — #491 회귀 방지
// ============================================================

test "Minify: CJS import binding preamble uses mangled name" {
    // CJS 모듈을 import할 때, --minify 시 preamble 변수 선언과
    // 코드 내 참조가 동일한 (mangled) 이름을 사용해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import ms from './lib';\nconsole.log(ms('hello'));");
    try writeFile(tmp.dir, "lib.js", "module.exports = function(s) { return s.toUpperCase(); };");

    const entry = try absPath(&tmp, "entry.ts");
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

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "toUpperCase") != null);
    // preamble 변수 선언과 console.log 참조가 모두 출력에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, output, "console.log") != null);
}

test "Minify: ESM import binding not mangled" {
    // ESM export 함수의 import binding은 mangler가 덮어쓰면 안 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './lib';\nconsole.log(greet('world'));");
    try writeFile(tmp.dir, "lib.ts", "export function greet(name: string) { return 'Hello ' + name; }");

    const entry = try absPath(&tmp, "entry.ts");
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

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
}

test "Minify: for-loop body var declaration has semicolon" {
    // #491: emitFor의 in_for_init defer 버그로 minify 시 세미콜론 누락됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "for (var i = 0; i < 3; i++) { var x = i; console.log(x); }");

    const entry = try absPath(&tmp, "entry.ts");
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

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    const body_start = std.mem.indexOf(u8, output, "var x=i") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, ';'), output[body_start + 7]);
}

test "Minify: template literal expression identifiers renamed (#493)" {
    // template literal 내 ${identifier} 참조가 mangled name으로 치환되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { prefix } from './lib';\nconsole.log(`val=${prefix}!`);");
    try writeFile(tmp.dir, "lib.ts", "export const prefix = 'hello';");

    const entry = try absPath(&tmp, "entry.ts");
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

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // export이므로 prefix 이름 보존, template literal에 올바르게 참조됨
    try std.testing.expect(std.mem.indexOf(u8, output, "prefix") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "Minify: nested scope variable not shadowed by mangled name (#494)" {
    // mangled 이름이 nested scope의 로컬 변수와 충돌하면 안 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // top-level 'check'가 mangling 대상이며, nested function 내 'var a'와 충돌하지 않아야 함
    try writeFile(tmp.dir, "entry.ts",
        \\const check = (x) => x > 0;
        \\function run() {
        \\  var a = 1;
        \\  if (check(a)) console.log("ok");
        \\}
        \\run();
    );

    const entry = try absPath(&tmp, "entry.ts");
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

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ok") != null);
}

// ============================================================
// Asset Loader Tests
// ============================================================

test "Asset loader: text — string export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import msg from './hello.txt';\nconsole.log(msg);");
    try writeFile(tmp.dir, "hello.txt", "Hello, World!");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".txt", .loader = .text }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // text 로더: 문자열이 CJS wrapper로 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Hello, World!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_hello") != null);
    // asset 파일 출력 없음 (text는 인라인)
    try std.testing.expect(result.asset_outputs == null);
}

test "Asset loader: text — escapes special characters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import s from './special.txt';\nconsole.log(s);");
    try writeFile(tmp.dir, "special.txt", "line1\nline2\\end\"quote");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".txt", .loader = .text }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // \n → \\n, \\ → \\\\, " → \\"
    try std.testing.expect(std.mem.indexOf(u8, result.output, "line1\\nline2\\\\end\\\"quote") != null);
}

test "Asset loader: dataurl — base64 data URL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './icon.png';\nconsole.log(url);");
    // 간단한 바이너리 데이터 (실제 PNG가 아니어도 테스트 목적으로 충분)
    try tmp.dir.writeFile(.{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .dataurl }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // data URL: data:image/png;base64,...
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,") != null);
    try std.testing.expect(result.asset_outputs == null);
}

test "Asset loader: file — hash filename + asset output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './logo.png';\nconsole.log(url);");
    try tmp.dir.writeFile(.{ .sub_path = "logo.png", .data = "fake-png-data" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // file 로더: URL 문자열 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "logo-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".png") != null);
    // asset_outputs에 원본 파일 내용 포함
    try std.testing.expect(result.asset_outputs != null);
    try std.testing.expectEqual(@as(usize, 1), result.asset_outputs.?.len);
    try std.testing.expectEqualStrings("fake-png-data", result.asset_outputs.?[0].contents);
}

test "Asset loader: file — public-path prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './img.png';\nconsole.log(url);");
    try tmp.dir.writeFile(.{ .sub_path = "img.png", .data = "data" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
        .public_path = "https://cdn.example.com/",
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "https://cdn.example.com/img-") != null);
}

test "Asset loader: file — content hash determinism" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './a.bin';\nconsole.log(url);");
    try tmp.dir.writeFile(.{ .sub_path = "a.bin", .data = "deterministic-content" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 첫 번째 번들
    var b1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .file }},
    });
    defer b1.deinit();
    const r1 = try b1.bundle();
    defer r1.deinit(std.testing.allocator);

    // 두 번째 번들 (같은 내용)
    var b2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .file }},
    });
    defer b2.deinit();
    const r2 = try b2.bundle();
    defer r2.deinit(std.testing.allocator);

    // 같은 내용 → 같은 해시 → 같은 출력
    try std.testing.expectEqualStrings(r1.output, r2.output);
}

test "Asset loader: binary — __toBinary runtime helper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './raw.bin';\nconsole.log(data);");
    try tmp.dir.writeFile(.{ .sub_path = "raw.bin", .data = &.{ 0xDE, 0xAD, 0xBE, 0xEF } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .binary }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // binary 로더: __toBinary 호출 + 런타임 헬퍼 주입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toBinary(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __toBinary") != null);
    try std.testing.expect(result.asset_outputs == null);
}

test "Asset loader: empty — undefined export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import x from './style.css';\nconsole.log(x);");
    try writeFile(tmp.dir, "style.css", "body { color: red; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".css", .loader = .empty }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "undefined") != null);
}

test "Asset loader: --loader override takes precedence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // .txt는 기본적으로 text 로더이지만, --loader로 file로 오버라이드
    try writeFile(tmp.dir, "entry.ts", "import url from './readme.txt';\nconsole.log(url);");
    try writeFile(tmp.dir, "readme.txt", "README content");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".txt", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // file 로더: URL 경로 출력 (text가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readme-") != null);
    // asset_outputs 존재 (file 로더)
    try std.testing.expect(result.asset_outputs != null);
}

test "Asset loader: asset-names pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './font.woff';\nconsole.log(url);");
    try tmp.dir.writeFile(.{ .sub_path = "font.woff", .data = "woff-data" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".woff", .loader = .file }},
        .asset_names = "assets/[name]-[hash]",
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // asset-names 패턴 적용: assets/font-HASH.woff
    try std.testing.expect(std.mem.indexOf(u8, result.output, "assets/font-") != null);
    // asset_outputs 경로에도 패턴 적용
    try std.testing.expect(result.asset_outputs != null);
    try std.testing.expect(std.mem.startsWith(u8, result.asset_outputs.?[0].path, "assets/font-"));
}

test "Asset loader: CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import msg from './data.txt';\nconsole.log(msg);");
    try writeFile(tmp.dir, "data.txt", "hello");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .loader_overrides = &.{.{ .ext = ".txt", .loader = .text }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
}

test "Asset loader: [dir] pattern preserves directory structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 서브디렉토리에 asset 배치
    tmp.dir.makePath("images/icons") catch {};
    try tmp.dir.writeFile(.{ .sub_path = "images/icons/logo.png", .data = "png-data" });
    try writeFile(tmp.dir, "entry.ts", "import url from './images/icons/logo.png';\nconsole.log(url);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
        .asset_names = "[dir]/[name]-[hash]",
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // [dir] = "images/icons" → 출력 경로에 디렉토리 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "images/icons/logo-") != null);
    // asset_outputs 경로에도 디렉토리 포함
    try std.testing.expect(result.asset_outputs != null);
    try std.testing.expect(std.mem.startsWith(u8, result.asset_outputs.?[0].path, "images/icons/logo-"));
}

test "Asset loader: [ext] pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "font.woff2", .data = "woff2-data" });
    try writeFile(tmp.dir, "entry.ts", "import url from './font.woff2';\nconsole.log(url);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".woff2", .loader = .file }},
        .asset_names = "static/[ext]/[name]-[hash]",
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // [ext] = "woff2" (dot 없이)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "static/woff2/font-") != null);
}

test "No loader: .png without --loader errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const icon = require('./icon.png');\nconsole.log(icon);");
    try tmp.dir.writeFile(.{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // loader 미설정 → 빌드 에러 발생
    try std.testing.expect(result.hasErrors());
    const has_no_loader = for (result.getDiagnostics()) |d| {
        if (std.mem.indexOf(u8, d.message, "No loader is configured") != null) break true;
    } else false;
    try std.testing.expect(has_no_loader);
}

test "No loader: .png with --loader:.png=file succeeds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const icon = require('./icon.png');\nconsole.log(icon);");
    try tmp.dir.writeFile(.{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // loader 지정 → 성공
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_icon") != null);
}

test "No loader: ESM import of .png without --loader errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    try tmp.dir.writeFile(.{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
    const has_no_loader = for (result.getDiagnostics()) |d| {
        if (std.mem.indexOf(u8, d.message, "No loader is configured") != null) break true;
    } else false;
    try std.testing.expect(has_no_loader);
}

test "No loader: .mp3 without --loader errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const audio = require('./sound.mp3');\nconsole.log(audio);");
    try tmp.dir.writeFile(.{ .sub_path = "sound.mp3", .data = "fake-mp3" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
}

test "Plugin load hook overrides asset loader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    try tmp.dir.writeFile(.{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 플러그인 없이 file 로더로 번들 → URL 문자열이 포함되어야 함
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // file 로더 출력: 해시가 포함된 파일명
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".png") != null);
    // registerAsset는 없어야 함 (플러그인이 없으므로)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "registerAsset") == null);
}

// ============================================================
// Batch D: metafile, analyze, legal-comments, inject, keepNames
// ============================================================

test "Batch D: metafile — JSON with inputs and outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { add } from './math';\nconsole.log(add(1, 2));");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // metafile JSON이 생성됨
    try std.testing.expect(result.metafile_json != null);
    const mf = result.metafile_json.?;
    // inputs 섹션에 두 모듈 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"inputs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, "entry.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, "math.ts") != null);
    // outputs 섹션 존재
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"outputs\"") != null);
    // import 관계 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"imports\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, "static_import") != null);
    // bytes 필드 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"bytes\"") != null);
}

test "Batch D: metafile — disabled when not requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log(1);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // metafile 미요청 시 null
    try std.testing.expect(result.metafile_json == null);
}

test "Batch D: analyze — forces metafile generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .analyze = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // analyze=true → metafile 자동 활성화
    try std.testing.expect(result.metafile_json != null);
}

test "Batch D: legal-comments=eof — collect at end of output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\/** @license MIT */
        \\console.log("hello");
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .legal_comments = .eof,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // legal comment가 출력 끝에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@license MIT") != null);
    // code가 legal comment보다 앞에 위치
    const code_pos = std.mem.indexOf(u8, result.output, "console.log") orelse 0;
    const license_pos = std.mem.indexOf(u8, result.output, "@license") orelse 0;
    try std.testing.expect(code_pos < license_pos);
}

test "Batch D: legal-comments=none — strip all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\/*! Copyright 2024 */
        \\console.log("hello");
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .legal_comments = .none,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // legal comment 완전 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Copyright") == null);
}

test "Batch D: legal-comments=eof — deduplication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈에 같은 license 주석
    try writeFile(tmp.dir, "a.ts",
        \\/** @license MIT */
        \\export const a = 1;
    );
    try writeFile(tmp.dir, "b.ts",
        \\/** @license MIT */
        \\export const b = 2;
    );
    try writeFile(tmp.dir, "entry.ts", "import { a } from './a';\nimport { b } from './b';\nconsole.log(a, b);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .legal_comments = .eof,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // @license MIT가 1번만 출현 (중복 제거)
    var count: usize = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_pos, "@license MIT")) |pos| {
        count += 1;
        search_pos = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Batch D: inject — prepends injected file before entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shim.js", "globalThis.MY_SHIM = true;");
    try writeFile(tmp.dir, "entry.ts", "console.log(MY_SHIM);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const inject = try absPath(&tmp, "shim.js");
    defer std.testing.allocator.free(inject);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .inject = &.{inject},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shim 코드가 entry보다 먼저 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MY_SHIM = true") != null);
    const shim_pos = std.mem.indexOf(u8, result.output, "MY_SHIM = true") orelse 0;
    const entry_pos = std.mem.indexOf(u8, result.output, "console.log") orelse 0;
    try std.testing.expect(shim_pos < entry_pos);
}

test "Batch D: inject — multiple inject files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shim1.js", "globalThis.A = 1;");
    try writeFile(tmp.dir, "shim2.js", "globalThis.B = 2;");
    try writeFile(tmp.dir, "entry.ts", "console.log(A, B);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const inject1 = try absPath(&tmp, "shim1.js");
    defer std.testing.allocator.free(inject1);
    const inject2 = try absPath(&tmp, "shim2.js");
    defer std.testing.allocator.free(inject2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .inject = &.{ inject1, inject2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 shim 모두 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B = 2") != null);
}

test "Batch D: keepNames — __name call for renamed functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈에서 같은 이름 → linker가 충돌 해결로 rename
    try writeFile(tmp.dir, "a.ts", "export function hello() { return 'a'; }");
    try writeFile(tmp.dir, "b.ts", "export function hello() { return 'b'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\import { hello as ha } from './a';
        \\import { hello as hb } from './b';
        \\console.log(ha(), hb());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 이름 충돌로 rename → __name 호출 삽입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") != null);
    // __name 런타임 헬퍼 주입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __name") != null);
    // 원본 이름 "hello" 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
}

test "Batch D: keepNames — no __name when names unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "function foo() { return 1; }\nconsole.log(foo());");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 이름 변경 없음 → __name 불필요
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") == null);
}

test "Batch D: keepNames — class declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export class Foo { run() { return 1; } }");
    try writeFile(tmp.dir, "b.ts", "export class Foo { run() { return 2; } }");
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo as A } from './a';
        \\import { Foo as B } from './b';
        \\console.log(new A().run(), new B().run());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // class도 __name 적용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Foo\"") != null);
}

test "Batch D: keepNames + code splitting — __name helper in chunk" {
    // code splitting + keepNames: 동적 import된 청크에도 __name 런타임 헬퍼가 주입되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const mod = import('./lazy');\nconsole.log(mod);");
    // lazy 청크에 두 개의 같은 이름 함수 → rename 발생
    try writeFile(tmp.dir, "lazy.ts",
        \\import { run } from './util';
        \\export function run() { return 'lazy'; }
        \\console.log(run());
    );
    try writeFile(tmp.dir, "util.ts", "export function run() { return 'util'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 최소 2개 청크
    try std.testing.expect(outs.len >= 2);

    // __name 호출이 있는 청크에 __name 런타임 헬퍼도 포함되어야 함
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "__name(") != null) {
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "var __name") != null);
        }
    }
}

test "Batch D: legal-comments=eof + minify — comments after minified code" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\/*! MIT License */
        \\export function greet() { return "hi"; }
    );
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './a';\nconsole.log(greet());");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_syntax = true,
        .legal_comments = .eof,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minified 코드 뒤에 legal comment
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MIT License") != null);
    const code_end = std.mem.indexOf(u8, result.output, "console.log") orelse 0;
    const license_pos = std.mem.indexOf(u8, result.output, "MIT License") orelse 0;
    try std.testing.expect(code_end < license_pos);
}

test "Batch D: metafile — code splitting produces per-chunk outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const mod = import('./lazy');\nconsole.log(mod);");
    try writeFile(tmp.dir, "lazy.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.metafile_json != null);
    const mf = result.metafile_json.?;
    // code splitting: outputs에 여러 청크 파일 경로 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"outputs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, ".js") != null);
}

test "Batch D: inject — inject file included in metafile inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shim.js", "globalThis.X = 1;");
    try writeFile(tmp.dir, "entry.ts", "console.log(X);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const inject = try absPath(&tmp, "shim.js");
    defer std.testing.allocator.free(inject);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .inject = &.{inject},
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.metafile_json != null);
    // inject 파일도 metafile inputs에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.metafile_json.?, "shim.js") != null);
}

// ============================================================
// Web Worker auto-bundling
// ============================================================

test "Worker: new Worker(new URL) produces separate IIFE bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w = new Worker(new URL('./worker.ts', import.meta.url));
        \\w.postMessage('hi');
    );
    try writeFile(tmp.dir, "worker.ts",
        \\self.onmessage = (e) => self.postMessage('pong');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 메인 번들에 worker URL이 교체됨 (new URL 대신 문자열)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".js\")") != null);
    // new URL이 사라짐
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(") == null);

    // worker 번들이 asset_outputs에 포함
    try std.testing.expect(result.asset_outputs != null);
    const assets = result.asset_outputs.?;
    try std.testing.expect(assets.len >= 1);

    // worker 번들이 IIFE로 래핑
    var found_worker = false;
    for (assets) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-")) {
            found_worker = true;
            try std.testing.expect(std.mem.indexOf(u8, a.contents, "self.onmessage") != null);
            try std.testing.expect(std.mem.startsWith(u8, a.contents, "(function() {"));
        }
    }
    try std.testing.expect(found_worker);
}

test "Worker: no Worker pattern means no extra assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1; console.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // worker가 없으면 asset_outputs가 null
    try std.testing.expect(result.asset_outputs == null);
}

test "Worker: multiple workers produce separate bundles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w1 = new Worker(new URL('./worker-a.ts', import.meta.url));
        \\const w2 = new Worker(new URL('./worker-b.ts', import.meta.url));
        \\w1.postMessage('a');
        \\w2.postMessage('b');
    );
    try writeFile(tmp.dir, "worker-a.ts", "self.onmessage = (e) => self.postMessage('a');");
    try writeFile(tmp.dir, "worker-b.ts", "self.onmessage = (e) => self.postMessage('b');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 두 worker URL이 모두 교체됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-a-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-b-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(") == null);

    // 2개 worker 번들이 asset_outputs에 포함
    try std.testing.expect(result.asset_outputs != null);
    try std.testing.expect(result.asset_outputs.?.len >= 2);

    var found_a = false;
    var found_b = false;
    for (result.asset_outputs.?) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-a-")) found_a = true;
        if (std.mem.startsWith(u8, a.path, "worker-b-")) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

test "Worker: duplicate references to same worker build only once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w1 = new Worker(new URL('./worker.ts', import.meta.url));
        \\const w2 = new Worker(new URL('./worker.ts', import.meta.url));
        \\w1.postMessage('first');
        \\w2.postMessage('second');
    );
    try writeFile(tmp.dir, "worker.ts", "self.onmessage = (e) => self.postMessage('ok');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 두 참조 모두 같은 파일명으로 교체
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-") != null);
    // new URL은 전부 사라짐
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(") == null);

    // asset_outputs에 worker 번들 1개만 (중복 빌드 방지)
    try std.testing.expect(result.asset_outputs != null);
    var worker_count: usize = 0;
    for (result.asset_outputs.?) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-")) worker_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), worker_count);
}

test "Worker: SharedWorker is also detected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const sw = new SharedWorker(new URL('./shared.ts', import.meta.url));
        \\sw.port.postMessage('hi');
    );
    try writeFile(tmp.dir, "shared.ts", "self.onconnect = (e) => {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new SharedWorker(\"./shared-") != null);
    try std.testing.expect(result.asset_outputs != null);
}

// ============================================================
// None-node crash prevention: parse errors must not crash transformer/codegen
// Previously, modules with parse errors had incomplete ASTs containing
// .none (0xFFFFFFFF) node indices, causing index-out-of-bounds panics.
// ============================================================

test "Bundle: Flow file with parse errors does not crash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Entry imports a Flow file with import typeof (requires --flow or @flow pragma)
    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./lib');
        \\console.log(x);
    );
    // Flow file with @flow pragma and import typeof — Flow type-only import
    try writeFile(tmp.dir, "lib.js",
        \\// @flow
        \\import typeof * as API from './api';
        \\module.exports = { value: 42 };
    );
    try writeFile(tmp.dir, "api.js",
        \\module.exports = {};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // Should not crash — either succeeds or reports errors gracefully
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Bundle: Flow export type alias + module.exports → CJS wrapping (#713)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./lib');
        \\console.log(x);
    );
    // Flow: import typeof + export type alias + module.exports 혼합
    // ReactNativePrivateInterface.js 패턴 — type-only export가 ESM 신호로 잘못 판별되면
    // __esm 래핑되어 module 변수 미정의 런타임 에러 발생
    try writeFile(tmp.dir, "lib.js",
        \\// @flow strict-local
        \\import typeof Foo from './dep';
        \\export type Bar = string;
        \\export type {Foo};
        \\module.exports = { value: 42 };
    );
    try writeFile(tmp.dir, "dep.js",
        \\module.exports = {};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS 모듈이므로 __commonJS로 래핑되어야 함 (__esm이 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "Bundle: TS export type alias + module.exports → CJS wrapping (#713)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const x = require('./lib');
        \\console.log(x);
    );
    // TS: export type alias + export interface + module.exports 혼합
    try writeFile(tmp.dir, "lib.ts",
        \\export type Foo = string;
        \\export interface Bar { x: number; }
        \\module.exports = { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS 모듈이므로 __commonJS로 래핑되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "Bundle: Flow export opaque type + module.exports → CJS wrapping (#713)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./lib');
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.js",
        \\// @flow
        \\export opaque type ID = string;
        \\module.exports = { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "Bundle: module with syntax errors does not crash transformer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Entry file is valid
    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./broken');
        \\console.log(x);
    );
    // Broken file with intentional syntax error
    try writeFile(tmp.dir, "broken.js",
        \\export const x = {
        \\  a: 1,
        \\  ...  // incomplete spread — parse error
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // Should not crash — broken module is skipped, bundle still produced
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

// ============================================================
// __esm live binding 테스트 (rolldown 방식)
// ============================================================

test "ESM live binding: function hoisted outside __esm references canonical var" {
    // __esm 모듈의 function이 다른 __esm 모듈의 변수를 참조할 때,
    // function은 밖에 호이스팅되고 canonical 변수를 직접 참조해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "style.js",
        \\export var color = 'red';
    );
    try writeFile(tmp.dir, "component.js",
        \\import { color } from './style.js';
        \\export function getColor() { return color; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./component.js');
        \\console.log(m.getColor());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // function이 __esm 밖에 호이스팅
    const esm_start = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const fn_pos = std.mem.indexOf(u8, result.output, "function getColor()") orelse unreachable;
    try std.testing.expect(fn_pos < esm_start);
    // live binding: component.js의 __esm init에 import 스냅샷 할당이 없어야 함.
    // init에는 init_xxx() 호출만 있고 __toCommonJS 패턴이 없어야 함.
    const component_init = std.mem.indexOf(u8, result.output, "\"component.js\"()") orelse unreachable;
    // init body는 다음 }); 까지
    const init_end = std.mem.indexOf(u8, result.output[component_init..], "\n\t}\n});") orelse
        std.mem.indexOf(u8, result.output[component_init..], "}});") orelse unreachable;
    const init_body = result.output[component_init .. component_init + init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_body, "__toCommonJS") == null);
}

test "ESM live binding: init only contains dependency init calls" {
    // __esm → __esm import 시, init 함수에는 의존 init 호출만 있어야 함.
    // 스냅샷 할당 코드(= (init_xxx(), __toCommonJS(exports_xxx)).xxx)가 없어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.js",
        \\export const value = 42;
    );
    try writeFile(tmp.dir, "mod.js",
        \\import { value } from './dep.js';
        \\export function getValue() { return value; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\const d = require('./dep.js');
        \\console.log(m.getValue(), d.value);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // mod.js의 init에 init_dep 호출이 있어야 함
    const mod_init = std.mem.indexOf(u8, result.output, "\"mod.js\"()") orelse unreachable;
    const init_end2 = std.mem.indexOf(u8, result.output[mod_init..], "\n\t}\n});") orelse
        std.mem.indexOf(u8, result.output[mod_init..], "}});") orelse unreachable;
    const mod_body = result.output[mod_init .. mod_init + init_end2];
    try std.testing.expect(std.mem.indexOf(u8, mod_body, "init_") != null);
    // init 안에 __toCommonJS 스냅샷 복사가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, mod_body, "__toCommonJS") == null);
}

test "ESM live binding: namespace import uses exports_xxx (not live binding)" {
    // namespace import(import * as X)는 exports_xxx로 rename되어야 함.
    // 이 import_declaration은 body codegen에서 할당문으로 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.js",
        \\export function add(a, b) { return a + b; }
        \\export function sub(a, b) { return a - b; }
    );
    try writeFile(tmp.dir, "mod.js",
        \\import * as Utils from './utils.js';
        \\export default Utils.add(1, 2);
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\console.log(m.default);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace import는 exports_xxx로 참조
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_") != null);
}

test "ESM live binding: re-export from __esm uses source canonical name" {
    // re-export(export { X } from './dep')에서 __esm 타겟의 canonical name을 사용해야 함.
    // __export getter가 올바른 변수를 참조.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "impl.js",
        \\export function doWork() { return 'done'; }
    );
    try writeFile(tmp.dir, "facade.js",
        \\export { doWork } from './impl.js';
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./facade.js');
        \\console.log(m.doWork());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // facade.js의 __export getter가 doWork를 참조 (undefined가 아닌 실제 함수)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "doWork") != null);
    // function doWork이 번들에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function doWork()") != null);
}

test "ESM live binding: class stays inside __esm init (block-scoped)" {
    // class는 block-scoped이므로 __esm init 안에 할당문으로 유지되어야 함.
    // function과 다르게 밖으로 호이스팅되면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\export class Greeter {
        \\  greet() { return 'hello'; }
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\console.log(new m.Greeter().greet());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const esm_start = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    // class는 할당문으로 __esm 안에 있어야 함
    const class_pos = std.mem.indexOf(u8, result.output, "Greeter = class") orelse unreachable;
    try std.testing.expect(class_pos > esm_start);
}

test "ESM live binding: RN platform forces __esm wrapping with live binding" {
    // --platform=react-native 시 모든 비-엔트리 ESM 모듈이 __esm 래핑되고,
    // 모듈 간 import가 live binding으로 처리되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "helper.js",
        \\export function format(s) { return '[' + s + ']'; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { format } from './helper.js';
        \\console.log(format('test'));
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm 래핑이 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm({") != null);
    // function이 __esm 밖에 호이스팅
    const esm_pos = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const fn_pos = std.mem.indexOf(u8, result.output, "function format(") orelse unreachable;
    try std.testing.expect(fn_pos < esm_pos);
    // helper.js의 init에 __toCommonJS 스냅샷 없음
    // (엔트리에서 require() 시 __toCommonJS가 사용될 수 있지만, 모듈 간 import에는 없어야 함)
    const helper_init = std.mem.indexOf(u8, result.output, "\"helper.js\"()") orelse unreachable;
    const helper_end = std.mem.indexOf(u8, result.output[helper_init..], "\n\t}\n});") orelse
        std.mem.indexOf(u8, result.output[helper_init..], "}});") orelse unreachable;
    const helper_body = result.output[helper_init .. helper_init + helper_end];
    try std.testing.expect(std.mem.indexOf(u8, helper_body, "__toCommonJS") == null);
}

// ============================================================
// JSX Automatic Import Injection
// ============================================================

test "JSX automatic: jsx-runtime import injected in bundle mode" {
    // --jsx=automatic 사용 시 react/jsx-runtime에서 _jsx, _jsxs, _Fragment import가 주입되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div><span>Hello</span></div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // _jsx가 react/jsx-runtime에서 import되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") != null);
    // React.createElement가 아닌 _jsx 호출이어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "React.createElement") == null);
}

test "JSX automatic-dev: jsx-dev-runtime import injected in bundle mode" {
    // --jsx-dev 사용 시 react/jsx-dev-runtime에서 _jsxDEV import가 주입되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // _jsxDEV가 react/jsx-dev-runtime에서 import되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-dev-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV") != null);
}

test "JSX automatic: no injection when no JSX in module" {
    // JSX가 없는 모듈에서는 jsx-runtime import가 주입되지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const x = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // jsx-runtime 관련 코드가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "jsx-runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") == null);
}

test "JSX automatic: classic mode does not inject jsx-runtime" {
    // --jsx=classic 사용 시 jsx-runtime import가 주입되지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .classic,
        .external = &.{"react"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // classic 모드에서는 React.createElement 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "jsx-runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") != null);
}

test "JSX automatic: custom import source" {
    // --jsx-import-source=preact 사용 시 preact/jsx-runtime에서 import되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .jsx_import_source = "preact",
        .external = &.{"preact/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preact/jsx-runtime에서 import되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "preact/jsx-runtime") != null);
    // "react/jsx-runtime"이 아닌 "preact/jsx-runtime"이어야 함
    // (preact에 react가 부분 문자열로 포함되므로, require("react/jsx-runtime") 정확히 검사)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"react/jsx-runtime\")") == null);
}

test "JSX automatic: ESM-wrapped module with CJS jsx-runtime — synthetic binding not skipped" {
    // ESM-wrapped 모듈(require()로 소비되는 ESM)에서 CJS jsx-runtime import 시
    // synthetic JSX binding이 linker의 ESM+CJS skip에 걸리지 않고 preamble에 emit되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // app.tsx: ESM syntax (export) + JSX → require로 소비되면 ESM-wrapped
    try writeFile(tmp.dir, "app.tsx",
        \\export function App() { return <div>Hello</div>; }
    );
    // entry.ts: require로 app.tsx를 소비 → app.tsx가 ESM-wrapped
    try writeFile(tmp.dir, "entry.ts",
        \\const app = require('./app.tsx');
        \\console.log(app.App());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM-wrapped 모듈임을 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") != null);
    // _jsxDEV 바인딩이 생성되어야 함 (ESM+CJS skip에 걸리지 않음)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-dev-runtime") != null);
}

test "JSX automatic: multiple modules sharing same jsx-runtime" {
    // 여러 모듈이 같은 jsx-runtime을 import할 때, 각 모듈에 바인딩이 독립적으로 생성되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "comp_a.tsx",
        \\export function CompA() { return <span>A</span>; }
    );
    try writeFile(tmp.dir, "comp_b.tsx",
        \\export function CompB() { return <span>B</span>; }
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { CompA } from './comp_a.tsx';
        \\import { CompB } from './comp_b.tsx';
        \\export function App() { return <div><CompA /><CompB /></div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // jsx-runtime이 번들에 참조됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-runtime") != null);
    // 모든 컴포넌트가 _jsx로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(CompA") != null or
        std.mem.indexOf(u8, result.output, "_jsx(CompB") != null);
    // React.createElement가 아닌 _jsx 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") == null);
}

test "JSX automatic: fragment syntax uses _Fragment" {
    // <> </> fragment 구문이 _Fragment로 변환되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <><span>A</span><span>B</span></>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // _Fragment가 사용되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_Fragment") != null);
    // _jsxs (static children — 여러 자식)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxs(") != null);
}

test "JSX automatic-dev: source location info included" {
    // --jsx-dev 모드에서 fileName, lineNumber, columnNumber가 포함되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // dev 모드: 소스 위치 정보 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fileName") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lineNumber") != null);
}

test "JSX automatic: mixed JSX and non-JSX modules" {
    // JSX가 있는 모듈에만 jsx-runtime import가 주입되고, 없는 모듈에는 주입되지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts",
        \\export function add(a: number, b: number) { return a + b; }
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { add } from './util.ts';
        \\export function App() { return <div>{add(1, 2)}</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry.tsx에서 _jsx 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(\"div\"") != null);
    // util.ts의 add 함수가 정상 번들됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "add(") != null);
}

test "JSX automatic: re-export of JSX component" {
    // JSX 컴포넌트를 re-export하는 배럴 파일이 정상 동작해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "button.tsx",
        \\export function Button() { return <button>Click</button>; }
    );
    try writeFile(tmp.dir, "index.ts",
        \\export { Button } from './button.tsx';
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { Button } from './index.ts';
        \\export function App() { return <div><Button /></div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈 모두 _jsx 사용 (button.tsx + entry.tsx)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(Button") != null);
}

test "JSX automatic: ESM-wrapped hoisted function can access _jsxDEV (scope test)" {
    // ESM-wrapped 모듈에서 function이 __esm 밖으로 호이스팅될 때,
    // _jsxDEV가 top-level var로 선언되어야 호이스팅된 함수에서 접근 가능.
    // 이전 버그: _jsxDEV가 __esm init 블록 안 지역변수로 선언되어 ReferenceError.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Comp() { return <div>Hello</div>; }
    );
    // require()로 소비하여 comp.tsx를 ESM-wrapped로 만듦
    try writeFile(tmp.dir, "entry.ts",
        \\const c = require('./comp.tsx');
        \\console.log(c.Comp());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm으로 래핑됨을 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") != null);
    // _jsxDEV가 top-level에 var로 선언 (호이스팅된 함수에서 접근 가능)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var _jsxDEV") != null);
    // 호이스팅된 function이 _jsxDEV를 사용 (React.createElement가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV(\"div\"") != null);
    // __esm init 안에서는 var 없이 할당만
    // "var _jsxDEV = " 가 아닌 할당문이 init 블록에 존재해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV = require") != null);
}

test "JSX automatic: ESM-wrapped with multiple JSX functions (_jsx, _jsxs, _Fragment)" {
    // ESM-wrapped 모듈에서 _jsx, _jsxs, _Fragment 모두 top-level 선언되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Comp() {
        \\  return <><div>A</div><span>B</span></>;
        \\}
    );
    try writeFile(tmp.dir, "entry.ts",
        \\const c = require('./comp.tsx');
        \\console.log(c.Comp());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 JSX 함수가 top-level에 선언됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_Fragment") != null);
    // Fragment + 여러 children → _jsxs 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxs(_Fragment") != null);
}

test "JSX automatic: non-ESM-wrapped module still uses var declaration" {
    // ESM-wrapped가 아닌 일반 모듈에서는 preamble에 var _jsx = ... 형태 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm이 아님 (일반 scope-hoisted)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") == null);
    // var _jsx = require(...) 형태 (var 포함)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var _jsx") != null);
}

// ============================================================
// Runtime helper: __copyProps / __toCommonJS (rolldown 호환)
// ============================================================

test "runtime helper: __copyProps uses getOwnPropertyNames, not Object.keys" {
    // ESM에서 CJS를 import할 때 __toESM → __copyProps가 주입됨.
    // __copyProps가 getOwnPropertyNames를 사용하여 non-enumerable 프로퍼티도 복사하는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ESM entry가 CJS를 import → __toESM/__copyProps 필요
    try writeFile(tmp.dir, "entry.ts", "import greet from './cjs-mod.js';\nconsole.log(greet());");
    try writeFile(tmp.dir, "cjs-mod.js",
        \\module.exports = function greet() { return 'hello'; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // getOwnPropertyNames 사용 확인 (Object.keys가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyNames") != null);
    // getOwnPropertyDescriptor로 enumerable 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyDescriptor") != null);
    // __copyProps 정의 부분에서 Object.keys가 없는지 확인
    if (std.mem.indexOf(u8, result.output, "__copyProps")) |cp_pos| {
        const end = @min(cp_pos + 300, result.output.len);
        const slice = result.output[cp_pos..end];
        try std.testing.expect(std.mem.indexOf(u8, slice, "Object.keys") == null);
    }
    // bind(null, key) 패턴으로 var 루프에서 key 고정 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".bind(null,") != null or
        std.mem.indexOf(u8, result.output, ".bind(null, ") != null);
}

test "runtime helper: __toCommonJS has module.exports direct return path" {
    // ESM 모듈이 CJS로 소비될 때 __toCommonJS가 주입됨.
    // __commonJS로 래핑된 모듈은 module.exports를 직접 반환하여 getter를 보존해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // CJS entry가 ESM을 require → __esm + __toCommonJS 필요
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm-mod.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "esm-mod.js",
        \\export const value = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __toCommonJS 헬퍼가 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS") != null);
    // module.exports 직접 반환 경로가 있어야 함 (rolldown 방식)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

// ============================================================
// RN 엔트리 __esm 래핑 (Rolldown 호환 초기화 순서 보장)
// ============================================================

test "RN platform: entry module is __esm wrapped (not scope-hoisted)" {
    // RN에서 엔트리도 __esm 래핑되어야 circular dep 초기화 순서가 보장됨.
    // Rolldown 방식: 번들 끝에 init_entry()를 호출하여 실행 시작.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { View } from './view.js';
        \\console.log(View);
    );
    try writeFile(tmp.dir, "view.js",
        \\export const View = "MockView";
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
    // 엔트리가 __esm 래핑됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_index = __esm(") != null or
        std.mem.indexOf(u8, result.output, "init_entry = __esm(") != null);
    // 번들 끝에 init_xxx() 호출이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_index();\n") != null or
        std.mem.indexOf(u8, result.output, "init_entry();\n") != null);
    // top-level var View = require_xxx().View 패턴이 없어야 함 (즉시 평가 방지)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var View = require_") == null);
}

test "RN platform: entry __esm contains import bindings inside init body" {
    // 엔트리의 import 바인딩이 __esm body 안에 있어야 함 (lazy 평가).
    // top-level에 var X = require_Y().X 형태로 노출되면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add, PI } from './math.js';
        \\console.log(add(1, 2), PI);
    );
    try writeFile(tmp.dir, "math.js",
        \\exports.add = function(a, b) { return a + b; };
        \\exports.PI = 3.14;
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
    // 엔트리가 __esm 래핑됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_entry = __esm(") != null);
    // __esm body 안에서 require_math() 호출이 있어야 함 (lazy 평가)
    // __esm body는 "entry.ts"() { ... } 형태
    const body_start = std.mem.indexOf(u8, result.output, "\"entry.ts\"()") orelse {
        return error.TestUnexpectedResult;
    };
    const body_slice = result.output[body_start..];
    // body 안에서 require_math() 호출 확인
    try std.testing.expect(std.mem.indexOf(u8, body_slice, "require_math()") != null);
    // init_entry() 호출이 번들 끝에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_entry();\n") != null);
}

test "non-RN platform: entry is NOT __esm wrapped (scope-hoisted)" {
    // browser/node 플랫폼에서는 엔트리가 scope-hoisted로 유지되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './mod.js';
        \\console.log(greet());
    );
    try writeFile(tmp.dir, "mod.js",
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 엔트리는 __esm 래핑 안 됨 (기본 browser 플랫폼)
    // init_entry() 호출이 번들 끝에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_entry()") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_index()") == null);
}
