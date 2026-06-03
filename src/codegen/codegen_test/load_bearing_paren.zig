//! load-bearing 괄호 회귀 매트릭스 (#4042) — 문자열 생존(빠른 1차 방어).
//! 의미(throw vs undefined, SyntaxError 회피)까지의 런타임 검증은
//! tests/integration/tests/load-bearing-paren.test.ts 가 담당한다.
//!
//! 입력은 괄호가 *의미를 갖는*(= 빼면 다른 프로그램이 되거나 invalid 가 되는)
//! 최소 표현이다. precedence 전환 후 emitExpr 가 괄호를 재유도한다 — 다만 군더더기
//! 제거로 *형태*가 바뀔 수 있어(예: `(42)`→`42 .`, `(a().b)`→`(a())`) 의미를 보존하는
//! 한 핵심 부분문자열을 갱신한다. indexOf 로 핵심 보존 부분문자열만 본다.
//!
//! 인스턴스 6·7(#4042)도 precedence 전환에서 해소되어 아래에 포함:
//!   - 6: `({x:1} as T).c` (TS as strip 후 object literal statement-start 괄호 재유도)
//!   - 7: es2019 optional-chain lowering 의 이중괄호 정리는 es_downlevel `?.` 테이블이 커버.

const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;

fn expectParenSurvives(output: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, output, needle) == null) {
        std.debug.print("\nload-bearing 괄호 유실: \"{s}\" 가 출력에 없음:\n{s}\n", .{ needle, output });
        return error.LoadBearingParenLost;
    }
}

test "load-bearing: optional-chain 끊기 (a?.b).c" {
    var r = try e2e(std.testing.allocator, "(a?.b).c;");
    defer r.deinit();
    // 괄호 유실 시 `a?.b.c` 는 a 가 nullish 면 전체 short-circuit(undefined),
    // 보존 시 `.c` 에서 throw — 의미가 다르다.
    try expectParenSurvives(r.output, "(a?.b)");
}

test "load-bearing: numeric-then-dot (42).toString()" {
    var r = try e2e(std.testing.allocator, "(42).toString();");
    defer r.deinit();
    // 괄호 유실 시 `42.toString` 은 `42.` 가 float 로 오파싱되어 invalid. precedence 전환
    // 후에는 괄호 대신 공백(`42 .toString`, esbuild needSpaceBeforeDot)으로 끊는다 —
    // 둘 다 의미 보존. `42.` 로 붙는 invalid 출력만 회귀.
    try expectParenSurvives(r.output, "42 .toString");
}

test "load-bearing: 음수 단항이 ** 의 좌측 (-a)**b" {
    var r = try e2e(std.testing.allocator, "(-a) ** b;");
    defer r.deinit();
    // 괄호 유실 시 `-a**b` 는 SyntaxError(단항이 ** 좌측에 직접 못 옴).
    try expectParenSurvives(r.output, "(-a)");
}

test "load-bearing: sequence 가 call callee (0,o.f)()" {
    var r = try e2e(std.testing.allocator, "(0, o.f)();");
    defer r.deinit();
    // 괄호 유실 시 `0,o.f()` 는 sequence 의 마지막이 메서드 호출(this=o)이 되어
    // indirect call(this=undefined)과 의미가 다르다.
    try expectParenSurvives(r.output, "(0,o.f)");
}

test "load-bearing: ?? 와 || 혼용 (a||b)??c" {
    var r = try e2e(std.testing.allocator, "(a || b) ?? c;");
    defer r.deinit();
    // 괄호 유실 시 `a||b??c` 는 SyntaxError(ECMAScript 가 괄호 없는 혼용 금지).
    try expectParenSurvives(r.output, "(a||b)");
}

test "load-bearing: new callee 의 call-chain new (a()).b()" {
    var r = try e2e(std.testing.allocator, "new (a().b)();");
    defer r.deinit();
    // 괄호 유실 시 `new a().b()` 는 `(new a()).b()` 로 new 가 첫 call 에 결합돼 깨진다(#1507).
    // precedence 전환 후 forbid_call 전파로 inner call 만 감싼다(`new (a()).b()`, esbuild parity)
    // — `(a().b)` 전체 대신 `(a())` 로 동등 보존.
    try expectParenSurvives(r.output, "new (a()).b()");
}

test "load-bearing: assignment 가 binary 피연산자 (a=b)+c" {
    var r = try e2e(std.testing.allocator, "(a = b) + c;");
    defer r.deinit();
    try expectParenSurvives(r.output, "(a=b)");
}

test "load-bearing: arrow 본문 object literal () => ({})" {
    var r = try e2e(std.testing.allocator, "const f = () => ({ x: 1 });");
    defer r.deinit();
    // 괄호 유실 시 `() => {x:1}` 의 `{` 는 블록으로 파싱되어 객체를 반환하지 않는다.
    // arrow `=>` 직후의 `({` 를 함께 봐 다른 위치 괄호와의 우연 매칭을 배제한다.
    try expectParenSurvives(r.output, "=>({");
}

test "load-bearing: 인스턴스6 — TS as strip 후 object statement-start ({x:1} as T).c" {
    var r = try e2e(std.testing.allocator, "({x:1} as any).c;");
    defer r.deinit();
    // `as any` 타입 래퍼를 벗겨도 object literal 이 statement-start 라 괄호 재유도 필요.
    // 유실 시 `{x:1}.c` 의 `{` 가 블록으로 오파싱(이슈 #4042 인스턴스 6).
    try expectParenSurvives(r.output, "({x:1})");
}

test "load-bearing: optional-chain 끊기 타입래퍼 통과 (a?.b as T).c" {
    var r = try e2e(std.testing.allocator, "(a?.b as any).c;");
    defer r.deinit();
    // 타입 래퍼를 벗길 때 괄호까지 떼면 `a?.b.c` 로 체인이 이어져 의미가 바뀐다
    // (a nullish 시 throw vs undefined). precedence 가 체인 끊기 괄호를 재유도.
    try expectParenSurvives(r.output, "(a?.b)");
}
