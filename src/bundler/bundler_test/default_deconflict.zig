const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

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

test "Default: barrel re-export default chain preserves bindings (#1321)" {
    // #1321: `import X from './x'; export default X; export { Y };` 패턴에서
    // binding_scanner가 X, Y 모두 local_name="default"로 .re_export 분류 →
    // esm_wrap이 local_name=="default"만 보고 현재 모듈의 _default$N에 잘못 연결.
    // react-native-svg에서 `default`와 `Shape`가 같은 _default$N을 참조하는 회귀.
    // Phase 3a(#1328): has_local_default_binding 플래그가 barrel `export { X }` 케이스에
    // false를 유지하므로 _default 단축 경로에 들어가지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import Svg, { Shape, Path } from './index';
        \\console.log(new Svg().kind, new Shape().kind, new Path().kind);
    );
    try writeFile(tmp.dir, "index.ts",
        \\export * from './barrel';
        \\export { default } from './barrel';
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import Svg from './Svg';
        \\import Shape from './Shape';
        \\import Path from './Path';
        \\export default Svg;
        \\export { Shape, Path };
    );
    try writeFile(tmp.dir, "Svg.ts", "export default class Svg { kind = 'Svg'; }");
    try writeFile(tmp.dir, "Shape.ts", "export default class Shape { kind = 'Shape'; }");
    try writeFile(tmp.dir, "Path.ts", "export default class Path { kind = 'Path'; }");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Shape: () => Shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Path: () => Path") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default\": () => Svg") != null);
}

test "Default: export { X as default } where X is default-import (#1321 edge)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import V from './barrel';
        \\console.log(V.tag);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import Real from './real';
        \\export { Real as default };
    );
    try writeFile(tmp.dir, "real.ts", "export default { tag: 'REAL' };");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"REAL\"") != null);
}

test "Default: mixed default + named imports re-exported from single source (#1321 edge)" {
    // `import X, { Y } from './a'; export default X; export { Y };`
    // X는 .re_export + has_local_default_binding=true → _default 단축 경로 OK.
    // Y는 .re_export + has_local_default_binding=false → 체인 resolve.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import D, { named } from './barrel';
        \\console.log(D, named);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import Def, { named } from './src';
        \\export default Def;
        \\export { named };
    );
    try writeFile(tmp.dir, "src.ts",
        \\export default 'DEFVAL';
        \\export const named = 'NAMEDVAL';
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"DEFVAL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"NAMEDVAL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "named: () => named") != null);
}

test "Default: Platform.js 패턴 — export default X where X is default-import (#1328)" {
    // RN Platform.js 회귀: `import Platform from './Platform.ios'; export default Platform;`
    // binding_scanner가 .re_export로 분류하지만 codegen은 `_default = Platform` emit함.
    // Phase 3a의 has_local_default_binding=true가 symbol table에 _default 등록 →
    // esm_wrap이 `return _default$N;` 올바른 코드 생성. 기존 버그에선 `return default;`
    // (reserved keyword) SyntaxError 발생.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import P from './Platform';
        \\console.log(P.os);
    );
    try writeFile(tmp.dir, "Platform.ts",
        \\import Impl from './Platform.ios';
        \\export default Impl;
    );
    try writeFile(tmp.dir, "Platform.ios.ts", "export default { os: 'ios' };");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ios\"") != null);
    // getter가 예약어 `default`를 identifier로 참조하면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return default;") == null);
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
// #1208: export default X where X is namespace import
// ============================================================

test "Default: export default from namespace import assigns ns var" {
    // `import * as X from './lib'; export default X;` 패턴.
    // ZTS가 var X$N을 호이스팅하지만 값 할당이 누락되던 버그 회귀 방지.
    // Reanimated/GestureDetector가 `Reanimated.default.createAnimatedComponent`로
    // 접근할 때 default getter가 undefined 반환 → 드래그 동작 실패 (#1208).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import Animated from './mod';
        \\console.log(Animated.foo);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\import * as X from './lib';
        \\export default X;
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const foo = 'barvalue';
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
    // ns var 할당이 반드시 존재해야 한다 (X = X_ns; 형태).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "X_ns") != null);
    // default getter가 X를 반환 (minified 또는 non-minified 둘 다 허용)
    // default getter는 arrow 또는 function expression (platform/minify에 따라 다름)
    const has_default_getter = std.mem.indexOf(u8, result.output, "\"default\": () => X") != null or
        std.mem.indexOf(u8, result.output, "\"default\":()=>X") != null or
        std.mem.indexOf(u8, result.output, "\"default\": function() { return X; }") != null;
    try std.testing.expect(has_default_getter);
    // 할당 라인 확인: `X = X_ns;`
    const has_assign = std.mem.indexOf(u8, result.output, "X = X_ns;") != null or
        std.mem.indexOf(u8, result.output, "X=X_ns;") != null;
    try std.testing.expect(has_assign);
}

test "Default: export default namespace — IIFE bundle resolves member access" {
    // default getter에서 반환된 namespace object의 member access가 올바르게 값을 반환해야.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import Pkg from './mod';
        \\console.log(Pkg.answer);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\import * as Stuff from './lib';
        \\export default Stuff;
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const answer = 42;
        \\export const other = 'skip';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // answer가 번들에 포함되어야 (trees-haker가 default 경유 namespace 접근도 보존)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Default: regular export default identifier still self-ref (no regression)" {
    // namespace가 아닌 일반 identifier는 self-ref 최적화가 그대로 유지되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import x from './mod';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const value = 'hello';
        \\export default value;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // regular default는 _ns suffix 없어야 — self-ref 최적화 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value_ns") == null);
}

test "Deconflict: rest parameter shadows renamed function (#1457)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\import { t as ignore } from "./shadow.js";
        \\import { t as fn } from "./pipe.js";
        \\globalThis.__out = [ignore, fn(99, 10, 20, 30)];
    );
    try writeFile(tmp.dir, "shadow.js", "export const t = \"x\";");
    try writeFile(tmp.dir, "pipe.js",
        \\export function t(e, ...t) {
        \\  return [e, t.length, t.map((x) => x * 2)];
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const fn_marker = "function ";
    const fn_start = std.mem.indexOf(u8, result.output, fn_marker) orelse return error.TestUnexpectedResult;
    const name_start = fn_start + fn_marker.len;
    const paren = std.mem.indexOfScalarPos(u8, result.output, name_start, '(') orelse return error.TestUnexpectedResult;
    const fn_name = result.output[name_start..paren];
    // pipe.js의 함수 t는 shadow.js의 t와 충돌해 rename된다.
    try std.testing.expect(!std.mem.eql(u8, fn_name, "t"));

    const length_ref = try std.fmt.allocPrint(std.testing.allocator, "{s}.length", .{fn_name});
    defer std.testing.allocator.free(length_ref);
    const map_ref = try std.fmt.allocPrint(std.testing.allocator, "{s}.map", .{fn_name});
    defer std.testing.allocator.free(map_ref);
    // 함수 내부의 rest 파라미터 `t`가 renamed 함수명으로 잘못 rewrite되면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, length_ref) == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, map_ref) == null);
}
