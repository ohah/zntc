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
