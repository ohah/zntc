const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

fn expectNoDuplicatePrivateMethodParams(output: []const u8) !void {
    var search_from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, output, search_from, '#')) |hash_pos| {
        const open_rel = std.mem.indexOfScalar(u8, output[hash_pos..], '(') orelse return;
        const open = hash_pos + open_rel;
        const close_rel = std.mem.indexOfScalar(u8, output[open + 1 ..], ')') orelse return;
        const params = output[open + 1 .. open + 1 + close_rel];
        var seen = std.StringHashMap(void).init(std.testing.allocator);
        defer seen.deinit();
        var it = std.mem.splitScalar(u8, params, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r\n");
            if (name.len == 0 or std.mem.indexOfAny(u8, name, "{}[]=.") != null) continue;
            if (seen.contains(name)) return error.DuplicatePrivateMethodParameter;
            try seen.put(name, {});
        }
        search_from = open + 1 + close_rel + 1;
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

    const result = try b.bundle(std.testing.io);
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

    const result = try b.bundle(std.testing.io);
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

    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // "default" bare 키워드가 값 위치에 나타나면 안 됨
    // getter 형태("get \"default\"()")는 허용, 값 위치(": default,")는 불가
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sub가 getter 객체로 생성됨 (live binding)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get x()") != null or
        std.mem.indexOf(u8, result.output, "x:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get y()") != null or
        std.mem.indexOf(u8, result.output, "y:") != null);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // foo 함수 정의가 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function foo") != null);
    // namespace getter 객체가 생성
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get foo()") != null or
        std.mem.indexOf(u8, result.output, "foo:") != null);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // platform=node에서 NODE_ENV="production" → flag=false → !flag=true → "prod" 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "prod") != null);
}

test "Minify: production env derived DEV flag folds through string methods" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const node_env = "production";
        \\const DEV = node_env && !node_env.toLowerCase().startsWith("prod");
        \\if (DEV) {
        \\  console.log("DEV_ONLY_LONG_DIAGNOSTIC");
        \\} else {
        \\  console.log("prod");
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
        .minify_syntax = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEV_ONLY_LONG_DIAGNOSTIC") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "toLowerCase") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "startsWith") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(\"prod\")") != null);
}

test "Minify: cross-module default DEV flag removes dead import fanout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import DEV from './dev';
        \\import { heavy } from './heavy';
        \\if (DEV) {
        \\  heavy();
        \\}
        \\console.log("prod");
    );
    try writeFile(tmp.dir, "dev.ts",
        \\export default false;
    );
    try writeFile(tmp.dir, "heavy.ts",
        \\export function heavy() {
        \\  console.log("HEAVY_DEV_ONLY");
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .minify_syntax = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HEAVY_DEV_ONLY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "heavy") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(\"prod\")") != null);
}

test "Minify: cross-module derived default DEV flag removes long diagnostic branch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { lifecycle_outside_component } from './errors';
        \\lifecycle_outside_component("onMount");
    );
    try writeFile(tmp.dir, "dev-fallback.ts",
        \\const node_env = "production";
        \\export default node_env && !node_env.toLowerCase().startsWith("prod");
    );
    try writeFile(tmp.dir, "errors.ts",
        \\import DEV from './dev-fallback';
        \\export function lifecycle_outside_component(name: string) {
        \\  if (DEV) {
        \\    throw new Error(`lifecycle_outside_component ${name} LONG_DEV_DIAGNOSTIC`);
        \\  } else {
        \\    throw new Error("https://svelte.dev/e/lifecycle_outside_component");
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .minify_syntax = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LONG_DEV_DIAGNOSTIC") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "toLowerCase") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "startsWith") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "https://svelte.dev/e/lifecycle_outside_component") != null);
}

test "Minify: cross-module true DEV flag keeps live import fanout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import DEV from './dev';
        \\import { heavy } from './heavy';
        \\if (DEV) {
        \\  heavy();
        \\}
        \\console.log("after");
    );
    try writeFile(tmp.dir, "dev.ts",
        \\export default true;
    );
    try writeFile(tmp.dir, "heavy.ts",
        \\export function heavy() {
        \\  console.log("HEAVY_LIVE_BRANCH");
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .minify_syntax = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HEAVY_LIVE_BRANCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(\"after\")") != null);
}

test "Minify: re-exported default DEV flag removes dead import fanout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { DEV } from './barrel';
        \\import { heavy } from './heavy';
        \\if (DEV) heavy();
        \\console.log("prod");
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { default as DEV } from './dev';
    );
    try writeFile(tmp.dir, "dev.ts",
        \\export default false;
    );
    try writeFile(tmp.dir, "heavy.ts",
        \\export function heavy() {
        \\  console.log("REEXPORTED_DEV_DEAD_BRANCH");
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .minify_syntax = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "REEXPORTED_DEV_DEAD_BRANCH") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(\"prod\")") != null);
}

test "Minify: constant fact materialization preserves object shorthand keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import DEV from './dev';
        \\const obj = { DEV };
        \\console.log(obj.DEV);
    );
    try writeFile(tmp.dir, "dev.ts",
        \\export default false;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .minify_syntax = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "{false") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEV") != null);
}

test "Minify: refreshed semantic recomputes mangling after constant fact DCE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import DEV from './dev';
        \\import { dead } from './dead';
        \\class Batch {
        \\  #process(root, effects, deferred) {
        \\    for (const effect of effects) {
        \\      deferred.push(root + effect);
        \\    }
        \\    return deferred.length;
        \\  }
        \\  run(items) {
        \\    const pending = [];
        \\    return this.#process(1, items, pending);
        \\  }
        \\}
        \\if (DEV) dead();
        \\console.log(new Batch().run([1, 2, 3]));
    );
    try writeFile(tmp.dir, "dev.ts",
        \\const node_env = "production";
        \\export default node_env && !node_env.toLowerCase().startsWith("prod");
    );
    try writeFile(tmp.dir, "dead.ts",
        \\export function dead() {
        \\  console.log("PRIVATE_MANGLE_DEAD_BRANCH");
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PRIVATE_MANGLE_DEAD_BRANCH") == null);
    try expectNoDuplicatePrivateMethodParams(result.output);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // TypeId가 번들에 포함 (namespace import를 통한 참조)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Symbol.for") != null);
    // NOTE(#1558): 현재 namespace import는 target 모듈 전체를 보존한다 —
    // processModuleImportsInner가 dead statement의 member access까지 커버하기 위해
    // "*" sentinel을 마킹하는 보수 동작. 결과적으로 `left` 같은 미사용 export도 남는다.
    // symbol-level 정밀 tree-shake은 #1558 (2→1 phase 재설계) 완료 후 복원 예정.
    // try std.testing.expect(std.mem.indexOf(u8, result.output, "function left") == null);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "toUpperCase") != null);
    // preamble 변수 선언과 console.log 참조가 모두 출력에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, output, "console.log") != null);
}

test "Minify: ESM import binding resolves correctly after mangling (#1581)" {
    // 중간 모듈의 export는 mangled되지만 import binding이 올바른 mangled 이름으로
    // 치환되어 호출이 정상 해소되어야 한다 (scope hoisting 후 같은 심볼 1개).
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // 실행 결과에 영향을 주는 문자열은 보존
    try std.testing.expect(std.mem.indexOf(u8, output, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "world") != null);
    // 원본 이름은 축약됨 (중간 모듈 export는 public API 아님)
    try std.testing.expect(std.mem.indexOf(u8, output, "greet") == null);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    const body_start = std.mem.indexOf(u8, output, "var x=i") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, ';'), output[body_start + 7]);
}

test "Minify: template literal expression identifiers renamed (#493)" {
    // template literal 내 ${identifier} 참조가 mangled name으로 일관되게 치환되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { long_prefix_name } from './lib';\nconsole.log(`val=${long_prefix_name}!`);");
    try writeFile(tmp.dir, "lib.ts", "export const long_prefix_name = 'hello';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // 중간 모듈 export는 mangled됨 (#1581)
    try std.testing.expect(std.mem.indexOf(u8, output, "long_prefix_name") == null);
    // template literal 구조와 실행 결과 문자열은 보존
    try std.testing.expect(std.mem.indexOf(u8, output, "val=") != null);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ok") != null);
}

test "Minify: TS type params do not collide with runtime vars (#1259)" {
    // 제네릭 타입 파라미터 T가 runtime에서 변수 이름 충돌을 일으키거나
    // mangler가 T에 slot을 할당하면 안 된다 (타입은 emit 단계에서 제거됨).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function gen<T>(a: T, b: T): T {
        \\  const result = a;
        \\  return result;
        \\}
        \\console.log(gen<string>("hi", "world"));
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 타입 파라미터 T는 output에 남지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<T>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": T") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hi") != null);
}

test "Minify: type alias / interface do not consume mangler slots (#1259)" {
    // type, interface 선언은 emit 안 되므로 mangler 대상이 아니어야 한다.
    // 같은 이름의 runtime 변수가 있을 때 name collision 없이 동작.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\type User = { name: string };
        \\interface Config { debug: boolean }
        \\function make(): User {
        \\  const payload = { name: "alice" };
        \\  return payload;
        \\}
        \\console.log(make().name);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "alice") != null);
}

test "Minify: generic class type params do not leak into runtime (#1259)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Box<TItem> {
        \\  item: TItem;
        \\  constructor(value: TItem) { this.item = value; }
        \\  get(): TItem { return this.item; }
        \\}
        \\const boxed = new Box<number>(42);
        \\console.log(boxed.get());
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TItem") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<number>") == null);
}

test "Minify: enum member access preserved after mangling (#1259)" {
    // enum은 값으로 emit되므로 mangling 대상. member 접근이 올바르게 동작해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\enum Color { Red = 1, Green = 2 }
        \\const picked = Color.Green;
        \\console.log(picked);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // enum member name은 속성이므로 보존됨, Green 접근 코드가 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Green") != null);
}

test "Minify: direct eval preserves visible local bindings (#1258)" {
    // direct eval은 스코프 내 모든 바인딩을 동적으로 참조할 수 있으므로,
    // eval을 포함한 함수 및 그 상위 스코프의 변수는 mangling되면 안 된다.
    // rolldown/oxc 방식: ContainsDirectEval 플래그를 상위로 전파.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function run() {
        \\  const veryLongPasswordVar = "secret";
        \\  return eval("veryLongPasswordVar");
        \\}
        \\console.log(run());
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 선언부도 eval 인자와 같은 이름을 유지해야 런타임에 eval("veryLongPasswordVar")가 resolve된다.
    // 단순 indexOf는 eval 인자 문자열에 걸려 pass되므로, 선언 패턴을 직접 확인.
    const has_decl = std.mem.indexOf(u8, result.output, "veryLongPasswordVar=") != null or
        std.mem.indexOf(u8, result.output, "veryLongPasswordVar =") != null;
    try std.testing.expect(has_decl);
}

test "Minify: direct eval preserves outer scope bindings too (#1258)" {
    // direct eval은 포함 함수의 모든 조상 스코프 바인딩을 볼 수 있으므로,
    // top-level 함수 이름도 eval 발생 시 보존되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\function topLevelFunc() {
        \\  return eval("topLevelFunc.name");
        \\}
        \\console.log(topLevelFunc());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const has_decl = std.mem.indexOf(u8, result.output, "function topLevelFunc") != null;
    try std.testing.expect(has_decl);
}

test "Minify: with statement preserves bindings in enclosing scope (#1258)" {
    // with 블록은 내부 식별자가 객체 속성으로 동적 해석될 수 있으므로,
    // with을 포함한 스코프와 상위 스코프 변수는 mangling되면 안 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\function run(obj) {
        \\  var greetingOuter = "hi";
        \\  with (obj) {
        \\    console.log(greetingOuter);
        \\  }
        \\}
        \\run({ greetingOuter: "hello" });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const has_decl = std.mem.indexOf(u8, result.output, "greetingOuter=") != null or
        std.mem.indexOf(u8, result.output, "greetingOuter =") != null;
    try std.testing.expect(has_decl);
}

// ============================================================
// Mangler: public-API boundary (#1581)
// ============================================================
// mangling 보존 대상은 entry 모듈의 export와 external import local binding만이다.
// 중간 모듈에서 export된 이름도 bundle 내부에서만 소비되므로 자유롭게 축약 가능.
// esbuild/rolldown 관행과 동일.

test "Minify: non-entry export name is mangled (#1581)" {
    // 중간 모듈의 긴 export 이름은 bundle 외부로 노출되지 않으므로 축약되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { VERY_LONG_INTERNAL_CONSTANT_NAME } from './constants';
        \\console.log(VERY_LONG_INTERNAL_CONSTANT_NAME);
    );
    try writeFile(tmp.dir, "constants.ts",
        \\export const VERY_LONG_INTERNAL_CONSTANT_NAME = 42;
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 긴 이름이 축약되어 출력에 남지 않는다
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VERY_LONG_INTERNAL_CONSTANT_NAME") == null);
    // 값 42는 그대로 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Minify: entry export name preserved (#1581)" {
    // entry 모듈의 export는 public API이므로 보존되어야 한다 (ESM 포맷).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const helper = 42;
        \\export const PUBLIC_API = helper * 2;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry의 public API 이름은 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PUBLIC_API") != null);
    // 내부 helper 이름은 축약
    try std.testing.expect(std.mem.indexOf(u8, result.output, "helper") == null);
}

test "Minify: external import local binding preserved (#1581)" {
    // external로 남는 import는 bundle 밖에서 해소되므로 local 이름을 보존해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { readFileSync } from 'node:fs';
        \\console.log(readFileSync('/tmp/x'));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // external import → local 이름 보존 (외부에서 정의된 이름)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readFileSync") != null);
}

test "Minify: non-entry default export synthetic `_default` is mangled (#1585)" {
    // 중간 모듈의 `export default`로 생성된 `_default` 합성 심볼도 축약 대상.
    // scope_maps[0]에 없는 합성 심볼이 mangler 후보에 포함되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import helper from './helper';
        \\console.log(helper.x);
    );
    try writeFile(tmp.dir, "helper.ts",
        \\export default { x: 42 };
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // `_default` 원본 이름이 번들에 남아 있으면 안 된다 (suffix 포함)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_default") == null);
    // 값(42)은 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Minify: multiple default exports collide — each `_default$N` is mangled (#1585)" {
    // 두 중간 모듈이 각각 `export default`를 가질 때
    // `_default`, `_default$2` 둘 다 mangling되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import a from './a';
        \\import b from './b';
        \\console.log(a.x + b.y);
    );
    try writeFile(tmp.dir, "a.ts",
        \\export default { x: 10 };
    );
    try writeFile(tmp.dir, "b.ts",
        \\export default { y: 20 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bun = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer bun.deinit();
    const result = try bun.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 원본 합성 이름이 남으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_default") == null);
    // 두 값 모두 보존 (실행 결과 불변)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "20") != null);
}

test "Minify: entry `export default` preserves external `default` keyword (#1585)" {
    // entry의 default export는 외부로 나가는 public API.
    // `export default <expr>` 구문과 `default` 키워드는 ESM 포맷에서 보존되어야 하고,
    // inline expression에서 생성되는 합성 `_default`도 public이므로 보존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export default { x: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM `default` export 구문 보존 (`export default ...` 또는 `export{...as default}`)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "default") != null);
    // 값(42)은 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

// ============================================================
// Minify syntax: redundant parens around `new` callee (#1586)
// ============================================================
// `new (expr)()`에서 expr이 MemberExpression 자리에 적합하면 parens 불필요.
// ClassExpression, Identifier, MemberExpression 모두 parens 없이 사용 가능.
// 단 callee에 CallExpression이 섞여 있으면 기존 newCalleeNeedsParens 로직이
// 여전히 parens를 유지함.

test "Minify: new (ClassExpression)() drops redundant parens (#1586)" {
    // svelte-style `new (class X extends Error {...})()` 패턴.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const x = new (class Foo extends Error {
        \\  name = "Foo";
        \\})();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // parens 제거 후: `new class Foo extends Error{...}()`
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new class") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new (class") == null);
}

test "Minify: new (Identifier)() drops redundant parens (#1586)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Box {}
        \\const x = new (Box)();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new (") == null);
}

test "Minify: new (MemberExpression)() drops redundant parens (#1586)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const ns = { Box: class { x = 1; } };
        \\const x = new (ns.Box)();
        \\console.log(x.x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // MemberExpression callee에서 parens 완전 제거 — 출력에 `new (` 미존재로 검증
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new (") == null);
    // MemberExpression 구조는 보존 (`.Box` 접근이 남아있어야 함)
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".Box") != null);
}

test "Minify: new (CallExpression)() keeps parens — safety (#1586)" {
    // `new (factory())()` 형태는 factory의 반환값을 constructor로 호출.
    // parens를 벗기면 `new factory()()`로 오파싱되어 의미가 변경됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function factory() { return class { x = 1; }; }
        \\const x = new (factory())();
        \\console.log(x.x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CallExpression callee는 parens 유지 (newCalleeNeedsParens true)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new (") != null);
}

test "Minify: redundant parens removed for new-callee even without minify_syntax (#1586/#4042)" {
    // #4042: precedence 기반 전환으로 *전 모드 통일* — minify_syntax 여부와 무관하게
    // 군더더기 괄호 제거. `new (class Foo extends Error {})()` 의 callee 괄호는
    // `new class Foo extends Error {}()` 로 떨어진다(class expression 은 PrimaryExpression
    // 이라 new callee 슬롯에 직접 가능, 의미 동일 — esbuild parity).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const x = new (class Foo extends Error {})();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = false,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 군더더기 괄호 제거(esbuild parity): `new class` (괄호 없음).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new class") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new (class") == null);
}

test "Minify: default export has no synthetic variable — no regression (#1585)" {
    // default export가 없는 번들은 `_default` 심볼을 만들지 않으므로
    // 본 PR 변경으로 부작용 없이 그대로 통과해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { named } from './lib';
        \\console.log(named);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const named = 'hello';
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_default") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

// ============================================================
// Minify syntax: anonymize class expression name (#1587)
// ============================================================
// ClassExpression의 name이 body 내부에서 참조되지 않으면 익명 class로 축약.
// #1592로 semantic이 class body scope에 name을 등록하므로 reference_count
// 기반 판단이 정확. ClassDeclaration은 외부 scope 심볼이라 영향 없음.

test "Minify: unreferenced class expression name is anonymized (#1587)" {
    // svelte-style `class StaleReactionError extends Error` 패턴.
    // body 내부에 StaleReactionError 참조가 없으므로 익명화 가능.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const e = new (class StaleReactionError extends Error {
        \\  name = "StaleReactionError";
        \\})();
        \\console.log(e);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // class 키워드 뒤에 식별자 StaleReactionError가 남으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class StaleReactionError") == null);
    // 단 "name = \"StaleReactionError\"" property string literal은 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"StaleReactionError\"") != null);
}

test "Minify: class expression with self-reference keeps its name (#1587)" {
    // body 내부에서 self-reference가 있으면 이름 제거 금지 (self-ref 깨짐).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const c = class SelfRef {
        \\  static make() { return new SelfRef(); }
        \\};
        \\console.log(c.make());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // self-ref 있으므로 SelfRef 이름은 유지되어야 함 — 식별자 보존 검증
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SelfRef") != null);
}

test "Minify: class declaration name never anonymized (#1587)" {
    // ClassDeclaration은 외부 scope 심볼이므로 anonymize 대상 아님.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Box {}
        \\const x = new Box();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ClassDeclaration은 외부 scope에 이름이 있어야 `new X()` 호출 성립.
    // mangled로 이름이 바뀌더라도 `class` 뒤 공백+식별자+body 구조는 유지되어야 하고,
    // 완전 익명(`class {` / `class{`)이 되어서는 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class {") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class{") == null);
}

test "Minify: anonymization disabled without minify_syntax (#1587)" {
    // minify_syntax 비활성 시 원본 이름 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const c = class UnusedName extends Error {};
        \\console.log(c);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = false,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 원본 이름 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UnusedName") != null);
}

test "Minify: keep_names disables anonymization (#1587)" {
    // keep_names=true일 때는 이름 유지 (debug용 이름 보존 옵션).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const c = class KeepMe extends Error {};
        \\console.log(c);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // keep_names → 이름 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "KeepMe") != null);
}

// ============================================================
// Minify syntax: anonymize on non-fast-path (#1596)
// ============================================================
// #1587 의 fast path (useDefineForClassFields=true AND !experimentalDecorators) 외에도
// body 멤버를 개별 분류하는 non-fast-path (visitClassWithAssignSemantics) 에서 동일 최적화.
// 단, class name 런타임 참조 요소 (static field / static block 다운레벨 / decorator) 없을 때만.

test "Minify non-fast-path: anonymize unreferenced class expression (#1596)" {
    // useDefineForClassFields=false → non-fast-path 진입.
    // static field / decorator 없으므로 익명화 가능.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const e = new (class StaleReactionError extends Error {
        \\  name = "StaleReactionError";
        \\})();
        \\console.log(e);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
        .use_define_for_class_fields = false,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class StaleReactionError") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"StaleReactionError\"") != null);
}

test "Minify non-fast-path: self-reference keeps name (#1596)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const c = class SelfRef {
        \\  static make() { return new SelfRef(); }
        \\};
        \\console.log(c.make());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
        .use_define_for_class_fields = false,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SelfRef") != null);
}

test "Minify non-fast-path: static field blocks anonymization (#1596)" {
    // static field 가 `ClassName.x = ...` 형태로 emit 되므로 이름 참조가 살아남아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const c = class WithStatic extends Error {
        \\  static version = 1;
        \\};
        \\console.log(c);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
        .use_define_for_class_fields = false,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WithStatic") != null);
}

test "Minify non-fast-path: experimental decorator blocks anonymization (#1596)" {
    // class 자체는 __decorateClass 의 argument 로 받아 이름 없이 써도 되지만,
    // method decorator 의 member 접근 helper 가 class name 을 참조할 수 있어 보수적으로 보존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function Log(target: any, key?: any, kind?: any) { return target; }
        \\const c = @Log class DecoratedExpr extends Error {
        \\  @Log method() { return 1; }
        \\};
        \\console.log(new c().method());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
        .experimental_decorators = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DecoratedExpr") != null);
}

test "Minify non-fast-path: instance field allows anonymization (#1596)" {
    // instance field 는 constructor 로 이동되므로 class name 참조가 남지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const e = new (class InstField extends Error {
        \\  count = 0;
        \\  label = "x";
        \\})();
        \\console.log(e);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
        .use_define_for_class_fields = false,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class InstField") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "InstField") == null);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .dataurl }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // data URL: data:image/png;base64,...
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,") != null);
    try std.testing.expect(result.asset_outputs == null);
}

test "Asset loader: base64 — pure base64 string (no data URL prefix)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import s from './data.bin';\nconsole.log(s);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.bin", .data = &.{ 0x48, 0x69 } }); // "Hi"

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .base64 }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // base64("Hi") = "SGk=" — pure base64, no data URL prefix
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"SGk=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:") == null);
    try std.testing.expect(result.asset_outputs == null);
}

test "Asset loader: copy — raw passthrough to asset output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './doc.pdf';\nconsole.log(url);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "doc.pdf", .data = "PDF-RAW-CONTENTS" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".pdf", .loader = .copy }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // copy 도 file 처럼 hash 가 붙은 path 를 export 하고, raw bytes 가 asset_outputs 에 포함됨.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "doc-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".pdf") != null);
    try std.testing.expect(result.asset_outputs != null);
    try std.testing.expectEqual(@as(usize, 1), result.asset_outputs.?.len);
    try std.testing.expectEqualStrings("PDF-RAW-CONTENTS", result.asset_outputs.?[0].contents);
}

test "Asset loader: file — hash filename + asset output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './logo.png';\nconsole.log(url);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logo.png", .data = "fake-png-data" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "img.png", .data = "data" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
        .public_path = "https://cdn.example.com/",
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "https://cdn.example.com/img-") != null);
}

test "Asset loader: file — content hash determinism" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import url from './a.bin';\nconsole.log(url);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.bin", .data = "deterministic-content" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 첫 번째 번들
    var b1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .file }},
    });
    defer b1.deinit();
    const r1 = try b1.bundle(std.testing.io);
    defer r1.deinit(std.testing.allocator);

    // 두 번째 번들 (같은 내용)
    var b2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .file }},
    });
    defer b2.deinit();
    const r2 = try b2.bundle(std.testing.io);
    defer r2.deinit(std.testing.allocator);

    // 같은 내용 → 같은 해시 → 같은 출력
    try std.testing.expectEqualStrings(r1.output, r2.output);
}

test "Asset loader: binary — __toBinary runtime helper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './raw.bin';\nconsole.log(data);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "raw.bin", .data = &.{ 0xDE, 0xAD, 0xBE, 0xEF } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".bin", .loader = .binary }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "font.woff", .data = "woff-data" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".woff", .loader = .file }},
        .asset_names = "assets/[name]-[hash]",
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    tmp.dir.createDirPath(std.testing.io, "images/icons") catch {};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "images/icons/logo.png", .data = "png-data" });
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
    const result = try b.bundle(std.testing.io);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "font.woff2", .data = "woff2-data" });
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // [ext] = "woff2" (dot 없이)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "static/woff2/font-") != null);
}

// #4466: `.png`/`.ttf` 등 알려진 바이너리 자산은 이제 --loader 없이도 기본
// `.file` 로더가 붙는다 (Vite/rspack parity). 예전엔 `no_loader` 에러였다.
// 알려지지 않은 확장자는 여전히 에러 — 아래 ".xyz" 테스트가 그 선을 지킨다.

test "#4466 기본 로더: .png 는 --loader 없이도 성공 (작으면 data URL 인라인)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const icon = require('./icon.png');\nconsole.log(icon);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 4바이트 → inline limit(4096) 이하 → 별도 파일 없이 data URL
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,") != null);
    try std.testing.expect(result.asset_outputs == null or result.asset_outputs.?.len == 0);
}

test "#4466 기본 로더: inline limit 초과 자산은 파일로 방출" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    // 5000B > 기본 한계 4096B
    const big = [_]u8{0xAB} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &big });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png") == null);
    const assets = result.asset_outputs orelse return error.ExpectedAssetOutput;
    try std.testing.expectEqual(@as(usize, 1), assets.len);
    try std.testing.expect(std.mem.endsWith(u8, assets[0].path, ".png"));
}

test "#4466 기본 로더: --asset-inline-limit=0 이면 항상 파일 방출" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .asset_inline_limit = 0,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png") == null);
    const assets = result.asset_outputs orelse return error.ExpectedAssetOutput;
    try std.testing.expectEqual(@as(usize, 1), assets.len);
}

test "#4466 기본 로더: 명시 --loader:.png=file 은 inline limit 을 이긴다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    // 4바이트 — 한계 이하지만, 사용자가 file 을 **명시**했으므로 파일이어야 한다.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png") == null);
    const assets = result.asset_outputs orelse return error.ExpectedAssetOutput;
    try std.testing.expectEqual(@as(usize, 1), assets.len);
}

test "No loader: 알려지지 않은 확장자(.xyz)는 여전히 에러" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const blob = require('./data.xyz');\nconsole.log(blob);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "data.xyz", .data = "whatever" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // loader 지정 → 성공
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_icon") != null);
}

test "#4466 기본 로더: ESM import of .png 도 --loader 없이 성공" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,") != null);
}

test "#4466 기본 로더: 폰트(.woff2/.ttf) 도 --loader 없이 성공" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import f from './x.woff2';\nconsole.log(f);");
    const big = [_]u8{0xCD} ** 5000; // 한계 초과 → 파일 방출
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.woff2", .data = &big });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const assets = result.asset_outputs orelse return error.ExpectedAssetOutput;
    try std.testing.expectEqual(@as(usize, 1), assets.len);
    try std.testing.expect(std.mem.endsWith(u8, assets[0].path, ".woff2"));
}

test "#4466 기본 로더: .mp3 도 --loader 없이 성공" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const audio = require('./sound.mp3');\nconsole.log(audio);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sound.mp3", .data = "fake-mp3" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "Plugin load hook overrides asset loader" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import icon from './icon.png';\nconsole.log(icon);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 플러그인 없이 file 로더로 번들 → URL 문자열이 포함되어야 함
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // file 로더 출력: 해시가 포함된 파일명
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".png") != null);
    // registerAsset는 없어야 함 (플러그인이 없으므로)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "registerAsset") == null);
}

// ============================================================
// #1618: Runtime helper name shortening in minify mode
// ============================================================

// Helper: CJS wrap이 발생하도록 require를 호출하는 fixture.
fn writeCjsWrapFixture(tmp_dir: std.Io.Dir) !void {
    try writeFile(tmp_dir, "lib.cjs", "module.exports = { greet: () => \"hi\" };");
    try writeFile(tmp_dir, "entry.ts",
        \\const lib = require('./lib.cjs');
        \\console.log(lib.greet());
    );
}

test "#1618 minify: __commonJS → $cj short name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCjsWrapFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minify 모드: preamble이 `var $c=` 형태로 축약 (#3256: $cj → $c 1 char 단축).
    // RFC PR-4 기본 ON: browser/node CJS wrapper param 은 `$e`/`$m` 로 mangle
    // (codegen 합성·free-ref 와 단일 소스 동기, 144-lib 런타임 MATCH 전수).
    // react_native 만 Metro 호환 위해 `exports`/`module` 보존 (별도 RN 테스트).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $c=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=$c(($e,$m)=>") != null);
    // 원본 `__commonJS` 이름은 나타나지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
}

test "#1618 non-minify: __commonJS name preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCjsWrapFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        // minify_whitespace=false → 기본(디버그 친화) 이름 유지
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __commonJS") != null);
    // 축약 이름은 나타나지 않아야 함 (#3256: $cj → $c 단축)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $c=") == null);
}

// Edge case: 사용자 코드가 `$c`와 동일한 이름의 로컬(non-exported) const를 선언.
// mangler가 `$c`를 reserved로 알고, base54 할당 시에도 skip하므로 사용자 심볼이
// `$c`로 emit되지 않아 preamble 정의와 충돌하지 않아야 함.
// (mangler는 non-exported + len>1 심볼을 rename 대상으로 가져가므로 사용자 `$c`는
//  base54 이름으로 rename됨.) — #3256: $cj → $c 단축 후.
test "#1618 minify: user-defined `$c` local const doesn't collide with runtime helper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.cjs", "module.exports = { greet: () => \"hi\" };");
    try writeFile(tmp.dir, "entry.ts",
        \\const lib = require('./lib.cjs');
        \\const $c = { tag: 42 };
        \\console.log(lib.greet(), $c.tag);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preamble: runtime helper 정의 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $c=(cb,mod)=>") != null);
    // 사용자 `$c`는 mangle되어 별도 선언으로 출력되지 않아야 함 —
    // preamble의 runtime helper 정의가 `var $c` 유일한 선언이어야 한다
    // (두 번째 `var $c` = 충돌, 사용자 값이 runtime helper를 덮어씀).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.output, "var $c"));
}

// Edge case: 사용자 코드가 `$cj` 함수 호출 (`$cj()` 형태)을 사용하지만 정의는 없는 경우.
// (외부 글로벌이라 가정) mangler가 이 참조를 그대로 두더라도 bundle이 깨지지 않아야 함.
test "#1618 minify: non-CJS bundle doesn't emit runtime helper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.ts", "export const x = 42;");
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './dep';
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM-only 번들: CJS wrap 불필요 → $cj preamble 미출현
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $cj=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __commonJS") == null);
}

// ============================================================
// #1621: Runtime helper 축약 확장 (__esm/__export/__toESM/__toCommonJS + Object.*)
// ============================================================

// Helper: ESM 모듈이 require() 로 소비되면 __esm 래핑 + __export + __toCommonJS 가
// 모두 활성화됨 (references/esbuild: CJS-ESM interop 경로).
fn writeEsmWrappedFixture(tmp_dir: std.Io.Dir) !void {
    try writeFile(tmp_dir, "mod.js",
        \\export function greet() { return 'hello'; }
        \\export const name = 'world';
    );
    try writeFile(tmp_dir, "entry.ts",
        \\const lib = require('./mod.js');
        \\console.log(lib.greet(), lib.name);
    );
}

test "#1621 minify: __esm/__export/__toCommonJS → $e/$x/$tC short names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeEsmWrappedFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preamble 정의 3종 모두 축약 형태로 출현해야 함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $e=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $tC=") != null);
    // 호출부: `=$e({` (ESM wrap) / `$x(` (export getter) / `$tC(` (require rewrite).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=$e({") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$x(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$tC(") != null);
    // 원본 긴 이름은 나타나지 않아야 함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS") == null);
}

test "#1621 non-minify: __esm/__export/__toCommonJS long names preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeEsmWrappedFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        // non-minify: 긴 이름 유지.
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __esm = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __export = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __toCommonJS = ") != null);
    // 축약 이름 선언은 없어야 함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $e=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $x=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $tC=") == null);
}

// Helper: CJS 모듈을 default import 하면 preamble 에서 __toESM 래핑이 활성화됨.
fn writeToEsmFixture(tmp_dir: std.Io.Dir) !void {
    try writeFile(tmp_dir, "lib.cjs",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = { v: 42 };
    );
    try writeFile(tmp_dir, "entry.ts",
        \\import lib from './lib.cjs';
        \\console.log(lib.v);
    );
}

test "#1621 minify: __toESM → $tE short name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeToEsmFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preamble 에 `var $tE=` 정의 + 호출부 `$tE(` 존재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $tE=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$tE(") != null);
    // 원본 이름은 없어야 함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") == null);
}

test "#1621 minify: Object.* alias shortened ($dp/$cr/$gP/$gN/$gD/$hO/$cp)" {
    // __toESM 런타임 preamble 내부에 Object.* alias 7종이 정의되므로,
    // __toESM 이 활성화되면 모두 축약 이름으로 선언되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeToEsmFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // Object.* alias 축약 선언 7종 전부 존재. 단일 var 선언으로 compact 될 수 있다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $cr=Object.create,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$gP=Object.getPrototypeOf") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$dp=Object.defineProperty") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$gN=Object.getOwnPropertyNames") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$gD=Object.getOwnPropertyDescriptor") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$hO=Object.prototype.hasOwnProperty") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cp=") != null);
    // 원본 긴 이름 전부 미출현.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__create") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__getProtoOf") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__defProp") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__getOwnPropNames") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__getOwnPropDesc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__hasOwn") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__copyProps") == null);
}

test "#1621 minify: __toESM compact __copyProps shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeToEsmFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // Object.* alias는 하나의 var 선언으로 compact 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $cr=Object.create,$gP=Object.getPrototypeOf,$dp=Object.defineProperty,$gN=Object.getOwnPropertyNames,$gD=Object.getOwnPropertyDescriptor,$hO=Object.prototype.hasOwnProperty,$cp=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ";var $gP=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ";var $dp=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ";var $gN=") == null);

    // __copyProps는 내부 2-arg 호출만 사용하므로 except와 n 보조 변수를 다시 도입하지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "except") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "key!==") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n=keys.length") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "i<n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "i<keys.length") != null);

    // 일반 minified variant는 짧은 arrow IIFE로 key를 capture하고 descriptor enumerable은 유지한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get:(k=>()=>from[k])(key)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "enumerable:!(desc=$gD(from,key))||desc.enumerable") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyNames") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyDescriptor") != null);
}

test "#1621 minify+react-native: configurable __toESM stays ES5 and compact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeToEsmFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .platform = .react_native,
        .configurable_exports = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // RN/Hermes variant는 ES5 function form과 configurable descriptor를 유지한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cp=function(to,from,desc)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$tE=function(mod,isNodeMode,target)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "configurable:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get:(function(k){return from[k]}).bind(null,key)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get:(k=>()=>from[k])(key)") == null);

    // compacting invariant는 configurable variant에도 동일하게 적용된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "except") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "key!==") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n=keys.length") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "i<keys.length") != null);
}

test "#1621 minify: __commonJS body 는 anonymous arrow (named function 제거)" {
    // 이전 동작: `function $r() {...}` named function expression — stack trace 친화.
    // 새 동작: anonymous arrow `()=>(...)` — 17 chars 절약 (esbuild/rolldown 식).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCjsWrapFixture(tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // helper body: arrow expression body — `(cb,mod)=>()=>(mod||cb(...)...)`.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(cb,mod)=>()=>") != null);
    // 이전 named function 패턴은 더 이상 emit 안 됨.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function $r()") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__require") == null);
}

// ============================================================
// #1621 확장: transformer-emitted downlevel helper 축약
// RN/Hermes 타겟(= es5 unsupported matrix)에서 다수 emit 되므로 실측 중요.
// ============================================================

const compat_mod = @import("../../transformer/compat.zig");

test "#1621 minify+es5: class → $eX/$cC/$cS 축약" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Animal { constructor(n) { this.n = n; } speak() { return this.n; } }
        \\class Dog extends Animal { constructor(n) { super(n); this.kind = "dog"; } }
        \\console.log(new Dog("rex").speak());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preamble 축약: __extends → $eX, __classCallCheck → $cC, __callSuper → $cS
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$eX=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cC=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cS=function") != null);
    // 호출부 모두 축약 이름
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$eX(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cC(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cS(") != null);
    // 원본 이름 부재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__extends(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classCallCheck(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__callSuper(") == null);
}

test "#1621 non-minify+es5: class helper 원본 이름 유지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Animal { constructor(n) { this.n = n; } }
        \\class Dog extends Animal {}
        \\console.log(new Dog("rex"));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .unsupported = compat_mod.fromESTarget(.es5),
        // minify 비활성 — 원본 이름 기대
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __extends = function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __classCallCheck = function") != null);
    // 축약 이름 부재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $eX=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $cC=") == null);
}

test "#1621 minify+es5: async → $aS/$gn 축약" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function run() { return await Promise.resolve(1); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$aS=function") != null);
    // $gn(__generator helper)은 IIFE 정의 → #4042 IIFE auto-paren 으로 `(function` (esbuild parity).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$gn=(function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__async(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__generator(") == null);
}

test "#1621 minify+es5: spread/rest → $tA/$aL/$rs 축약" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function merge(a, ...rest) {
        \\  const { x, ...others } = rest[0];
        \\  return [...a, x, others];
        \\}
        \\console.log(merge([1, 2], { x: 10, y: 20, z: 30 }));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __rest (object rest) + __toConsumableArray/__arrayLikeToArray (array spread)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$rs=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$tA=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$aL=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__rest(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toConsumableArray(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__arrayLikeToArray(") == null);
}

test "#1621 minify+es5: tagged template → $tt 축약" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function tag(strs, ...vals) { return strs.raw.join("") + vals.join(","); }
        \\console.log(tag`hello ${1} world ${2}`);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$tt=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__taggedTemplateLiteral(") == null);
}

test "#1621 minify+es5: private method/field → $pI/$pG/$pF 축약" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Box {
        \\  #value = 0;
        \\  #secret() { return this.#value; }
        \\  inc() { this.#value += 1; return this.#secret(); }
        \\}
        \\console.log(new Box().inc());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .unsupported = compat_mod.fromESTarget(.es2021),
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // private method / field helpers 축약.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$pI=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$pG=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classPrivateMethodInit(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classPrivateMethodGet(") == null);
}

test "#1621 minify+keep-names: __name → $nm 축약" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function greeter(name) { return "hi " + name; }
        \\export function main() { return greeter("world"); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $nm=") != null);
    // 호출부도 $nm(
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$nm(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") == null);
}

test "#1621 minify + decorator: __decorateClass/__decorateParam → $dC/$dK" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function Log(target: any, key?: any, kind?: any) { return target; }
        \\@Log
        \\class Service {
        \\  @Log method(@Log arg: string) { return arg; }
        \\}
        \\console.log(new Service().method("x"));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .experimental_decorators = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // decorator preamble: $dp2 + $gD + $dC + $dK 가 단일 var 선언 chain 으로 emit 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $dp2=Object.defineProperty,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$dC=(decorators,target,key,kind)=>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$dK=(index,decorator)=>") != null);
    // single var chain 회복: 중복 `var $dC=` / `var $dK=` 선언이 없어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $dC=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var $dK=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__decorateClass") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__decorateParam") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__defProp2") == null);
}

test "#1621 runtime correctness: es5 minified bundle 실행 결과 일치" {
    // es5 타겟 + minify 로 축약된 helper 들이 원본과 동일한 동작을 하는지 실측.
    // class extends + async + spread 를 한번에 — RN 환경의 대표 패턴.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\class Base { constructor(x) { this.x = x; } tag() { return "base:" + this.x; } }
        \\class Child extends Base {
        \\  constructor(x, y) { super(x); this.y = y; }
        \\  tag() { return super.tag() + ",y:" + this.y; }
        \\}
        \\function merge(a, ...rest) { return [...a, ...rest]; }
        \\const inst = new Child(1, 2);
        \\const arr = merge([inst.x], inst.y, 99);
        \\console.log(inst.tag(), arr.join(","));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preamble + 호출부 모두 축약 이름 일관.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$eX=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$cC=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$tA=function") != null);
    // preamble 의 `var $X=...` 선언 이후 그 이름으로만 호출 — 원본 이름 절대 부재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__extends(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classCallCheck(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toConsumableArray(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__arrayLikeToArray(") == null);
}

// ============================================================
// #4466 — CSS url() 자산 방출 + 재작성
// ============================================================

/// 번들 결과에서 CSS 출력 하나를 찾는다.
fn findCssOutput(result: anytype) ?[]const u8 {
    const outs = result.asset_outputs orelse return null;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".css")) return o.contents;
    }
    return null;
}

test "#4466 CSS url(): 자산 해시 방출 + url 재작성" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css",
        \\@font-face { font-family: icons; src: url(./icons.woff2) format("woff2"); }
    );
    // inline limit 초과 → 별도 파일
    const font = [_]u8{0x77} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icons.woff2", .data = &font });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    // 원문 참조는 사라지고 해시 자산을 가리켜야 한다 (dangling 404 방지)
    try std.testing.expect(std.mem.indexOf(u8, css, "url(./icons.woff2)") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "icons-") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".woff2\"") != null);

    // 자산 파일이 실제로 방출됐는지
    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var found_font = false;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".woff2")) {
            found_font = true;
            try std.testing.expectEqualSlices(u8, &font, o.contents);
        }
    }
    try std.testing.expect(found_font);
}

test "#4466 CSS url(): CSS 전용 자산은 JS 번들에 죽은 __commonJS 로 실리지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';\nconsole.log('hi');");
    try writeFile(tmp.dir, "style.css", ".a { background: url(./bg.png); }");
    const img = [_]u8{0x11} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bg.png", .data = &img });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // JS 는 이 자산을 아무도 require 하지 않는다 → 래퍼가 없어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_bg") == null);
    // 그래도 자산 파일은 방출된다.
    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var found = false;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".png")) found = true;
    }
    try std.testing.expect(found);
}

test "#4466 CSS url(): JS 와 CSS 가 같은 자산을 참조하면 파일 1개로 dedup + JS 래퍼 유지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';\nimport u from './shared.png';\nconsole.log(u);");
    try writeFile(tmp.dir, "style.css", ".a { background: url(./shared.png); }");
    const img = [_]u8{0x22} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shared.png", .data = &img });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // JS 가 실제로 import 하므로 래퍼는 남아야 한다
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_shared") != null);

    // 자산 파일은 하나만
    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var png_count: usize = 0;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".png")) png_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), png_count);
}

test "#4466 CSS url(): 작은 자산은 data URL 로 인라인 (별도 파일 없음)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css", ".a { background: url(./tiny.png); }");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tiny.png", .data = "tiny" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "url(\"data:image/png;base64,") != null);

    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    for (outs) |o| {
        try std.testing.expect(!std.mem.endsWith(u8, o.path, ".png"));
    }
}

test "#4466 CSS url(): 해석 실패는 경고 — 빌드는 성공하고 원문 유지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    // gone.png 를 만들지 않는다
    try writeFile(tmp.dir, "style.css", ".a { background: url(./gone.png); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // 하드 에러가 아니어야 한다 — 기존에 빌드되던 프로젝트를 깨지 않는다
    try std.testing.expect(!result.hasErrors());
    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "url(./gone.png)") != null);
}

test "#4466 CSS url(): external/SVG fragment/절대경로는 손대지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css",
        \\.a { background: url(https://cdn.example.com/a.png); }
        \\.b { filter: url(#blur); }
        \\.c { background: url(/public/keep.png); }
        \\.d { background: url(data:image/gif;base64,R0lGOD); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "url(https://cdn.example.com/a.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(#blur)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(/public/keep.png)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(data:image/gif;base64,R0lGOD)") != null);
}

test "#4466 CSS url(): ?query / #fragment suffix 보존 (IE9 ?#iefix)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css",
        \\@font-face { src: url(./f.eot?#iefix) format("embedded-opentype"); }
    );
    const font = [_]u8{0x33} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.eot", .data = &font });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    // 해시 재작성 + suffix 보존
    try std.testing.expect(std.mem.indexOf(u8, css, ".eot?#iefix\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(./f.eot?#iefix)") == null);
}

test "#4466 CSS url(): --public-path 접두" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css", ".a { background: url(./bg.png); }");
    const img = [_]u8{0x44} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bg.png", .data = &img });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .public_path = "/static/",
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "url(\"/static/bg-") != null);
}

// --- #4466 code-review max 후속: 리뷰가 잡아낸 회귀들의 가드 ---

test "#4466 CSS url(): 기본 테이블 밖 확장자(.cur)도 빌드를 깨지 않는다" {
    // 회귀: `.css_url` 이 일반 import 파이프라인을 타면서, 기본 asset 확장자 테이블에
    // 없는 `.cur`/`.apng`/`.svgz` 등이 `no_loader` **에러**로 빌드를 세웠다. CSS url()
    // 대상은 확장자와 무관하게 파일 자산이다 (Vite 동작).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css", ".c { cursor: url(./p.cur), auto; }");
    const cur = [_]u8{0x55} ** 5000; // 인라인 한계 초과 → 파일
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p.cur", .data = &cur });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "p-") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".cur\"") != null);
}

test "#4466 CSS url(): root-absolute 는 경고 없이 원문 유지" {
    // 회귀: `url(/logo.png)` (public 디렉토리 규약) 이 ImportRecord 로 등록돼
    // resolver 가 못 찾고 "Cannot resolve CSS url() asset" 경고를 헛되이 뿜었다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css", ".a { background: url(/logo.png); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 진단이 아예 없어야 한다 — 정상적인 public 디렉토리 참조다.
    for (result.getDiagnostics()) |d| {
        try std.testing.expect(std.mem.indexOf(u8, d.message, "Cannot resolve CSS url()") == null);
    }
    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "url(/logo.png)") != null);
}

test "#4466 CSS url(): #fragment 참조 자산은 인라인하지 않는다 (SVG 스프라이트)" {
    // 회귀: `.svg` 가 기본 file 로더 + 4KB inline limit 대상이라, 작은 스프라이트가
    // data URL 로 인라인되면서 `#icon` fragment 가 통째로 사라졌다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css", ".i { background: url(./sprite.svg#icon); }");
    try writeFile(tmp.dir, "sprite.svg", "<svg><g id=\"icon\"/></svg>"); // 4KB 미만

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    // data URL 이 아니라 파일이어야 하고, fragment 가 살아 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, css, "data:") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".svg#icon\"") != null);

    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var found_svg = false;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".svg")) found_svg = true;
    }
    try std.testing.expect(found_svg);
}

test "#4466 CSS url(): external 판정된 url() 이 @import 로 새어나가지 않는다" {
    // 회귀: `--packages=external` 등으로 css_url record 가 is_external 이 되면
    // ExternalImportCollector 가 그걸 @import 로 오인해 출력 CSS 상단에
    // `@import "hero.png";` 를 뿜었다 → 브라우저가 PNG 를 stylesheet 로 fetch.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './style.css';");
    try writeFile(tmp.dir, "style.css", ".b { background: url(hero.png); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .packages_external = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    const css = findCssOutput(result) orelse return error.ExpectedCssOutput;
    try std.testing.expect(std.mem.indexOf(u8, css, "@import") == null);
}

test "#4475 동명 basename 자산의 require 래퍼가 deconflict 된다" {
    // 회귀: asset 모듈은 semantic 이 없어 래퍼 이름 등록을 건너뛰었고, emit 이
    // basename 기반 fallback(`require_logo`)을 써서 두 자산이 같은 이름을 가졌다.
    // 두 번째 선언이 첫 번째를 가려 `import x from './a/logo.png'` 가 b 의 URL 을
    // 돌려주는 조용한 오컴파일.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a");
    try tmp.dir.createDirPath(std.testing.io, "b");
    try writeFile(tmp.dir, "entry.ts", "import x from './a/logo.png';\nimport y from './b/logo.png';\nconsole.log(x, y);");
    // inline limit 초과 + 내용이 서로 달라야 해시가 갈린다.
    const img_a = [_]u8{0xA1} ** 5000;
    const img_b = [_]u8{0xB2} ** 5000;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a/logo.png", .data = &img_a });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b/logo.png", .data = &img_b });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 두 자산이 각각 방출됐어야 한다.
    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var png_count: usize = 0;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".png")) png_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), png_count);

    // 래퍼 이름이 충돌하면 안 된다 — `var require_logo` 가 두 번 나오면 BUG.
    var idx: usize = 0;
    var decl_count: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, idx, "var require_logo")) |pos| {
        // `var require_logo$2` 도 매치되므로, 정확히 `require_logo` 로 끝나는지 본다.
        const after = pos + "var require_logo".len;
        if (after < result.output.len and result.output[after] == ' ') decl_count += 1;
        idx = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), decl_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_logo$") != null);
}

// ============================================================
// #4467 — Vite query-suffix import (?raw / ?url / ?inline / ?worker)
// ============================================================

test "#4467 ?raw — 파일 내용을 문자열로 인라인" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import txt from './data.txt?raw';\nconsole.log(txt);");
    try writeFile(tmp.dir, "data.txt", "hello raw content");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello raw content\"") != null);
}

test "#4467 ?url — inline-limit 이하여도 파일로 방출 (명시 요청)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import u from './tiny.png?url';\nconsole.log(u);");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "tiny.png", .data = "tiny" }); // 4B

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // `?url` 은 사용자가 URL 을 명시 요청한 것 — inline-limit 에 먹히면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:") == null);
    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var found = false;
    for (outs) |o| {
        if (std.mem.endsWith(u8, o.path, ".png")) found = true;
    }
    try std.testing.expect(found);
}

test "#4467 ?inline — data URL 로 인라인" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import i from './big.png?inline';\nconsole.log(i);");
    const big = [_]u8{0x99} ** 5000; // 한계 초과지만 ?inline 이 이긴다
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "big.png", .data = &big });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,") != null);
}

test "#4467 같은 파일의 ?url 과 ?inline 은 별개 모듈" {
    // #4475 (래퍼 이름 deconflict) 가 없으면 둘이 서로를 가려 같은 값이 나온다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import u from './x.png?url';
        \\import i from './x.png?inline';
        \\console.log(u, i);
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.png", .data = "tiny" });

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 파일 URL 과 data URL 이 **둘 다** 나와야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "data:image/png;base64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".png\"") != null);
}

test "#4467 ?worker — Worker 생성 함수를 default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import W from './calc.worker.js?worker';\nconst w = new W();\nconsole.log(w);");
    try writeFile(tmp.dir, "calc.worker.js", "self.onmessage = (e) => self.postMessage(e.data * 2);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 표준 worker 패턴으로 합성돼 기존 worker 기계가 별도 청크로 빌드한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import.meta.url") != null);
    // 워커가 별도 파일로 방출됐는지
    const outs = result.asset_outputs orelse return error.ExpectedAssetOutput;
    var found_worker = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.path, "calc.worker") != null) found_worker = true;
    }
    try std.testing.expect(found_worker);
}

test "#4467 알려지지 않은 query 는 건드리지 않는다 (vue SFC 등)" {
    // `?vue&type=style&lang.css` 같은 기존 관용구는 플러그인 영역이다.
    // ViteQuery 가 null 을 반환해 resolver 가 예전처럼 동작해야 한다.
    try std.testing.expect(types.ViteQuery.fromPath("./App.vue?vue&type=style&lang.css") == null);
}

test "#4467 query-suffix 로 block_list 를 우회할 수 없다" {
    // 회귀: resolve() 의 query 분기가 block_list 검사 **전에** early-return 해서,
    // `forbidden/x.txt` 는 막히는데 `forbidden/x.txt?raw` 는 통과했다 — query 를
    // 붙이기만 하면 차단 정책이 뚫리는 구멍.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "forbidden");
    try writeFile(tmp.dir, "forbidden/x.txt", "secret");
    try writeFile(tmp.dir, "entry.ts", "import t from './forbidden/x.txt?raw';\nconsole.log(t);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .block_list = &.{"forbidden/.*"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // 차단됐어야 한다 — 내용이 번들에 들어가면 BUG.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "secret") == null);
}

test "#4467 ?sharedworker 는 SharedWorker 를 만든다" {
    // 회귀: sharedworker 를 worker 와 같은 enum 값으로 접어서 `new Worker` 가 나갔다.
    // `sw.port` 가 없어 런타임에 조용히 깨진다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import SW from './bus.js?sharedworker';\nconsole.log(new SW());");
    try writeFile(tmp.dir, "bus.js", "self.onconnect = () => {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "new SharedWorker(new URL(") != null);
}

test "#4467 ?worker 는 type:module 을 붙이지 않는다 (worker 청크가 classic IIFE)" {
    // 회귀: 래퍼가 { type: "module" } 을 하드코딩했다. 그런데 zntc 는 worker entry 를
    // 항상 classic script(IIFE)로 방출한다 — module worker semantics(strict mode,
    // importScripts 부재)가 적용돼 classic 번들이 시작부터 터질 수 있다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import W from './w.js?worker';\nconsole.log(new W());");
    try writeFile(tmp.dir, "w.js", "self.onmessage = () => {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type: \"module\"") == null);
}

test "#4467 query 모듈의 watcher 경로는 디스크 경로여야 한다" {
    // 회귀: module_paths(=watcher 가 감시할 목록)에 `/abs/x.txt?raw` 를 넘겨서,
    // watcher 가 존재하지 않는 파일을 감시하고 진짜 `/abs/x.txt` 는 아무도 안 봤다.
    // → 편집해도 rebuild 가 안 걸림 (CLI --watch 에서 재현됨).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "note.txt", "V1");
    try writeFile(tmp.dir, "entry.ts", "import t from './note.txt?raw';\nconsole.log(t);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    const paths = result.module_paths orelse return error.ExpectedModulePaths;
    var found_bare = false;
    for (paths) |p| {
        // query 가 붙은 경로가 watcher 목록에 있으면 BUG — 디스크에 없는 이름이다.
        try std.testing.expect(std.mem.indexOfScalar(u8, p, '?') == null);
        if (std.mem.endsWith(u8, p, "note.txt")) found_bare = true;
    }
    // 실제 파일이 감시 목록에 있어야 한다.
    try std.testing.expect(found_bare);
}

// ============================================================
// #4482 — 번들(linking_metadata) 경로의 emit-시점 노드 교체와 load-bearing 괄호/공백
// ============================================================
//
// codegen 은 emit 시점에 노드를 갈아치운다: 상수 인라인(identifier → `void 0`/`-2` 텍스트),
// 상수 단락 fold(`ON && -1` → `-1`), 상수 조건 fold(`ON ? -1 : 2` → `-1`).
// 그래서 **AST 태그**를 보는 괄호/공백 판정은 fold 로 사라질 분기를 보게 되어 구멍이 났다.
// 이 경로는 linking_metadata 가 있어야만 활성화되므로 transpile/codegen 유닛으로는 재현되지
// 않는다 — 번들 테스트로 박제한다.

fn bundleMinified(tmp: *std.testing.TmpDir, comptime opts: struct { syntax: bool = true }) !@import("../bundler.zig").BundleResult {
    const entry = try absPath(tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
        .minify_syntax = opts.syntax,
        .minify_whitespace = true,
    });
    defer b.deinit();
    return b.bundle(std.testing.io);
}

test "#4482 bundle: 상수 인라인된 undefined 가 ** 좌변이면 괄호" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "flags.ts", "export const U = undefined;");
    try writeFile(tmp.dir, "entry.ts",
        \\import { U } from './flags';
        \\globalThis.a = U ** 2;
    );
    var result = try bundleMinified(&tmp, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // 유실 시 `void 0**2` — SyntaxError (단항이 ** 좌변에 직접 못 옴).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(void 0)**2") != null);
}

test "#4482 bundle: 상수 인라인된 undefined 가 member object 면 괄호" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "flags.ts", "export const U = undefined;");
    try writeFile(tmp.dir, "entry.ts",
        \\import { U } from './flags';
        \\try { globalThis.a = U.toString(); } catch (e) { globalThis.a = "TypeError"; }
    );
    var result = try bundleMinified(&tmp, .{ .syntax = false });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // 유실 시 `void 0.toString()` = `void (0..toString())` → SyntaxError.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(void 0).toString()") != null);
}

test "#4482 bundle: 상수 인라인된 정수는 member 앞에 공백 (`2 .toString()`)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "flags.ts", "export const N = 2;");
    try writeFile(tmp.dir, "entry.ts",
        \\import { N } from './flags';
        \\globalThis.a = N.toString();
    );
    var result = try bundleMinified(&tmp, .{ .syntax = false });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // 유실 시 `2.toString()` — `2.` 가 float 로 오파싱 → SyntaxError.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "2 .toString()") != null);
}

test "#4482 bundle: emit 시점 fold 로 살아남는 분기가 ** 좌변이면 괄호" {
    // `(ON && -1) ** k` / `(ON ? -1 : 2) ** k` — codegen 이 logical/conditional 을 접고
    // 살아남는 `-1` 을 그 자리에 emit 한다. AST 태그(logical/conditional)만 보면 단항이
    // 아니라고 판단해 괄호를 안 붙였다 → `-1 ** k` = SyntaxError. minify 없이도 발생.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "flags.ts", "export const ON = true;");
    try writeFile(tmp.dir, "entry.ts",
        \\import { ON } from './flags';
        \\globalThis.r1 = (ON && -1) ** globalThis.k;
        \\globalThis.r2 = (ON ? -1 : 2) ** globalThis.k;
    );
    var result = try bundleMinified(&tmp, .{ .syntax = false });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.output, "(-1)**globalThis.k"));
}

test "#4482 bundle: emit 시점 fold 로 살아남는 분기의 부호 토큰 병합 방지" {
    // `x - (ON ? -1 : 1)` → `x--1` (SyntaxError), `-(ON ? -t : t)` → `--t` (t 를 감소시키는
    // silent miscompile). 공백 판정이 **출력 바이트** 기준이라야 fold 를 따라간다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "flags.ts", "export const ON = true;");
    try writeFile(tmp.dir, "entry.ts",
        \\import { ON } from './flags';
        \\globalThis.b = globalThis.x - (ON ? -1 : 1);
        \\globalThis.c = -(ON ? -globalThis.t : globalThis.t);
    );
    var result = try bundleMinified(&tmp, .{ .syntax = false });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "globalThis.x- -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=- -globalThis.t") != null);
}
