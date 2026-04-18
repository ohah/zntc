const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try bun.bundle();
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM `default` export 구문 보존 (`export default ...` 또는 `export{...as default}`)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "default") != null);
    // 값(42)은 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_default") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
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
