const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;
const e2eCJS = helpers.e2eCJS;
const e2eJSX = helpers.e2eJSX;
const e2eFull = helpers.e2eFull;
const e2eWithOptions = helpers.e2eWithOptions;
const e2eSourceMap = helpers.e2eSourceMap;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;
const TestResult = helpers.TestResult;
const e2eTarget = helpers.e2eTarget;
const expectAsyncStateMachine = helpers.expectAsyncStateMachine;
const e2eES5Async = helpers.e2eES5Async;
const assertNoAsyncSelfLoop = helpers.assertNoAsyncSelfLoop;

// ES Downlevel Tests (--target)
// ============================================================

// --- ?? (nullish coalescing) ---

test "ES2020: ?? simple identifier" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a!=null?a:b;", r.output);
}

test "ES2020: ?? side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "const x = foo() ?? b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;const x=(_a=foo())!=null?_a:b;", r.output);
}

test "ES2020: ?? no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

test "ES2020: ?? no transform on es2020" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

// --- ?. (optional chaining) ---

test "ES2020: ?. member" {
    var r = try e2eTarget(std.testing.allocator, "a?.b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("(a==null?void 0:a.b);", r.output);
}

test "ES2020: ?. computed" {
    var r = try e2eTarget(std.testing.allocator, "a?.[0];", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("(a==null?void 0:a[0]);", r.output);
}

test "ES2020: ?. call" {
    var r = try e2eTarget(std.testing.allocator, "a?.();", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("(a==null?void 0:a());", r.output);
}

test "ES2020: ?. side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "foo()?.bar;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;((_a=foo())==null?void 0:_a.bar);", r.output);
}

test "ES2020: ?. chain continuation" {
    var r = try e2eTarget(std.testing.allocator, "a?.b.c;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("(a==null?void 0:a.b.c);", r.output);
}

test "ES2020: ?. no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "a?.b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("a?.b;", r.output);
}

// --- ??= (nullish assignment) ---

test "ES2021: ??= to es2020" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a??(a=b);", r.output);
}

test "ES2021: ??= to es2019 (double lowering)" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a!=null?a:(a=b);", r.output);
}

test "ES2021: ??= no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("a??=b;", r.output);
}

// --- ||= &&= (logical assignment) ---

test "ES2021: ||=" {
    var r = try e2eTarget(std.testing.allocator, "a ||= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a||(a=b);", r.output);
}

test "ES2021: &&=" {
    var r = try e2eTarget(std.testing.allocator, "a &&= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a&&(a=b);", r.output);
}

test "ES2021: ||= no transform on es2021" {
    var r = try e2eTarget(std.testing.allocator, "a ||= b;", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("a||=b;", r.output);
}

// --- ** (exponentiation) ---

test "ES2016: ** to Math.pow" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .es2015);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Math.pow(a,b);", r.output);
}

test "ES2016: **= to Math.pow assignment" {
    var r = try e2eTarget(std.testing.allocator, "a **= b;", .es2015);
    defer r.deinit();
    try std.testing.expectEqualStrings("a=Math.pow(a,b);", r.output);
}

test "ES2016: ** no transform on es2016" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .es2016);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a**b;", r.output);
}

test "ES2016: ** no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a**b;", r.output);
}

test "ES2016: **= no transform on es2016" {
    var r = try e2eTarget(std.testing.allocator, "a **= b;", .es2016);
    defer r.deinit();
    try std.testing.expectEqualStrings("a**=b;", r.output);
}

// --- catch binding (ES2019) ---

test "ES2019: optional catch binding" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(_unused){y;}", r.output);
}

test "ES2019: catch with binding preserved" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch (e) { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(e){y;}", r.output);
}

test "ES2019: optional catch no transform on es2019" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch{y;}", r.output);
}

// --- ES2022: class static block ---

test "ES2022: static block to IIFE" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { console.log(\"init\"); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}(()=>{console.log(\"init\");})();", r.output);
}

test "ES2022: static block no transform on es2022" {
    // static_block은 writeNodeSpan으로 소스를 그대로 복사하므로 공백이 유지됨
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .es2022);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\")}}", r.output);
}

test "ES2022: static block no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\")}}", r.output);
}

test "ES2022: multiple static blocks" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { a(); } method() {} static { b(); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{method(){}}(()=>{a();})();(()=>{b();})();", r.output);
}

test "ES2022: static block with methods preserved" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { method() { return 1; } static { init(); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{method(){return 1;}}(()=>{init();})();", r.output);
}

// --- ES2017: async/await → generator ---

test "ES2017: async function declaration" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { return await bar(); }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export function foo(){return __async(function*(){return (yield bar());}).call(this);}", r.output);
}

test "ES2017: async arrow block body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => { await x; };", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){(yield x);}).call(this);", r.output);
}

test "ES2017: async arrow expression body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => await x;", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){return (yield x);}).call(this);", r.output);
}

test "ES2017: no transform on es2017" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { await x; }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2017) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export async function foo(){await x;}", r.output);
}

test "ES2017: no transform on esnext" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { await x; }", .{ .unsupported = TransformOptions.compat.fromESTarget(.esnext) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export async function foo(){await x;}", r.output);
}

test "ES2017: non-async function unchanged" {
    var r = try e2eFull(std.testing.allocator, "export function foo() { return 1; }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export function foo(){return 1;}", r.output);
}

// --- ES5: async → state machine (async_await + generator 둘 다 unsupported) ---

test "ES5: async function → __async + __generator state machine" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return await bar(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state") != null);
}

test "ES5: async function with multiple awaits" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var x = await a(); await b(x); return x; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES5: async arrow block body → state machine" {
    var r = try e2eTarget(std.testing.allocator, "var f = async () => { await x; };", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async arrow expression body → state machine" {
    var r = try e2eTarget(std.testing.allocator, "var f = async () => await x;", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async function with if/await" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { if (x) { await a(); } await b(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async if-await as last statement — no self-loop in resume case" {
    // Regression: `if (cond) { await x(); }` 가 함수의 마지막 statement 일 때 await
    // resume 후 case 가 자기 자신으로 jump 하는 self-loop 발생 (collectIfOperations 의
    // end_label 을 yield 전 미리 할당해서 yield resume label 과 충돌).
    // 실제 발견 — ExpoApp ExternalLink 에서 in-app browser 닫으면 무한 루프 → 모든 onPress dead.
    var r = try e2eTarget(std.testing.allocator, "async function f(x) { if (x) { await a(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    // self-loop pattern — `_state.sent()` 직후 `return [3, N]` 의 N 이 자기 case 의 label.
    // 이 함수에서 await yield label 은 1 (label 0 은 시작), end label 은 2 여야 함.
    // bug 시: `case 1:_state.sent();return [3,1]` (자기 self-jump → 무한 루프).
    // fix 시: `case 1:_state.sent();return [2]` (end) 또는 `return [3,2]` (forward jump).
    // (e2eTarget 은 minify_whitespace=true 라 space 제거된 형태로 검사.)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent();return [3,1]") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent();return [3, 1]") == null);
}

test "ES5: async if-await with later statements — case fall-through correctness" {
    // 위 테스트의 동반 — if 후 trailing statement 가 있을 때도 await resume 이 정상 fall-through
    // 해야 함. 이 케이스는 기존에 동작하던 패턴 (회귀 방지용).
    var r = try e2eTarget(std.testing.allocator, "async function f(x) { if (x) { await a(); } var y = 1; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var y") != null);
}

// `assertNoAsyncSelfLoop` 가 case-label-aware 라 self-loop (`_state.sent();return [3,N]` 의
// N 이 자기 case 의 label) 만 fail. forward jump 는 정상. `e2eES5Async` 가 ES5 transform +
// state-machine 검증 + self-loop 검사 자동. 25 case = #1887 회귀 + 다른 control-flow generic.
const AsyncStateMachineCase = struct {
    name: []const u8,
    src: []const u8,
};

const async_state_machine_cases = [_]AsyncStateMachineCase{
    // === if-await — #1887 회귀 케이스 ===
    .{ .name = "if-await as last statement (#1887 reproduction)", .src = "async function f(x) { if (x) { await a(); } }" },
    .{ .name = "if-await multi-statement then body (real ExpoApp ExternalLink pattern)", .src = "async function f(e, h) { if (e !== 'web') { e.preventDefault(); await openBrowserAsync(h); } }" },
    .{ .name = "if-else with await in then only", .src = "async function f(x) { if (x) { await a(); } else { b(); } }" },
    .{ .name = "if-else with await in else only", .src = "async function f(x) { if (x) { a(); } else { await b(); } }" },
    .{ .name = "if-else with await in both branches", .src = "async function f(x) { if (x) { await a(); } else { await b(); } }" },
    .{ .name = "nested if with inner await", .src = "async function f(x, y) { if (x) { if (y) { await a(); } } }" },
    .{ .name = "deeply nested if (3 levels)", .src = "async function f(a, b, c) { if (a) { if (b) { if (c) { await x(); } } } }" },
    .{ .name = "sequential if-await blocks", .src = "async function f(x, y) { if (x) { await a(); } if (y) { await b(); } }" },
    .{ .name = "sibling if-await inside same parent if", .src = "async function f(p, x, y) { if (p) { if (x) { await a(); } if (y) { await b(); } } }" },
    .{ .name = "await inside for-loop body", .src = "async function f(arr) { for (var i = 0; i < arr.length; i++) { if (arr[i]) { await a(); } } }" },
    .{ .name = "await inside while-loop body", .src = "async function f(x) { while (x) { if (x.flag) { await a(); } x = x.next; } }" },
    .{ .name = "try-catch wrapping if-await", .src = "async function f(x) { try { if (x) { await a(); } } catch (e) { b(e); } }" },
    .{ .name = "if-await as arrow function body", .src = "var f = async (e) => { if (e !== 'web') { await a(); } };" },
    .{ .name = "early return after if-await", .src = "async function f(x) { if (x) { await a(); } return 1; }" },
    .{ .name = "multiple awaits in same then block", .src = "async function f(x) { if (x) { await a(); await b(); await c(); } }" },
    .{ .name = "condition expression contains await", .src = "async function f() { if (await check()) { await a(); } }" },

    // === 다른 control-flow + await — 이미 sentinel pattern 적용된 site 회귀 방지 ===
    .{ .name = "try-catch + await", .src = "async function f() { try { await a(); } catch (e) {} }" },
    .{ .name = "try-finally + await", .src = "async function f() { try { await a(); } finally { b(); } }" },
    .{ .name = "switch case body + await", .src = "async function f(x) { switch (x) { case 1: await a(); break; case 2: await b(); break; } }" },
    .{ .name = "do-while + await", .src = "async function f(x) { do { await a(); } while (x); }" },
    .{ .name = "for-of + await", .src = "async function f(arr) { for (var x of arr) { await x; } }" },
    .{ .name = "labeled outer break + await", .src = "async function f() { outer: for (;;) { if (true) { await a(); break outer; } } }" },
    .{ .name = "loop break in if-await", .src = "async function f() { for (;;) { if (true) { await a(); break; } } }" },
    .{ .name = "if-await + try-catch combined", .src = "async function f(x) { if (x) { try { await a(); } catch (e) {} } }" },
    .{ .name = "nested async function inside async function", .src = "async function f() { var inner = async function() { if (true) { await b(); } }; await inner(); }" },
};

test "ES5: async state-machine edge cases (#1887 + control-flow self-loop)" {
    for (async_state_machine_cases) |c| {
        var r = e2eES5Async(std.testing.allocator, c.src) catch |err| {
            std.debug.print("\nfailed case: {s}\nsrc: {s}\n", .{ c.name, c.src });
            return err;
        };
        defer r.deinit();
    }
}

test "ES5: if-await edge — empty then block (no statements)" {
    // 빈 then — await 없으니 e2eES5Async 의 self-loop assertion N/A. emit 깨지지 않는지만.
    var r = try e2eTarget(std.testing.allocator, "async function f(x) { if (x) {} await a(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with destructuring var hoisting" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var {a, b} = await getObj(); return a + b; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    // destructuring은 개별 identifier로 호이스팅: var a, b; (not var {a, b};)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a,b") != null or
        std.mem.indexOf(u8, r.output, "var a, b") != null);
    // destructuring 패턴이 초기화 없이 나오면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var {") == null);
}

// --- yield/await in expression position ---

test "ES5: await in if condition (logical AND)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { if (x && (await check())) { doSomething(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES5: await in if condition (logical OR)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { if (x || (await fallback())) { run(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in if condition (simple)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { if (await check()) { run(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in while condition" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { while (await hasNext()) { process(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in for test condition" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { for (var i = 0; await check(i); i++) { run(i); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in return expression (nested in call)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return bar(await x); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: multiple awaits in call args" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { bar(await x, await y); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in binary expression" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return (await a) + (await b); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in unary expression (negation)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { if (!(await check())) { fallback(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in ternary expression" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { return x ? await a() : await b(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: double await (await (await nested()))" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return await (await getPromise()); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in var init (nested in call)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var x = bar(await y); return x; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
}

test "ES5: generator with yield in if condition" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(x) { if (x && (yield check())) { run(); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: generator with yield in return expression" {
    var r = try e2eTarget(std.testing.allocator, "function* gen() { return foo(yield x); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: await in object literal" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return {x: await a, y: await b}; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in template literal" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return `hello ${await name()}`; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in spread element" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return bar(...await getArgs()); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in member expression (a.b.method(await x))" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { if (a.b && (await a.c())) { run(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: multiple awaits in array literal use temp vars" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return [await a, await b]; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    // 각 yield 결과가 temp 변수에 저장되어야 함 (직접 _state.sent() 중복 호출 방지)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=_state.sent()") != null or
        std.mem.indexOf(u8, r.output, "= _state.sent()") != null);
}

test "ES5: class async method → state machine (RN KeyboardAvoidingView pattern)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  async bar(x) {
        \\    if (x && (await check())) { return 0; }
        \\    const y = await compute(x);
        \\    return y;
        \\  }
        \\}
    , .es5);
    defer r.deinit();
    // class async method도 state machine으로 변환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
    // async 키워드가 메서드 선언에 남아있으면 안 됨 (async function은 __async 헬퍼 제외)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function") == null);
}

test "ES5: class static async method → state machine" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static async fetch() { return await getData(); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: destructuring default parameter with spread (AnimatedImplementation pattern)" {
    var r = try e2eTarget(std.testing.allocator, "function foo() { return {...x}; }\nfunction bar({a = 1, b = true} = {}) { return a; }", .es5);
    defer r.deinit();
    // spread + destructuring default parameter → 크래시 없이 출력
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "ES5: destructuring default parameter in function" {
    var r = try e2eTarget(std.testing.allocator, "function loop(animation, {iterations = -1, reset = true} = {}) { return iterations; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
    // destructuring은 var {iterations, reset} = _ref 형태로 분해
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: destructuring property key not renamed by linker" {
    // { polyfillGlobal: polyfillGlobal$4 } → var polyfillGlobal$4 = _ref.polyfillGlobal
    // 프로퍼티 키(polyfillGlobal)는 리네이밍되면 안 됨 (_ref.polyfillGlobal$4 가 되면 버그)
    var r = try e2eTarget(std.testing.allocator, "const obj = {a: 1}; const {a: renamed} = obj; renamed;", .es5);
    defer r.deinit();
    // 프로퍼티 접근은 원본 이름: _a.a
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
    // 변수명은 renamed
    try std.testing.expect(std.mem.indexOf(u8, r.output, "renamed") != null);
}

test "ES5: generator with destructuring var hoisting" {
    var r = try e2eTarget(std.testing.allocator, "function* gen() { var {x, y} = yield getObj(); return x; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var {") == null);
}

test "ES5: __async runtime ES5 compatibility" {
    const rt = @import("../../bundler/runtime_helpers.zig");
    // ES5 런타임 상수에 arrow function / rest params가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5, "=>") == null);
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5, "...") == null);
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5_MIN, "=>") == null);
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5_MIN, "...") == null);
    // ES5 타겟에서 es5_compat가 설정되는지 확인
    var r = try e2eTarget(std.testing.allocator, "async function foo() { await bar(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

// --- ES5: 추가 async/generator edge cases ---

test "ES5: async with try/catch + await" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { try { await a(); } catch(e) { await b(e); } finally { await c(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with do-while + await in condition" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var i = 0; do { i++; } while (await check(i)); return i; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: class async arrow field" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  _update = async () => {
        \\    const x = await getData();
        \\    this.setState({data: x});
        \\  };
        \\}
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES5: class with async method + non-async method" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  sync() { return 1; }
        \\  async asyncMethod() { return await bar(); }
        \\  static staticSync() { return 2; }
        \\}
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype.sync") != null);
}

test "ES5: async with while(true) + await + break" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { while (true) { var x = await next(); if (!x) break; } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with switch + await" {
    var r = try e2eTarget(std.testing.allocator,
        \\async function foo(type) {
        \\  switch (type) {
        \\    case 'a': await handleA(); break;
        \\    case 'b': await handleB(); break;
        \\    default: await handleDefault();
        \\  }
        \\}
    , .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with labeled break + await" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { outer: for (var i = 0; i < 3; i++) { if (await check(i)) break outer; } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: nested async functions" {
    var r = try e2eTarget(std.testing.allocator,
        \\async function outer() {
        \\  async function inner() { return await bar(); }
        \\  return await inner();
        \\}
    , .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

// --- ES2018: object spread ---

test "ES2018: spread only" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},obj);", r.output);
}

test "ES2018: props then spread" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, ...obj };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({a:1},obj);", r.output);
}

test "ES2018: spread then props" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},obj,{b:2});", r.output);
}

test "ES2018: mixed spread" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, ...obj, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({a:1},obj,{b:2});", r.output);
}

test "ES2018: multiple spreads" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...a, ...b };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},a,b);", r.output);
}

test "ES2018: no transform on es2018" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...obj};", r.output);
}

test "ES2018: no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...obj};", r.output);
}

test "ES2018: no spread - no transform" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={a:1,b:2};", r.output);
}

// --- ES2022: class static block ---

test "ES2022: static block this → class name" {
    // class Foo { static { this.x = 1; } }
    // → class Foo {} (() => { Foo.x = 1; })();
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { this.x = 1; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}(()=>{Foo.x=1;})();", r.output);
}

test "ES2022: static block this in nested function not replaced" {
    // 일반 함수 안의 this는 치환하면 안 됨 (자체 this 바인딩)
    var r = try e2eTarget(std.testing.allocator, "class Bar { static { function f() { return this; } } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Bar{}(()=>{function f(){return this;}})();", r.output);
}

test "ES2022: static block this in arrow replaced" {
    // arrow function은 this 상속 → 치환 대상
    var r = try e2eTarget(std.testing.allocator, "class Baz { static { const f = () => this.x; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Baz{}(()=>{const f=()=>Baz.x;})();", r.output);
}

test "ES2022: static block anonymous class - this not replaced" {
    // 익명 클래스: 클래스 이름이 없으므로 this 그대로
    var r = try e2eTarget(std.testing.allocator, "var x = class { static { this.y = 1; } };", .es2021);
    defer r.deinit();
    // 익명 클래스는 this 치환 안 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.y") != null);
}

test "ES2022: static block this - no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{this.x=1;}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{this.x=1;}}", r.output);
}

test "ES2022: multiple static blocks with this" {
    var r = try e2eTarget(std.testing.allocator, "class A { static { this.x = 1; } static { this.y = 2; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class A{}(()=>{A.x=1;})();(()=>{A.y=2;})();", r.output);
}

// --- ES2015: template literal ---

test "ES2015: no-substitution template" {
    var r = try e2eTarget(std.testing.allocator, "var x=`hello`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"hello\";", r.output);
}

test "ES2015: template with substitution" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\" + b + \"c\";", r.output);
}

test "ES2015: template empty head" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\" + a;", r.output);
}

test "ES2015: template multiple substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}${b}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\" + a + b;", r.output);
}

test "ES2015: template with text between substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c${d}e`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\" + b + \"c\" + d + \"e\";", r.output);
}

test "ES2015: empty template" {
    var r = try e2eTarget(std.testing.allocator, "var x=``;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\";", r.output);
}

test "ES2015: template no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x=`hello`;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello`;", r.output);
}

// --- tagged template ---

test "tagged template: basic" {
    var r = try e2e(std.testing.allocator, "foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo`hello`;", r.output);
}

test "tagged template: with substitution" {
    var r = try e2e(std.testing.allocator, "foo`hello ${x} world`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo`hello ${x} world`;", r.output);
}

test "tagged template: after var declaration" {
    var r = try e2e(std.testing.allocator, "var x;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var x;foo`hello`;", r.output);
}

test "tagged template: after let declaration" {
    var r = try e2e(std.testing.allocator, "let x=1;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;foo`hello`;", r.output);
}

test "tagged template: after function declaration" {
    var r = try e2e(std.testing.allocator, "function f(){}foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(){}foo`hello`;", r.output);
}

test "tagged template: as identifier as tag" {
    var r = try e2e(std.testing.allocator, "as`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("as`hello`;", r.output);
}

test "tagged template: member expression tag" {
    var r = try e2e(std.testing.allocator, "foo.bar`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo.bar`hello`;", r.output);
}

test "tagged template: no-substitution after expression statement" {
    var r = try e2e(std.testing.allocator, "1;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("1;foo`hello`;", r.output);
}

// --- ES2015: shorthand property ---

test "ES2015: shorthand property expansion" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,y};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:x,y:y};", r.output);
}

test "ES2015: mixed shorthand and full property" {
    var r = try e2eTarget(std.testing.allocator, "var o={x:1,y};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:1,y:y};", r.output);
}

test "ES2015: shorthand no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,y};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x,y};", r.output);
}

// --- ES2015: computed property ---

test "ES2015: computed property lowering" {
    var r = try e2eTarget(std.testing.allocator, "var o={a:1,[k]:v,b:2};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={a:1},_a[k]=v,_a.b=2,_a);", r.output);
}

test "ES2015: computed property only" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k]:v};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={},_a[k]=v,_a);", r.output);
}

test "ES2015: no computed - no transform" {
    var r = try e2eTarget(std.testing.allocator, "var o={a:1,b:2};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={a:1,b:2};", r.output);
}

test "ES2015: computed no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k]:v};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={[k]:v};", r.output);
}

// --- ES2015: object method shorthand (#1385) ---

test "ES2015: object method shorthand → key:function" {
    var r = try e2eTarget(std.testing.allocator, "var o={m(){return 1;}};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={m:function(){return 1;}};", r.output);
}

test "ES2015: object method shorthand + shorthand property mix" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,m(){return 1;}};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:x,m:function(){return 1;}};", r.output);
}

test "ES2015: object getter/setter preserved (ES5 supports)" {
    var r = try e2eTarget(std.testing.allocator, "var o={get x(){return 1;},set x(v){},m(){return 2;}};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={get x(){return 1;},set x(v){},m:function(){return 2;}};", r.output);
}

test "ES2015: object computed method → bracket assignment with function" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k](){return 1;}};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={},_a[k]=function(){return 1;},_a);", r.output);
}

test "ES2015: object Symbol.dispose computed method" {
    var r = try e2eTarget(std.testing.allocator, "var o={[Symbol.dispose](){}};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={},_a[Symbol.dispose]=function(){},_a);", r.output);
}

test "ES2015: object method no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={m(){return 1;}};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={m(){return 1;}};", r.output);
}

test "ES2015: object async method → state machine wrapped in function" {
    var r = try e2eTarget(std.testing.allocator, "var o={async a(){return 1;}};", .es5);
    defer r.deinit();
    // a: function() { ... __async(...) ... }
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a:function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") != null);
    // 메서드 shorthand 원형이 남아 있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async a(") == null);
}

test "ES2015: object generator method → state machine wrapped in function" {
    var r = try e2eTarget(std.testing.allocator, "var o={*g(){yield 1;}};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "g:function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "*g(") == null);
}

// --- ES2015: default/rest parameters ---

test "ES2015: default parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1){return x;}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){x=x===void 0?1:x;return x;}", r.output);
}

test "ES2015: rest parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f(a,...rest){return rest;}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(a){var rest=[].slice.call(arguments,1);return rest;}", r.output);
}

test "ES2015: default + rest combined" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1,...rest){}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){x=x===void 0?1:x;var rest=[].slice.call(arguments,1);}", r.output);
}

test "ES2015: params no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1,...rest){}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x=1,...rest){}", r.output);
}

// --- ES2015: spread ---

test "ES2015: spread in call" {
    var r = try e2eTarget(std.testing.allocator, "f(...arr);", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("f.apply(void 0,[].concat(__toConsumableArray(arr)));", r.output);
}

test "ES2015: spread in call with args" {
    var r = try e2eTarget(std.testing.allocator, "f(a,...arr);", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("f.apply(void 0,[].concat([a],__toConsumableArray(arr)));", r.output);
}

test "ES2015: spread in array" {
    var r = try e2eTarget(std.testing.allocator, "var x=[...arr,1];", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=[].concat(__toConsumableArray(arr),[1]);", r.output);
}

test "ES2015: spread no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "f(...arr);", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("f(...arr);", r.output);
}

test "ES2015: spread in new expression" {
    var r = try e2eTarget(std.testing.allocator, "new Foo(...args);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.bind.apply") != null);
}

// --- ES2015: arrow function ---

test "ES2015: arrow expression body" {
    var r = try e2eTarget(std.testing.allocator, "var f=()=>42;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(){return 42;};", r.output);
}

test "ES2015: arrow with param" {
    var r = try e2eTarget(std.testing.allocator, "var f=x=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x + 1;};", r.output);
}

test "ES2015: arrow with parens param" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x + 1;};", r.output);
}

test "ES2015: arrow block body" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>{return x;};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x;};", r.output);
}

test "ES2015: arrow multiple params" {
    var r = try e2eTarget(std.testing.allocator, "var f=(a,b)=>a+b;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(a,b){return a + b;};", r.output);
}

test "ES2015: arrow no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var f=()=>42;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=()=>42;", r.output);
}

test "ES2015: arrow destructuring params lowered" {
    var r = try e2eTarget(std.testing.allocator, "var f=({a,...rest})=>rest;", .es5);
    defer r.deinit();
    // destructuring + rest → 임시 변수 + __rest
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...rest") == null);
}

test "ES2015: arrow destructuring with rename lowered" {
    var r = try e2eTarget(std.testing.allocator, "var f=({ref:forwardedRef,style,...rest})=>rest;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "forwardedRef") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
}

test "ES2015: __rest includes string literal keys in exclude list" {
    var r = try e2eTarget(std.testing.allocator, "var f=({'aria-busy':ariaBusy,style,...rest})=>rest;", .es5);
    defer r.deinit();
    // 'aria-busy'가 __rest 제외 목록에 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"aria-busy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"style\"") != null);
}

test "ES2015: __rest with multiple string literal keys" {
    var r = try e2eTarget(std.testing.allocator, "var f=({ref:fwd,'aria-busy':ab,'aria-label':al,style,...rest})=>rest;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"ref\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"aria-busy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"aria-label\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"style\"") != null);
}

test "ES2015: arrow default param lowered" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x=1)=>x;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(") != null);
    // default param → body에 초기화 문 삽입
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null or
        std.mem.indexOf(u8, r.output, "=1") != null);
}

test "ES2015: arrow simple params — no unnecessary lowering" {
    var r = try e2eTarget(std.testing.allocator, "var f=(a,b)=>a+b;", .es5);
    defer r.deinit();
    // 단순 파라미터는 그대로 유지 (destructuring lowering 불필요)
    try std.testing.expectEqualStrings("var f=function(a,b){return a + b;};", r.output);
}

test "ES2015: class method destructuring params lowered" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { method({x,...rest}:any) { return rest; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...rest") == null);
}

test "ES2015: class setter destructuring params lowered" {
    var r = try e2eTarget(std.testing.allocator, "class Bar { set val({x,...rest}:any) {} }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...rest") == null);
}

test "ES2015: class method default param lowered" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { method(x=1) { return x; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "ES2015: class constructor destructuring params lowered" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { constructor({x,...rest}:any) { console.log(rest); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo(_b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...rest") == null);
}

test "ES2015: async function destructuring params lowered" {
    var r = try e2eTarget(std.testing.allocator, "async function f({a,...r}:any) { return r; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function f(_b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...r") == null);
}

test "ES2015: generator function destructuring params lowered" {
    var r = try e2eTarget(std.testing.allocator, "function* g({x,...rest}:any) { yield rest; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function g(_b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...rest") == null);
}

// --- ES2015: for-of ---

test "ES2015: for-of with const" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){f(x);}", .es5);
    defer r.deinit();
    // iterator protocol: Symbol.iterator + .next() + try-catch-finally
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Symbol.iterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".next()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".value") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".done") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "try") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "catch") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "finally") != null);
}

test "ES2015: for-of with expression left" {
    var r = try e2eTarget(std.testing.allocator, "for(x of arr){}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Symbol.iterator") != null);
}

test "ES2015: for-of no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){}", r.output);
}

test "ES2015: for-of iterator.return cleanup in finally" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of s){}", .es5);
    defer r.deinit();
    // finally에서 .return != null 체크 + .return() 호출
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".return!=null") != null or
        std.mem.indexOf(u8, r.output, ".return != null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".return()") != null);
}

test "ES2015: for-of catch rethrows in finally" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of s){}", .es5);
    defer r.deinit();
    // catch에서 에러 플래그 설정, finally에서 rethrow
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "throw ") != null);
}

test "ES2015: for-of let produces var" {
    var r = try e2eTarget(std.testing.allocator, "for(let x of arr){f(x);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".value") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Symbol.iterator") != null);
}

test "ES2015: for-of .next().done in test expr" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".next()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".done") != null);
}

test "ES2015: nested for-of unique variable names" {
    // 중첩 for-of에서 변수명 충돌 없이 각각 고유한 temp var 사용
    var r = try e2eTarget(std.testing.allocator, "for(const x of a){for(const y of b){}}", .es5);
    defer r.deinit();
    // Symbol.iterator가 2번 이상 나와야 함 (outer + inner)
    const first = std.mem.indexOf(u8, r.output, "Symbol.iterator") orelse unreachable;
    try std.testing.expect(std.mem.indexOf(u8, r.output[first + 1 ..], "Symbol.iterator") != null);
}

// --- ES2015: for-of body destructuring (#1383) ---
// `var [a, b] = _e.value` 와 같은 var + pattern 조합은 ES5 문법 오류 →
// 반드시 임시 변수 + element/prop 접근 declarator 로 전개되어야 한다.

fn expectNoVarPattern(output: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, output, "var [") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var {") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var  [") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var  {") == null);
}

test "ES2015: for-of array destructuring body lowered" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a,b] of arr){use(a,b);}", .es5);
    defer r.deinit();
    try expectNoVarPattern(r.output);
    // _t = _e.value, a = _t[0], b = _t[1]
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".value") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[1]") != null);
}

test "ES2015: for-of object destructuring body lowered" {
    var r = try e2eTarget(std.testing.allocator, "for(const {x,y} of items){use(x,y);}", .es5);
    defer r.deinit();
    try expectNoVarPattern(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".y") != null);
}

test "ES2015: for-of nested destructuring body lowered" {
    var r = try e2eTarget(std.testing.allocator, "for(const [i,{x,y}] of pts){use(i,x,y);}", .es5);
    defer r.deinit();
    try expectNoVarPattern(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".x") != null);
}

test "ES2015: for-of rest destructuring body lowered" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a,...rest] of arr){use(a,rest);}", .es5);
    defer r.deinit();
    try expectNoVarPattern(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".slice(1)") != null);
}

test "ES2015: for-of default destructuring body lowered" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a=1,b=2] of arr){use(a,b);}", .es5);
    defer r.deinit();
    try expectNoVarPattern(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "ES2015: for-of let destructuring body lowered" {
    var r = try e2eTarget(std.testing.allocator, "for(let {a,b} of xs){use(a,b);}", .es5);
    defer r.deinit();
    try expectNoVarPattern(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".b") != null);
}

test "ES2015: for-of destructuring not lowered on esnext" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a,b] of arr){}", .esnext);
    defer r.deinit();
    // esnext: 변환 없이 원본 그대로
    try std.testing.expectEqualStrings("for(const [a,b] of arr){}", r.output);
}

test "ES2018: for-await destructuring body lowered at es2015 target (#1382)" {
    // for-await 가 while 로 낮아지면서 body 에 var-pattern 이 남지 않아야 함
    var r = try e2eTarget(
        std.testing.allocator,
        "async function f(){ for await(const [a,b] of xs){use(a,b);} }",
        .es2015,
    );
    defer r.deinit();
    try expectNoVarPattern(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".value") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[1]") != null);
}

// --- ES2015: destructuring ---

test "ES2015: object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,a=_a.a,b=_a.b;", r.output);
}

test "ES2015: array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var [x,y]=arr;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=arr,x=_a[0],y=_a[1];", r.output);
}

test "ES2015: destructuring rename" {
    var r = try e2eTarget(std.testing.allocator, "var {a:c}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,c=_a.a;", r.output);
}

test "ES2015: destructuring default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,a=_a.a===void 0?1:_a.a;", r.output);
}

test "ES2015: destructuring no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var {a:a,b:b}=obj;", r.output);
}

test "ES2015: assignment object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "({a,b}=obj);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a=_a.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "b=_a.b") != null);
}

test "ES2015: assignment array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "([x,y]=arr);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=arr") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=_a[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y=_a[1]") != null);
}

test "ES2015: assignment destructuring with default" {
    var r = try e2eTarget(std.testing.allocator, "({a=1,b}=obj);", .es5);
    defer r.deinit();
    // a = _ref.a === void 0 ? 1 : _ref.a
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0?1:") != null);
}

test "ES2015: assignment array destructuring with default" {
    var r = try e2eTarget(std.testing.allocator, "([x=1,y]=arr);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0?1:") != null);
}

// --- ES2015: let/const → var ---

test "ES2015: let to var" {
    var r = try e2eTarget(std.testing.allocator, "let x=1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=1;", r.output);
}

test "ES2015: const to var" {
    var r = try e2eTarget(std.testing.allocator, "const y=2;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var y=2;", r.output);
}

test "ES2015: var stays var" {
    var r = try e2eTarget(std.testing.allocator, "var z=3;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=3;", r.output);
}

test "ES2015: let/const no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "let x=1;const y=2;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;const y=2;", r.output);
}

// --- ES2015: class ---

test "ES2015: class with constructor and methods" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{constructor(x){this.x=x;}method(){return this.x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo(x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.prototype.method=function()") != null);
}

test "ES2015: class with static method" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static create(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.create=function()") != null);
}

test "ES2015: empty class" {
    var r = try e2eTarget(std.testing.allocator, "class Empty{}", .es5);
    defer r.deinit();
    // class → IIFE: var Empty = (function() { function Empty() {} return Empty; })()
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var Empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Empty()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return Empty") != null);
}

test "ES2015: class with instance field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{x=1;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
}

test "ES2015: class with static field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static y=2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.y=2") != null);
}

test "ES2015: class no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}", r.output);
}

// --- ES2015: generator ---

test "ES2015: basic generator" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator with return" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;return 42;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [2,42]") != null);
}

test "ES2015: generator with for loop yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){for(var i=0;i<3;i++){yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
    // 조건 부정: !(i<3)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!(i<3)") != null or
        std.mem.indexOf(u8, r.output, "!(i < 3)") != null);
}

test "ES2015: generator with if yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(x){if(x){yield 1;}yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,2]") != null);
}

test "ES2015: generator no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;}", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") == null);
}

test "ES2015: generator var hoisting with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var x=yield 1;return x;}", .es5);
    defer r.deinit();
    // var x가 switch 밖에 호이스팅됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
    // x = _state.sent()
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
    // generator 플래그 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator var hoisting without yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var a=1;yield a;}", .es5);
    defer r.deinit();
    // var a가 호이스팅됨, case 안에는 a=1 assignment만
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,a]") != null);
}

test "ES2015: generator yield*" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield* [1,2];}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [5,[1,2]]") != null);
}

test "ES2015: generator do-while with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var i=0;do{yield i;i++;}while(i<3);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
    // do-while: body 먼저, 조건으로 점프
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i<3") != null or
        std.mem.indexOf(u8, r.output, "i < 3") != null);
}

test "ES2015: generator try/catch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){yield e;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES2015: generator try/catch/finally with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){f(e);}finally{cleanup();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [7]") != null); // endfinally
    try std.testing.expect(std.mem.indexOf(u8, r.output, "cleanup()") != null);
}

// ============================================================
// ES2015 다운레벨링 추가 테스트
// ============================================================

// --- class extends/super ---

test "ES2015: class extends with super()" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(x){super(x);this.x=x;}}", .es5);
    defer r.deinit();
    // super(x) → var _this=__callSuper(this,_super,[x]) + _this.x=x + return _this
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(this,_super,[x])") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x=x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(C,_super)") != null);
}

test "ES2015: class extends default constructor" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){}}", .es5);
    defer r.deinit();
    // 기본 생성자 → return __callSuper(this,_super,arguments) — implicit forwarding
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(this,_super,arguments)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(C,_super)") != null);
}

test "ES2015: super.method() call" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return super.m();}}", .es5);
    defer r.deinit();
    // super.m() → _super.prototype.m.call(this) — IIFE 매개변수 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.m.call(this)") != null);
}

// --- class getter/setter ---

test "ES2015: class getter/setter paired" {
    var r = try e2eTarget(std.testing.allocator, "class F{get v(){return 1;}set v(x){}}", .es5);
    defer r.deinit();
    // 하나의 Object.defineProperty로 합쳐져야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty") != null);
    // configurable: true — ES6 class getter/setter는 스펙상 configurable
    try std.testing.expect(std.mem.indexOf(u8, r.output, "configurable:true") != null);
    // "get:" 와 "set:" 가 같은 호출 안에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "get:function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "set:function(x)") != null);
}

test "ES2015: class static getter" {
    var r = try e2eTarget(std.testing.allocator, "class F{static get n(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(F") != null);
}

test "ES2015: IIFE getter uses inner function name, not outer renamed variable" {
    // class Foo extends Bar { get x() {} } → IIFE 내부에서
    // Object.defineProperty(Foo.prototype, ...) 여야 함 (Foo$1.prototype 아님).
    // IIFE 반환 전에는 외부 변수가 undefined이므로 외부 이름을 쓰면 TypeError 발생.
    var r = try e2eTarget(std.testing.allocator, "class Foo extends Bar{get x(){return 1;}}", .es5);
    defer r.deinit();
    // IIFE 내부에서 내부 함수명(Foo)으로 prototype 접근
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(Foo.prototype") != null);
    // IIFE 패턴 확인
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(Foo,_super)") != null);
}

test "ES2015: class extends member expression (e.g. React.Component)" {
    // class Foo extends a.B {} → IIFE에 a.B가 인자로 전달되어야 함.
    // 표현식 super class가 무시되면 super()가 미변환 + __extends 누락.
    var r = try e2eTarget(std.testing.allocator, "class Foo extends a.B{constructor(){super();this.x=1;}}", .es5);
    defer r.deinit();
    // IIFE 인자에 a.B 표현식 전달
    try std.testing.expect(std.mem.indexOf(u8, r.output, ")(a.B)") != null);
    // _super 매개변수 + __extends 호출
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(_super)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(Foo,_super)") != null);
    // super() → __callSuper(this,_super,arguments) 변환
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(this,_super,[])") != null);
    // 원본 super 키워드가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super(") == null);
}

// --- class expression ---

test "ES2015: class expression simple" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Class()") != null);
}

test "ES2015: class expression with method" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{m(){return 1;}};", .es5);
    defer r.deinit();
    // IIFE 패턴
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _Class") != null);
}

test "ES2015: class expression with extends" {
    var r = try e2eTarget(std.testing.allocator, "const F=class extends P{m(){}};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(") != null);
}

test "ES2015: class expression extends member expression" {
    var r = try e2eTarget(std.testing.allocator, "const F=class extends a.B{constructor(){super();}};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ")(a.B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(this,_super,[])") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super(") == null);
}

// --- class private field ---

test "ES2015: class private field WeakMap" {
    var r = try e2eTarget(std.testing.allocator, "class F{#x=1;g(){return this.#x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.set(this,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.get(this)") != null);
}

test "ES2015: class private field set" {
    // #1488: wm.set 은 WeakMap을 반환하므로 expression 값이 value가 되도록 helper 경유.
    var r = try e2eTarget(std.testing.allocator, "class F{#x=0;s(v){this.#x=v;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateFieldSet(_x,this,v)") != null);
}

// --- class static private field ---

test "ES2022: static private field descriptor object" {
    // static #x → var _x = { writable: true, value: init }
    var r = try e2eTarget(std.testing.allocator, "class F{static #x=new Map();}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "writable:true") != null or
        std.mem.indexOf(u8, r.output, "writable: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value:new Map") != null or
        std.mem.indexOf(u8, r.output, "value: new Map") != null);
    // WeakMap이 아닌 descriptor 객체
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "new WeakMap"), null);
}

test "ES2022: static private field get uses helper" {
    // static method에서 ClassName.#x 접근 → __classStaticPrivateFieldSpecGet
    var r = try e2eTarget(std.testing.allocator, "class F{static #m=new Map();static g(){return F.#m;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet(F,F,_m)") != null);
}

test "ES2022: static private field set uses helper" {
    // static method에서 ClassName.#x = v → __classStaticPrivateFieldSpecSet
    var r = try e2eTarget(std.testing.allocator, "class F{static #m=0;static s(v){F.#m=v;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecSet(F,F,_m,v)") != null);
}

test "ES2022: static private field chained access" {
    // static private field의 메서드 체이닝: F.#m.get(name)
    var r = try e2eTarget(std.testing.allocator, "class F{static #m=new Map();static get(k){return F.#m.get(k);}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classStaticPrivateFieldSpecGet(F,F,_m)") != null);
}

test "ES2022: instance private field still uses WeakMap" {
    // instance private field는 기존 WeakMap 패턴 유지
    var r = try e2eTarget(std.testing.allocator, "class F{#x=1;static #y=2;g(){return this.#x;}}", .es5);
    defer r.deinit();
    // instance: WeakMap
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.get(this)") != null);
    // static: descriptor
    try std.testing.expect(std.mem.indexOf(u8, r.output, "writable:true") != null or
        std.mem.indexOf(u8, r.output, "writable: true") != null);
}

test "ES2022: static private field default value void 0" {
    // 초기값 없는 static private field → value: void 0
    var r = try e2eTarget(std.testing.allocator, "class F{static #x;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value:void 0") != null or
        std.mem.indexOf(u8, r.output, "value: void 0") != null);
}

// --- destructuring rest ---

test "ES2015: destructuring object rest" {
    var r = try e2eTarget(std.testing.allocator, "var {a,...r}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"a\"]") != null);
}

test "ES2015: destructuring array rest" {
    var r = try e2eTarget(std.testing.allocator, "var [a,...r]=arr;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".slice(1)") != null);
}

// --- generator labeled break/continue ---

test "ES2015: generator labeled break" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)break outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // break outer → return [3, N] (end label로 점프)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [3,") != null);
}

test "ES2015: generator labeled continue" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)continue outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // continue outer → return [3, N] (update label로 점프 → i++ 실행)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i++") != null);
}

// --- generator switch yield ---

test "ES2015: generator switch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){switch(x){case 1:yield 'a';break;default:yield 'b';}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // switch → if-else 체인으로 분해
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,\"a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,\"b\"]") != null);
}

// --- static block ES5 ---

test "ES2015: static block in class declaration" {
    var r = try e2eTarget(std.testing.allocator, "class F{static v;static{F.v=42;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.v=42") != null);
}

// --- arrow this capture in class method ---

test "ES2015: arrow this capture in class method" {
    var r = try e2eTarget(std.testing.allocator, "class F{x=1;g(){var fn=()=>this.x;return fn();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x") != null);
}

// --- arrow edge cases ---

test "ES2015: arrow returning object literal" {
    var r = try e2eTarget(std.testing.allocator, "var f = () => ({ x: 1 });", .es5);
    defer r.deinit();
    // 객체 리터럴 반환 시 괄호 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x:1") != null);
}

test "ES2015: arrow with destructuring param" {
    var r = try e2eTarget(std.testing.allocator, "var f = ({x,y}) => x+y;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(") != null);
}

test "ES2015: nested arrow this capture" {
    var r = try e2eTarget(std.testing.allocator, "function outer(){var f=()=>{var g=()=>this.x;};}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x") != null);
}

test "ES2015: arrow in object method preserves this" {
    var r = try e2eTarget(std.testing.allocator, "var obj={m(){return ()=>this;}};", .es5);
    defer r.deinit();
    // arrow → function 변환 + _this 참조
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function()") != null);
}

// --- destructuring edge cases ---

test "ES2015: nested object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a:{b}}=obj;", .es5);
    defer r.deinit();
    // 중첩 구조분해 → 임시 변수 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
}

test "ES2015: array in object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a:[x,y]}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]") != null);
}

test "ES2015: destructuring function parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f({a,b}){return a+b;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function f(") != null);
}

test "ES2015: destructuring with computed key" {
    var r = try e2eTarget(std.testing.allocator, "var k='x';var {[k]:v}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

test "ES2015: destructuring with string key uses bracket notation" {
    // 하이픈 포함 문자열 키: _ref["aria-busy"] (bracket), _ref.ariaBusy (dot) 아님
    var r = try e2eTarget(std.testing.allocator,
        \\var {"aria-busy":busy,"aria-checked":checked}=obj;
    , .es5);
    defer r.deinit();
    // bracket notation 사용 확인
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"aria-busy\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"aria-checked\"]") != null);
    // dot notation이 아닌지 확인
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, ".\"aria-busy\""), null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, ".\"aria-checked\""), null);
}

test "ES2015: destructuring with string key and default uses bracket notation" {
    // 문자열 키 + 기본값: _ref["aria-busy"] === void 0 ? false : _ref["aria-busy"]
    var r = try e2eTarget(std.testing.allocator,
        \\var {"aria-busy":busy=false}=obj;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"aria-busy\"]") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, ".\"aria-busy\""), null);
}

test "ES2015: for-of with destructuring" {
    var r = try e2eTarget(std.testing.allocator, "for(const [k,v] of arr){}", .es5);
    defer r.deinit();
    // for-of → iterator protocol, destructuring 결합
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Symbol.iterator") != null);
}

// --- class edge cases ---

test "ES2015: class with computed method" {
    var r = try e2eTarget(std.testing.allocator, "var k='m';class F{[k](){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function F()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
}

test "ES2015: class with computed method uses bracket notation" {
    // [Symbol.iterator]() → prototype[Symbol.iterator] = function() (dot 없이)
    var r = try e2eTarget(std.testing.allocator, "class F{[Symbol.iterator](){return this;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype[Symbol.iterator]") != null);
    // prototype.[Symbol.iterator] (잘못된 dot notation) 금지
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "prototype.["), null);
}

test "ES2015: static computed field uses bracket notation" {
    var r = try e2eTarget(std.testing.allocator, "var k='x';class F{static [k]=1;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F[k]=1") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "F.[k]"), null);
}

test "ES2015: instance computed field uses bracket notation" {
    var r = try e2eTarget(std.testing.allocator, "var k='tag';class F{[k]='foo';}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this[k]") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "this.[k]"), null);
}

test "ES2015: class with multiple fields" {
    var r = try e2eTarget(std.testing.allocator, "class F{a=1;b='hi';c=true;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.b=\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.c=true") != null);
}

test "ES2015: class constructor with super and field" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=0;}class D extends B{y=1;constructor(){super();this.z=2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    // super()가 있으므로 instance field는 _this에 할당
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.y=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.z=2") != null);
}

// --- generator edge cases ---

test "ES2015: generator with while yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){var i=0;while(i<3){yield i;i++;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
}

test "ES2015: generator expression" {
    var r = try e2eTarget(std.testing.allocator, "var g=function*(){yield 1;yield 2;};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
}

test "ES2015: generator with multiple return" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){if(x>0){return 'pos';}yield 0;return 'neg';}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // yield 0 → [4, 0], return "neg" → [2, "neg"]
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [2,\"neg\"]") != null);
}

// --- for-of edge cases ---

test "ES2015: for-of with let" {
    var r = try e2eTarget(std.testing.allocator, "for(let x of arr){f(x);}", .es5);
    defer r.deinit();
    // let → var + for-of → index loop
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

test "ES2015: for-of with break" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){if(x>1)break;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "break") != null);
}

// --- for-await-of ES5 lowering (#1381) ---
// ES5/Hermes 는 `for await` 키워드 자체를 파싱 못 하므로, async_await 미지원 타겟에서는
// __asyncValues + while 루프로 변환해야 한다 (#1381).
// 부수적으로 #1379 의 `var x = void 0 of` 도 해결됨 (for-await 헤드가 사라지므로).

test "ES2018: for-await-of const — lowered to __asyncValues + while (#1381)" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){for await(const v of iter)g(v);}", .es5);
    defer r.deinit();
    // for await 키워드가 출력에 남으면 Hermes 파싱 실패.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") == null);
    // __asyncValues 호출이 나타나야 함.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") != null);
    // while 루프로 변환.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "while") != null or
        std.mem.indexOf(u8, r.output, ".done") != null);
    // 바깥 async function 은 __async + generator 로 변환되므로 await → yield.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0 of") == null);
}

test "ES2018: for-await-of let — lowered (#1381)" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){for await(let v of iter)g(v);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") != null);
}

test "ES2018: for-await-of var — lowered (#1381)" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){for await(var v of iter)g(v);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") != null);
}

test "ES2018: for-await-of assignment head — lowered (#1381)" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){var v;for await(v of iter)g(v);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") != null);
}

test "ES2018: for-await-of with break — lowered (#1381)" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){for await(const v of iter){if(v)break;g(v);}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") == null);
    // #1480 이후 break는 __generator state machine의 label jump(return [3, N])로 변환됨.
    // iterator.return 호출 (finally 안)로 cleanup 보장.
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".return") != null);
}

test "ES2018: for-await-of preserved at esnext" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){for await(const v of iter)g(v);}", .esnext);
    defer r.deinit();
    // esnext 는 변환 없음 — for await 유지.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") == null);
}

// --- #1404: 합성 노드 span 의 STRING_TABLE_BIT 처리 회귀 가드 ---
// for-await lowering 이 만든 __asyncValues / _iter 등 합성 identifier_reference 는
// span 이 string_table 인코딩 (start | 0x80000000). 워크릿 auto-detect 가
// self.ast.source[span.start..span.end] 로 직접 읽으면 OOB → SIGBUS.
// platform=react-native + 합성 호출 패턴 으로 재현 → 크래시 안 나면 통과.

test "ES2018: for-await-of with synthetic call — no SIGBUS in worklet auto-detect (#1404)" {
    var r = try e2eTarget(std.testing.allocator, "async function*g(){yield 1;}async function f(){let t=0;for await(const v of g())t+=v;return t;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") != null);
}

test "ES2015: object method shorthand + computed key — no SIGBUS (#1404 원본)" {
    var r = try e2eTarget(std.testing.allocator, "const o = { async fn() { return 1; }, [\"k\"]: 2 };", .es5);
    defer r.deinit();
    try std.testing.expect(r.output.len > 0);
}

test "ES2015: generator method shorthand + computed method — no SIGBUS (#1404)" {
    var r = try e2eTarget(std.testing.allocator, "const o = { *gen() { yield 1; }, [\"k\"]() { return 2; } };", .es5);
    defer r.deinit();
    try std.testing.expect(r.output.len > 0);
}

// --- spread edge cases ---

test "ES2015: spread in new with apply" {
    var r = try e2eTarget(std.testing.allocator, "new Foo(...args);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "apply") != null or std.mem.indexOf(u8, r.output, "concat") != null);
}

test "ES2015: spread multiple arrays" {
    var r = try e2eTarget(std.testing.allocator, "var x=[...a,...b,...c];", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "concat") != null);
}

// --- template literal edge cases ---

test "ES2015: template with expression" {
    var r = try e2eTarget(std.testing.allocator, "var s=`${a+b} = ${c}`;", .es5);
    defer r.deinit();
    // 백틱 → 문자열 연결
    try std.testing.expect(std.mem.indexOf(u8, r.output, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" = \"") != null or std.mem.indexOf(u8, r.output, "' = '") != null);
}

test "ES2015: template nested" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a${`b${c}`}d`;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "+") != null);
}

test "ES2015: template with actual newline" {
    var r = try e2eTarget(std.testing.allocator, "var s=`hello\nworld`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"hello\\nworld\";", r.output);
}

test "ES2015: template with newline and substitution" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a\n${b}\nc`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\n\" + b + \"\\nc\";", r.output);
}

test "ES2015: template with carriage return" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a\r\nb`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\r\\nb\";", r.output);
}

test "ES2015: template with U+2028 line separator" {
    // U+2028 (UTF-8: 0xE2 0x80 0xA8) — 템플릿에서는 유효, ES5 문자열에서는 줄바꿈 취급
    var r = try e2eTarget(std.testing.allocator, "var s=`a\xe2\x80\xa8b`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\u2028b\";", r.output);
}

test "ES2015: template with U+2029 paragraph separator" {
    // U+2029 (UTF-8: 0xE2 0x80 0xA9)
    var r = try e2eTarget(std.testing.allocator, "var s=`a\xe2\x80\xa9b`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\u2029b\";", r.output);
}

// --- combined features ---

test "ES2015: class with generator method" {
    var r = try e2eTarget(std.testing.allocator, "class F{*gen(){yield 1;}}", .es5);
    defer r.deinit();
    // class → function + prototype
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "gen") != null);
}

test "ES2015: destructuring with spread and default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1,...rest}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null or std.mem.indexOf(u8, r.output, "hasOwnProperty") != null);
}

test "ES2015: multiple let in for-of" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a,b] of items){let sum=a+b;f(sum);}", .es5);
    defer r.deinit();
    // const/let → var, for-of → index loop, destructuring → temp
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

// --- ES2020 edge cases ---

test "ES2020: ?? nested" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b ?? c;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "ES2020: ?. deep chain" {
    var r = try e2eTarget(std.testing.allocator, "a?.b?.c?.d;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

test "ES2020: ?. with method call" {
    var r = try e2eTarget(std.testing.allocator, "obj?.method(1,2);", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

test "ES2020: ?? with ?. combined" {
    var r = try e2eTarget(std.testing.allocator, "const x = a?.b ?? 'default';", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

// --- ES2021 edge cases ---

test "ES2021: ??= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ??= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

test "ES2021: ||= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ||= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

// --- ES2022 edge cases ---

test "ES2022: static block with side effects" {
    var r = try e2eTarget(std.testing.allocator, "class F{static count=0;static{F.count++;}}", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.count++") != null or std.mem.indexOf(u8, r.output, "F.count+=1") != null);
}

// --- temp var hoisting ---

test "ES2020: temp var hoisted for ?? in function" {
    var r = try e2eTarget(std.testing.allocator, "function f(){return foo()??bar;}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=foo()") != null);
}

test "ES2020: temp var hoisted for ?. in function" {
    var r = try e2eTarget(std.testing.allocator, "function f(){return foo()?.bar;}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
}

// --- ES2021 ---

test "ES2021: &&= logical assignment" {
    var r = try e2eTarget(std.testing.allocator, "let a=1;a&&=10;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a&&(a=10)") != null);
}

// --- ES2022 → es2021 ---

test "ES2022: static block to IIFE (target=es2021)" {
    var r = try e2eTarget(std.testing.allocator, "class F{static{F.v=1;}}", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.v=1") != null);
}

// --- useDefineForClassFields=false ---

test "useDefineForClassFields=false: instance to constructor" {
    var r = try e2eFull(std.testing.allocator, "class Foo{x=1;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
    // x=1 은 class body에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo{x=1") == null);
}

test "useDefineForClassFields=false: static field outside class" {
    var r = try e2eFull(std.testing.allocator, "class Foo{static z=2;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.z=2") != null);
    // static z=2 는 class body에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static") == null);
}

test "useDefineForClassFields=false: multiple static assignments ordered" {
    var r = try e2eFull(std.testing.allocator, "class Foo{static a=1;static b=2;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.b=2") != null);
    // a가 b보다 먼저
    const a_pos = std.mem.indexOf(u8, r.output, "Foo.a=1").?;
    const b_pos = std.mem.indexOf(u8, r.output, "Foo.b=2").?;
    try std.testing.expect(a_pos < b_pos);
}

test "useDefineForClassFields=false: method preserved" {
    var r = try e2eFull(std.testing.allocator, "class Foo{x=1;method(){return this.x;}}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "method()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
}

test "useDefineForClassFields=false: no-init fields removed" {
    var r = try e2eFull(std.testing.allocator, "class Foo{y;static w;method(){}}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    // y, w 모두 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "method") != null);
    // class body에 y, w가 없어야 함 (method만 있음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";y") == null);
}

// #1386: for-in/for-of 헤더의 let/const → var 다운레벨 시 `= void 0` init 주입 금지.
// 주입하면 codegen이 `k=void 0; for(var k in ...)` 로 hoist해 strict mode에서
// `var k` 선언 전 접근이 되어 ReferenceError.
test "ES2015: for-in let produces var without void 0 hoist (#1386)" {
    var r = try e2eTarget(std.testing.allocator, "for(let k in obj){use(k);}", .es5);
    defer r.deinit();
    // `k = void 0` 같은 hoist 아티팩트가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "k=void 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "k = void 0") == null);
    // for-in 자체는 var 로 다운레벨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(var k in") != null or
        std.mem.indexOf(u8, r.output, "for (var k in") != null);
}

test "ES2015: for-in const produces var without void 0 hoist (#1386)" {
    var r = try e2eTarget(std.testing.allocator, "for(const k in obj){use(k);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "k=void 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "k = void 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(var k in") != null or
        std.mem.indexOf(u8, r.output, "for (var k in") != null);
}

test "ES2015: for-in var unchanged (#1386)" {
    // var 는 기존부터 init 없음 — 동작 변경 없음 확인
    var r = try e2eTarget(std.testing.allocator, "for(var k in obj){use(k);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "k=void 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(var k in") != null or
        std.mem.indexOf(u8, r.output, "for (var k in") != null);
}

test "ES2015: for-in let esnext preserved (#1386)" {
    // esnext 타겟에선 let 그대로 유지
    var r = try e2eTarget(std.testing.allocator, "for(let k in obj){use(k);}", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(let k in") != null or
        std.mem.indexOf(u8, r.output, "for (let k in") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") == null);
}

// --- regex dotAll / named capture / sticky (#1387) ---

test "regex: dotAll /a.b/s → /a[\\s\\S]b/ (es2017)" {
    var r = try e2eTarget(std.testing.allocator, "const a = /a.b/s;", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/a[\\s\\S]b/") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/s") == null);
}

test "regex: dotAll escape 된 . 는 변환 X (#1387)" {
    var r = try e2eTarget(std.testing.allocator, "const a = /a\\.b/s;", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/a\\.b/") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\\s\\S]") == null);
}

test "regex: dotAll character class 내부 . 는 그대로 (#1387)" {
    var r = try e2eTarget(std.testing.allocator, "const a = /[a.]b/s;", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/[a.]b/") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\\s\\S]") == null);
}

test "regex: named capture → positional (#1387)" {
    var r = try e2eTarget(std.testing.allocator, "const d = /(?<year>\\d{4})/;", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/(\\d{4})/") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "?<") == null);
}

test "regex: sticky /y flag strip at es5 (#1387)" {
    var r = try e2eTarget(std.testing.allocator, "const a = /foo/y;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/foo/;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/y") == null);
}

test "regex: esnext no-op (#1387)" {
    var r = try e2eTarget(std.testing.allocator, "const a = /a.b/s; const d = /(?<y>\\d)/;", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/a.b/s") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(?<y>") != null);
}

// --- unicode brace escape `\u{X}` (#1388) ---

test "unicode_escape: astral string '\\u{1F600}' → surrogate pair (es5)" {
    var r = try e2eTarget(std.testing.allocator, "const e = '\\u{1F600}';", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\uD83D\\uDE00") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u{") == null);
}

test "unicode_escape: BMP string '\\u{41}' → '\\u0041' (es5)" {
    var r = try e2eTarget(std.testing.allocator, "const e = '\\u{41}';", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u0041") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u{") == null);
}

test "unicode_escape: template literal astral (es2015 target — template 보존)" {
    // es5는 template literal 자체를 문자열 concat으로 downlevel 하므로, template_element 보존을
    // 위해 es2015 target 으로 확인. unicode_brace_escape 는 es2015 에서도 처리됨 (esVersion=es2015).
    // ESTarget.es2015 → feature 도입 버전이 <= es2015 인 feature 는 unsupported가 아니지만,
    // unicode_brace_escape 의 도입 버전이 es2015 라 es2015+ 에서는 no-op. 대신 es2015 하위 버전이
    // ESTarget enum에 없으므로 es5 를 쓰되 문자열 리터럴로만 확인한다.
    // (template 내부 lowering 은 이미 es2015_template 가 하위에서 처리하며, 그 이후 내려오는
    //  문자열은 string_literal 경로로 들어간다.)
    var r = try e2eTarget(std.testing.allocator, "const e = `\\u{1F600}`;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\uD83D\\uDE00") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u{") == null);
}

test "unicode_escape: plain '{abc}' 영향 없음 (es5)" {
    var r = try e2eTarget(std.testing.allocator, "const e = '{abc}';", .es5);
    defer r.deinit();
    // quote style 은 기본 double.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"{abc}\"") != null);
}

test "unicode_escape: regex /[\\u{1F600}]/u → surrogate pair + u strip (es5)" {
    var r = try e2eTarget(std.testing.allocator, "const r = /[\\u{1F600}]/u;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\uD83D\\uDE00") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u{") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/u") == null);
}

test "unicode_escape: esnext 문자열 no-op" {
    var r = try e2eTarget(std.testing.allocator, "const e = '\\u{1F600}';", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u{1F600}") != null);
}

test "unicode_escape: es2015 no-op" {
    var r = try e2eTarget(std.testing.allocator, "const e = '\\u{1F600}';", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\\u{1F600}") != null);
}

// === ES5 async transform regression suite (zts/issues 1896, 1901) ===

test "ES5: compound assignment with await RHS preserves operator (#1896)" {
    // `sum += await x()` 가 `sum = _state.sent()` 으로 변환되어 += 누락 → 누적 안 됨.
    // for-loop / while-loop 둘 다 동일 root cause. Babel/TS 는 `sum += _state.sent()`
    // 또는 `sum = sum + _state.sent()` 로 emit.
    var r = try e2eES5Async(std.testing.allocator, "async function f() { var sum = 0; for (var i = 0; i < 3; i++) { sum += await Promise.resolve(i + 1); } return sum; }");
    defer r.deinit();
    // 정확한 + 또는 += 보존. `sum=_state.sent()` (단순 = 으로 덮어쓰기) 면 fail.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sum=_state.sent()") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sum =_state.sent()") == null);
}

test "ES5: compound assignment +/while await RHS preserves operator (#1896)" {
    var r = try e2eES5Async(std.testing.allocator, "async function f() { var i = 0; var sum = 0; while (i < 3) { sum += await Promise.resolve(i); i++; } return sum; }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sum=_state.sent()") == null);
}

test "ES5: for-await-of hoists loop var to function top (#1901)" {
    // `for await (var v of arr)` 의 `var v` 가 함수 top 에 hoist 안 되면 strict mode
    // 에서 `v is not defined` throw. Babel/TS 는 함수 top 에 모든 var (loop binding +
    // synthetic helpers) hoist.
    var r = try e2eTarget(std.testing.allocator, "async function f() { var arr = [Promise.resolve(1)]; for await (var v of arr) {} return v; }", .es5);
    defer r.deinit();
    // 함수 top 의 var 선언에 `v` 포함 — `var sum,arr` 같은 형태에 v 추가되어 있어야.
    // 정확한 hoist 검증: emit 안 어딘가에 함수 top-level `var ` 안 `v` 포함.
    // 간단화: `var ` + 식별자 chain 안 `v` 가 있어야. 현재 (bug) 는 v 가 없음.
    // false-negative 회피용으로 substring 검사 — minify 시 `var v,` 또는 `,v,` 또는 `,v;`.
    const has_v_decl =
        std.mem.indexOf(u8, r.output, "var v;") != null or
        std.mem.indexOf(u8, r.output, "var v=") != null or
        std.mem.indexOf(u8, r.output, "var v,") != null or
        std.mem.indexOf(u8, r.output, ",v;") != null or
        std.mem.indexOf(u8, r.output, ",v=") != null or
        std.mem.indexOf(u8, r.output, ",v,") != null;
    try std.testing.expect(has_v_decl);
}
