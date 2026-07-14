//! new callee 체인 방출 회귀 (#4500) — 중첩 new 뒤의 member/subscript 체인과
//! tagged template 이 **바깥 new 의 callee** 로 흡수되는지(ECMAScript
//! `MemberExpression: new MemberExpression Arguments`) 문자열 수준으로 박제한다.
//!
//! 예전 방출(전부 silent miscompile):
//!   `new new Inner().C()` → `new new Inner()().C()`  (TypeError: not a constructor)
//!   `new tag`x`.B()`      → `new tag()`x`.B()`       (TypeError: not a function)
//!
//! 런타임 의미(node 실행)는 tests/integration/tests/new-callee-chain.test.ts 가 본다.
//! 여기서는 방출 문자열 + **idempotency**(방출물을 다시 파싱·방출해도 동일)를 가드한다 —
//! 파이프라인이 2-pass/번들에서 자기 출력을 다시 읽어도 의미가 안 바뀌어야 한다.

const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;

/// source 를 방출하고 기대 문자열과 비교한 뒤, **방출물을 다시 e2e** 해 같은 문자열이
/// 나오는지(idempotent) 확인한다.
fn expectEmitAndIdempotent(source: []const u8, expected: []const u8) !void {
    var r1 = try e2e(std.testing.allocator, source);
    defer r1.deinit();
    try std.testing.expectEqualStrings(expected, std.mem.trim(u8, r1.output, " \n\t"));

    var r2 = try e2e(std.testing.allocator, r1.output);
    defer r2.deinit();
    try std.testing.expectEqualStrings(expected, std.mem.trim(u8, r2.output, " \n\t"));
}

test "new callee: 중첩 new 뒤 member 체인 (#4500)" {
    // callee = `new Inner().C`, Arguments = `()`.
    try expectEmitAndIdempotent("const x = new new Inner().C();", "const x=new new Inner().C();");
    // subscript 도 동일.
    try expectEmitAndIdempotent("const z = new new Inner()[k]();", "const z=new new Inner()[k]();");
    // 인자 없는 바깥 new — codegen 은 argless new 에 `()` 를 붙이지만(의미 동일),
    // callee 는 `new A().b` 로 유지돼야 한다(`new new A()().b` 가 아니라).
    try expectEmitAndIdempotent("const y = new new A().b;", "const y=new new A().b();");
}

test "new callee: tagged template (#4500)" {
    // callee = `` tag`x`.B ``.
    try expectEmitAndIdempotent("const x = new tag`x`.B();", "const x=new tag`x`.B();");
    // callee 가 tagged template 자체인 argless new.
    try expectEmitAndIdempotent("const t = new tag`x`;", "const t=new tag`x`();");
}

test "new callee: 기존 정상 형태 회귀 가드 (#4500)" {
    // 인자 *있는* new 뒤의 template 은 callee 가 아니라 new 결과를 태그한다.
    try expectEmitAndIdempotent("const a = new f()`x`;", "const a=new f()`x`;");
    try expectEmitAndIdempotent("const b = new new a()();", "const b=new new a()();");
    try expectEmitAndIdempotent("const c = new a.b();", "const c=new a.b();");
    try expectEmitAndIdempotent("const d = new a();", "const d=new a();");
}

test "new callee: tag 안의 call 은 괄호 보존 (#4500)" {
    // new 의 callee 안에 있는 call 은 괄호로 감싸야 한다 — `` new f()`x`() `` 로 방출하면
    // `f` 가 *생성*되고 template 결과가 *호출*되는 다른 프로그램이 된다. member 의 object 처럼
    // tagged template 의 tag 에도 forbid_call 을 전파해야 나오는 괄호다.
    try expectEmitAndIdempotent("const x = new (f())`x`;", "const x=new (f())`x`();");
    try expectEmitAndIdempotent("const x = new (f())`x`.B();", "const x=new (f())`x`.B();");
    try expectEmitAndIdempotent("const x = new (f().g)`x`.B();", "const x=new (f()).g`x`.B();");
    // new 밖(일반 tagged template)에선 tag 의 call 에 괄호가 붙으면 안 된다(회귀 가드).
    try expectEmitAndIdempotent("const x = f()`x`;", "const x=f()`x`;");
    try expectEmitAndIdempotent("const x = f().g`x`;", "const x=f().g`x`;");
}

test "new callee: 명시 괄호 형태의 round-trip (#4500)" {
    // 소스가 `new (new A().b)()` 여도 방출은 `new new A().b()` — 이걸 zntc 가 다시 파싱했을 때
    // 같은 의미(callee = `new A().b`)로 읽혀야 파이프라인이 idempotent 하다.
    try expectEmitAndIdempotent("const x = new (new A().b)();", "const x=new new A().b();");
    try expectEmitAndIdempotent("const y = new (tag`x`.B)();", "const y=new tag`x`.B();");
}

test "new callee: TS non-null assertion(`!`) 은 callee 안에 머문다 (#4505)" {
    // `new a!.b()` 의 callee 는 `a!.b` 다(`new (a!.b)()`, tsc 동일). `!` 를 callee 루프에서
    // 흡수하지 않으면 `.b` 가 new 밖으로 새고 argless 로 끝난 new 에 codegen 이 `()` 를 붙여
    // `new a().b()` — **a 를 생성한 뒤 그 결과의 .b 를 호출**하는 다른 프로그램이 됐다.
    try expectEmitAndIdempotent("const x = new a!.b();", "const x=new a.b();");
    try expectEmitAndIdempotent("const y = new a!.b!.c();", "const y=new a.b.c();");
    try expectEmitAndIdempotent("const t = new a!`x`.B();", "const t=new a`x`.B();");
    // callee 가 `a!` 자체인 형태 — 예전엔 `new a()()` (생성 결과를 *호출*) 였다.
    try expectEmitAndIdempotent("const z = new a!();", "const z=new a();");
    // 인자 *있는* new 뒤의 `!` 는 callee 가 아니라 new 결과에 붙는다(`(new f())!.b`) — 회귀 가드.
    try expectEmitAndIdempotent("const w = new f()!.b;", "const w=new f().b;");
    // new 없는 `a!.b()` 는 원래 정상 (회귀 가드).
    try expectEmitAndIdempotent("const v = a!.b();", "const v=a.b();");
}

test "new callee: TS type arguments(`<T>`) 뒤의 체인도 callee (#4505)" {
    // `` new a<T>`x`.B() `` 의 callee 는 `` a<T>`x`.B `` 다(타입 소거 후 `` a`x`.B ``).
    // type-args speculation 이 callee 루프 *바깥*에 있어 `<T>` 뒤 체인이 new 밖으로 샜다.
    try expectEmitAndIdempotent("const x = new a<T>`x`.B();", "const x=new a`x`.B();");
    try expectEmitAndIdempotent("const y = new a<T>`x`();", "const y=new a`x`();");
    try expectEmitAndIdempotent("const z = new a<T>.b();", "const z=new a.b();");
    // 정상 형태 회귀 가드 — `<T>` 뒤가 바로 `(` 면 new 자신의 타입 인자다.
    try expectEmitAndIdempotent("const w = new a<T>();", "const w=new a();");
    try expectEmitAndIdempotent("const u = new a<T, U>(1);", "const u=new a(1);");
    // callee 체인 뒤의 `<U>` 도 (타입 인자로) 소거되고 인자 절만 남는다.
    try expectEmitAndIdempotent("const v = new a!.b<U>();", "const v=new a.b();");
    // `<` 가 type-args 가 아니면 비교 연산자로 남아야 한다 — speculation 실패 경로 가드.
    try expectEmitAndIdempotent("const c = new a<T>[k]();", "const c=new a()<T>[k]();");
}
