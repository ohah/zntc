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
const e2eWithOptions = helpers.e2eWithOptions;

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

test "load-bearing: 깊은 optional chain 은 spurious 끊김 괄호 없음 — depth cap 회귀 (#4042 dedup follow-up)" {
    // 65+ 깊이 optional chain(break 컨텍스트 아님)이 codegen 의 옛 depth-64 cap 에선
    // spine-walk 가 64 에서 false 를 반환 → has_non_optional_chain_parent 오설정 → 체인
    // *중간*에 spurious 끊김 괄호(`var x=(a?.b...c64).c...`)가 생겼다. 이는 nullish 단락
    // 지점을 바꿔 의미가 달라지는 silent miscompile. spineHasOptionalChain 단일화 시 cap 을
    // 100_000 으로 통일해 해소 — 깊이와 무관하게 끊김 없는 chain 은 괄호가 0 개여야 한다.
    // (잘못된 입력 주의: `(deep).d` 같은 명시 break 는 cap 과 무관하게 break 괄호 1개라
    //  회귀를 못 잡는다. break 없는 declarator-init chain 이어야 cap 버그가 드러난다.)
    const src = "var x = a?.b" ++ ".c" ** 70 ++ ";"; // depth 72, break 없음 → 괄호 0
    var r = try e2e(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, r.output, "("));
}

test "load-bearing: new callee 가 optional chain new (a?.b)()" {
    var r = try e2e(std.testing.allocator, "new (a?.b)();");
    defer r.deinit();
    // 괄호 유실 시 `new a?.b()` 는 SyntaxError(new 의 첫 `()` 가 optional chain 안으로
    // 들어갈 수 없음). new 타겟에 has_non_optional_chain_parent set 으로 체인 끊기.
    try expectParenSurvives(r.output, "(a?.b)");
}

test "load-bearing: 정수-점 numeric separator 100_000 .toString()" {
    var r = try e2e(std.testing.allocator, "(100_000).toString();");
    defer r.deinit();
    // `100_000.toString` 은 `100_000.` 가 float 로 오파싱되어 invalid → 공백 보존
    // (needSpaceBeforeDot, all-digit 만 보면 구분자 `_` 가 누락되던 회귀).
    try expectParenSurvives(r.output, "100_000 .toString");
}

test "load-bearing: for-init top-level in 은 for-in 헤더 오파싱 방지 for((a in b);;)" {
    var r = try e2e(std.testing.allocator, "for ((a in b);;) {}");
    defer r.deinit();
    // 괄호 유실 시 `for (a in b;;)` 는 for-in 헤더로 오파싱 → SyntaxError. forbid_in 시드.
    try expectParenSurvives(r.output, "(a in b)");
}

test "load-bearing: assignment shorthand default sequence ({x=(a,b)}=o)" {
    var r = try e2e(std.testing.allocator, "({x = (a, b)} = obj);");
    defer r.deinit();
    // 괄호 유실 시 `x=a,b` 는 default 가 `a` 로 바뀌고 `b` 가 별도 평가 → silent miscompile.
    try expectParenSurvives(r.output, "(a,b)");
}

test "load-bearing: 주석이 statement-start object 마크 무력화 (/*c*/{a:1}).b" {
    var r = try e2eWithOptions(std.testing.allocator, "(/*c*/{a:1}).b;", .{});
    defer r.deinit();
    // 주석이 buf 위치를 밀어 stmt_start 마크와 어긋나면 `{a:1}.b` 의 `{` 가 block 으로
    // 오파싱(legal 주석은 minify 에서도 생존 → 프로덕션 깨짐). save/restore 로 재앵커.
    try expectParenSurvives(r.output, "({ a: 1 })");
}

test "load-bearing: 주석이 arrow body object 마크 무력화 ()=>(/*c*/{a:1})" {
    var r = try e2eWithOptions(std.testing.allocator, "var f = () => (/*c*/{a:1});", .{});
    defer r.deinit();
    // 유실 시 `() => {a:1}` 의 `{` 가 block body → 객체 미반환(silent runtime miscompile).
    try expectParenSurvives(r.output, "({ a: 1 })");
}

test "load-bearing: for-init sequence 의 in 누수 for((a in b),c;;)" {
    var r = try e2e(std.testing.allocator, "for ((a in b), c;;) {}");
    defer r.deinit();
    // 유실 시 `for (a in b,c;;)` 는 for-in 헤더 오파싱 → SyntaxError. forbid_in 시드된
    // sequence 는 통째로 감싼다(emitList 가 원소 flag clear 하므로 sequence 레벨 처리).
    try expectParenSurvives(r.output, "(a in b,c)");
}

// ============================================================
// #4482 — minify 가 노드 태그를 바꾼 뒤의 load-bearing 괄호 / 토큰 병합
// ============================================================
//
// 위 매트릭스는 *소스 그대로의* 노드 태그를 전제한다. minify 는 그 태그를 바꾼다:
//   `-a` (a=2 상수)  → numeric_literal("-2")     — `.unary_expression` 아님
//   `true`           → `!0` (boolean_literal)     — 출력만 단항으로 시작
//   `undefined`      → `void 0` (identifier)      — 출력만 단항으로 시작
// 그래서 `exprNeedsParens` 의 `.unary_expression` case 를 빠져나가 괄호가 유실됐다.
// (상수 폴딩이 만드는 음수 numeric_literal 케이스는 AST 미니파이어가 transpile 레이어에서
//  돌아 codegen 하네스로는 재현이 안 된다 → transpile.zig 의 #4482 테스트가 커버.)
// 또 단항 `-`/`+` 피연산자 슬롯엔 토큰 병합 방지 공백 가드가 없어 `-(-t)` → `--t`
// (t 를 감소시키는 silent miscompile) 가 나왔다.

fn e2eMinifySyntax(allocator: std.mem.Allocator, source: []const u8) !helpers.TestResult {
    return e2eWithOptions(allocator, source, .{ .minify_whitespace = true, .minify_syntax = true });
}

test "#4482 minify: !0/!1 peephole 도 ** 좌측이면 괄호" {
    var r = try e2eMinifySyntax(std.testing.allocator, "g(true ** 2);");
    defer r.deinit();
    try expectParenSurvives(r.output, "(!0)**2");
}

test "#4482 minify: void 0 peephole 도 ** 좌측이면 괄호" {
    var r = try e2eMinifySyntax(std.testing.allocator, "g(undefined ** 2);");
    defer r.deinit();
    try expectParenSurvives(r.output, "(void 0)**2");
}

test "#4482 minify: !0 이 member object 면 괄호" {
    var r = try e2eMinifySyntax(std.testing.allocator, "g(true.toString());");
    defer r.deinit();
    // 유실 시 `!0.toString()` → SyntaxError.
    try expectParenSurvives(r.output, "(!0).toString");
}

test "#4482: 단항 - 뒤 prefix -- 는 공백으로 끊는다 (minify 무관)" {
    var r = try e2e(std.testing.allocator, "let t = 5; g(-(--t));");
    defer r.deinit();
    // 유실 시 `-(--t)` → `---t` = `--` + `-t` → SyntaxError. d3-ease elastic 이 이 패턴.
    try expectParenSurvives(r.output, "- --t");
}

test "#4482: 단항 - 뒤 단항 - 도 공백으로 끊는다" {
    var r = try e2e(std.testing.allocator, "g(-(-t));");
    defer r.deinit();
    // 유실 시 `--t` — **파싱되는** prefix 감소 연산 → t 를 바꾸는 silent miscompile.
    try expectParenSurvives(r.output, "- -t");
}

test "#4482: 단항 + 뒤 prefix ++ 도 공백" {
    var r = try e2e(std.testing.allocator, "let t = 5; g(+(++t));");
    defer r.deinit();
    try expectParenSurvives(r.output, "+ ++t");
}

test "#4482: `<` 뒤 `!--x` 는 HTML 주석(<!--) 오파싱 방지 공백" {
    var r = try e2e(std.testing.allocator, "let b = 1; g(a < !--b);");
    defer r.deinit();
    // 유실 시 `a<!--b` — classic script 에서 `<!--` 는 한 줄 주석 시작(Annex B) 이라
    // 그 뒤가 통째로 사라진다.
    try expectParenSurvives(r.output, "<! --b");
}

test "#4482: 과잉 공백/괄호 방지 — 부호가 다르면 그대로 붙인다" {
    var r = try e2e(std.testing.allocator, "g(-(+t)); g(+(-t)); g(1 - -2); g(2 ** 3); g(a ** -b);");
    defer r.deinit();
    try expectParenSurvives(r.output, "-+t");
    try expectParenSurvives(r.output, "+-t");
    try expectParenSurvives(r.output, "2**3");
    try expectParenSurvives(r.output, "a**-b");
}

// ============================================================
// #4482 계약 — `**` 좌변 괄호: level 을 올리는 쪽과 괄호를 치는 쪽의 동기화
// ============================================================
//
// `binaryChildLevels` 는 "괄호 필요" 를 자식 level 을 `.call` 로 올리는 것으로 표현하고,
// 실제 `(` 는 다른 쪽(`exprNeedsParens` / identifier self-wrap)이 친다. 두 목록이 어긋나면
// **level 이 조용히 버려진다** — 이게 #4482 의 정확한 발생 기전이었다.
//
// 구조적 강제는 `expressions.assertPowLeftWrapped` 가 한다: `**` 좌변이 prefix 단항으로
// 시작한다고 판정했는데 방출된 첫 바이트가 `(` 가 아니면 runtime_safety 빌드에서 즉시 panic.
// 아래 매트릭스는 그 사후조건이 **모든 형태를 실제로 지나가게** 하는 역할이다 (커버리지).

test "#4482 계약: `**` 좌변의 prefix-단항 형태 전수 — 전부 괄호" {
    // 소스 단항 (미니파이 없음 — 태그가 그대로 unary_expression)
    var r1 = try e2e(std.testing.allocator, "g((-a) ** b); g((!a) ** b); g((~a) ** b); g((void a) ** b); g((typeof a) ** b);");
    defer r1.deinit();
    try expectParenSurvives(r1.output, "(-a)**b");
    try expectParenSurvives(r1.output, "(!a)**b");
    try expectParenSurvives(r1.output, "(~a)**b");
    try expectParenSurvives(r1.output, "(void a)**b");
    try expectParenSurvives(r1.output, "(typeof a)**b");

    // minify peephole 로 단항이 되는 형태
    var r2 = try e2eMinifySyntax(std.testing.allocator, "g(true ** 2); g(false ** 2); g(undefined ** 2);");
    defer r2.deinit();
    try expectParenSurvives(r2.output, "(!0)**2");
    try expectParenSurvives(r2.output, "(!1)**2");
    try expectParenSurvives(r2.output, "(void 0)**2");
}

test "#4482 계약: 괄호가 필요없는 좌변은 그대로 (과잉 괄호 방지)" {
    // 양수 리터럴 / 식별자 / 호출 / member 는 단항으로 시작하지 않는다.
    var r = try e2e(std.testing.allocator, "g(a ** b); g(a.b ** c); g(f() ** c); g((a + b) ** c);");
    defer r.deinit();
    try expectParenSurvives(r.output, "a**b");
    try expectParenSurvives(r.output, "a.b**c");
    try expectParenSurvives(r.output, "f()**c");
    // 우선순위 때문에 필요한 괄호는 유지 (`a+b**c` 는 `a+(b**c)` 로 파싱됨).
    try expectParenSurvives(r.output, "(a+b)**c");
}

// ============================================================
// #4515 — `undefined` peephole 은 **unbound global** 참조에만 유효
// ============================================================
//
// 예전 가드는 `sym_id == null` 하나였는데, `sym_id` 는 linking_metadata(=번들 모드)가
// 있을 때만 채워진다. transpile 모드엔 metadata 가 없어 sym_id 가 **항상** null →
// "unbound global" 판정이 무조건 참 → 섀도잉된 지역 `undefined` 까지 `void 0` 이 됐다.
// 문법은 유효한데 **값만 틀리는** silent miscompile.

test "#4515 minify: 섀도잉된 지역 undefined 는 void 0 으로 치환하지 않는다" {
    var r = try e2eMinifySyntax(
        std.testing.allocator,
        "function f(x){ let undefined = x; g(undefined); }",
    );
    defer r.deinit();
    // 치환되면 `g(void 0)` — x 가 아니라 진짜 undefined 를 넘긴다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") == null);
    try expectParenSurvives(r.output, "g(undefined)");
}

test "#4515 minify: 섀도잉되면 shorthand 도 원본 그대로 (키까지 바뀌지 않는다)" {
    var r = try e2eMinifySyntax(
        std.testing.allocator,
        "function f(x){ let undefined = x; return { undefined }; }",
    );
    defer r.deinit();
    // 치환되면 `{undefined:void 0}` — 값이 x 가 아니게 된다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") == null);
    try expectParenSurvives(r.output, "{undefined}");
}

test "#4515 minify: 섀도잉이 없으면 peephole 유지 (size 회귀 0)" {
    var r = try e2eMinifySyntax(std.testing.allocator, "function f(g){ g(undefined); }");
    defer r.deinit();
    try expectParenSurvives(r.output, "g(void 0)");
}

test "#4515 minify: 섀도잉 없는 shorthand 는 longhand 로 펼쳐 치환 (키 보존)" {
    // shorthand 를 그대로 두면 노드 하나가 키이자 값이라 `{void 0}` — SyntaxError.
    var r = try e2eMinifySyntax(std.testing.allocator, "function f(){ return { undefined }; }");
    defer r.deinit();
    try expectParenSurvives(r.output, "{undefined:void 0}");
}

test "#4515 minify: import 바인딩 undefined 도 섀도잉으로 본다" {
    // import specifier 의 local 은 별도 binding_identifier 노드가 아니라 `import_specifier`
    // 의 오른쪽 자식이고 태그가 `identifier_reference` 다. binding_identifier 만 훑으면
    // 이 바인딩이 안 보여서 (1) 참조가 `void 0` 으로 바뀌고 (2) local 이름 자신이
    // `import { v as void 0 }` — **파싱 불가** 로 방출된다.
    var r = try e2eMinifySyntax(
        std.testing.allocator,
        "import { v as undefined } from \"./x.js\"; g(undefined);",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") == null);
}

test "#4515 minify: import default / namespace 로 바인딩된 undefined 도 섀도잉" {
    var r1 = try e2eMinifySyntax(
        std.testing.allocator,
        "import undefined from \"./x.js\"; g(undefined);",
    );
    defer r1.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "void 0") == null);

    var r2 = try e2eMinifySyntax(
        std.testing.allocator,
        "import * as undefined from \"./x.js\"; g(undefined);",
    );
    defer r2.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "void 0") == null);
}

test "#4515 minify: 섀도잉 없는 import 모듈에선 peephole 유지" {
    var r = try e2eMinifySyntax(
        std.testing.allocator,
        "import def from \"./x.js\"; g(def, undefined);",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}
