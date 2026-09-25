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
const e2eTargetAssignSemantics = helpers.e2eTargetAssignSemantics;
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
    try std.testing.expectEqualStrings("a==null?void 0:a.b;", r.output);
}

test "ES2020: ?. computed" {
    var r = try e2eTarget(std.testing.allocator, "a?.[0];", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a[0];", r.output);
}

test "ES2020: ?. call" {
    var r = try e2eTarget(std.testing.allocator, "a?.();", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a();", r.output);
}

test "ES2020: optional eval call indirect eval 보존" {
    var r = try e2eTarget(std.testing.allocator, "eval?.('x=1');", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(0,eval)(") != null);
}

test "ES2020: ?. side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "foo()?.bar;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;(_a=foo())==null?void 0:_a.bar;", r.output);
}

test "ES2020: ?. chain continuation" {
    var r = try e2eTarget(std.testing.allocator, "a?.b.c;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a.b.c;", r.output);
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
    try std.testing.expectEqualStrings("a!=null?a:a=b;", r.output);
}

test "ES2021: ??= member to es2019 captures to temp" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ??= b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;(_a=obj.x)!=null?_a:obj.x=b;", r.output);
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

test "ES2016: **= member receiver 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "getObj().x **= 3;", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=getObj()).x=Math.pow(_a.x,3)") != null);
}

test "ES2016: **= computed member key 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "obj[getKey()] **= 3;", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj[_a=getKey()]=Math.pow(obj[_a],3)") != null);
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
    // 합성 binding 은 hoist 없는 유일 임시 이름(_a)을 쓴다. 고정 `_unused` 는 외부
    // 동명 변수를 섀도잉하는 miscompile 이라 제거됨(#4415).
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(_a){y;}", r.output);
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

// #4468: static block 은 이제 **AST 로** 출력된다 (예전엔 writeNodeSpan 으로 소스
// 원문을 복사 → rename/define 등 AST 변형이 통째로 유실됐다). 그래서 다른 블록과
// 똑같이 statement 종결 `;` 가 붙는다 — minify_syntax 가 꺼진 상태의 일관된 동작.
test "ES2022: static block no transform on es2022" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .es2022);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\");}}", r.output);
}

test "ES2022: static block no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\");}}", r.output);
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
    try std.testing.expectEqualStrings("export function foo(){return __async(function*(){return yield bar();}).call(this);}", r.output);
}

test "ES2017: async arrow block body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => { await x; };", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){yield x;}).call(this);", r.output);
}

test "ES2017: async arrow expression body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => await x;", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){return yield x;}).call(this);", r.output);
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

test "ES5: async try/catch return lowers to generator return op" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { try { if (x) return 1; } catch (e) { return 2; } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return 1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return 2;") == null);
}

test "ES5: async sync-return-only catalog — every statement type triggers state machine" {
    // PR #3141 의 205d4e4e + d61f861a 가 같은 invariant (`containsYield` 와 함께
    // `containsReturn` 도 fast-path skip 가드에서 검사) 의 statement-type 별 누락을
    // 두 라운드로 발견했던 사례.
    //
    // `es2015_generator/scan.zig` 의 `hasYieldOrReturn` helper 가 모든 collect-
    // *-operations 진입점에서 일관 호출되어야 한다. 새 statement type 의 fast-path
    // 분기 추가 시 helper 누락이면 sync `return` 이 raw 로 emit 되고 `__generator`
    // callback 이 generator instruction `[op, value]` 가 아닌 raw 값을 반환 →
    // 런타임 무한 동기 루프.
    //
    // 새 statement type 의 fast-path 분기를 추가했다면 아래 cases 에도 한 줄 추가.
    const cases = [_]struct { tag: []const u8, src: []const u8 }{
        .{ .tag = "if-else", .src = "async function f(x) { if (x) { return 1; } else { return 0; } }" },
        .{ .tag = "switch", .src = "async function f(x) { switch (x) { case 1: return 1; default: return 0; } }" },
        .{ .tag = "for", .src = "async function f() { for (var i = 0; i < 2; i++) { return i; } }" },
        .{ .tag = "while", .src = "async function f() { while (true) { return 1; } }" },
        .{ .tag = "do-while", .src = "async function f() { do { return 1; } while (false); }" },
        .{ .tag = "for-of", .src = "async function f(arr) { for (var x of arr) { return x; } }" },
        .{ .tag = "for-in", .src = "async function f(o) { for (var k in o) { return k; } }" },
        .{ .tag = "try", .src = "async function f() { try { return 1; } catch (e) {} }" },
        .{ .tag = "try-finally", .src = "async function f() { try { } finally { return 1; } }" },
    };

    for (cases) |c| {
        var r = try e2eTarget(std.testing.allocator, c.src, .es5);
        defer r.deinit();
        try expectAsyncStateMachine(r.output);
        // generator instruction `return[2, ...]` (terminate op) 가 emit 되어야 함.
        try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,") != null);
        // raw `return X;` 가 generator callback 안에 새지 않았는지 — raw return
        // 패턴 검사는 fixture 마다 다르지만 `[2,` 가 있으면서 raw 식별자 return
        // 만 또 존재하면 누락 신호.
    }
}

test "ES5: async control-flow return after await lowers to generator return op" {
    const cases = [_]struct {
        src: []const u8,
        expected: []const []const u8,
        forbidden: []const []const u8,
    }{
        .{
            .src = "async function f(x) { await a(); switch (x) { case 1: return true; default: return false; } }",
            .expected = &.{ "return[2,true]", "return[2,false]" },
            .forbidden = &.{ "return true;", "return false;" },
        },
        .{
            .src = "async function f(xs) { await a(); for (var i = 0; i < xs.length; i++) { if (xs[i]) return 1; } return 0; }",
            .expected = &.{ "return[2,1]", "return[2,0]" },
            .forbidden = &.{"return 1;"},
        },
        .{
            .src = "async function f(x) { await a(); while (x) { return 1; } return 0; }",
            .expected = &.{ "return[2,1]", "return[2,0]" },
            .forbidden = &.{"return 1;"},
        },
        .{
            .src = "async function f(xs) { await a(); for (var x of xs) { return x; } return null; }",
            .expected = &.{ "return[2,x]", "return[2,null]" },
            .forbidden = &.{"return x;"},
        },
    };

    for (cases) |c| {
        var r = try e2eTarget(std.testing.allocator, c.src, .es5);
        defer r.deinit();
        try expectAsyncStateMachine(r.output);
        for (c.expected) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, r.output, needle) != null);
        }
        for (c.forbidden) |needle| {
            try std.testing.expect(std.mem.indexOf(u8, r.output, needle) == null);
        }
    }
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
    // self-loop pattern — `_state.sent()` 직후 `return[3, N]` 의 N 이 자기 case 의 label.
    // 이 함수에서 await yield label 은 1 (label 0 은 시작), end label 은 2 여야 함.
    // bug 시: `case 1:_state.sent();return[3,1]` (자기 self-jump → 무한 루프).
    // fix 시: `case 1:_state.sent();return[2]` (end) 또는 `return[3,2]` (forward jump).
    // (e2eTarget 은 minify_whitespace=true 라 space 제거된 형태로 검사.)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent();return[3,1]") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent();return[3, 1]") == null);
}

test "ES5: async if-await with later statements — case fall-through correctness" {
    // 위 테스트의 동반 — if 후 trailing statement 가 있을 때도 await resume 이 정상 fall-through
    // 해야 함. 이 케이스는 기존에 동작하던 패턴 (회귀 방지용).
    var r = try e2eTarget(std.testing.allocator, "async function f(x) { if (x) { await a(); } var y = 1; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var y") != null);
}

// `assertNoAsyncSelfLoop` 가 case-label-aware 라 self-loop (`_state.sent();return[3,N]` 의
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

// === #1909: async function this binding via __generator(thisArg, ...) ===

test "ES5: async function emits __generator(this, ...) for body this access (#1909)" {
    // async method 안 `this.x` 가 generator state machine callback 의 null this 가 아닌
    // enclosing function 의 this 로 binding 되도록 __generator 첫 인자에 `this` 전달.
    var r = try e2eTarget(std.testing.allocator, "var obj = { x: 10, async f() { return this.x * 2; } }; obj.f();", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    // signature: __generator(this, function(...) {...}) — old signature `__generator(function...)` 면 fail.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator(this,function") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator(this, function") != null or
        std.mem.indexOf(u8, r.output, "__generator(this,function") != null);
}

// === #4699: 본문이 다른 함수로 옮겨질 때 `arguments` 캡처 ===

test "es2015: async 함수의 arguments 가 캡처된다 (#4699)" {
    // body 가 `__async(function*(){…})` 안쪽으로 옮겨지면 `arguments` 는 **그 안쪽**
    // 함수 것을 가리킨다. `this` 는 `.call(this)` 로 따로 전달되는데 `arguments` 만
    // 빠져 있었다 — arrow 다운레벨에만 걸린 게이트였다.
    var r = try e2eTarget(std.testing.allocator, "async function f() { return arguments; }", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_arguments=arguments") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _arguments") != null);
}

test "es5: generator 함수의 arguments 가 캡처된다 (#4699)" {
    // `__generator(this, function(_state){…})` 의 안쪽 함수는 `_state` 를 받으므로
    // 캡처가 없으면 `arguments` 가 `[_state]` 가 된다.
    var r = try e2eTarget(std.testing.allocator, "function* g() { yield arguments; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_arguments=arguments") != null);
}

test "es2015: 클래스 async 메서드의 arguments 도 캡처된다 (#4699)" {
    var r = try e2eTarget(std.testing.allocator, "class C { async m() { return arguments; } }", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_arguments=arguments") != null);
}

test "es2017: async generator 는 arguments 를 인자로 넘긴다 (#4699 과잉 캡처 방지)" {
    // `__asyncGenerator(this, arguments, fn)` 이 이미 전달하므로 캡처를 끼우면 안 된다.
    // (끼우면 안쪽 visit 의 pushArrowEnv 가 needs_arguments_var 를 되돌려 선언이 유실된다.)
    var r = try e2eTarget(std.testing.allocator, "async function* g() { yield arguments; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator(this,arguments") != null or
        std.mem.indexOf(u8, r.output, "__asyncGenerator(this, arguments") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_arguments=arguments") == null);
}

test "es2015: async 클래스 메서드가 다운레벨된다 (#4699)" {
    // `async` 는 ES2017 — class 가 네이티브로 남는 es2015/es2016 에선 어느 경로도
    // 타지 않아 `async m()` 이 그대로 샜다.
    var r = try e2eTarget(std.testing.allocator, "class C { async m() { return 1; } }", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async m(") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async ") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") != null);
}

test "es5: generator 클래스 메서드가 다운레벨된다 (#4699)" {
    // class→함수 낮추기 경로가 `is_async` 만 분기해서, generator 단독은 플래그가
    // 보존된 채 `function*` 으로 남았다(ES5 문법 아님).
    var r = try e2eTarget(std.testing.allocator, "class C { *m() { yield 1; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
}

test "es2016: static async 메서드 / super 조합도 (#4699)" {
    var r = try e2eTarget(
        std.testing.allocator,
        "class B { b(){return 1;} } class D extends B { static async s() { return 1; } async m() { return super.b(); } }",
        .es2016,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async ") == null);
    // 본문이 다른 함수로 옮겨지므로 raw super 가 남으면 파싱 불가.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.b") == null);
}

test "es2017: async 메서드는 네이티브 유지 (#4699 과잉 변환 방지)" {
    // es2017 은 async 가 네이티브 — 낮추면 불필요한 헬퍼 bloat.
    var r = try e2eTarget(std.testing.allocator, "class C { async m() { return 1; } }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async m(") != null);
}

test "es2015: generator 메서드는 네이티브 유지 (#4699 과잉 변환 방지)" {
    // generator 는 ES2015 — es2015 타겟에선 그대로 둬야 한다.
    var r = try e2eTarget(std.testing.allocator, "class C { *m() { yield 1; } }", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "*m(") != null);
}

test "es2017: async generator **메서드** 도 다운레벨된다 (#4628 후속)" {
    // 최상위 함수만 고치면 절반이다 — 클래스/객체 메서드는 각각 다른 경로를 탄다.
    var r = try e2eTarget(
        std.testing.allocator,
        "class C { async *m() { yield 1; } } const o = { async *n() { yield 2; } };",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async*") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async *") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") != null);
}

test "es2017: async generator 메서드 안 yield* 도 위임된다 (#4628 후속)" {
    var r = try e2eTarget(
        std.testing.allocator,
        "class C { async *a() { yield 1; } async *b() { yield* this.a(); } }",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__yieldStar") != null);
}

test "es2017: async generator 메서드의 super 가 살아남는다 (#4628 후속)" {
    // 본문이 plain `function*` 으로 옮겨지므로 raw `super` 는 SyntaxError 다 —
    // 추출 컨텍스트를 켜 `__superGet(...)` 으로 낮춰야 한다.
    var r = try e2eTarget(
        std.testing.allocator,
        "class B { base() { return 1; } } class D extends B { async *m() { yield super.base(); } }",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") != null);
    // raw super 가 남으면 산출물이 파싱조차 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.base") == null);
}

test "es5: async generator 메서드가 async iterator 를 돌려준다 (#4628 후속)" {
    // es5 는 class 를 함수로 낮추는 별도 경로(es2015_class)를 타는데, 거기서 async
    // generator 를 **일반 async 처럼** `__async(...)` 로 감싸 Promise 를 돌려줬다
    // (런타임에 `o[Symbol.iterator] is not a function`). class 낮추기가 보기 전에
    // 평범한 메서드로 바꿔 둬야 한다.
    var r = try e2eTarget(std.testing.allocator, "class C { async *m() { yield 1; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") != null);
}

test "es2018: async generator 메서드는 네이티브 유지 (#4628 후속 과잉 변환 방지)" {
    var r = try e2eTarget(std.testing.allocator, "class C { async *m() { yield 1; } }", .es2018);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async*m()") != null or
        std.mem.indexOf(u8, r.output, "async *m()") != null);
}

// === #4629: public class field 는 ES2022 — `class` 비트와 독립 ===

test "es2017: public class field 가 다운레벨된다 (#4629)" {
    // class 는 네이티브인데 필드만 ES2022 — 예전엔 필드 낮추기가 class→IIFE 낮추기에만
    // 얹혀 있어 es2015~es2021 에서 필드가 그대로 샜다(타겟 엔진 파싱 불가).
    var r = try e2eTarget(std.testing.allocator, "class C { n = 7; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class C") != null); // class 는 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField") != null);
}

test "es2017: 초기값 없는 public field 도 정의된다 (#4629)" {
    // define 의미론에선 `'u' in obj === true` 여야 한다 — elide 하면 안 된다.
    var r = try e2eTarget(std.testing.allocator, "class C { u; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "es2017: static public field 도 class 밖으로 나온다 (#4629)" {
    var r = try e2eTarget(std.testing.allocator, "class C { static z = 1; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static z") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField") != null);
}

test "es2022: public class field 는 네이티브 유지 (#4629 과잉 변환 방지)" {
    var r = try e2eTarget(std.testing.allocator, "class C { n = 7; }", .es2022);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "n=7") != null); // minify_whitespace

}

test "es2017: useDefineForClassFields=false 면 assign 의미론 유지 (#4629)" {
    // 옵션이 명시적으로 assign 을 요구하면 헬퍼를 끼우지 않는다.
    var r = try e2eTargetAssignSemantics(std.testing.allocator, "class C { n = 7; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.n=7") != null); // minify_whitespace

}

// === #4628: async generator (`async function*`) 는 ES2018 — 자기 비트로 게이트 ===

test "es2017: async generator 가 다운레벨된다 (#4628)" {
    // es2017 은 async 도 generator 도 네이티브라, 예전엔 그 두 비트 어느 쪽으로도
    // 게이트되지 않아 `async function*` 이 그대로 새어나갔다 (타겟 엔진 파싱 불가).
    var r = try e2eTarget(std.testing.allocator, "async function* g() { yield 1; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function*") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") != null);
}

test "es2018: async generator 는 네이티브 유지 (#4628 과잉 변환 방지)" {
    // ES2018 부터는 네이티브다 — 낮추면 불필요한 헬퍼 bloat.
    var r = try e2eTarget(std.testing.allocator, "async function* g() { yield 1; }", .es2018);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function*") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") == null);
}

test "es2017: yield* 위임의 완료값이 plain/min 양쪽에서 보존된다 (#4700)" {
    // ⚠️ 헬퍼는 plain 과 MIN 두 벌이라 **한쪽만 고치면 minify 빌드만 조용히 깨진다**
    // (실제로 밟았다). 두 변종이 같은 규칙을 갖는지 상수 수준에서 본다.
    const rt_mod = @import("../../bundler/runtime_helpers.zig");
    // 마커의 yield* 표시(`__await(p, 1)`)를 만드는 쪽
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.YIELD_STAR_RUNTIME, "), 1) }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.YIELD_STAR_RUNTIME_MIN, "),1)}") != null);
    // return 메서드를 보존하며 재개하는 쪽 — next 로 바뀌면 완료값이 사라진다.
    // ⚠️ `m.s &&` 게이트가 **반드시** 붙어야 한다. 빼면 위임과 무관한 평범한 `await`
    //    까지 return 으로 재개돼 `finally` 안 await 이후가 통째로 잘린다 (#4705).
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.ASYNC_GENERATOR_RUNTIME, "m.s && n === \"return\" ? n : \"next\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.ASYNC_GENERATOR_RUNTIME_MIN, "m.s&&n===\"return\"?n:\"next\"") != null);
    // 마커가 2필드(`v`, `s`)여야 위 규칙이 성립한다.
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.AWAIT_RUNTIME, "this.s = s") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.AWAIT_RUNTIME_MIN, "this.s=s") != null);
}

test "es2017: async generator 는 yield 한 값을 await 하고 결과 키 순서를 지킨다 (#4705)" {
    // async generator 의 `yield x` 는 x 를 await 한다(스펙 AsyncGeneratorYield).
    // 그냥 settle 로 흘려보내면 `yield Promise.resolve(1)` 이 Promise 를 그대로
    // 내보내고, 거부되면 generator 안에서 잡을 수 없게 된다.
    // 동시에 IteratorResult 는 `{ value, done }` 순서여야 한다(CreateIterResultObject).
    const rt_mod = @import("../../bundler/runtime_helpers.zig");
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.ASYNC_GENERATOR_RUNTIME, "Promise.resolve(r.value).then(function(v) { settle(q[0][2], { value: v, done: r.done }); }, reject)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.ASYNC_GENERATOR_RUNTIME_MIN, "Promise.resolve(r.value).then(function(v){settle(q[0][2],{value:v,done:r.done})},reject)") != null);
    // 위임 재개값도 같은 키 순서.
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.ASYNC_GENERATOR_RUNTIME, "{ value: y.value, done: y.done }") != null);
    try std.testing.expect(std.mem.indexOf(u8, rt_mod.ASYNC_GENERATOR_RUNTIME_MIN, "{value:y.value,done:y.done}") != null);
}

test "es2017: __asyncDelegator 는 더 이상 쓰이지 않는다 (#4700)" {
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* a() { yield 1; } async function* b() { yield* a(); }",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncDelegator") == null);
}

test "es2017: async generator 안 yield* 는 __yieldStar 로 위임 (#4628 · #4700)" {
    // `yield*` 를 그대로 두면 __asyncGenerator 의 **동기** inner generator 가
    // async iterable 에서 Symbol.iterator 를 찾다 런타임에 "not iterable" 로 죽는다.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* a() { yield 1; } async function* b() { yield* a(); }",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__yieldStar") != null);
    // delegate 플래그를 유지한다 — 동기 yield* 프로토콜이 그대로 돌아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield*__yieldStar(") != null or
        std.mem.indexOf(u8, r.output, "yield* __yieldStar(") != null);
}

test "es2017: 평범한 generator 의 yield* 는 건드리지 않는다 (#4628 과잉 변환 방지)" {
    // async 가 아닌 generator 는 동기 프로토콜 그대로 — delegator 를 끼우면 안 된다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* a() { yield 1; } function* b() { yield* a(); }",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncDelegator") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield* a()") != null);
}

// === #1910: yield* iterable — __values() wrap ===

test "ES2017: for-await 루프 변수는 원래 종류(const/let)를 유지한다 (#4722)" {
    // es2015~es2017 은 let/const 가 네이티브다. `var` 로 내리면 반복별 바인딩이 합쳐져
    // 루프 안 클로저가 전부 마지막 값을 캡처한다.
    var r = try e2eTarget(std.testing.allocator, "async function f(s){ for await (const v of s) g(()=>v); }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const v=") != null or std.mem.indexOf(u8, r.output, "const v =") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var v=") == null);
}

test "ES5: async 함수의 for-await 루프 변수 캡처도 _loop 로 복원한다 (#4722)" {
    var r = try e2eTarget(std.testing.allocator, "async function f(s){ for await (const v of s) g(()=>v); }", .es5);
    defer r.deinit();
    // 정의만이 아니라 **호출**돼야 한다(반복마다 새 프레임). 루프 변수는 풀이 뒤 본문 첫
    // 선언이라 `_loop` 안에서 반복마다 선언된다 (#4746 3단계 — 예전엔 파라미터로 전달).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(_loop())") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "v=_step.value;") != null);
}

test "ES5: 중첩 async 가 바깥 상태 기계 temp 를 지우지 않는다 (#4722)" {
    // 안쪽 async 화살표 lowering 이 generator_temp_var_spans 를 통째로 clear 해, 바깥에
    // 등록된 `_loop` 선언이 사라졌다(`_loop is not defined`).
    var r = try e2eTarget(
        std.testing.allocator,
        "async function f(s){ for await (const v of s) g(() => v); const r = await (async () => 1)(); return r; }",
        .es5,
    );
    defer r.deinit();
    const var_at = std.mem.indexOf(u8, r.output, "function f(s){var ") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, r.output, var_at, ";") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, r.output[var_at..end], "_loop") != null);
}

test "ES5: 추출된 루프 안의 바깥 라벨 continue 는 같은 함수면 라벨로 점프한다 (#4722)" {
    // 예전엔 자기 루프 라벨이 아니면 전부 `return "continue|O"` 로 위에 전달해, 바깥 루프가
    // 추출되지 않은 같은 함수의 루프일 때 **함수 전체를 빠져나갔다**(동기 코드에서도).
    var r = try e2eTarget(
        std.testing.allocator,
        "function run(fns){ O: for (const a of [1,2]) { for (const b of [1,2]) { fns.push(()=>b); if (b===2) continue O; } } done(); }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "continue O") != null);
    // 바깥(추출 안 된) 루프 레벨에서 신호를 return 으로 흘려 보내면 안 된다.
    const outer_check = std.mem.lastIndexOf(u8, r.output, "_ret===\"continue|O\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, r.output[outer_check..], "_ret===\"continue|O\")continue O"));
}

test "ES5: 루프 본문 안에서 정의된 라벨은 바깥 신호가 아니다 (#4722)" {
    // 바깥 루프 본문을 추출할 때 안쪽 라벨(B)의 정상 `continue B` 까지 `return` 신호로
    // 바꾸면 안 된다 — B 는 추출된 클로저 안에 그대로 있다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function run(fns){ for (const a of [1,2]) { fns.push(()=>a); B: for (const b of [1,2]) { if (b===1) continue B; x(); } } }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"continue|B\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "continue B") != null);
}

test "ES5: 추출로 블록이 된 클래식 for 에도 라벨이 붙는다 (#4722)" {
    // `{ var _loop = …; for (…) {…} }` 블록에 라벨이 남으면 `continue O` 가 갈 곳이 없다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function run(fns){ O: for (let i=0;i<3;i++) { fns.push(()=>i); for (let j=0;j<3;j++) { fns.push(()=>j); if (j===1) continue O; } } }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "O:for") != null or std.mem.indexOf(u8, r.output, "O: for") != null);
}

test "ES5: generator 안 일반 경로 for-of 도 캡처 시 _loop 를 generator 로 뽑는다 (#4722)" {
    // for-await 본문은 일반 visitor 로 방문돼 안쪽 for-of 가 일반 경로를 탄다. 거기서
    // 본문에 yield 가 있는데 평범한 함수로 뽑으면 raw yield 가 남아 파싱되지 않았다.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* g(s,t,fns){ for await (const a of s) { for (const b of t) { fns.push(()=>b); yield b; } } }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    // 합성된 `var _loop = …` 은 대입으로 접히므로 이름이 바깥 var 목록에 있어야 한다.
    const var_at = std.mem.indexOf(u8, r.output, "{var ") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, r.output, var_at, ";") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, r.output[var_at..end], "_loop") != null);
}

test "ES5: generator 안 for-of 는 조기 종료 시 iterator 의 return() 을 부른다 (#4714)" {
    // break·return·throw·바깥 .return() 으로 빠져나가면 IteratorClose 가 필요하다.
    // 예전엔 루프를 op 로 바로 접어 정리가 없었다 — 위임한 generator 의 finally 가 안 돌았다.
    var r = try e2eTarget(std.testing.allocator, "function* g(s){ for (const v of s) { if (v) break; yield v; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".return!=null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".return()") != null);
}

test "ES5: iterator close 는 정상 완료 플래그로 next() 예외 시 닫지 않는다 (#4714)" {
    // 플래그를 iterator 생성 **전에** true 로 두고, 조건식에서 `.done` 을 담는다.
    // next() 가 던지면 직전의 true 가 남아 finally 가 닫지 않는다(스펙).
    var r = try e2eTarget(std.testing.allocator, "function* g(s){ for (const v of s) yield v; }", .es5);
    defer r.deinit();
    const flag_at = std.mem.indexOf(u8, r.output, "=true;") orelse return error.TestUnexpectedResult;
    const values_at = std.mem.indexOf(u8, r.output, "__values(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(flag_at < values_at);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".next()).done") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!(_") != null);
}

test "ES5: 본문 throw 로 빠질 때 return() 의 에러보다 원래 에러가 우선한다 (#4714)" {
    // catch 로 원래 에러를 기억하고, 닫기를 감싼 안쪽 finally 에서 다시 던진다.
    var r = try e2eTarget(std.testing.allocator, "function* g(s){ for (const v of s) yield v; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "finally{if(_") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ")throw _") != null);
    // `= true` 는 세 곳: 루프 전 정상완료 플래그, 다음 next() 전 되돌림, catch 의 에러 표시.
    // 하나라도 빠지면 next() 예외 시 닫거나(앞 둘) 원래 에러를 잃는다(catch).
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, r.output, "=true;"));
    // 닫기는 정상 완료가 아닐 때만 — `!_n` 게이트가 없으면 다 돈 iterator 를 또 닫는다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "try{if(!_") != null);
}

test "ES5: 빈 case 가 '문장들 + yield' case 로 폴스루하지 않는다 (#4722)" {
    // #4718 은 바로 다음 op 가 yield 일 때만 봤다. 문장 몇 개 뒤에 yield 가 와도, 빈 라벨로
    // 들어오면 재개 라벨이 그 case 자신이라 문장까지 통째로 다시 실행된다.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* g(s){ B: for await (const v of s) { C: { if (v) break C; yield v; } } a(); yield 'end'; }",
        .es5,
    );
    defer r.deinit();
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, r.output, idx, ":case ")) |p| {
        idx = p + 1;
        const colon = std.mem.indexOfPos(u8, r.output, p + 6, ":") orelse continue;
        const next_case = std.mem.indexOfPos(u8, r.output, colon, "case ") orelse r.output.len;
        const body = r.output[colon + 1 .. next_case];
        try std.testing.expect(std.mem.indexOf(u8, body, "return[4,") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "return[4,__await") == null);
    }
}

test "ES2021: 필드를 낮추면 모든 멤버의 computed 키를 클래스 앞에서 한 번 평가한다 (#4723)" {
    // 필드 키가 생성자로 들어가면 인스턴스마다 재평가되고, 메서드 키가 IIFE 안에 남으면
    // 키의 yield/await 가 새 함수 안으로 들어간다. 키는 소스 순서대로 temp 로 뺀다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* g(){ const C = class { [yield 'f'] = 1; static [yield 's'] = 2; get [yield 'g']() { return 3; } }; return C; }",
        .es2021,
    );
    defer r.deinit();
    // 키 식이 생성자/IIFE 에 남지 않았다
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(this,yield") == null);
    // 소스 순서: f → s → g
    const f_at = std.mem.indexOf(u8, r.output, "yield \"f\"") orelse std.mem.indexOf(u8, r.output, "yield\"f\"") orelse return error.TestUnexpectedResult;
    const s_at = std.mem.indexOf(u8, r.output, "yield \"s\"") orelse std.mem.indexOf(u8, r.output, "yield\"s\"") orelse return error.TestUnexpectedResult;
    const g_at = std.mem.indexOf(u8, r.output, "yield \"g\"") orelse std.mem.indexOf(u8, r.output, "yield\"g\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(f_at < s_at and s_at < g_at);
}

test "ES2021: static 필드가 있는 익명 클래스 식이 크래시하지 않고 값으로 남는다 (#4723)" {
    // 이름이 없어 static 할당이 `.none` 이름을 역참조해 컴파일러가 죽었다(#4629 회귀).
    var r = try e2eTarget(std.testing.allocator, "var k='x'; f(class { static [k] = 1; });", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "f(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(") != null);
}

test "ES2021: const 에 바인딩된 익명 클래스는 선언 이름을 받는다 (#4723)" {
    // 낮추면서 IIFE·temp 이름·쉼표 식으로 감싸면 이름 추론이 깨진다(`X.name` 이 `_a`/`""`).
    // const 는 재할당이 불가능해 이름을 붙여도 의미가 같다.
    var r = try e2eTarget(std.testing.allocator, "const X = class { static y = 1; };", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class X") != null);
}

test "ES2017: async generator 안 클래스 computed 키의 await 도 __await 로 표시된다 (#4723)" {
    // await rewrite 가 클래스를 통째로 건너뛰어, 키의 await 가 plain yield 가 되면
    // __asyncGenerator 가 그 값을 소비자에게 내보내 키가 undefined 가 된다.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* g(){ const C = class { [await k]() { return 1; } async m(){ await z; } }; yield C; }",
        .es2017,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[yield __await(k)]") != null);
    // 메서드 본문의 await 는 그 메서드 것 — 건드리면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "await z") != null);
}

test "ES5: 객체 리터럴 메서드의 computed 키 yield 도 추출된다 (#4723)" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){ const o = { [yield 'm']() { return 1; } }; return o; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: 클래스 헤더(computed 키·extends)의 yield 도 추출된다 (#4723)" {
    // es5 는 클래스를 IIFE 로 낮추므로 키 식이 **새 함수 안**으로 들어간다. 키의 yield 를
    // 상태 기계가 먼저 꺼내 두지 않으면 raw `yield` 가 남아 산출물이 파싱되지 않는다.
    const cases = [_][]const u8{
        "function* g(){ const C = class { [yield 'k']() { return 1; } }; return C; }",
        "function* g(B){ const C = class extends (yield B) { m() {} }; return C; }",
        "function* g(){ class C { static [yield 's']() { return 1; } } return C; }",
    };
    for (cases) |src| {
        var r = try e2eTarget(std.testing.allocator, src, .es5);
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null); // 공허 방지
        try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    }
}

test "ES5: generator 안 클래스 선언은 generator 안에 남는다 (#4723)" {
    // es5 클래스 선언은 `var C = (function(){…})()` 를 pending_nodes 로 보류하고 `.none` 을
    // 돌려준다. 상태 기계 수집기가 그걸 비우지 않으면 **모듈 최상위로 새어** 클로저
    // (여기선 `t`)를 잃는다. yield 가 없어도 재현된다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* g(t){ class C { m(){ return t; } } yield new C().m(); }",
        .es5,
    );
    defer r.deinit();
    const gen_at = std.mem.indexOf(u8, r.output, "__generator(") orelse return error.TestUnexpectedResult;
    const cls_at = std.mem.indexOf(u8, r.output, "C=(function") orelse
        std.mem.indexOf(u8, r.output, "C = (function") orelse return error.TestUnexpectedResult;
    try std.testing.expect(cls_at > gen_at);
}

test "ES5: computed key / 멤버 대입 좌변 / for update 의 yield 도 추출된다 (#4721)" {
    // 추출되지 않은 `yield` 는 `__generator` 콜백(평범한 function) 안에 raw 로 남아
    // **산출물이 파싱조차 되지 않는다**(`SyntaxError: Unexpected strict mode reserved word`).
    // es5 산출물에는 `yield` 키워드가 하나도 없어야 한다.
    const cases = [_][]const u8{
        // 객체 리터럴 computed key — `computed_property_key` 래퍼를 순회해야 한다
        "function* g(){ const o = { ['k' + (yield 1)]: 2 }; return o; }",
        // computed 멤버가 **대입 좌변** — 우변만 보던 게이트가 놓쳤다
        "function* g(){ const o = {}; o[yield 'k'] = 1; return o; }",
        // for 의 update 절 — 진입 검사와 추출 양쪽에 빠져 있었다
        "function* g(){ for (let i = 0; i < 2; i += (yield 'u')) use(i); }",
        // for 의 init 절
        "function* g(){ for (let i = (yield 'i'); i < 2; i++) use(i); }",
    };
    for (cases) |src| {
        var r = try e2eTarget(std.testing.allocator, src, .es5);
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null); // 공허 방지
        try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    }
}

test "ES5: yield 없는 for 문은 상태 기계로 접지 않는다 (#4721 역방향)" {
    // 진입 검사를 넓히면서 모든 for 를 상태 기계로 접어 버리면 출력이 커지고 느려진다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function f(){ for (let i = 0; i < 2; i++) use(i); }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for (") != null or
        std.mem.indexOf(u8, r.output, "for(") != null);
}

test "ES5: 라벨이 겹치는 자리의 yield 는 별칭 case 로 폴스루하지 않는다 (#4718)" {
    // `__generator` 의 op 4(`yield`)·5(`yield*`)는 재개 라벨을 **현재 라벨 + 1** 로 잡는다.
    // 따라서 그 op 는 자기 case 의 라벨 + 1 에서 재개돼야 한다. 그런데 라벨이 같은 자리에
    // 두 개 생기면(예: try 영역 종료 + 라벨 스코프 종료) `case 14: case 15: return [4, v]`
    // 가 되고, 14 로 들어오면 재개가 15 = 같은 yield → **값이 두 번 방출된다**.
    // op 4(`yield`) 와 op 5(`yield*`) 둘 다 재개 라벨을 쓰므로 양쪽을 본다.
    const sources = [_][]const u8{
        "async function* g(){ B: for await (const v of [1,2]) { C: { if (v===1) break C; yield 'b'+v; } } yield 'end'; }",
        "function* inner(){ yield 1; } function* g(){ A: { yield 'a'; break A; } yield* inner(); }",
    };
    const expect_op = [_][]const u8{ "return[4,", "return[5," };

    for (sources, expect_op) |src, op| {
        var r = try e2eTarget(std.testing.allocator, src, .es5);
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.output, op) != null); // 공허 방지

        // `case A:case B:return[4,` / `[5,` 형태가 남아 있으면 별칭 라벨이다.
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, r.output, idx, ":case ")) |p| {
            idx = p + 1;
            const colon = std.mem.indexOfPos(u8, r.output, p + 6, ":") orelse continue;
            const rest = r.output[colon + 1 ..];
            try std.testing.expect(!std.mem.startsWith(u8, rest, "return[4,"));
            try std.testing.expect(!std.mem.startsWith(u8, rest, "return[5,"));
        }
    }
}

test "ES5: 라벨 붙은 for-await 의 continue 는 break 와 다른 곳으로 간다 (#4710)" {
    // `collectLabeledOperations` 의 `is_loop` 판정에 `.for_await_of_statement` 가 빠져
    // 있었다. 빠지면 `continue_label` 이 null 이 되고 `continue <label>` 이
    // `continue_label orelse break_label` 로 떨어져 **바깥 루프를 끊는다**.
    //
    // 라벨 번호에 의존하지 않도록, 같은 프로그램에서 `continue` 와 `break` 만 바꿔
    // 넣었을 때 **산출물이 달라야 한다**는 차분으로 본다. 버그가 있으면 두 산출물이
    // 바이트 단위로 같아진다.
    const src_head = "async function* g(){ A: for await (const a of [1,2]) { for await (const b of [1,2]) { if (b===2) ";
    const src_tail = " A; yield a; } } }";

    var r_continue = try e2eTarget(std.testing.allocator, src_head ++ "continue" ++ src_tail, .es5);
    defer r_continue.deinit();
    var r_break = try e2eTarget(std.testing.allocator, src_head ++ "break" ++ src_tail, .es5);
    defer r_break.deinit();

    try std.testing.expect(r_continue.output.len > 0);
    try std.testing.expect(!std.mem.eql(u8, r_continue.output, r_break.output));

    // 그리고 `continue` 의 점프 대상이 **결정돼야** 한다. for-await 는 while 로 낮아지므로
    // 그 while 이 자기 cond_label 을 `generator_loop_continue_label` 로 남겨야 하는데,
    // 안 남기면 sentinel fixup 이 기본값 0 으로 떨어져 `[3, 0]`(함수 맨 앞으로 점프)이
    // 방출된다 — 정상 출력에는 절대 나오지 않는 형태다.
    try std.testing.expect(std.mem.indexOf(u8, r_continue.output, "[3,0]") == null);
    try std.testing.expect(std.mem.indexOf(u8, r_continue.output, "[3, 0]") == null);
}

test "ES5: 상태 기계 루프의 캡처된 let 은 _loop generator 로 뽑아 위임한다 (#4716)" {
    // 상태 기계는 지역 변수를 함수 최상단 `var` 로 호이스트한다 → `let` 의 반복별
    // 바인딩이 하나로 합쳐져 루프 안 클로저가 전부 마지막 값을 캡처한다.
    // 본문에 `yield` 가 있어 평범한 함수로는 못 뽑으므로 **generator 로 뽑고 `yield*`**
    // 로 위임한다. 상태 기계가 그 위임을 `[5, __values(_loop(x))]` 로 접는다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* g(){ var fns=[]; for (let v of [1,2]) { fns.push(function(){return v;}); yield v; } }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[5,__values(") != null or
        std.mem.indexOf(u8, r.output, "[5, __values(") != null);
}

test "ES5: 캡처가 없으면 _loop 추출을 하지 않는다 (#4716 역방향)" {
    // 추출은 클로저가 루프 변수를 캡처할 때만 필요하다. 무조건 뽑으면 모든 루프가
    // 중첩 generator + 위임으로 바뀌어 출력이 커지고 느려진다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* g(){ for (let v of [1,2]) { yield v; } }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_loop") == null);
}

test "ES5: generator 안 for-of 는 __values iterator 프로토콜로 돈다 (#4709)" {
    // state machine 경로는 예전에 `_arr[_i]` / `_arr.length` 인덱스 루프로 접었다.
    // `.length` 가 없는 Set·Map·generator 는 첫 비교에서 루프가 끝나 **조용히 아무것도
    // 나오지 않는다**(배열·문자열만 우연히 동작). 에러도 경고도 없어 더 위험했다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* g(src) { for (const v of src) yield v; }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".next()") != null);
    // 인덱스 루프의 흔적이 남아 있으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".length") == null);
}

test "ES5: generator 안 for-in 은 그대로 키 배열 인덱스 루프다 (#4709 역방향)" {
    // for-in 은 iterator 프로토콜이 아니라 **키 수집** 의미다. for-of 와 같이 묶어
    // __values 로 돌리면 own+상속 enumerable 키 열거가 깨진다.
    var r = try e2eTarget(
        std.testing.allocator,
        "function* g(obj) { for (const k in obj) yield k; }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".length") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".push(") != null);
}

test "ES5: yield* string wraps with __values (#1910)" {
    var r = try e2eTarget(std.testing.allocator, "function* g() { yield* 'abc'; }", .es5);
    defer r.deinit();
    // raw value 직접 op[5] 로 가는 게 아니라 __values() 거쳐야 string/Map/Set 도 처리.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[5,\"abc\"]") == null);
}

test "ES5: yield* nested generator still works (#1910 regression)" {
    var r = try e2eTarget(std.testing.allocator, "function* a() { yield 1; } function* b() { yield* a(); yield 2; }", .es5);
    defer r.deinit();
    // 일반 generator (async X) 라 __async 없음 — __generator 만 확인.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
}

test "ES5: async generator 안 for-await 의 내부 await 은 __await 로 감싼다 (#4707)" {
    // es5 에서 async generator 의 inner 는 **동기** generator 라 await 과 yield 가 같은
    // op `[4, x]` 로 나간다. 둘을 가르는 건 `__await(…)` 포장뿐이다. for-await 다운레벨이
    // state machine 을 만드는 **도중에** 새로 만드는 await 이 포장을 못 받으면,
    // `__asyncGenerator` 가 그 값을 소비자에게 내보내고 `_state.sent()` 가 undefined 가
    // 되어 다음 줄 `.done` 접근에서 TypeError 가 난다.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* g() { for await (const v of [1, 2]) yield v; }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") != null);
    // for-await 의 `await _iter.next()` 가 `__await(...)` 로 감싸여 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__await(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".next()]") == null);
}

test "ES5: 평범한 async 함수의 for-await 은 __await 로 감싸지 않는다 (#4707 역방향)" {
    // `__async` 의 generator 프로토콜은 raw yield 를 쓴다. 여기까지 감싸면 헬퍼가
    // 이해하지 못하는 마커가 섞인다 — 신호가 async generator 밖으로 새면 안 된다.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function f() { for await (const v of [1, 2]) console.log(v); }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__await(") == null);
}

// === #1911: async generator (async function*) — __asyncGenerator wrapper ===

test "ES5: async generator emits __asyncGenerator wrapper call (#1911)" {
    // Note: e2eTarget = transform+codegen 만 — runtime helper 정의 emit 은 bundler 영역.
    // 여기선 호출 site 만 검증; helper 정의는 bundler_test/basic.zig 에서.
    var r = try e2eTarget(std.testing.allocator, "async function* g() { yield 1; yield 2; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator(this,arguments,") != null);
}

test "ES5: async generator with await wraps via __await (#1911)" {
    // body 안 `await x` 가 `yield __await(x)` 로 변환.
    var r = try e2eTarget(std.testing.allocator, "async function* g() { yield await Promise.resolve(1); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__await(") != null);
}

test "ES5: async generator state temps are not redeclared inside callback (#1911)" {
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* g() { yield 1; await Promise.resolve(); yield 2; } async function f(){ for await (var v of g()) {} }",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator(this,arguments,") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_state){{var _a") == null);
}

test "ES5: regular async function still uses __async (not __asyncGenerator) (#1911 regression)" {
    // is_async + !is_generator 케이스가 새 분기로 잘못 빠지지 않게 회귀 방지.
    var r = try e2eTarget(std.testing.allocator, "async function f() { return await Promise.resolve(1); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncGenerator") == null);
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
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return{x: await a, y: await b}; }", .es5);
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
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return[await a, await b]; }", .es5);
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
    var r = try e2eTarget(std.testing.allocator, "function foo() { return{...x}; }\nfunction bar({a = 1, b = true} = {}) { return a; }", .es5);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(Foo.prototype,\"sync\"") != null);
}

test "ES5: class expression with arrow `this` field declares _this alias (#4279)" {
    // class 식(expression) + 메서드(has_extra → IIFE) + 화살표 this 필드.
    // 과거 IIFE 재빌드가 `var _this = this;` alias prepend 를 누락 → 화살표 필드가
    // `_this is not defined` 로 런타임 크래시했다. 재빌드 제거 후 alias 가 보존돼야 한다.
    var r = try e2eTarget(std.testing.allocator,
        \\const C = class {
        \\  m() { return 1; }
        \\  f = () => this;
        \\};
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
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
    try std.testing.expectEqualStrings("var x=\"a\"+b+\"c\";", r.output);
}

test "ES2015: template empty head" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\"+a;", r.output);
}

test "ES2015: template multiple substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}${b}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\"+a+b;", r.output);
}

test "ES2015: template with text between substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c${d}e`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\"+b+\"c\"+d+\"e\";", r.output);
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

test "Hermes: async object method lowers even when object extensions are supported" {
    var r = try e2eFull(
        std.testing.allocator,
        "new ReadableStream({async pull(controller){const {done,value}=await iterator.next();return value;},cancel(reason){return iterator.return(reason);}});",
        .{ .unsupported = TransformOptions.compat.fromHermesPreset() },
        .{ .minify_whitespace = true },
        ".js",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "pull:function") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async pull") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield iterator.next") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "cancel(reason)") != null);
}

test "Hermes: async arrow expression body extracts nested await" {
    var r = try e2eFull(
        std.testing.allocator,
        "const encodeText=async (str)=>new Uint8Array(await new Request(str).arrayBuffer());",
        .{ .unsupported = TransformOptions.compat.fromHermesPreset() },
        .{ .minify_whitespace = true },
        ".js",
    );
    defer r.deinit();

    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield new Request") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new Uint8Array(_") != null);
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

test "ES2015: default parameter self TDZ 보존" {
    var r = try e2eTarget(std.testing.allocator, "function f(a=a){return a;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__tdz(\"a\")") != null);
}

test "ES2015: default parameter later binding TDZ 보존" {
    var r = try e2eTarget(std.testing.allocator, "function f(a=b,b=2){return a+b;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__tdz(\"b\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "b=b===void 0?2:b") != null);
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
    try std.testing.expectEqualStrings("var f=function(x){return x+1;};", r.output);
}

test "ES2015: arrow with parens param" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x+1;};", r.output);
}

test "ES2015: arrow block body" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>{return x;};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x;};", r.output);
}

test "ES2015: arrow multiple params" {
    var r = try e2eTarget(std.testing.allocator, "var f=(a,b)=>a+b;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(a,b){return a+b;};", r.output);
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
    try std.testing.expectEqualStrings("var f=function(a,b){return a+b;};", r.output);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo(_") != null);
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
    // iterator protocol: __values(반복자, Symbol 없는 엔진도) + .next() + try-catch-finally (#4746)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
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
    // 반복자 생성이 2번 이상 나와야 함 (outer + inner) — __values 헬퍼 호출 (#4746)
    const first = std.mem.indexOf(u8, r.output, "__values(a)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, r.output[first + 1 ..], "__values(b)") != null);
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
    // es2015 는 구조분해·`const` 가 네이티브다 — 루프 변수는 원래 종류로 남아 반복별
    // 바인딩을 지킨다(#4722). 예전 기대값 `[0]`/`[1]` 은 모든 타겟에서 `var` + 인덱스로
    // 풀던 부산물이었다(그래서 클로저가 전부 마지막 값을 캡처했다).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const [a,b]=") != null);
}

// --- ES2015: destructuring ---

test "ES2015: object destructuring" {
    // declarator 가 _a 를 직접 init 하므로 hoistTempVars 가 redundant 한 `var _a;` 를 추가하지 않는다 (#1960).
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a=obj,a=_a.a,b=_a.b;", r.output);
}

test "ES2015: array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var [x,y]=arr;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a=__read(arr,2),x=_a[0],y=_a[1];", r.output);
}

test "ES2015: array destructuring iterable read helper" {
    var r = try e2eTarget(std.testing.allocator, "var [x]=iter;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__read(iter,1)") != null);
}

test "ES2015: destructuring rename" {
    var r = try e2eTarget(std.testing.allocator, "var {a:c}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a=obj,c=_a.a;", r.output);
}

test "ES2015: destructuring default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a=obj,a=_a.a===void 0?1:_a.a;", r.output);
}

test "ES2015: destructuring default self TDZ 보존" {
    var r = try e2eTarget(std.testing.allocator, "var {a=a}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__tdz(\"a\")") != null);
}

test "ES2015: destructuring default later binding TDZ 보존" {
    var r = try e2eTarget(std.testing.allocator, "var {a=b,b=1}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__tdz(\"b\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "b=_a.b===void 0?1:_a.b") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=__read(arr,2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=_a[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y=_a[1]") != null);
}

// #4789: 대입의 나머지 요소를 버리던 결함 — 선언처럼 `_ref.slice(N)` 을 대입해야 한다.
test "ES2015: assignment array destructuring rest" {
    var r = try e2eTarget(std.testing.allocator, "[x,...y]=arr;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=__read(arr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y=_a.slice(1)") != null);
}

test "ES2015: assignment array destructuring nested rest pattern" {
    var r = try e2eTarget(std.testing.allocator, "[x,...[y,z]]=arr;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_b=__read(_a.slice(1),2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "z=_b[1]") != null);
}

// #4789: 대입 rest 자리의 private 필드·중첩 객체 rest 도 구조 분해를 지원하는 타깃에서 낮춘다.
// 안 낮추면 `[..._x.get(this)]=s` (잘못된 좌변) · es2017 에 객체 rest 문법이 남는다.
test "ES2017: assignment rest private field forces lowering" {
    var r = try e2eTarget(std.testing.allocator, "class B{#x;f(s){[...this.#x]=s;}}", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "ClassPrivateFieldSet(_x,this,_a.slice(0))") != null);
}

test "ES2017: assignment array rest nested object rest forces lowering" {
    var r = try e2eTarget(std.testing.allocator, "[a,...{b,...c}]=arr;", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "c=__rest(") != null);
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

// --- #1960: ES5 destructuring 회귀 ---

test "#1960-A (single fn): ES5 destructuring 출력에 var _a 가 한 번만 등장" {
    // function 안 destructuring → declarator 가 _a 를 init. hoistTempVars 가 redundant
    // `var _a;` 를 추가하면 mergeAdjacentDecls 가 `var _a, _a = init, ...` 로 합쳐 어색.
    var r = try e2eTarget(std.testing.allocator, "function f(o){const {x,y}=o;return x+y;}", .es5);
    defer r.deinit();
    // `var _a` 등장 횟수: declarator 안의 한 번만 — 함수 외부, 함수 안 redundant decl 모두 없어야 함
    var count: usize = 0;
    var iter = std.mem.window(u8, r.output, 6, 1);
    while (iter.next()) |w| {
        if (std.mem.eql(u8, w, "var _a")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=o") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=_a.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y=_a.y") != null);
}

test "#1960-A (multi fn): ES5 destructuring scope 격리 (외부 var _a; 없음)" {
    // 다른 함수 / root scope 의 hoistTempVars 가 함수 안 _a 를 다시 hoist 하면 안 됨.
    var r = try e2eTarget(std.testing.allocator, "function f(o){const {x}=o;return x;} function g(p){const {y}=p;return y;}", .es5);
    defer r.deinit();
    // root scope 에 lone `var _a;` (init 없는) 이 등장하면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a;") == null);
    // 두 함수 각각 _a 를 재사용 (function-scoped — counter restore 의 부수 효과)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=o") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=p") != null);
}

test "#1960-B: ES5 async + binding pattern destructuring lowering" {
    // const { x } = await fetch("") → state machine 안에서 ({ x:x } = _state.sent()) 로
    // 떨어지는데 ES5 에서 binding pattern LHS 는 invalid syntax. sequence expression 으로 분해.
    var r = try e2eTarget(
        std.testing.allocator,
        "async function f(){const {x}=await fetch('');return x;}",
        .es5,
    );
    defer r.deinit();
    // destructuring assignment 잔존 금지 (binding pattern LHS = ...)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{x:x}=") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{ x:x }=") == null);
    // sequence expression 으로 분해되어 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=_state.sent()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=_a.x") != null);
}

test "#1960-B: ES5 async + array binding pattern destructuring lowering" {
    var r = try e2eTarget(
        std.testing.allocator,
        "async function f(){const [a,b]=await fetch('');return a+b;}",
        .es5,
    );
    defer r.deinit();
    // await 결과가 이터러블이어도 되도록 `__read` 로 배열을 만든다 (#4791).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=__read(_state.sent(),2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a=_a[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "b=_a[1]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(Foo.prototype,\"method\"") != null);
}

test "ES2015: class with static method" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static create(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(Foo,\"create\"") != null);
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
    // #4629: define 의미론(`useDefineForClassFields=true`, 기본값)이면 assign 이 아니라
    // own property 정의다 — 바로 아래 static field 테스트가 예전부터 기대하던 것과 대칭.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(this,\"x\",1)") != null);
}

test "ES2015: class with static field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static y=2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "defineProperty(Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator with return" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;return 42;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,42]") != null);
}

test "ES2015: generator with for loop yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){for(var i=0;i<3;i++){yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,i]") != null);
    // 조건 부정: !(i<3)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!(i<3)") != null or
        std.mem.indexOf(u8, r.output, "!(i < 3)") != null);
}

test "ES2015: generator with if yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(x){if(x){yield 1;}yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,2]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,a]") != null);
}

test "ES2015: generator yield*" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield* [1,2];}", .es5);
    defer r.deinit();
    // (#1910) yield* 가 raw iterable 을 __values() 로 wrap — `return[5, __values([1,2])]`
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[5,__values([1,2])]") != null);
}

test "ES2015: generator do-while with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var i=0;do{yield i;i++;}while(i<3);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,i]") != null);
    // do-while: body 먼저, 조건으로 점프
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i<3") != null or
        std.mem.indexOf(u8, r.output, "i < 3") != null);
}

test "ES2015: generator try/catch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){yield e;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES2015: generator try/catch/finally with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){f(e);}finally{cleanup();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[7]") != null); // endfinally
    try std.testing.expect(std.mem.indexOf(u8, r.output, "cleanup()") != null);
}

// ============================================================
// ES2015 다운레벨링 추가 테스트
// ============================================================

// --- class extends/super ---

test "ES2015: class extends with super()" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(x){super(x);this.x=x;}}", .es5);
    defer r.deinit();
    // super(x) → _this=__callSuper(_super,[x],_newTarget) 뒤 this 접근/반환은 초기화 검사
    // _newTarget 은 derived ctor 시작에 캡쳐된 this.constructor — multi-level chain 에서도
    // 항상 top NewTarget 으로 평가돼 prototype propagation 이 정확.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[x],_newTarget)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _newTarget=this.constructor") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisInitialized(_this).x=x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return __assertThisInitialized(_this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(C,_super)") != null);
}

test "ES2015: class extends default constructor" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){}}", .es5);
    defer r.deinit();
    // 기본 생성자 → var _newTarget=this.constructor; return __callSuper(_super,arguments,_newTarget);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,arguments,_newTarget)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _newTarget=this.constructor") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(C,_super)") != null);
}

test "ES2015: super.method() call" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return super.m();}}", .es5);
    defer r.deinit();
    // super.m() → _super.prototype.m.call(this) — IIFE 매개변수 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.m.call(this)") != null);
}

test "ES2015: super property get/set receiver 보존" {
    var r1 = try e2eTarget(std.testing.allocator, "class C extends P{m(){return super.x;}}", .es5);
    defer r1.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "__superGet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "_super.prototype.x") == null);

    var r2 = try e2eTarget(std.testing.allocator, "class C extends P{m(){super.x=1;}}", .es5);
    defer r2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "__superSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "_super.prototype.x=1") == null);
}

test "ES2015: super property compound assignment receiver 보존" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){super.x += 2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.x+2") == null);
}

test "ES2015: computed super property assignment key 단일 평가" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){super[key()] += 2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=key()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,_a,this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,_a") != null);
}

test "ES2015: super property update expression receiver 보존" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return super.x++;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"x\",this)++") == null);
}

// #2022: derived constructor 안의 super.x receiver 는 외부 `this` 가 아니라 _this 여야 한다.
// super() lowering 이 인스턴스를 `_this = __callSuper(...)` 에 저장하므로 base accessor 의 `this`
// 가 인스턴스를 보려면 receiver 도 같은 _this 로 전달돼야 함.
test "ES2015: derived constructor 안 super property set receiver = _this (#2022)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){super();super.x=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,\"x\",1,__assertThisInitialized(_this))") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,\"x\",1,this)") == null);
}

test "ES2015: derived constructor 안 super property get receiver = _this (#2022)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){super();return super.x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"x\",__assertThisInitialized(_this))") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"x\",this)") == null);
}

test "ES2015: derived constructor 안 super property compound assign receiver = _this (#2022)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){super();super.x+=3;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisInitialized(_this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,\"x\",__superGet(_super.prototype,\"x\",this)") == null);
}

test "ES2015: derived constructor 안 computed super[k]= receiver = _this (#2022)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){super();const k=\"x\";super[k]=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,k,1,__assertThisInitialized(_this))") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,k,1,this)") == null);
}

// #2030: transparent wrapper(괄호, TS as/satisfies/type-assertion/!, Flow cast) 로 감싸진 super 도
// super lowering 의 obj 검사가 통과해야 한다 — 그렇지 않으면 raw `(super)[k]` / `super.x` 가 emit 돼
// 런타임 syntax error.
test "ES2015: 괄호 super 도 lowering — (super)[k] (#2030)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){const k=\"x\";(super)[k]=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(super)") == null);
}

test "ES2015: TS as-cast super 도 lowering — (super as any).x (#2030)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){(super as any).x=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,\"x\"") != null);
    // type assertion 이 strip 된 후 raw `super.x = 1` 로 떨어지면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.x=1") == null);
}

test "ES2015: TS as-cast computed super 도 lowering — (super as any)[k] (#2030)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){const k=\"x\";(super as any)[k]=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,k") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super[k]=1") == null);
}

test "ES2015: TS legacy <T>cast super 도 lowering — (<any>super)[k] (#2030)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){const k=\"x\";(<any>super)[k]=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superSet(_super.prototype,k") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super[k]=1") == null);
}

test "ES2015: TS non-null assertion super 도 lowering — super!.x (#2030)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return (super!).x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.x") == null);
}

test "ES2015: wrapped super method call 도 lowering — (super as any).m() (#2030)" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return (super as any).m();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.m") == null);
}

test "ES2015: static super access는 parent constructor 참조" {
    var r1 = try e2eTarget(std.testing.allocator, "class C extends P{static m(){return super.x+super.m();}}", .es5);
    defer r1.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "__superGet(_super,\"x\",this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "_super.m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "_super.prototype") == null);

    var r2 = try e2eTarget(std.testing.allocator, "class C extends P{static x=super.y;}", .es5);
    defer r2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "__superGet(_super,\"y\",C)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "_super.prototype") == null);
}

test "ES2015: derived constructor this 초기화 검사" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){this.x=1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisInitialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__possibleConstructorReturn") == null);
}

test "ES2015: derived constructor return 검사" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__possibleConstructorReturn") != null);
}

test "ES2015: derived constructor return 값이 super를 먼저 평가" {
    var r = try e2eTarget(std.testing.allocator, "function value(x){return undefined;}class C extends P{constructor(){return value(super());}}", .es5);
    defer r.deinit();
    const helper_pos = std.mem.indexOf(u8, r.output, "__possibleConstructorReturn(value(") orelse return error.TestExpectedEqual;
    const this_pos = std.mem.indexOfPos(u8, r.output, helper_pos, "),_this)") orelse return error.TestExpectedEqual;
    try std.testing.expect(helper_pos < this_pos);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__possibleConstructorReturn(_this,value(") == null);
}

test "ES2015: derived constructor return comma expression super 평가 순서" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){return (super(),undefined);}}", .es5);
    defer r.deinit();
    const helper_pos = std.mem.indexOf(u8, r.output, "__possibleConstructorReturn((__assertThisUninitialized") orelse return error.TestExpectedEqual;
    const this_pos = std.mem.indexOfPos(u8, r.output, helper_pos, "),_this)") orelse return error.TestExpectedEqual;
    try std.testing.expect(helper_pos < this_pos);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__possibleConstructorReturn(_this,((__assertThisUninitialized") == null);
}

test "ES2015: derived constructor return primitive도 super 후 검사" {
    var r = try e2eTarget(std.testing.allocator, "function value(x){return 1;}class C extends P{constructor(){return value(super());}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__possibleConstructorReturn(value(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__possibleConstructorReturn(_this,value(") == null);
}

test "ES2015: derived constructor super 중복 호출은 할당 전 검사" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(){super();super();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisUninitialized(_this),_this=__callSuper") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisUninitialized(_this,_this=") == null);
}

test "ES2015: derived constructor arrow this capture waits for super" {
    var r = try e2eTarget(
        std.testing.allocator,
        "class B{}class C extends B{constructor(emitter){super();emitter.addListener('evt',event=>{this.seen=event.value;});}}",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisUninitialized(_this),_this=__callSuper") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(event){_this.seen=event.value;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") == null);
}

test "ES2015: derived constructor arrow super uses lexical NewTarget" {
    // arrow 안의 super() 도 outer 의 _newTarget 변수를 closure 로 캡쳐 → lexical NewTarget 보존.
    var r = try e2eTarget(std.testing.allocator, "class B{constructor(arg){this.x=arg;}}class C extends B{constructor(){var callSuper=()=>super('foo');callSuper();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[\"foo\"],_newTarget)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _newTarget=this.constructor") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(this,_super") == null);
}

test "ES2015: nested arrow super 도 outer _newTarget 캡쳐" {
    // arrow 안의 arrow 안의 super() — 이중 closure 너머에서도 _newTarget 동일.
    var r = try e2eTarget(
        std.testing.allocator,
        "class B{constructor(arg){this.x=arg;}}class C extends B{constructor(){var f=()=>{var g=()=>super('y');g();};f();}}",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[\"y\"],_newTarget)") != null);
    // _newTarget 선언은 outer ctor 에 1번만 있어야 — 중복 선언 금지
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.output, "var _newTarget="));
}

test "ES2015: 분기별 super() 도 동일 _newTarget 사용" {
    // if/else 분기 양쪽에서 super() — 각 호출이 동일한 _newTarget 캡쳐 사용.
    var r = try e2eTarget(
        std.testing.allocator,
        "class B{constructor(v){this.v=v;}}class C extends B{constructor(flag){if(flag)super(1);else super(2);}}",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[1],_newTarget)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[2],_newTarget)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _newTarget=this.constructor") != null);
}

test "ES2015: super(...spread) 도 _newTarget 캡쳐 유지" {
    // spread 인자도 visit 후 array literal 로 그대로 전달, NewTarget 만 _newTarget.
    var r = try e2eTarget(
        std.testing.allocator,
        "class B{constructor(){this.args=arguments;}}class C extends B{constructor(...xs){super(...xs);}}",
        .es5,
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",_newTarget)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _newTarget=this.constructor") != null);
    // 원본 super 키워드 미잔존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super(") == null);
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

test "ES2015: class method descriptor는 enumerable false" {
    var r = try e2eTarget(std.testing.allocator, "class F{m(){return 1;}static s(){return 2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(F.prototype,\"m\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(F,\"s\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "configurable:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "writable:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.prototype.m=function") == null);
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
    // super() → __callSuper(_super,[],_newTarget) 변환
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[],_newTarget)") != null);
    // 원본 super 키워드가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super(") == null);
}

// --- class expression ---

test "ES2015: class expression simple" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{};", .es5);
    defer r.deinit();
    // #4723: `const F = class {}` 는 이름 추론으로 `F.name === "F"` 다. 예전 기대값
    // `function _Class()` 는 그 추론을 깨뜨린 출력(`F.name === "_Class"`)을 고정하고 있었다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function F()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_Class") == null);
}

test "ES2015: class expression with method" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{m(){return 1;}};", .es5);
    defer r.deinit();
    // IIFE 패턴. 이름은 선언 이름을 따른다(#4723 — 이름 추론 보존).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return F") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callSuper(_super,[],_newTarget)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__zntcClassPrivateFieldSet(_x,this,v)") != null);
}

test "ES2015: private field helper avoids constructor reference collision" {
    var r = try e2eTarget(std.testing.allocator,
        \\function make(max) {
        \\  var _y = function(n) { return Array; };
        \\  class Cache {
        \\    #y;
        \\    constructor() {
        \\      this.#y = 1;
        \\      this.arr = new (max ? _y(max) : Array)(max);
        \\    }
        \\  }
        \\  return new Cache().arr.length;
        \\}
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _y2=new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new (max?_y(max):Array)(max)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _y=new WeakMap") == null);
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

// #4790: 객체 rest 선언을 낮춰도 원래 선언 종류를 지킨다. `var` 로 바꾸면 블록 밖으로 새고
// for 헤더 `let` 의 반복별 바인딩이 사라진다.
// #4801: static 필드 초기값을 클래스 밖(`__publicField(A, …)`)으로 옮기면 그 안 `this`·`super` 가
// 클래스를 벗어난다 — `this` 는 클래스 이름, `super` 는 static 헬퍼로 낮춰야 한다.
test "ES2017: static field arrow this becomes class reference" {
    var r = try e2eTarget(std.testing.allocator, "class A { static x = 1; static f = () => this.x; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "()=>A.x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this") == null);
}

test "ES2017: static field arrow super is lowered outside class" {
    var r = try e2eTarget(std.testing.allocator, "class P { static s() {} } class Q extends P { static t = () => super.s(); }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".call(Q)") != null);
}

// 메서드·getter·중첩 클래스는 자기 `this` 를 가진다 — static 초기값·static 블록 안에서도 치환 금지.
test "ES2017: static init keeps this of methods, getters and nested classes" {
    var r = try e2eTarget(std.testing.allocator, "class A { static o = { get g() { return this; } }; static N = () => class { m() { return this; } }; static { this.k = { m() { return this; } }; } }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "get g(){return this;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "m(){return this;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return A;") == null);
}

test "ES2017: static init keeps this of nested class field initializers" {
    // 중첩 클래스 필드는 생성자로 옮겨진다 — 메서드 방문을 안 거치므로 클래스 경계에서 막아야 한다.
    var r = try e2eTarget(std.testing.allocator, "class A { static N = () => class { v = this; }; }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"v\",this)") != null);
}

test "ES2017: object rest declaration keeps const/let" {
    var r = try e2eTarget(std.testing.allocator, "{const {a,...r}=o;}{let {b,...s}=o;}", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const _a=o,a=_a.a,r=__rest(_a,[\"a\"]);") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let _b=o,b=_b.b,s=__rest(_b,[\"b\"]);") != null);
}

test "ES2017: object rest declaration in for header keeps let" {
    var r = try e2eTarget(std.testing.allocator, "for(let {i,...r}=o;i<2;i++)f(()=>i);", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(let _a=o,") != null);
}

// #4790: 같은 스코프의 `export const _a=…` 가 있으면 임시 변수를 `var _a;` 로 끌어올리지 않는다.
test "ES2017: object rest export const temp is not hoisted again" {
    var r = try e2eTarget(std.testing.allocator, "export const {a,...r}=o;", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export const _a=o,") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") == null);
}

test "ES5: object rest declaration still lowers to var" {
    var r = try e2eTarget(std.testing.allocator, "{const {a,...r}=o;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest(") != null);
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
    // break outer → return[3, N] (end label로 점프)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[3,") != null);
}

test "ES2015: generator labeled continue" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)continue outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // continue outer → return[3, N] (update label로 점프 → i++ 실행)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i++") != null);
}

// --- generator switch yield ---

test "ES2015: generator switch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){switch(x){case 1:yield 'a';break;default:yield 'b';}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // switch → if-else 체인으로 분해
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,\"a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,\"b\"]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__values(") != null);
}

// --- class edge cases ---

test "ES2015: class with computed method" {
    var r = try e2eTarget(std.testing.allocator, "var k='m';class F{[k](){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function F()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
}

test "ES2015: class with computed method uses bracket notation" {
    // [Symbol.iterator]() → Object.defineProperty(prototype, <key>, ...) (dot 없이).
    // computed key 는 hoist 된 임시 변수로 캡쳐되거나 직접 emit 될 수 있어 prefix/suffix 사이의
    // 식별자만 검증한다 (정확한 temp 이름에 결합하지 않음).
    var r = try e2eTarget(std.testing.allocator, "class F{[Symbol.iterator](){return this;}}", .es5);
    defer r.deinit();
    const prefix = std.mem.indexOf(u8, r.output, "Object.defineProperty(F.prototype,") orelse return error.TestUnexpectedResult;
    const after_prefix = prefix + "Object.defineProperty(F.prototype,".len;
    try std.testing.expect(after_prefix < r.output.len);
    const first = r.output[after_prefix];
    try std.testing.expect(std.ascii.isAlphabetic(first) or first == '_');
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Symbol.iterator") != null);
    // prototype.[Symbol.iterator] (잘못된 dot notation) 금지
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "prototype.["), null);
}

test "ES2015: static computed field uses bracket notation" {
    var r = try e2eTarget(std.testing.allocator, "var k='x';class F{static [k]=1;}", .es5);
    defer r.deinit();
    // computed key 는 hoist 된 임시 변수 (`var _a=k;`) 로 캡쳐된 뒤 defineProperty key로 사용된다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "defineProperty(F") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "F.[k]"), null);
}

test "ES2015: instance computed field uses computed key expression" {
    var r = try e2eTarget(std.testing.allocator, "var k='tag';class F{[k]='foo';}", .es5);
    defer r.deinit();
    // computed 키는 **클래스 정의 시점에 한 번** 평가돼야 한다(#4723). 예전 기대값
    // `__publicField(this,k,` 는 키를 생성자 안에서 **인스턴스마다 재평가**하는 출력을
    // 고정하고 있었다(#4629 에서 들어간 회귀). 이제 클래스 앞에서 temp 로 평가한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(this,k,") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=k;") != null or
        std.mem.indexOf(u8, r.output, "=k,") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "this.[k]"), null);
}

test "ES2015: class with multiple fields" {
    var r = try e2eTarget(std.testing.allocator, "class F{a=1;b='hi';c=true;}", .es5);
    defer r.deinit();
    // #4629: define 의미론 — 순서 보존 확인도 겸한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(this,\"a\",1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(this,\"b\",\"hi\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(this,\"c\",true)") != null);
}

test "ES2015: class constructor with super and field" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=0;}class D extends B{y=1;constructor(){super();this.z=2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    // super()가 있으므로 instance field 의 수신자는 `this` 가 아니라 `_this` 여야 한다.
    // #4629 로 정의 형태가 바뀌어도 그 수신자 선택은 그대로여야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__publicField(_this,\"y\",1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__assertThisInitialized(_this).z=2") != null);
}

test "ES2015: parameter property with default uses bare binding for assignment" {
    var r = try e2eTarget(std.testing.allocator, "class B{}class D extends B{constructor(public config: Config = {}){super();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.config=config") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "config:Config") == null);
}

// --- generator edge cases ---

test "ES2015: generator with while yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){var i=0;while(i<3){yield i;i++;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[4,i]") != null);
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
    // yield 0 → [4, 0], return"neg" → [2, "neg"]
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,\"neg\"]") != null);
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
    // #1480 이후 break는 __generator state machine의 label jump(return[3, N])로 변환됨.
    // iterator.return 호출 (finally 안)로 cleanup 보장.
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".return") != null);
}

test "ES2018: for-await-of inside try participates in async state machine" {
    var r = try e2eTarget(std.testing.allocator, "async function f(iter){try{for await(const v of iter){await g(v);}}finally{cleanup();}}", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for await") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "await ") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__asyncValues") != null);
}

test "ES5: throw sequence with nested await extracts before throw" {
    var r = try e2eTarget(std.testing.allocator, "async function f(err){throw this.once('error',function(){}),await finished(this.destroy(err)),err;}", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "throw this.once") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "throw err") != null);
}

test "ES5: await inside TS assertion participates in async state machine" {
    var r = try e2eTarget(std.testing.allocator, "async function f(permission){const status=(await NativeModule.check(permission)) as PermissionStatus;return status;}", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "status=((yield") == null);
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
    try std.testing.expectEqualStrings("var s=\"a\\n\"+b+\"\\nc\";", r.output);
}

test "ES2015: template with carriage return" {
    // ECMA-262 TV: <CR><LF>/<CR> 은 <LF> 로 정규화 (#4213) — 이전 기대값
    // "a\r\nb" 는 스펙 위반(native cooked 와 divergence) 박제였다.
    var r = try e2eTarget(std.testing.allocator, "var s=`a\r\nb`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\nb\";", r.output);
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

test "ES2020: optional method call this 바인딩 보존" {
    var r = try e2eTarget(std.testing.allocator, "obj.method?.(1,2);", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;(_a=obj.method)==null?void 0:_a.call(obj,1,2);", r.output);
}

test "ES2020: optional method call 복잡 receiver 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "getObj().method?.();", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a,_b;(_b=(_a=getObj()).method)==null?void 0:_b.call(_a);", r.output);
}

test "ES2020: optional super method call this 바인딩 보존" {
    var r = try e2eTarget(std.testing.allocator, "class B{m(){return this.x}}class C extends B{x=5;test(){return super.m?.()}}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=super)") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super.m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".call(this)") != null);
}

test "ES2020: optional computed super method call this 바인딩 보존" {
    var r = try e2eTarget(std.testing.allocator, "class B{m(){return this.x}}class C extends B{x=5;test(){return super['m']?.()}}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=super)") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super[\"m\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".call(this)") != null);
}

test "ES2020: optional super method call ES5 클래스 다운레벨 보존" {
    var r = try e2eTarget(std.testing.allocator, "class B{m(){return this.x}}class C extends B{x=5;test(){return super.m?.()}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".call(this)") != null);
}

// #2034: transparent wrapper(괄호, TS as/!/<T>) 로 감싸진 super 가 optional chain base 일 때
// raw `super` 가 temp 대입 RHS 로 emit 되던 버그 — super 는 항상 정의되어 있으므로 optional 무의미.
// optional flag 만 벗기고 정상 super lowering 으로 routing.
test "ES2020: 괄호 super 의 optional chain — (super)?.x (#2034)" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=1}class C extends B{m(){return (super)?.x}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super)") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=(super)") == null);
}

test "ES2020: TS as-cast super 의 optional chain — (super as any)?.x (#2034)" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=1}class C extends B{m(){return (super as any)?.x}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super)") == null);
}

test "ES2020: TS as-cast super 의 optional computed chain — (super as any)?.[k] (#2034)" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=1;[k:string]:any}class C extends B{m(){const k=\"x\";return (super as any)?.[k]}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,k") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super)") == null);
}

test "ES2020: TS as-cast super 의 optional method call — (super as any)?.m() (#2034)" {
    var r = try e2eTarget(std.testing.allocator, "class B{m(){return 1}}class C extends B{run(){return (super as any)?.m()}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super)") == null);
}

test "ES2020: TS non-null assertion super 의 optional chain — (super!)?.m() (#2034)" {
    var r = try e2eTarget(std.testing.allocator, "class B{m(){return 1}}class C extends B{run(){return (super!)?.m()}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super)") == null);
}

test "ES2020: wrapped super + 후속 optional chain — (super as any)?.x?.y (#2034)" {
    // ?.x 는 super-base 라 strip 되고 __superGet 으로 lowering, ?.y 는 일반 ternary 로 보존.
    var r = try e2eTarget(std.testing.allocator, "class B{get nested(){return{y:1}}}class C extends B{m(){return (super as any)?.nested?.y}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__superGet(_super.prototype,\"nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super)") == null);
}

test "ES2020: optional receiver + optional method call receiver 단락 평가" {
    var r = try e2eTarget(std.testing.allocator, "obj?.method?.(arg());", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj==null?void 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".call(obj,arg())") != null);
}

test "ES2020: optional receiver + optional method call 복잡 receiver 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "getObj()?.method?.(arg());", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=getObj())==null?void 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".call(_a,arg())") != null);
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

test "ES2021: logical assignment super member receiver 보존" {
    var r1 = try e2eTarget(std.testing.allocator, "class C extends B{m(){super.x ||= 1;}}", .es2020);
    defer r1.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "=super") == null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "super.x||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "super.x=1") != null);

    var r2 = try e2eTarget(std.testing.allocator, "class C extends B{m(){super.x &&= 2;}}", .es2020);
    defer r2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "=super") == null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "super.x&&") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "super.x=2") != null);

    var r3 = try e2eTarget(std.testing.allocator, "class C extends B{m(){super.x ??= 3;}}", .es2020);
    defer r3.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "=super") == null);
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "super.x??") != null);
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "super.x=3") != null);
}

test "ES2021: logical assignment computed super member key 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "class C extends B{m(){super[getKey()] ||= 1;}}", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=super") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super[_a=getKey()]||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super[_a]=1") != null);
}

test "ES2021: ||= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ||= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

test "ES2021: ||= member receiver 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "getObj().x ||= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=getObj()).x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a.x=5") != null);
}

test "ES2021: &&= member receiver 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "getObj().x &&= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=getObj()).x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a.x=5") != null);
}

test "ES2021: ??= computed member key 1회 평가" {
    var r = try e2eTarget(std.testing.allocator, "obj[getKey()] ??= 5;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=getKey()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj[_a]=5") != null);
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

test "ES2020: temp var hoisted for ?? in class method" {
    var r = try e2eTarget(std.testing.allocator, "class C{m(options){var queryHash=options.queryHash??hash(options.queryKey);return queryHash;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value:function(options){var _a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=options.queryHash)") != null);
}

test "ES2020: temp var hoisted for ?? in preserved class method" {
    var r = try e2eTarget(std.testing.allocator, "class C{m(options){return options.queryHash??hash(options.queryKey);}}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "m(options){var _a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=options.queryHash)") != null);
}

test "ES2020: temp var hoisted inside async state machine" {
    var r = try e2eTarget(std.testing.allocator, "async function f(context){return context.fetchOptions?.meta;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_state){{var _a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=context.fetchOptions)") != null);
}

test "ES2020: temp var hoisted inside generator state machine" {
    var r = try e2eTarget(std.testing.allocator, "function* f(context){yield 1;return context.fetchOptions?.meta;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_state){{var _a;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a=context.fetchOptions)") != null);
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

// === ES5 async transform regression suite (zntc/issues 1896, 1901) ===

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

test "ES5: async method state machine captures this for nested arrows" {
    var r = try e2eES5Async(std.testing.allocator,
        \\class QueryLike {
        \\  constructor() { this.value = 42; }
        \\  async fetch() {
        \\    const createContext = () => ({ value: this.value });
        \\    const context = createContext();
        \\    return context.value;
        \\  }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "value:_this.value") != null);
}

test "ES5: Babel async-to-generator fixture async-arrow-in-method captures lexical this" {
    var r = try e2eES5Async(std.testing.allocator,
        \\let TestClass = {
        \\  name: "John Doe",
        \\  testMethodFailure() {
        \\    return new Promise(async (resolve) => {
        \\      console.log(this);
        \\      setTimeout(resolve, 1000);
        \\    });
        \\  }
        \\};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(_this)") != null);
}

test "ES5: Babel async-to-generator fixture object-method-with-arrows keeps function boundaries" {
    var r = try e2eES5Async(std.testing.allocator,
        \\class Class {
        \\  async method() {
        \\    this;
        \\    () => this;
        \\    () => {
        \\      this;
        \\      () => this;
        \\      function x() {
        \\        this;
        \\        () => { this; }
        \\        async () => { this; }
        \\      }
        \\    }
        \\    function x() {
        \\      this;
        \\      () => { this; }
        \\      async () => { this; }
        \\    }
        \\  }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _arguments=arguments") == null);
}

test "ES5: Babel async-to-generator fixture deeply-nested-asyncs captures this and arguments" {
    var r = try e2eES5Async(std.testing.allocator,
        \\async function s(x, ...args) {
        \\  let t = async (y, a) => {
        \\    let r = async (z, b, ...innerArgs) =>  {
        \\      await z;
        \\      console.log(this, innerArgs, arguments);
        \\      return this.x;
        \\    }
        \\    await r();
        \\    console.log(this, args, arguments);
        \\    return this.g(r);
        \\  }
        \\  await t();
        \\  return this.h(t);
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _arguments=arguments") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(_this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_arguments)") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(_state){{var _a") == null);
}

test "ES5: async for-in body extracts await into state machine" {
    var r = try e2eES5Async(std.testing.allocator,
        \\async function validateAll(fields) {
        \\  for (const name in fields) {
        \\    const field = fields[name];
        \\    const fieldError = await validateField(field);
        \\    if (fieldError) break;
        \\  }
        \\  return true;
        \\}
    );
    defer r.deinit();
    // #4337: for-in 은 native for-in 으로 키 수집(own+상속, shadow-safe) — Object.keys(own-only) 아님.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.keys") == null);
    // 객체를 임시 변수에 먼저 담고(`_a=fields`) 그 키를 native for-in 으로 모은다 (#4746 풀이).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=fields;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_keys.push(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(yield validateField") == null);
    // 본문 const 는 상태 기계에서 블록 스코프를 지키려 `field$N` 으로 바뀐다 (#4712).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "validateField(field") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES5: async return sequence stays one generator return value" {
    var r = try e2eES5Async(std.testing.allocator,
        \\async function setup() {
        \\  return hook(), { onMessage: 1 };
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,(hook(),{onMessage:1})]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[2,hook(),{onMessage:1}]") == null);
}

test "ES5: async switch case block extracts await" {
    var r = try e2eES5Async(std.testing.allocator,
        \\async function requestCamera(result) {
        \\  switch (result) {
        \\    case "denied": {
        \\      const permission = await requestCameraPermission();
        \\      return permission === "granted";
        \\    }
        \\    default:
        \\      return false;
        \\  }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(yield requestCameraPermission") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "requestCameraPermission()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES5: class async method + nested-member optional-call hoists temp decl (react-query v5 regression)" {
    // es5 에서 class → IIFE 로 먼저 lowering → async 메서드는 es2015_class/
    // methods.zig 의 class-async-state-machine 경로로 처리된다. 이 경로만
    // es2017.zig 의 불변식(saved_temp_counter + hoistTempVarsSkippingSpans +
    // counter 복원)을 빠뜨려, optional chaining nested-member-call 이 만든
    // temp(_a/_b)의 `var` 선언이 함수 body 에 지역 hoist 되지 않고 counter 가
    // module-top 으로 누수됐다. scope-hoist 번들 모듈에서 per-module resync 가
    // 미사용 module-top `var _a..` 를 elide → `ReferenceError: _c is not
    // defined` (react-query v5 mutation execute). bundle-level end-to-end
    // 회귀 가드는 tests/integration/tests/react-query-v5-smoke.test.ts.
    var r = try e2eTarget(std.testing.allocator,
        \\class M {
        \\  o = { cb: async function (v) { return v; } };
        \\  async run(v) {
        \\    await Promise.resolve();
        \\    const c = await this.o.cb?.(v);
        \\    return (c ?? 0) + v;
        \\  }
        \\}
    , .es5);
    defer r.deinit();
    // class async 메서드도 state machine 으로 변환.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // optional-chaining nested-member-call temp 가 출력에 쓰이면 반드시 그
    // `var` 선언이 함께 emit 돼야 한다 — 선언 없는 `_a`/`_b` 사용 = 회귀.
    const uses_temp = std.mem.indexOf(u8, r.output, "_b.call(") != null or
        std.mem.indexOf(u8, r.output, "(_b=") != null or
        std.mem.indexOf(u8, r.output, "(_b =") != null or
        std.mem.indexOf(u8, r.output, "(_a=") != null or
        std.mem.indexOf(u8, r.output, "(_a =") != null;
    if (uses_temp) {
        try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null or
            std.mem.indexOf(u8, r.output, "var _b") != null or
            std.mem.indexOf(u8, r.output, ",_a") != null or
            std.mem.indexOf(u8, r.output, ",_b") != null);
    }
}

test "ES5 generator: labeled `continue` in for-of jumps to iterator advance, not cond (#4281)" {
    // 라벨된 for-of 의 `continue outer` 는 outer iterator advance(_a++)로 가야 한다.
    // (본문에 yield 가 있어야 상태 기계를 탄다 — 없으면 루프가 native 로 남는다, #4746.)
    // 버그 땐 outer cond 로 점프(`...return[3,3];return[3,1]`)해 _a++ 를 건너뛰어 무한 루프했다.
    // 수정 후엔 advance case 로 점프(`...return[3,3];return[3,6]`). (런타임: value=4, 종료)
    var r = try e2eTarget(std.testing.allocator,
        \\function* g() {
        \\  let s = 0;
        \\  outer: for (const x of [1, 2, 3]) {
        \\    for (const y of [0]) { if (x === 2) continue outer; s += x; yield y; }
        \\  }
        \\  return s;
        \\}
    , .es5);
    defer r.deinit();
    // continue outer 가 outer cond(case 1)로 바로 점프하던 버그 시그니처가 없어야 한다.
    // 헤더 const 는 상태 기계에서 `x$N` 으로 바뀐다 (#4712) — 이름 대신 `===2))` 로 찾는다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===2))return[3,3];return[3,1]") == null);
    // continue outer 의 점프 대상 case 는 **전진 지점**이어야 한다 — cond(`if(!!(` 로 시작하는
    // next() 호출 case)로 바로 가면 안 된다. 라벨 번호에 의존하지 않도록 대상 case 를 찾아
    // 그 본문 첫머리를 본다(#4714 가 iterator close 용 try 영역을 더해 번호가 바뀐다).
    const sig = "===2))return[3,3];return[3,";
    const at = std.mem.indexOf(u8, r.output, sig) orelse return error.TestUnexpectedResult;
    const num_start = at + sig.len;
    const num_end = std.mem.indexOfScalarPos(u8, r.output, num_start, ']') orelse return error.TestUnexpectedResult;
    var case_buf: [32]u8 = undefined;
    const case_text = try std.fmt.bufPrint(&case_buf, "case {s}:", .{r.output[num_start..num_end]});
    const case_at = std.mem.indexOf(u8, r.output, case_text) orelse return error.TestUnexpectedResult;
    var body = r.output[case_at + case_text.len ..];
    // 비어 있는 별칭 case(`case 8:case 9:`)는 건너뛴다.
    while (std.mem.startsWith(u8, body, "case ")) {
        const colon = std.mem.indexOfScalar(u8, body, ':') orelse break;
        body = body[colon + 1 ..];
    }
    try std.testing.expect(!std.mem.startsWith(u8, body, "if(!!("));
}

test "ES5 generator: labeled `continue` in do-while jumps to cond, not body (#4281)" {
    // 라벨된 do-while 의 `continue outer` 는 조건 평가 지점으로 가야 한다.
    // 버그 땐 body_label 로 점프(`...return[3,2];return[3,1]`)해 조건을 재평가하지 않았다.
    // 수정 후엔 cond case 로 점프(`...return[3,2];return[3,3]`). (런타임: value=8, 종료)
    var r = try e2eTarget(std.testing.allocator,
        \\function* g() {
        \\  let i = 0, s = 0;
        \\  outer: do { i++; if (i === 2) continue outer; s += i; } while (i < 4);
        \\  return s;
        \\}
    , .es5);
    defer r.deinit();
    // continue outer 가 body_label(case 1)로 점프하던 버그 시그니처가 없어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "if(!(i===2))return[3,2];return[3,1]") == null);
    // continue outer 가 cond(case 3)로 점프.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "if(!(i===2))return[3,2];return[3,3]") != null);
}

// #4468: static block 이 소스 원문 복사되던 시절엔 블록 안에서 **TS 타입이 strip
// 되지 않아** 문법적으로 깨진 JS 가 나왔다. 통합 스냅샷에만 의존하지 않도록
// codegen 유닛에서도 고정한다.
test "#4468 static block: TS 타입 어노테이션이 블록 안에서도 strip 된다" {
    var r = try e2eTarget(std.testing.allocator, "let getX;class C{#x=1;static{getX=(obj: C): number => obj.#x;}}", .esnext);
    defer r.deinit();
    // `: C` / `: number` 가 남으면 JS 로 파싱 불가.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj: C") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ": number") == null);
    // minify_whitespace 에선 단일 파라미터 괄호가 빠진다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj=>obj.#x") != null);
}

// 주석 배치(빈 블록 안의 주석이 밖으로 새지 않는지)는 codegen 유닛에서 검증할 수
// 없다 — 이 harness 는 `comments` 배열을 배선하지 않아 codegen 이 주석을 못 본다.
// 통합 스냅샷(tests/integration/tests/tsc/__snapshots__/classes.test.ts.snap)이 담당.

// ============================================================
// #4488 — for-await 다운레벨이 generator 안에 raw `await` 를 남김
// ============================================================
//
// `for await` 다운레벨은 iterator 프로토콜 + **`await` 표현식**을 만든다. 그 await 는 바깥
// async lowering 이 `yield` 로 바꿔 줘야 하는데, visitor 는 자기가 *방문한* await 만 낮춘다.
// for-await 는 body 를 visit 하는 **도중에** 새 await 노드를 만들므로 이미 지나간 방문을
// 받지 못했다 → generator 안에 raw `await` 가 남아 산출물이 파싱조차 안 됐다
// (`'await' is not allowed in non-async function`, es2015/es2016).
//
// 파싱 가능성 자체는 helpers 의 **산출물 재파싱 게이트**가 잡는다 (이 버그를 그렇게 찾았다).
// 여기서는 세 async 형태가 모두 `yield` 로 낮아졌는지를 명시적으로 박제한다.

fn expectNoRawAwait(output: []const u8) !void {
    // `__await(` 헬퍼 호출(async generator 의 `yield __await(v)`)은 정상 — 그 외의 `await ` 만 본다.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, output, i, "await")) |pos| {
        i = pos + 5;
        if (pos >= 2 and std.mem.eql(u8, output[pos - 2 .. pos], "__")) continue; // __await / __asyncValues 등
        if (pos + 5 < output.len and (output[pos + 5] == '(' or output[pos + 5] == '=')) continue; // __await(v) / 헬퍼 정의
        if (pos > 0 and (std.ascii.isAlphanumeric(output[pos - 1]) or output[pos - 1] == '_' or output[pos - 1] == '$')) continue;
        std.debug.print("\ngenerator 안에 raw await 잔존:\n{s}\n", .{output});
        return error.RawAwaitInGenerator;
    }
}

test "#4488 ES2015: async function 의 for-await 가 generator 안에 await 를 남기지 않는다" {
    var r = try e2eTarget(
        std.testing.allocator,
        "async function f(xs){ for await (const x of xs) { use(x); } }",
        .es2015,
    );
    defer r.deinit();
    try expectNoRawAwait(r.output);
}

test "#4488 ES2015: async generator 의 for-await 도 yield __await 로 낮아진다" {
    var r = try e2eTarget(
        std.testing.allocator,
        "async function* g(xs){ for await (const x of xs) { yield x; } }",
        .es2015,
    );
    defer r.deinit();
    try expectNoRawAwait(r.output);
    // async generator 는 사용자 yield 와 구분하기 위해 `yield __await(v)` 형태여야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__await(") != null);
}

test "#4488 ES2015: async arrow 의 for-await 도 동일" {
    var r = try e2eTarget(
        std.testing.allocator,
        "const f = async (xs) => { for await (const x of xs) { use(x); } };",
        .es2015,
    );
    defer r.deinit();
    try expectNoRawAwait(r.output);
}

test "ES5: 객체 리터럴 메서드의 super 는 그 객체의 프로토타입을 본다 (#4729)" {
    // 예전엔 home object 를 몰라 `Object.prototype` 을 기준으로 삼았다 — `__proto__` 가 있으면
    // 호출 즉시 TypeError. 평가마다 새 바인딩이 필요해 함수 파라미터로 home 을 잡는다.
    var r = try e2eTarget(std.testing.allocator, "const o={__proto__:p, n(){ return super.m(); }};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(_obj){return _obj={") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.prototype.m") == null);
}

test "ES5: 클래스 메서드 안 객체 리터럴의 super 는 바깥 클래스 부모를 보지 않는다 (#4729)" {
    // 메서드가 함수로 바뀌는 경로는 바깥 클래스의 super 문맥을 끊지 않아 `_super.prototype`
    // 을 기준으로 삼았다(조용히 틀린 값).
    var r = try e2eTarget(std.testing.allocator, "class B extends A{ m(){ return {n(){ return super.x(); }}; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).x.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.x") == null);
}

test "ES2016: async 객체 메서드 본문이 generator 로 옮겨져도 super 가 home 을 본다 (#4729)" {
    // 본문이 `function*` 로 옮겨지면 native super 는 SyntaxError 다. arrow 파라미터로 home 을
    // 잡아 평가마다 새 바인딩을 만든다(루프 안 객체들이 서로의 프로토타입을 보지 않게).
    var r = try e2eTarget(std.testing.allocator, "const o={__proto__:p, async n(){ return super.m(); }};", .es2016);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_obj=>_obj={") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.") == null);
}

test "ES5: 객체 값 자리가 this 를 쓰면 함수로 감싸지 않고 임시 변수에 담는다 (#4729)" {
    // 일반 함수로 감싸면 값 자리의 `this` 가 바뀐다 — 함수 단위 임시 변수로 돌아간다.
    var r = try e2eTarget(std.testing.allocator, "function F(){ return {a:this.k, n(){ return super.m(); }}; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function(_obj)") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _a={a:this.k,") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_a).m.call(this)") != null);
}

test "ES2015: super 가 native 로 남는 타겟에선 객체를 감싸지 않는다 (#4729)" {
    var r = try e2eTarget(std.testing.allocator, "const o={__proto__:p, n(){ return super.m(); }};", .es2015);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.m()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_obj") == null);
}

test "ES5: _loop 으로 추출된 본문의 임시 변수는 _loop 안에 선언한다 (#4729)" {
    // 바깥 함수에 두면 모든 반복이 한 변수를 공유해, 반복마다 만든 클로저가 마지막 값을 본다.
    var r = try e2eTarget(std.testing.allocator, "for (let i=0;i<2;i++){ fns.push(()=>i); x = a.b?.c; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _loop=function(i){var _a;") != null);
    try std.testing.expect(std.mem.startsWith(u8, r.output, "var _loop"));
}

test "ES5: 객체 메서드 안 클래스의 super 는 그 클래스 부모를 본다 (#4729)" {
    // 클래스 진입 시 바깥 객체 메서드의 home 을 끊지 않으면, home 이 클래스 super 보다
    // 먼저 잡혀 클래스 메서드의 `super.q()` 가 객체의 프로토타입을 본다.
    var r = try e2eTarget(std.testing.allocator, "const o={__proto__:p, n(){ class C extends X { m(){ return super.q(); } } return super.m(); }};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_super.prototype.q.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).m.call(this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).q") == null);
}

test "ES2016: async 객체 메서드 안 native 클래스의 super 는 그대로 둔다 (#4729)" {
    // class 가 native 인 타겟 — 바깥 home 이 새면 클래스 메서드의 super 까지 낮춰진다.
    var r = try e2eTarget(std.testing.allocator, "const o={__proto__:p, async n(){ class C extends X { m(){ return super.q(); } } return super.m(); }};", .es2016);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super.q()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).m.call(this)") != null);
}

test "ES5: await 가 든 객체(상태 기계 재구성)의 메서드 super 도 home 을 본다 (#4729)" {
    // 상태 기계는 yield 가 든 객체를 object_expression 방문 없이 멤버별로 재구성한다 —
    // 거기서 home 을 배정하지 않으면 옛 fallback(Object.prototype)이 쓰인다.
    var r = try e2eTarget(std.testing.allocator, "async function f(){ return {w: await x, get g(){ return super.v; }}; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.prototype") == null);
}

test "ES2016: 객체 메서드 안 클래스 필드 초기화식의 super 는 클래스 기준이다 (#4729)" {
    // 필드 초기화식은 메서드 방문을 거치지 않으므로, 클래스 진입 시 home 을 끊지 않으면
    // 바깥 객체의 프로토타입으로 낮춰진다.
    var r = try e2eTarget(std.testing.allocator, "const o={__proto__:p, async n(){ class C extends X { f = super.q; } return super.m(); }};", .es2016);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"f\",super.q)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).q") == null);
}

test "ES5: for-in/for-of 에서 _loop 으로 추출된 본문의 임시 변수도 _loop 안에 선언한다 (#4729)" {
    var r_in = try e2eTarget(std.testing.allocator, "for (const k in o){ fns.push(()=>k); x = a.b?.c; }", .es5);
    defer r_in.deinit();
    try std.testing.expect(std.mem.startsWith(u8, r_in.output, "var _loop=function(k){var _a;"));

    var r_of = try e2eTarget(std.testing.allocator, "for (const k of o){ fns.push(()=>k); x = a.b?.c; }", .es5);
    defer r_of.deinit();
    // for-of 는 반복자 for 로 풀리고 k 는 본문 선언이 된다(#4746) — `_loop` 은 파라미터가 없다.
    const loop_at = std.mem.indexOf(u8, r_of.output, "var _loop=function(){var _") orelse return error.TestUnexpectedResult;
    // 옵셔널 체인 temp 는 _loop 본문 안에서 선언·사용된다.
    const body = r_of.output[loop_at..];
    const decl_end = std.mem.indexOfScalar(u8, body, ';') orelse return error.TestUnexpectedResult;
    const temp = body["var _loop=function(){var ".len..decl_end];
    var needle_buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "x=({s}=a.b)", .{temp});
    try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
}

test "native 필드 + async 낮추기 조합: 객체 메서드 안 클래스 필드의 super 는 클래스 기준이다 (#4729)" {
    // 필드는 native 로 남고 async 메서드만 낮추는 조합 — 필드 초기화식이 class 방문 안에서
    // 그대로 visit 된다. 클래스 진입 시 바깥 home 을 끊지 않으면 필드의 `super.q` 가
    // 객체의 프로토타입으로 낮춰진다.
    var u = helpers.TransformOptions.compat.fromESTarget(.esnext);
    u.async_await = true;
    var r = try e2eFull(std.testing.allocator, "const o={__proto__:p, async n(){ class C extends X { f = super.q; } return super.m(); }};", .{ .unsupported = u }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "f=super.q;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.getPrototypeOf(_obj).m.call(this)") != null);
}

test "객체 home 파라미터 이름은 사용자 식별자를 가리지 않는다 (#4729 후속)" {
    // `_obj` 는 temp 패턴(`_a`)이 아니라 기존 충돌 검사에 걸리지 않았다 — 값 자리의 사용자
    // `_obj` 가 arrow/function 파라미터에 가려져 undefined 가 됐다.
    var r5 = try e2eTarget(std.testing.allocator, "const _obj = 5; const o = { __proto__: p, a: _obj, n(){ return super.m(); } };", .es5);
    defer r5.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r5.output, "(function(_obj2){return _obj2={") != null);
    try std.testing.expect(std.mem.indexOf(u8, r5.output, "a:_obj,") != null);

    var r16 = try e2eTarget(std.testing.allocator, "const _obj = 5; const o = { __proto__: p, a: _obj, async n(){ return super.m(); } };", .es2016);
    defer r16.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r16.output, "(_obj2=>_obj2={") != null);
    try std.testing.expect(std.mem.indexOf(u8, r16.output, "a:_obj,") != null);
}

test "ES5: 블록·함수 본문의 using 도 dispose 로 낮춘다 (#4730)" {
    // es5 는 블록이 block scoping 경로로 먼저 빠져 using 낮추기를 건너뛰었다 — dispose
    // 없이 var 가 됐다(함수 본문도 block_statement 라 같은 경로).
    var r = try e2eTarget(std.testing.allocator, "function f(){ using a = g(); use(a); } { using b = h(); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a=__using(_stack") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var b=__using(_stack") != null);
    try std.testing.expect(std.mem.count(u8, r.output, "__callDispose(_stack") == 2);
}

test "ES2024: using 낮추기마다 이름이 고유하고 에러 상태를 초기화한다 (#4730)" {
    // 고정 이름이면 중첩 블록이 바깥 스택을 덮어쓰고, 앞 블록의 _hasError 가 남아 뒤 블록의
    // finally 가 옛 에러를 다시 던진다.
    var r = try e2eTarget(std.testing.allocator, "{ using a = g(); { using b = h(); } }", .es2024);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _stack=[],_error=void 0,_hasError=false;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _stack2=[],_error2=void 0,_hasError2=false;") != null);
    // catch 파라미터도 낮추기마다 번호가 붙는다 — 상태 기계가 함수 안 고유 이름으로 믿는다 (#4760).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "catch(_2){_error2=_2;_hasError2=true;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callDispose(_stack2,_error2,_hasError2)") != null);
    // 블록 안 using 은 native let/const 타겟에서 const 로 남는다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const a=__using(_stack,") != null);
}

test "ES2024: using 이름은 사용자 식별자를 피한다 (#4730)" {
    var r = try e2eTarget(std.testing.allocator, "{ using a = g(); var _stack = 1; }", .es2024);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _stack2=[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__using(_stack2,") != null);
}

test "ES2024: 함수 본문 using 은 본문 전체를 감싸 뒤쪽 함수 선언도 호이스팅된다 (#4730)" {
    // 첫 using 부터만 감싸면 `g()` 가 try 밖에 남아 try 블록 안의 g 를 못 본다.
    var r = try e2eTarget(std.testing.allocator, "function f(){ log(g()); using a = r(); function g(){ return 1; } }", .es2024);
    defer r.deinit();
    const try_at = std.mem.indexOf(u8, r.output, "try{") orelse return error.TestUnexpectedResult;
    const call_at = std.mem.indexOf(u8, r.output, "log(g())") orelse return error.TestUnexpectedResult;
    const fn_at = std.mem.indexOf(u8, r.output, "function g()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(try_at < call_at);
    try std.testing.expect(try_at < fn_at);
}

test "ES2024: 모듈 최상위 using 의 export 는 try 밖 export 목록으로 모은다 (#4730)" {
    // export 는 try 안에 있을 수 없다 — 예전 출력은 문법 오류였다.
    var r = try e2eFull(std.testing.allocator, "using a = r(); export const k = 1; export function g(){ return k; } export class C {} export default 7;", .{ .unsupported = helpers.TransformOptions.compat.fromESTarget(.es2024) }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    const try_at = std.mem.indexOf(u8, r.output, "try{") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export function g()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export function g()").? < try_at);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var k=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var C=class C") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export {k,C,_default as default};") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export const") == null);
}

test "ES2024: for (using x of …) 헤더는 본문 블록의 using 으로 옮겨 낮춘다 (#4730)" {
    // 헤더의 using 은 어떤 타겟에서도 낮춰지지 않아 `using` 문법이 그대로 남았다.
    var r = try e2eTarget(std.testing.allocator, "for (using x of xs) use(x);", .es2024);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(const _using of xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const x=__using(_stack,_using)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "using x") == null);
}

test "ES5: async 함수 안 for (await using …) 의 dispose await 도 상태 기계가 접는다 (#4730)" {
    // await 는 낮추기가 합성해 원본에 없다 — 상태 기계가 이 루프를 일반 문장으로 보내 raw
    // await 가 남았다(SyntaxError).
    var r = try e2eTarget(std.testing.allocator, "async function f(){ for (await using x of xs) use(x); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "await ") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callDispose(_stack") != null);
}

test "ES2024: using 낮추기는 지시문을 목록 맨 앞에 남긴다 (#4730)" {
    // 지시문이 try 안으로 들어가면 평범한 문자열 식이 되어 strict 모드가 풀린다.
    var r = try e2eTarget(std.testing.allocator, "function f(){ \"use strict\"; using a = r(); }", .es2024);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function f(){\"use strict\";var _stack=[]") != null);
}

test "ES5: generator 상태 기계 안 using 도 dispose 한다 (#4730)" {
    // 상태 기계는 yield 가 든 목록을 직접 수집해 목록 방문(using 낮추기)을 거치지 않았다.
    // 새 이름은 상태 기계가 대입으로 바꾸므로 wrapper 최상단에 선언돼야 한다.
    var r = try e2eTarget(std.testing.allocator, "function* g(){ using a = r(); yield 1; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function g(){var _stack,_error,_hasError,a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a=__using(_stack,r())") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__callDispose(_stack,_error,_hasError);return[7];") != null);
}

test "ES5·최상위: using 목록의 함수 선언은 try 밖 앞쪽으로 끌어올린다 (#4730)" {
    // es5 는 블록 안 함수 선언이 표준이 아니고, 모듈 최상위는 export function 때문에 try
    // 안에 둘 수 없다. 끌어올려도 앞쪽 문장에서 호출할 수 있다.
    var r5 = try e2eTarget(std.testing.allocator, "function f(){ log(g()); using a = r(); function g(){ return 1; } }", .es5);
    defer r5.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r5.output, "function g(){return 1;}var _stack=[]") != null);

    var rt = try e2eTarget(std.testing.allocator, "log(g()); using a = r(); function g(){ return 1; }", .es2024);
    defer rt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rt.output, "function g(){return 1;}var _stack=[]") != null);
}

test "ES5: generator 중첩 블록 using 의 새 이름도 wrapper 최상단에 선언한다 (#4730)" {
    // 중첩 블록은 호이스팅 수집 뒤에 재구성되므로 이름을 직접 등록해야 한다 — 빠지면
    // 선언 없는 대입(`_stack = []`)이 된다.
    var r = try e2eTarget(std.testing.allocator, "function* g(){ { using a = r(); yield 1; } }", .es5);
    defer r.deinit();
    // 블록의 using 바인딩은 블록 스코프라 `a$N` 으로 바뀌어 등록된다 (#4712).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_stack,_error,_hasError") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a,") == null);
}

test "ES5 상태 기계: catch 파라미터는 고유 이름으로 바뀌어 바깥 동명 바인딩을 가리지 않는다 (#4712)" {
    // 예전엔 catch 파라미터를 원래 이름 그대로 wrapper 최상단 var 로 올려, catch 안의 대입이
    // catch 밖의 같은 이름(바깥 스코프)까지 덮었다.
    var r = try e2eTarget(std.testing.allocator, "function* g(){ try { yield 1; } catch (err) { err = 1; yield 2; } log(err); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function g(){var err$1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "err$1=_state.sent();err$1=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "log(err);") != null);
}

test "ES5 상태 기계: 수집하지 않는 catch 는 native catch 로 남고 파라미터를 올리지 않는다 (#4712)" {
    // yield 없는 try 는 문장 그대로 나가 native catch 스코프를 쓴다 — 파라미터를 wrapper 로
    // 올리면 바깥 동명 바인딩을 가린다.
    var r = try e2eTarget(std.testing.allocator, "function* g(){ try { f(); } catch (e) { log(e); } yield 1; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function g(){return $gn(") != null or std.mem.indexOf(u8, r.output, "function g(){return __generator(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "catch(e){log(e);}") != null);
}

test "ES5 상태 기계: 중첩 블록·루프 헤더의 let 은 고유 이름으로 바뀐다 (#4712)" {
    var rb = try e2eTarget(std.testing.allocator, "function* g(){ { let x = 1; yield 1; log(x); } log(x); }", .es5);
    defer rb.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rb.output, "function g(){var x$1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rb.output, "log(x$1);log(x);") != null);

    var rl = try e2eTarget(std.testing.allocator, "function* g(){ for (let i = 0; i < 1; i++) { yield i; } log(i); }", .es5);
    defer rl.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rl.output, "function g(){var i$1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rl.output, "log(i);") != null);
}

test "ES5 상태 기계: 구조분해 catch 파라미터는 단순 대입으로 낮추고 키를 보존한다 (#4712)" {
    // 패턴을 대입 좌변에 그대로 쓰면 es5 에 구조분해가 남고, 리네임된 축약형 키가 다른
    // 속성을 읽고, minify 가 값 자리를 선언과 잇지 못한다.
    var r = try e2eTarget(std.testing.allocator, "function* g(){ try { yield 1; } catch ({ message }) { yield 2; log(message); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "message$1=_b.message,") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "({") == null);

    // 기본값이 붙은 중첩 패턴도 재귀로 푼다.
    var rn = try e2eTarget(std.testing.allocator, "function* g(){ try { yield 1; } catch ({ b: [c] = d }) { yield 2; log(c); } }", .es5);
    defer rn.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rn.output, "c$1=_c[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rn.output, "[c") == null);
}

test "ES5: 리네임된 구조분해 기본값의 멤버 접근은 원래 속성 이름을 쓴다 (#4712)" {
    // `{ a = 1 }` 의 기본값 분기가 키를 방문해 블록 리네임을 받아 `_a.a$1` 을 읽었다.
    var r = try e2eTarget(std.testing.allocator, "function f(o){ let a = 0; { let { a = 1 } = o; g(a); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a$1=_a.a===void 0?1:_a.a;") != null);
}

test "상태 기계: 구조분해가 native 인 타겟에서도 구조분해 대입은 단순 대입으로 낮춘다 (#4712)" {
    // 바인딩 패턴을 대입 좌변에 두면 minify 재해석이 패턴 안을 선언으로 봐서, 리네임된
    // 블록 바인딩의 대입이 호이스트된 선언과 이어지지 않는다(Hermes + minify 에서 드러남).
    var u = helpers.TransformOptions.compat.fromESTarget(.esnext);
    u.generator = true;
    u.block_scoping = true;
    var r = try e2eFull(std.testing.allocator, "function* g(e){ { let { m } = e; yield 1; log(m); } }", .{ .unsupported = u }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "m$1=_a.m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "({") == null);
}

test "ES5 상태 기계: 컴파일러가 만든 catch 임시 변수는 리네임하지 않는다 (#4712)" {
    // for-of 닫기의 합성 catch 파라미터는 이미 wrapper 에 등록된 고유 이름이다.
    var r = try e2eTarget(std.testing.allocator, "function* g(s){ for (var v of s) { if (v) break; yield v; } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "$") == null);
}

test "상태 기계: block scoping 이 native 인 조합에선 블록 바인딩을 원래 이름으로 올린다 (#4712)" {
    // 식별자 리네임은 block scoping 을 낮출 때만 적용된다 — 리네임 없이 선언만 `x$N` 으로
    // 등록하면 참조가 선언 없는 `x` 가 된다. 이 조합에선 예전 동작을 유지한다.
    var u = helpers.TransformOptions.compat.fromESTarget(.esnext);
    u.generator = true;
    var r = try e2eFull(std.testing.allocator, "function* g(){ { let x = 1; yield 1; log(x); } }", .{ .unsupported = u }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "$") == null);
}

test "ES5: 루프 본문 선언을 클로저가 캡처하면 반복별로 뽑는다 (#4743)" {
    // 헤더 let 만 추출 조건이던 때는 `var` 헤더 루프의 본문 const 가 하나로 합쳐져 모든
    // 클로저가 마지막 값을 봤다.
    var r = try e2eTarget(std.testing.allocator, "for (var i=0;i<2;i++){ const v=i; f.push(()=>v); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _loop=function(){var v=i;f.push(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(var i=0;i<2;i++)_loop();") != null);
}

test "ES5: while / do-while 도 본문 캡처 시 반복별로 뽑는다 (#4743)" {
    // 두 루프는 헤더 선언이 없어 추출 경로 자체가 없었다.
    var rw = try e2eTarget(std.testing.allocator, "while (c()){ const v=n(); f.push(()=>v); }", .es5);
    defer rw.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rw.output, "while(c())_loop();") != null);

    var rd = try e2eTarget(std.testing.allocator, "do { let v=n(); f.push(()=>v); } while (c());", .es5);
    defer rd.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rd.output, "do _loop();while(c());") != null);
}

test "ES5: 추출된 루프 본문의 var 는 바깥으로 끌어올린다 (#4743)" {
    // 본문을 함수로 뽑으면 var 가 그 함수의 지역 변수가 되어 루프 밖에서 사라졌다
    // (`ReferenceError: w is not defined`).
    var r = try e2eTarget(std.testing.allocator, "for (let i=0;i<2;i++){ var w=i; f.push(()=>i); } use(w);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var w,_loop=function(i){w=i;") != null);
}

test "ES5: 캡처가 없으면 루프 본문을 뽑지 않는다 (#4743)" {
    var r = try e2eTarget(std.testing.allocator, "for (var i=0;i<2;i++){ const v=i; s+=v; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_loop") == null);
}

test "ES5 상태 기계: 루프 안 catch 파라미터를 캡처하면 반복별 generator 로 뽑는다 (#4743)" {
    // 상태 기계는 catch 파라미터를 wrapper var 로 올리므로 캡처되면 모든 반복이 공유했다.
    var r = try e2eTarget(std.testing.allocator, "function* g(){ for (var i=0;i<2;i++){ try { throw i; } catch (e) { yield 0; f.push(()=>e); } } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return[5,__values(_loop())]") != null);
}

test "ES5 상태 기계: while 본문 캡처도 반복별 generator 로 뽑는다 (#4743)" {
    var r = try e2eTarget(std.testing.allocator, "async function g(){ while (c()){ const v=n(); await 0; f.push(()=>v); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "if(!c())return[3,3];return[5,__values(_loop())];") != null);
}

test "ES5: for-of 본문 선언 캡처도 반복별로 뽑는다 (#4743)" {
    // 헤더 x 가 아니라 본문 v 를 캡처 — 예전엔 헤더만 봐서 추출하지 않았다.
    var r = try e2eTarget(std.testing.allocator, "for (const x of xs){ const v=x*2; f.push(()=>v); }", .es5);
    defer r.deinit();
    // for-of 풀이 뒤 x·v 모두 본문 선언이라 둘 다 _loop 안에서 반복마다 새로 선언된다 (#4746).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_loop=function(){var x=_step.value;var v=x*2;") != null);
}

test "ES5: 중첩 루프 본문의 캡처는 안쪽 루프만 뽑는다 (#4743)" {
    // 안쪽 루프의 본문 선언은 안쪽 루프가 반복마다 뽑는다 — 바깥 루프까지 뽑을 필요 없다.
    var r = try e2eTarget(std.testing.allocator, "for (var i=0;i<2;i++){ for (var j=0;j<2;j++){ const v=j; f.push(()=>v); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.startsWith(u8, r.output, "for(var i=0;i<2;i++){{var _loop=function(){"));
    try std.testing.expect(std.mem.count(u8, r.output, "_loop=function") == 1);
}

test "ES5: 추출할 때 중첩 함수 안의 var 는 끌어올리지 않는다 (#4743)" {
    var r = try e2eTarget(std.testing.allocator, "for (let i=0;i<2;i++){ function h(){ var z=1; return z; } f.push(()=>i+h()); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function h(){var z=1;return z;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var z,") == null);
}

test "ES5 상태 기계: 구조분해 대입의 object rest 를 __rest 로 채운다 (#4750)" {
    // 상태 기계는 `const {a, ...r} = o` 를 대입으로 낮추는데, 이 경로가 rest 를 무시해
    // r 이 undefined 로 남았다(Hermes 는 #4712 가 이 경로로 바꾼 회귀).
    var r = try e2eTarget(std.testing.allocator, "function* g(o){ const { a, ...r } = o; yield r; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a=_a.a,r=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(_a,[\"a\"])") != null);
}

test "ES5 상태 기계: 구조분해 대입의 array rest 를 slice 로 채우고 패턴 rest 는 재귀로 푼다 (#4750)" {
    var ra = try e2eTarget(std.testing.allocator, "function* g(o){ const [x, ...r] = o; yield r; }", .es5);
    defer ra.deinit();
    try std.testing.expect(std.mem.indexOf(u8, ra.output, "x=_a[0],r=_a.slice(1)") != null);

    var rn = try e2eTarget(std.testing.allocator, "function* g(o){ const [x, ...[y, z]] = o; yield y+z; }", .es5);
    defer rn.deinit();
    // 중첩 배열 패턴도 `__read` 로 배열을 만든 뒤 푼다 (#4791).
    try std.testing.expect(std.mem.indexOf(u8, rn.output, "_b=__read(_a.slice(1),2),y=_b[0],z=_b[1]") != null);
}

// #4791: 상태 기계의 구조 분해 대입도 선언 경로처럼 `__read` 로 배열을 만든다 — 이터러블(Set 등)에
// 인덱스·slice 를 바로 쓰면 `_a.slice is not a function`.
test "ES5 상태 기계: 배열 구조분해 대입이 __read 를 거친다 (#4791)" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){ const [x, ...r] = yield 0; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=__read(_state.sent()),x=_a[0],r=_a.slice(1)") != null);

    var rn = try e2eTarget(std.testing.allocator, "function* g(){ const { l: [a] } = yield 0; }", .es5);
    defer rn.deinit();
    try std.testing.expect(std.mem.indexOf(u8, rn.output, "_b=__read(_a.l,1),a=_b[0]") != null);
}

// #4791: 끌어올린 변수 목록에 배열 구멍(`.elision`)이 빈 이름으로 들어가 `var a,,b` 가 됐다.
test "ES5 상태 기계: 배열 구멍은 끌어올린 변수 목록에 안 들어간다 (#4791)" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){ const [a, , b] = yield 0; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",,") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a,b;") != null);
}

// #4791: 선언의 rest 가 패턴이면 임시 변수로 받아 푼다 — 그대로 두면 es5 에 `[y,z]=` 가 남는다.
test "ES5: 배열 선언 rest 안 중첩 패턴을 푼다 (#4791)" {
    var r = try e2eTarget(std.testing.allocator, "var [x,...[y,z]]=arr;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a=__read(arr),x=_a[0],_b=_a.slice(1),y=_b[0],z=_b[1];", r.output);

    var ro = try e2eTarget(std.testing.allocator, "var [...{length}]=arr;", .es5);
    defer ro.deinit();
    try std.testing.expect(std.mem.indexOf(u8, ro.output, "_b=_a.slice(0),length=_b.length") != null);
}

test "ES5: for-of 풀이의 step 변수는 모듈 전체에서 고유한 이름이다 (#4746)" {
    // 루프 변수 선언(`x = _step.value`)은 본문 안이라 본문이 `_loop` 로 추출되면 함수 경계 너머
    // 참조가 된다. 카운터 temp 를 쓰면 추출된 generator 가 자기 상태 기계 temp 로 같은 이름을
    // 선언해 가려 `undefined` 를 읽었다.
    var r = try e2eTarget(std.testing.allocator, "for (const x of a) for (const y of b) f(x, y);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=_step.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var y=_step2.value;") != null);
}

test "ES5 상태 기계: yield 없는 라벨 for-of 는 라벨을 안쪽 for 에 붙인 native 루프로 남는다 (#4746)" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){ outer: for (const x of a) { for (const y of b) { if (y) continue outer; } } yield 1; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "outer:for(var ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "continue outer;") != null);
}

test "for-of 풀이: 본문이 헤더 이름을 다시 선언하면 본문을 합치지 않고 한 겹 감싼다 (#4746)" {
    // 헤더와 본문은 스코프가 다르다. let/const 가 native 로 남는 조합에서 합치면 같은 블록에
    // `let x` 가 두 번 선언돼 SyntaxError 다(es5 는 var 로 내려 가려진다).
    var u = helpers.TransformOptions.compat.fromESTarget(.esnext);
    u.for_of = true;
    var r = try e2eFull(std.testing.allocator, "for (const x of a) { let x = 1; f(x); }", .{ .unsupported = u }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{const x=_step.value;{let x=1;f(x);}}") != null);

    var r2 = try e2eFull(std.testing.allocator, "for (const x of a) { let y = 1; f(x, y); }", .{ .unsupported = u }, .{ .minify_whitespace = true }, ".ts");
    defer r2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "{const x=_step.value;let y=1;f(x,y);}") != null);
}

test "ES5 상태 기계: for-in 은 키 스냅샷 + 인덱스 for 풀이를 수집하고 _keys/_idx 는 모듈 고유 이름이다 (#4746)" {
    // 루프 변수 선언(`x = _keys[_idx]`)이 본문 안이라, 본문이 `_loop` 로 추출되면 함수 경계 너머
    // 참조가 된다 — 카운터 temp 면 중첩 함수 temp 에 가려진다(for-of step 과 같은 이유).
    var r = try e2eTarget(std.testing.allocator, "function* g(a,b){ for (const x in a) for (const y in b) yield x+y; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_keys=[];for(_b in _a)_keys.push(_b);_idx=0;") != null);
    // 초기값 없는 키 변수 `_b` 도 wrapper 에 선언돼야 한다 — strict 모드에서 ReferenceError.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function g(a,b){var _a,_keys,_b,_idx,") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=_keys[_idx];") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=_keys2[_idx2];") != null);
}

test "ES5 상태 기계: for-in 대상 식의 yield 는 선언 수집이 먼저 처리한다 (#4746)" {
    // 대상 객체를 `_obj` 에 먼저 담아야 키 수집 for-in 에 yield 가 남지 않는다(남으면 그 for-in 을
    // 다시 풀이하려다 끝나지 않는다).
    var r = try e2eTarget(std.testing.allocator, "function* g(){ for (const k in (yield 1)) yield k; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=_state.sent();_a=_c;_keys=[];for(_b in _a)") != null);
}

test "ES5 상태 기계: 라벨 for-in 의 continue 는 바깥 인덱스 증가로 간다 (#4746)" {
    var r = try e2eTarget(std.testing.allocator, "function* g(o){ L: for (const k in o) { for (const j in o) { if (j) continue L; yield j; } } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "if(!j$2)return[3,3];return[3,7];") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "case 6:case 7:_idx++;") != null);
}

test "ES2017: for-await 풀이는 임시 변수를 선언 때 초기화하고 닫기를 기다린다 (#4746)" {
    // 같은 함수에서 루프가 다시 실행되면 초기화 안 된 `_step`·`_errObj` 가 앞 실행 값을 들고
    // 있어, 새 iterator 를 닫거나 옛 에러를 다시 던졌다.
    var r = try e2eTarget(std.testing.allocator, "async function f(s){ for await (const v of s) g(v); }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_step=void 0,_b=void 0,_c=void 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const v=_step.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "await _b.call(_a)") != null);
}

test "ES2017 async generator: for-await 는 본문 전처리로 풀려 합성 await 도 yield __await 가 되고 라벨은 while 에 붙는다 (#4746)" {
    var r = try e2eTarget(std.testing.allocator, "async function* g(s){ L: for await (const v of s) { yield v; continue L; } }", .es2017);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "L:while(!(_step=yield __await(_a.next())).done)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield __await(_b.call(_a))") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "await ") == null);
}

test "ES5 상태 기계: 변환기가 만든 이름을 리네임해도 string_table 재할당 뒤 깨지지 않는다" {
    // `for (using x of …)` 는 헤더를 `const _using` 으로 바꾸고, 상태 기계가 그 이름을
    // `_using$N` 으로 리네임한다. `_using` 은 원문이 아니라 `string_table` 에 있어서, 이름 조각을
    // 모은 뒤 using 재구성·for-of 풀이가 `addString` 으로 표를 옮기면 조각이 해제된 메모리를
    // 가리켰다 — Debug 빌드에서 `var …,\xaa\xaa…$1` 이 찍혀 SyntaxError.
    const src =
        \\const R = (n, log) => ({ [Symbol.dispose]() { log.push('d' + n); } });
        \\const AR = (n, log) => ({ async [Symbol.asyncDispose]() { log.push('ad' + n); } });
        \\const log = [];
        \\function* g() {
        \\  for (using x of [R(1, log), R(2, log)]) {
        \\    yield 1;
        \\    log.push('y');
        \\  }
        \\}
        \\for (const v of g()) log.push('v');
        \\console.log(log.join());
    ;
    var r = try e2eTarget(std.testing.allocator, src, .es5);
    defer r.deinit();
    for (r.output) |c| try std.testing.expect(c < 0x80);
    // `_using` 은 만들 때 함수 안에서 고유하게 지어져 상태 기계가 다시 바꾸지 않는다 (#4760).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_using = _step.value") != null or std.mem.indexOf(u8, r.output, "_using=_step.value") != null);
}

test "ES5 블록 스코핑: 함수 본문 var 와 같은 이름의 블록 let 은 새 이름을 받는다 (#4758, 심볼 표)" {
    // 테스트 하네스도 분석기 스코프를 넘겨 심볼 표 경로를 탄다 — 예전 이름 스택은 함수 본문
    // var 를 보지 못해 둘을 한 var 로 합쳤다.
    var r = try e2eTarget(std.testing.allocator, "function f() { var x = 0; { let x = 1; g(x); } return x; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x$") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=0;") != null);
}
