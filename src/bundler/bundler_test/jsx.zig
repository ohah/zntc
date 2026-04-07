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
