//! Worklet 변환 테스트 (transformer_test.zig에서 분리).
//! Babel react-native-worklets plugin 호환성 검증을 집중적으로 다룬다.
//!
//! 참고:
//! - worklet_babel_parity_test.zig — Babel 테스트 포팅(parity)
//! - plugins/worklet_plugin.zig — 실제 플러그인 구현

const std = @import("std");
const tt = @import("transformer_test.zig");
const transformer_mod = @import("transformer.zig");
const TransformOptions = transformer_mod.TransformOptions;
const Plugin = @import("../bundler/plugin.zig").Plugin;
const worklet_plugin_mod = @import("plugins/worklet_plugin.zig");

const transformWorklet = tt.transformWorklet;
const generateCode = tt.generateCode;
const parseAndTransformWithOptions = tt.parseAndTransformWithOptions;

test "Worklet: function with worklet directive adds property assignments" {
    var r = try transformWorklet(std.testing.allocator,
        \\function animate(x) {
        \\  "worklet";
        \\  return withSpring(x + offset);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // "worklet" 디렉티브가 제거되고, 함수 뒤에 __workletHash, __closure, __initData가 추가됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
    // "worklet" 디렉티브는 출력에서 제거됨
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\"") == null);
}

test "Worklet: function without worklet directive is unchanged" {
    var r = try transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  return x + 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // worklet 변환 없음
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") == null);
}

test "Worklet: statement count includes property assignments" {
    // function + 3 property assignments = 4 statements
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function animate(x) { \"worklet\"; return withSpring(x + offset); }",
        .{ .plugins = &[_]Plugin{worklet_plugin_mod.plugin()}, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    // 1 function declaration + 4 property assignments (hash/closure/initData/stackDetails/pluginVersion) = 6 statements
    try std.testing.expectEqual(@as(u32, 6), r.statementCount());
}

test "Worklet: no closure vars produces empty closure object" {
    var r = try transformWorklet(std.testing.allocator,
        \\function simple() {
        \\  "worklet";
        \\  return 42;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: multiple closure vars are sorted alphabetically" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim(x) {
        \\  "worklet";
        \\  return withSpring(x + offset + scale);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // closure 변수: offset, scale, withSpring (알파벳 순)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "scale") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "withSpring") != null);
}

test "Worklet: parameters are not closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim(x, y) {
        \\  "worklet";
        \\  return x + y + offset;
        \\}
    );
    defer r.deinit();
    // function + 5 property assignments = 6 statements
    try std.testing.expectEqual(@as(u32, 6), r.statementCount());
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x, y는 파라미터이므로 closure에 포함되지 않아야 함
    // __closure에 offset만 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { offset: offset }") != null);
}

test "Worklet: initData contains code and location" {
    var r = try transformWorklet(std.testing.allocator,
        \\function move() {
        \\  "worklet";
        \\  return velocity;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __initData에 code와 location 필드가 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "code:") != null or
        std.mem.indexOf(u8, code, "code: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "location:") != null or
        std.mem.indexOf(u8, code, "location: ") != null);
    // location에 test.ts 경로가 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "test.ts") != null);
}

test "Worklet: non-worklet function mixed with worklet function" {
    var r = try transformWorklet(std.testing.allocator,
        \\function normal() { return 1; }
        \\function anim() {
        \\  "worklet";
        \\  return 2;
        \\}
    );
    defer r.deinit();
    // normal(1) + anim(1) + 5 property assignments = 7 statements
    try std.testing.expectEqual(@as(u32, 7), r.statementCount());
}

test "Worklet: globals are excluded from closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim() {
        \\  "worklet";
        \\  console.log(Math.random());
        \\  return undefined;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // console, Math, undefined는 글로벌이므로 closure에 포함되지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: worklet transform disabled when no plugins" {
    // plugins 없이 변환하면 worklet 처리 안 됨
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function f() { \"worklet\"; return 1; }",
        .{},
    );
    defer r.deinit();
    // plugins가 없으므로 worklet 변환 없음 — statement 1개 (함수만)
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Worklet: rest params are not included in closure (#1104)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function guard(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{
            .plugins = &plugins,
            .jsx_filename = "test.ts",
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // pre-visit body 사용: fn, args는 파라미터이므로 closure 비어야 함.
    // ES5 헬퍼(__toConsumableArray)는 pre-visit body에 없으므로 closure에 미포함.
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: directive found after rest params transform (#1102)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function guard(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{
            .plugins = &plugins,
            .jsx_filename = "test.ts",
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // worklet 변환이 적용되어야 함 (디렉티브가 rest params 뒤로 밀려도)
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    // "worklet" 디렉티브가 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\"") == null);
}

test "Worklet: function_expression worklet produces IIFE factory (#1100)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var x = wrap(function myWorklet() { \"worklet\"; return 42; });",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // IIFE factory로 감싸져야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    // 원본 함수가 IIFE 안에서 var로 할당
    try std.testing.expect(std.mem.indexOf(u8, code, "var myWorklet") != null);
    // return으로 반환
    try std.testing.expect(std.mem.indexOf(u8, code, "return myWorklet") != null);
}

test "Worklet: property access not collected as closure var (if_statement ternary)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(std.testing.allocator,
        \\function calc(current, previous) {
        \\  "worklet";
        \\  if (previous === undefined) {
        \\    return current.force;
        \\  } else {
        \\    return current.force - previous.force;
        \\  }
        \\}
    , .{ .plugins = &plugins, .jsx_filename = "test.ts" });
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 'force'는 property access이므로 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested member expression a.b.c excludes property names" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  return obj.a.b.c;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj는 param → closure 비어야 함. a, b, c는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: external variable captured, property excluded" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var config = { speed: 1 }; function f(x) { \"worklet\"; return x * config.speed; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // config → closure, speed → property 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "config") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { config: config }") != null);
}

test "Worklet: try-catch body member access excludes property" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  try { return obj.data; } catch(e) { return e.message; }
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj, e는 param/catch local → closure 비어야 함. data, message는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: destructuring locals not in closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  const { x, y } = obj;
        \\  return x + y;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x, y는 destructuring → locals. obj는 param → locals.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: conditional expression member access" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(x, flag) {
        \\  "worklet";
        \\  return flag ? x.a : x.b;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // a, b는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: inner function declaration is local" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var cb = 1; function f() { \"worklet\"; function inner() { return 1; } return cb; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // inner → local function. cb → external closure var.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { cb: cb }") != null);
}

test "Worklet: globalThis property not collected as closure var (unary_expression extra)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var fn = 1; function setup() { \"worklet\"; if (!globalThis.__myProp) { globalThis.__myProp = fn; } }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __myProp는 globalThis의 property이므로 closure에 포함되면 안 됨
    // fn만 closure에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { fn: fn }") != null);
}

test "Worklet: arrow function params not in closure (ES5 lowering)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // value, context는 파라미터이므로 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: arrow function params not in closure (arrow 보존, ES5 lowering 없음)" {
    // #1283 후속: RN Hermes 프리셋은 arrow를 보존 — parser가 모든 arrow의 params를
    // formal_parameters list로 정규화하므로 worklet plugin이 파라미터를 올바르게
    // 인식해야 한다. value/context는 closure에 포함되면 안 됨.
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // params(value, context)는 closure에서 제외, ext만 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    // value/context가 __closure에 들어가면 안 됨 (Hermes ReferenceError 방지)
    try std.testing.expect(std.mem.indexOf(u8, code, "value: value") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "context: context") == null);
}

test "Worklet: single-param arrow (x => ...) — x는 closure에서 제외 (arrow 보존)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = x => { \"worklet\"; return ext + x; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "x: x") == null);
}

test "Worklet: arrow function with typed var params not in closure (ES5 lowering)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "type Fn = any; var ext = 1; export const pf: Fn = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // type annotation이 변수에 있고 params에는 없는 경우에도 params는 제외되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: pre-visit body used for initData (no ES5 helpers in closure)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function setup() { \"worklet\"; const f = (cb: any, ...args: any[]) => { cb(...args); }; globalThis.setTimeout = f as any; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // pre-visit body 사용: ES5 헬퍼(__toConsumableArray)가 closure에 없어야 함.
    // Hermes UI runtime이 spread를 네이티브 지원하므로 ES5 변환 불필요.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested function captures outer refs but params stay local" {
    var r = try transformWorklet(std.testing.allocator,
        \\var ext = 1;
        \\export function w() {
        \\  "worklet";
        \\  function inner(x) { return x + ext; }
        \\  return inner(1);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // ext는 inner body에서 참조하는 외부 변수 → worklet closure에 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "ext}=this.__closure") != null);
    // inner의 param x는 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "x: x") == null);
}

test "Worklet: default param (c = 0) not in closure" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export const f = (c = 0) => { \"worklet\"; return c * 2; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // c는 default parameter — closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: default param with external ref" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var scale = 2; export const f = (c = 0) => { \"worklet\"; return c * scale; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // c는 param → 제외, scale은 외부 참조 → 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { scale: scale }") != null);
}

test "Worklet: __stackDetails property is emitted" {
    // Babel workletFactory.ts:298-327 포맷: [new global.Error(), lineOffset, -27]
    var r = try transformWorklet(std.testing.allocator,
        \\function f() {
        \\  "worklet";
        \\  return 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__stackDetails = [new global.Error()") != null);
}

test "Worklet: initData code has no ES5 helpers (spread preserved)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function g(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // initData.code에 __toConsumableArray가 없어야 함 (pre-visit body 사용)
    const init_start = std.mem.indexOf(u8, code, "__initData = { code:") orelse unreachable;
    const init_end = std.mem.indexOfPos(u8, code, init_start, "location:") orelse unreachable;
    const init_section = code[init_start..init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_section, "__toConsumableArray") == null);
    // 원본 spread 문법이 유지되어야 함
    try std.testing.expect(std.mem.indexOf(u8, init_section, "...args") != null);
}

test "Worklet: initData code has no TS syntax (as expression stripped)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function g(v: number) { \"worklet\"; return v as any; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // initData.code에 TS 'as' 구문이 없어야 함
    const init_start = std.mem.indexOf(u8, code, "__initData = { code:") orelse unreachable;
    const init_end = std.mem.indexOfPos(u8, code, init_start, "location:") orelse unreachable;
    const init_section = code[init_start..init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_section, " as ") == null);
}

test "Worklet: global and __DEV__ not captured in closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\export function f() {
        \\  "worklet";
        \\  if (__DEV__) { console.log(global); }
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // global과 __DEV__는 JS_GLOBALS에 등록 → closure에 포함 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: multiple default params not in closure" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const f = (a = 0, b = 1) => { \"worklet\"; return a + b + ext; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // a, b는 default params → 제외, ext만 closure에
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: arrow function with worklet directive is transformed (ES5)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const f = () => { \"worklet\"; return ext; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // arrow worklet이 IIFE factory로 변환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    // "worklet" 디렉티브가 제거되어야 함 (__initData 안은 제외)
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
}

test "Worklet: nested worklet calls another worklet" {
    var r = try transformWorklet(std.testing.allocator,
        \\function helper() {
        \\  "worklet";
        \\  return 42;
        \\}
        \\function main() {
        \\  "worklet";
        \\  return helper();
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 둘 다 worklet으로 변환
    var count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, code, search, "__workletHash")) |pos| {
        count += 1;
        search = pos + 1;
    }
    try std.testing.expect(count >= 2);
    // main의 closure에 helper가 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "helper: helper") != null);
}

test "Worklet: computed property access in worklet body" {
    var r = try transformWorklet(std.testing.allocator,
        \\var obj = {};
        \\var key = "x";
        \\function f() {
        \\  "worklet";
        \\  return obj[key];
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj와 key 모두 closure에 포함 (computed access는 둘 다 외부 참조)
    try std.testing.expect(std.mem.indexOf(u8, code, "key: key") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "obj: obj") != null);
}

test "Worklet: object method with worklet directive is transformed" {
    var r = try transformWorklet(std.testing.allocator,
        \\var logger = { warn(msg) {
        \\  "worklet";
        \\  return msg;
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // object method worklet → object_property + IIFE로 변환
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
    // method가 object_property value로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, code, "warn:") != null);
}

test "Worklet: object method with outer closure vars captured" {
    var r = try transformWorklet(std.testing.allocator,
        \\var config = {};
        \\var obj = { build(props) {
        \\  "worklet";
        \\  return config[props];
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "config}=this.__closure") != null);
}

test "Worklet: getter with worklet directive becomes factory body (Babel 호환)" {
    // getter/setter는 class body에서 IIFE 교체 불가 → body를 factory block으로 치환.
    // `get x() { var x = function(){...}; x.__workletHash=...; return x; }`
    // getter 접근 시 worklet 함수를 반환 (Reanimated 런타임과 일치).
    var r = try transformWorklet(std.testing.allocator,
        \\var obj = { get x() {
        \\  "worklet";
        \\  return 1;
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
}

test "Worklet: scope hoisting rename reflected in closure value" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        \\import { helper } from "./a";
        \\import { helper as h2 } from "./b";
        \\export function w() { "worklet"; return helper() + h2(); }
    ,
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // closure에 helper가 포함되어야 함 (explicit key-value)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "helper:") != null);
}

test "Worklet: auto-workletization for scheduleOnUI argument" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\scheduleOnUI(() => {
        \\  console.log("auto worklet");
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // auto-worklet 변환: __workletHash가 주입되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
}

test "Worklet: auto-workletization for runOnUI argument" {
    var r = try transformWorklet(std.testing.allocator,
        \\function runOnUI(fn) { return fn; }
        \\runOnUI(() => {
        \\  return 42;
        \\})();
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: auto-workletization skips non-function args" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\var x = 1;
        \\scheduleOnUI(x);
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 인자가 함수가 아니면 worklet 변환 없음
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: auto-workletization with correct arg index (withDecay arg 1)" {
    var r = try transformWorklet(std.testing.allocator,
        \\function withDecay(config, callback) {}
        \\withDecay({}, () => {
        \\  console.log("done");
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // withDecay의 두 번째 인자(index 1)가 worklet화
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: auto-workletization does not affect wrong arg index" {
    var r = try transformWorklet(std.testing.allocator,
        \\function withDecay(config, callback) {}
        \\withDecay(() => { return 1; }, null);
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // withDecay의 첫 번째 인자(index 0)는 auto-worklet 대상 아님
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: method auto-workletization for gesture handler onBegin" {
    // Babel parity: `Gesture.Foo()` 체인의 onBegin만 workletize.
    var r = try transformWorklet(std.testing.allocator,
        \\Gesture.Pan().onBegin((e) => {
        \\  console.log(e);
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: method onBegin on non-gesture-object receiver is NOT workletized" {
    // 임의 객체의 `.onBegin()`은 auto-worklet 대상 아님 (Babel parity).
    var r = try transformWorklet(std.testing.allocator,
        \\var gesture = {};
        \\gesture.onBegin((e) => {
        \\  console.log(e);
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: auto-workletization inside worklet function body" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\function outer() {
        \\  "worklet";
        \\  scheduleOnUI(() => {
        \\    console.log("inner");
        \\  });
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // outer 함수의 __workletHash
    try std.testing.expect(std.mem.indexOf(u8, code, "outer.__workletHash") != null);
    // inner arrow도 auto-worklet 변환되어야 함 (IIFE로 wrapping)
    // 이전 버그: stripDirective가 원본 body로 덮어써서 inner 변환이 손실
    const count = std.mem.count(u8, code, "__workletHash");
    try std.testing.expect(count >= 2); // outer + inner
}

test "Worklet: closure analysis includes refs inside object getters/setters/methods" {
    var r = try transformWorklet(std.testing.allocator,
        \\function outerFn() { return 42; }
        \\function w() {
        \\  "worklet";
        \\  return { get v() { return outerFn(); }, set v(x) { outerFn(); }, m() { outerFn(); } };
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // outerFn이 __closure에 포함되어야 함 (getter/setter/method body에서 참조)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "outerFn") != null);
    // __initData.code에서 this.__closure로 destructure
    try std.testing.expect(std.mem.indexOf(u8, code, "outerFn}=this.__closure") != null);
}

test "Worklet: object method worklet strips directive from IIFE body" {
    // method_definition 경로에서 stripped body를 사용하지 않으면
    // IIFE 내부 function 바디에 `'worklet'` directive가 잔존 (Reanimated runtime 크래시).
    var r = try transformWorklet(std.testing.allocator,
        \\var ERROR_MESSAGES = {
        \\  invalidColor(color) {
        \\    "worklet";
        \\    return "Invalid color: " + color;
        \\  }
        \\};
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "invalidColor.__workletHash") != null);
}

test "Worklet: recursive function self-reference excluded from __closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\function recurse(n) {
        \\  "worklet";
        \\  if (n > 0) recurse(n - 1);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: TS type assertion (as) does not break closure analysis" {
    var r = try transformWorklet(std.testing.allocator,
        \\var outer = {} as any;
        \\function w() {
        \\  "worklet";
        \\  return (outer as any).value;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "outer}=this.__closure") != null);
}

test "Worklet: closure captures through ternary, template literal, array, spread" {
    var r = try transformWorklet(std.testing.allocator,
        \\var a = 1, b = 2, c = 3, d = [4];
        \\function w() {
        \\  "worklet";
        \\  var x = a ? b : c;
        \\  var y = `${a}`;
        \\  var z = [...d, a];
        \\  return x + y + z;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "a: a") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "b: b") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "c: c") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "d: d") != null);
}

test "Worklet: closure captures through switch, for-in, try-catch" {
    var r = try transformWorklet(std.testing.allocator,
        \\var val = 1, obj = {}, fn2 = () => {};
        \\function w() {
        \\  "worklet";
        \\  switch (val) { case 1: break; }
        \\  for (var k in obj) {}
        \\  try { fn2(); } catch (e) {}
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "val: val") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "obj: obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "fn2: fn2") != null);
    // catch param 'e'는 closure가 아닌 로컬
    try std.testing.expect(std.mem.indexOf(u8, code, "e: e") == null);
}

test "Worklet: method param shadowing does not leak to outer closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\var x = 1;
        \\function w() {
        \\  "worklet";
        \\  var x = 2;
        \\  return { set v(x) { console.log(x); } };
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x는 worklet 내부 로컬이므로 closure에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested object with computed property and new expression" {
    var r = try transformWorklet(std.testing.allocator,
        \\var key = "a", Cls = class {};
        \\function w() {
        \\  "worklet";
        \\  var o = { [key]: new Cls() };
        \\  return o;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "key: key") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "Cls: Cls") != null);
}

test "Worklet: nested function and arrow capture outer imports" {
    var r = try transformWorklet(std.testing.allocator,
        \\var isShared = (v) => v != null;
        \\var helper = () => 42;
        \\function w() {
        \\  "worklet";
        \\  function extract(x) {
        \\    if (isShared(x)) return;
        \\    var fn = () => helper();
        \\  }
        \\  return extract;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 중첩 function 안의 isShared와 arrow 안의 helper 모두 worklet closure에 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "isShared: isShared") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "helper: helper") != null);
    // extract의 param x는 closure에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, " x:x") == null);
}

test "Worklet: arrow callback param does not leak into outer closure (cover grammar)" {
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  var arr = [];
        \\  arr.forEach((item) => item());
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // arrow param 'item'은 closure에 없어야 함 (cover grammar 파라미터)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: arrow with destructured param does not leak" {
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  var fn = ({ a, b }) => a + b;
        \\  return fn;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

// ============================================================
// Babel parity: __initData.code destructuring shorthand + sourceMap field (#1193 follow-up)
// ============================================================

test "Worklet: __initData.code uses shorthand destructuring (const {X} = this.__closure)" {
    // Babel react-native-worklets는 worklet code string에서 shorthand 형태로 emit.
    // Reanimated runtime이 해당 형태를 기대하는 경우를 대비 parity 유지.
    var r = try transformWorklet(std.testing.allocator,
        \\var foo = 1;
        \\function w() {
        \\  "worklet";
        \\  return foo + 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "{foo}=this.__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "{foo:foo}=this.__closure") == null);
}

test "Worklet: __initData.code shorthand for multiple closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\var a = 1, b = 2, c = 3;
        \\function w() {
        \\  "worklet";
        \\  return a + b + c;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "{a,b,c}=this.__closure") != null);
}

test "Worklet: __initData does NOT emit sourceMap when none generated" {
    // Babel plugin은 실제 source map 생성 성공 시에만 sourceMap 필드를 주입
    // (workletFactory.ts:187). 빈 문자열을 넣으면 Reanimated 네이티브가
    // JSON 파싱 실패 → UI Runtime 초기화 abort →
    // `Expected microtaskQueueFinalizers to be defined` 에러로 이어짐.
    // ZTS는 worklet 수준 source map 미지원 → 필드 생략이 정답.
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  return 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "sourceMap") == null);
}
