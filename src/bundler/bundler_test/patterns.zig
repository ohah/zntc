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

test "minifyIdentifiers: for-in LHS identifier should be renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\var myObj = { a: 1, b: 2 };
        \\var myKey;
        \\for (myKey in myObj) {
        \\  console.log(myKey);
        \\}
        \\export var result = myKey;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const r = try b.bundle();
    defer r.deinit(std.testing.allocator);

    // "myKey" should NOT appear in the output (it should be renamed)
    // The for-in LHS must use the same renamed identifier as the var declaration
    try std.testing.expect(std.mem.indexOf(u8, r.output, "myKey") == null);
    // "myObj" should also be renamed
    try std.testing.expect(std.mem.indexOf(u8, r.output, "myObj") == null);
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
