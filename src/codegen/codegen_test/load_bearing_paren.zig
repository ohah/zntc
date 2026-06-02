//! load-bearing 괄호 회귀 매트릭스 (#4042) — 문자열 생존(빠른 1차 방어).
//! 의미(throw vs undefined, SyntaxError 회피)까지의 런타임 검증은
//! tests/integration/tests/load-bearing-paren.test.ts 가 담당한다.
//!
//! 입력은 괄호가 *의미를 갖는*(= 빼면 다른 프로그램이 되거나 invalid 가 되는)
//! 최소 표현이다. 현재(precedence 전환 전)는 parenthesized_expression 노드로
//! 보존하고, 전환(PR4) 후에는 emitExpr 가 precedence 로 재유도한다 — 어느 쪽이든
//! 괄호가 살아있어야 한다. indexOf 로 핵심 괄호 부분문자열 생존만 보므로
//! minify/공백 정책 변화에 영향받지 않고 PR3·PR4 양쪽에서 통과한다.
//!
//! TODO(PR4): 아래 두 케이스는 현재 codegen 갭(이슈 #4042 인스턴스 6·7)이라
//! precedence 전환에서 비로소 해소된다 — 그때 매트릭스에 추가한다.
//!   - `({x:1} as T).c` (TS as strip 후 statement-start `{` 유실)
//!   - es2019 optional-chain lowering 의 이중괄호 정리

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
    // 괄호 유실 시 `42.toString` 은 `42.` 가 float 로 오파싱되어 invalid.
    try expectParenSurvives(r.output, "(42)");
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

test "load-bearing: new callee 의 call-chain new (a().b)()" {
    var r = try e2e(std.testing.allocator, "new (a().b)();");
    defer r.deinit();
    // 괄호 유실 시 `new a().b()` 는 `(new a()).b()` 로 결합이 깨진다(#1507).
    try expectParenSurvives(r.output, "(a().b)");
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
