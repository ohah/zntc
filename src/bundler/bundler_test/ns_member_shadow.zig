//! Regression: `import * as M from 'mod'` + `M.x` 의 inline 결과가 importer scope 의
//! 같은 이름 binding 과 self-shadow 하던 무한 재귀.
//! 실제 사례: `react-native/.../LogBox/LogBoxNotificationContainer.js` 의
//! `const setSelectedLog = (i) => LogBoxData.setSelectedLog(i)`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("../test_helpers.zig");
const writeFile = helpers.writeFile;

fn bundleEntry(backing: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !helpers.Bundled {
    return helpers.bundleEntry(backing, tmp, entry_name, .{});
}

test "ns shadow: importer 의 nested binding 과 충돌하는 member access 는 ns 객체로 emit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "data.js",
        \\export function setSelectedLog(idx) { return "real:" + idx; }
    );
    try writeFile(tmp.dir, "container.js",
        \\import * as LogBoxData from './data.js';
        \\export function Container(props) {
        \\  const setSelectedLog = (i) => LogBoxData.setSelectedLog(i);
        \\  return setSelectedLog(props.idx);
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { Container } from './container.js';
        \\globalThis.__out = Container({ idx: 7 });
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // self-shadow regression: 같은 줄에 const setSelectedLog 정의 + setSelectedLog(i) 호출이
    // 함께 있으면 안 됨. inline 결과는 namespace 객체 access (something.setSelectedLog) 여야 함.
    try testing.expect(std.mem.indexOf(u8, code, "return setSelectedLog(i)") == null);
    try testing.expect(std.mem.indexOf(u8, code, ".setSelectedLog(i)") != null);
}

test "ns shadow: 충돌 없는 member 는 그대로 inline 유지 (불필요한 ns 객체 access 회피)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "data.js",
        \\export function uniqueName(x) { return x + 1; }
    );
    try writeFile(tmp.dir, "user.js",
        \\import * as M from './data.js';
        \\export function compute(v) { return M.uniqueName(v); }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { compute } from './user.js';
        \\globalThis.__out = compute(10);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // 충돌 없으면 inline 유지: M.uniqueName(v) → uniqueName(v)
    try testing.expect(std.mem.indexOf(u8, code, "return uniqueName(v)") != null);
    // namespace 객체 access 는 만들지 않음
    try testing.expect(std.mem.indexOf(u8, code, "M_ns.uniqueName") == null);
}

test "ns shadow: nested function 안의 binding 도 충돌로 인식" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "data.js",
        \\export function helper(x) { return "data:" + x; }
    );
    try writeFile(tmp.dir, "deep.js",
        \\import * as Mod from './data.js';
        \\export function outer() {
        \\  function inner() {
        \\    const helper = (x) => Mod.helper(x);
        \\    return helper(1);
        \\  }
        \\  return inner();
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { outer } from './deep.js';
        \\globalThis.__out = outer();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // inner 안의 const helper 는 nested binding → Mod.helper 는 inline 되면 안 됨
    try testing.expect(std.mem.indexOf(u8, code, "(x) => helper(x)") == null);
    try testing.expect(std.mem.indexOf(u8, code, ".helper(x)") != null);
}

test "ZZ-DIAG materialized ns + missing member access" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js", "export const a = 1;\nexport const b = 2;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.keys = Object.keys(ns);
        \\globalThis.v = ns.a;
        \\globalThis.miss = typeof ns.zzz;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();
    std.debug.print("\n===DIAG-OUTPUT-START===\n{s}\n===DIAG-OUTPUT-END===\n", .{code});
    std.debug.print("has (void 0): {}\n", .{std.mem.indexOf(u8, code, "(void 0)") != null});
    std.debug.print("has get a(): {}\n", .{std.mem.indexOf(u8, code, "get a()") != null});
}

// 한 namespace 의 일부 export 만 충돌하면 그것만 fallback, 나머지는 inline 유지.
// 구분 가능한 이름 (`shadowed` vs `safe_*`) 으로 두 path 가 모두 활성화되는지 검증.
test "ns shadow: 부분 충돌 — shadowed member 는 fallback, 나머지는 inline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "data.js",
        \\export function shadowed(x) { return "shadow:" + x; }
        \\export function safeOne(x) { return "one:" + x; }
        \\export function safeTwo(x) { return "two:" + x; }
    );
    try writeFile(tmp.dir, "user.js",
        \\import * as M from './data.js';
        \\export function go() {
        \\  const shadowed = (i) => M.shadowed(i);
        \\  return shadowed(1) + M.safeOne(2) + M.safeTwo(3);
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { go } from './user.js';
        \\globalThis.__out = go();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // shadowed: 충돌 → ns 객체 access
    try testing.expect(std.mem.indexOf(u8, code, "(i) => shadowed(i)") == null);
    try testing.expect(std.mem.indexOf(u8, code, ".shadowed(i)") != null);
    // safeOne / safeTwo: 비충돌 → inline 유지 (M_ns.safeOne 형태로 가지 않음)
    try testing.expect(std.mem.indexOf(u8, code, "safeOne(2)") != null);
    try testing.expect(std.mem.indexOf(u8, code, "safeTwo(3)") != null);
    try testing.expect(std.mem.indexOf(u8, code, ".safeOne(2)") == null);
    try testing.expect(std.mem.indexOf(u8, code, ".safeTwo(3)") == null);
}

// nested binding 외에도 함수 매개변수 / catch 매개변수 같은 다른 binding kind 도
// `nested_name_sets` 에 포함되어야 충돌이 잡힘.
test "ns shadow: 함수 매개변수 binding 도 충돌로 인식" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "data.js",
        \\export function clear(x) { return "data:" + x; }
    );
    try writeFile(tmp.dir, "user.js",
        \\import * as Data from './data.js';
        \\export function wrap(clear) {
        \\  return clear() + Data.clear(0);
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { wrap } from './user.js';
        \\globalThis.__out = wrap(() => "param");
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // wrap 의 매개변수 clear 와 충돌 → Data.clear(0) 는 ns 객체 access 로 emit
    try testing.expect(std.mem.indexOf(u8, code, ".clear(0)") != null);
    // 매개변수 호출 clear() 는 그대로
    try testing.expect(std.mem.indexOf(u8, code, "clear()") != null);
}

// 여러 namespace import 가 같은 local binding 과 충돌하면 둘 다 fallback 처리.
// 한 importer 모듈 안에서 namespace 별 독립적으로 shadow detection 이 작동하는지 검증.
test "ns shadow: 여러 namespace import 가 같은 이름과 충돌해도 각각 처리" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js",
        \\export function foo(x) { return "a:" + x; }
    );
    try writeFile(tmp.dir, "b.js",
        \\export function foo(x) { return "b:" + x; }
    );
    try writeFile(tmp.dir, "user.js",
        \\import * as A from './a.js';
        \\import * as B from './b.js';
        \\export function go() {
        \\  const foo = (i) => A.foo(i) + B.foo(i);
        \\  return foo(1);
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { go } from './user.js';
        \\globalThis.__out = go();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // 두 namespace 모두 ns 객체로 emit — `(i) => foo(i)` 자기 호출 패턴이 있으면 안 됨
    try testing.expect(std.mem.indexOf(u8, code, "(i) => foo(i)") == null);
    // 두 access 모두 .foo(i) 형태 — 최소 2번 등장해야 함
    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, code, search_start, ".foo(i)")) |idx| {
        count += 1;
        search_start = idx + 1;
    }
    try testing.expect(count >= 2);
}

// ============================================================
// 미존재 멤버 접근 → `void 0` (ESM: undefined). member-rewrite 된 namespace 는
// ns 객체를 materialize 하지 않으므로, rewrite map 에 없는 멤버를 literal `ns.x` 로
// emit 하면 선언된 적 없는 ns 식별자 참조 → ReferenceError 였다. esbuild 처럼
// `void 0` 으로 재작성. (#3982 ambiguous 멤버와 동형 출력.)
// ============================================================

test "ns missing member: member-rewrite 된 ns 의 미존재 export 접근은 void 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js", "export const marker = 1;\nexport const other = 2;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.a = ns.marker;
        \\globalThis.b = typeof ns.nope;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // 미존재 `nope` 는 void 0 으로 재작성 — dangling `.nope` member access 가 남으면 안 됨.
    try testing.expect(std.mem.indexOf(u8, code, "void 0") != null);
    try testing.expect(std.mem.indexOf(u8, code, ".nope") == null);
    // 존재하는 marker 는 정상 rewrite(over-correction 아님) — bare 참조로 살아있어야 함.
    try testing.expect(std.mem.indexOf(u8, code, "marker = 1") != null);
}

// `export * as regexes` 만 있고 plain export* 가 없으면 top-level `string` 은 미존재.
// 그 접근도 dangling 이 아니라 void 0 이어야 한다(#4011 leak-direction 디버깅에서 노출된
// 별개 ReferenceError 의 fix).
test "ns missing member: export * as ns 만 있는 모듈의 미존재 top-level 접근은 void 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.js", "export const string = 1;");
    try writeFile(tmp.dir, "core.js", "export * as regexes from './regexes.js';\nexport const marker = 1;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './core.js';
        \\globalThis.a = ns.marker;
        \\globalThis.b = typeof ns.absentTop;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    try testing.expect(std.mem.indexOf(u8, code, "void 0") != null);
    try testing.expect(std.mem.indexOf(u8, code, ".absentTop") == null);
    // 실제 named export `regexes` 는 보존(미존재 처리에 휩쓸리면 안 됨).
    try testing.expect(std.mem.indexOf(u8, code, "regexes") != null);
}

// 미존재 멤버가 call/member 의 피연산자일 때 `(void 0)` paren 이 필수.
// bare `void 0` 은 `ns.x()` → `void 0()`(=`void(0())`), `ns.x.y` → `void 0.y`(SyntaxError)
// 로 잘못 파싱된다. paren 으로 모든 컨텍스트에서 undefined 의미 보존.
test "ns missing member: call/member 컨텍스트는 (void 0) paren 으로 감싼다" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js", "export const marker = 1;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.a = ns.marker;
        \\globalThis.b = ns.nope && ns.nope.foo;
        \\globalThis.c = (typeof ns.fn === 'function') ? ns.fn() : 'no-fn';
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // paren-wrapped void 0 만 존재 — `void 0.foo` / `void 0(` 같은 bare 형태가 있으면 SyntaxError.
    try testing.expect(std.mem.indexOf(u8, code, "(void 0)") != null);
    try testing.expect(std.mem.indexOf(u8, code, "void 0.") == null);
    try testing.expect(std.mem.indexOf(u8, code, "void 0(") == null);
}

// lvalue(assignment/update) 타겟인 미존재 멤버는 `(void 0)` 으로 바꾸면 안 된다 —
// `(void 0) = 1` / `(void 0)++` 는 SyntaxError 라 번들 전체가 깨진다. 재작성을 건너뛰고
// 기존 fall-through(런타임 throw, namespace 멤버 대입은 어차피 ESM 에러)를 유지한다.
test "ns missing member: lvalue(assignment/update) 타겟은 (void 0) 으로 바꾸지 않음" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js", "export const marker = 1;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.a = ns.marker;
        \\ns.nope = 5;
        \\ns.cnt++;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // `(void 0) =` / `(void 0)++` 같은 invalid assignment target 이 생기면 안 된다.
    try testing.expect(std.mem.indexOf(u8, code, "(void 0) =") == null);
    try testing.expect(std.mem.indexOf(u8, code, "(void 0)=") == null);
    try testing.expect(std.mem.indexOf(u8, code, "(void 0)++") == null);
    // rvalue read(ns.marker)는 정상 rewrite.
    try testing.expect(std.mem.indexOf(u8, code, "marker = 1") != null);
}

// materialize 된 namespace(값으로 사용 → 실제 객체 존재)는 미존재 멤버를 void 0 으로
// 바꾸지 않고 실제 객체 access(`var.x`→undefined)로 둔다 — 객체가 선언돼 있어 안전하고,
// CJS 동적 멤버를 잘못 가리지 않기 위한 gate. over-correction 가드.
test "ns missing member: 값으로 쓰여 materialize 된 ns 는 void 0 으로 강제하지 않음" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js", "export const a = 1;\nexport const b = 2;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.keys = Object.keys(ns);
        \\globalThis.v = ns.a;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // ns 가 값으로 쓰여 인라인 객체가 materialize 되어야 한다(getter 객체).
    try testing.expect(std.mem.indexOf(u8, code, "get a()") != null);
}

// `export * from './inner'` chain 을 통한 export 도 shadowing 으로 잡혀야 함.
// 회귀 가드 (simplify 단계에서 발견): 이전 구현은 cache-miss path 에서
// `export * from` 을 skip 해 false negative 였음. 지금은 `cached_exports` (DFS 결과)
// 단일 진실로 사용하므로 chain 을 따라간 export 도 정확히 잡힘.
test "ns shadow: export * 체인 통한 export 도 shadowing 으로 인식" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "inner.js",
        \\export function chained(x) { return "inner:" + x; }
    );
    try writeFile(tmp.dir, "barrel.js",
        \\export * from './inner.js';
    );
    try writeFile(tmp.dir, "user.js",
        \\import * as M from './barrel.js';
        \\export function go() {
        \\  const chained = (i) => M.chained(i);
        \\  return chained(1);
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { go } from './user.js';
        \\globalThis.__out = go();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // chained 이 self-reference 로 가면 안 됨
    try testing.expect(std.mem.indexOf(u8, code, "(i) => chained(i)") == null);
    try testing.expect(std.mem.indexOf(u8, code, ".chained(i)") != null);
}
