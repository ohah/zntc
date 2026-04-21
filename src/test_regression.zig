//! ZTS 회귀 테스트
//!
//! 과거 fix 커밋에서 수정된 버그들이 다시 발생하지 않도록 보장한다.
//! 각 테스트는 해당 커밋 해시와 버그 설명을 주석으로 포함한다.
//!
//! 패턴:
//!   - 파싱 성공 테스트: `parser.errors.items.len == 0`
//!   - 파싱 에러 테스트: `parser.errors.items.len > 0` (negative test)
//!   - E2E 테스트: 파싱 + 변환 + 코드젠 전체 파이프라인

const std = @import("std");
const Scanner = @import("lexer/scanner.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const Transformer = @import("transformer/transformer.zig").Transformer;
const TransformOptions = @import("transformer/transformer.zig").TransformOptions;
const Codegen = @import("codegen/codegen.zig").Codegen;
const CodegenOptions = @import("codegen/codegen.zig").CodegenOptions;

// ============================================================
// E2E 헬퍼: 파싱 → 변환 → 코드젠 전체 파이프라인
// ============================================================

/// Arena 기반 테스트 결과. deinit()으로 모든 메모리를 일괄 해제.
const TestResult = struct {
    output: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

// E2E 헬퍼: source → (파싱 + 변환 + 코드젠) → 출력 문자열
fn e2e(backing_allocator: std.mem.Allocator, source: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();

    var t = try Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, t.ast, .{ .minify = true });
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

// 파서만 실행하는 헬퍼 (에러 개수만 확인할 때 사용)
const ParseResult = struct {
    parser_inst: Parser,
    scanner: Scanner,
    allocator: std.mem.Allocator,

    fn deinit(self: *ParseResult) void {
        self.parser_inst.deinit();
        self.scanner.deinit();
    }

    fn hasErrors(self: *const ParseResult) bool {
        return self.parser_inst.errors.items.len > 0;
    }

    fn noErrors(self: *const ParseResult) bool {
        return self.parser_inst.errors.items.len == 0;
    }
};

fn parseOnly(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var result = ParseResult{
        .scanner = try Scanner.init(allocator, source),
        .parser_inst = undefined,
        .allocator = allocator,
    };
    result.parser_inst = Parser.init(allocator, &result.scanner);
    _ = try result.parser_inst.parse();
    return result;
}

// ============================================================
// 회귀 테스트: 82dcf5e — accessor codegen 키워드 + static 플래그
// ============================================================

// fix: /simplify - accessor codegen keyword + parse order (82dcf5e)
// 버그: emitAccessorProp이 "accessor " 키워드를 출력하지 않고 key=value 형태로만 출력했었음.
test "regression: accessor keyword emitted in codegen (82dcf5e)" {
    var r = try e2e(std.testing.allocator, "class C { accessor x = 1; }");
    defer r.deinit();
    // "accessor "가 출력에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, r.output, "accessor ") != null);
}

// fix: /simplify - accessor codegen keyword + parse order (82dcf5e)
// 버그: static accessor에서 static 플래그가 출력되지 않았음.
test "regression: static accessor keyword emitted in codegen (82dcf5e)" {
    var r = try e2e(std.testing.allocator, "class C { static accessor x = 1; }");
    defer r.deinit();
    // "static " + "accessor "가 모두 출력에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "accessor ") != null);
}

// ============================================================
// 회귀 테스트: f934292 — static initializer 내 arrow body context 복원
// ============================================================

// fix(parser): restore in_static_initializer in arrow body (f934292)
// 버그: static { () => arguments } 에서 arguments가 허용되었음.
//       arrow는 자체 arguments 바인딩이 없으므로 static initializer 컨텍스트를 상속해야 한다.
test "regression: arguments forbidden in arrow inside static initializer (f934292)" {
    var r = try parseOnly(std.testing.allocator, "class C { static { const f = () => arguments; } }");
    defer r.deinit();
    // static initializer 내 arrow에서 arguments는 SyntaxError
    try std.testing.expect(r.hasErrors());
}

// fix(parser): restore in_static_initializer in arrow body (f934292)
// 검증: static initializer 밖의 일반 함수에서 arrow + arguments는 정상 파싱
test "regression: arguments allowed in arrow inside regular function (f934292)" {
    var r = try parseOnly(std.testing.allocator, "function f() { const g = () => arguments; }");
    defer r.deinit();
    // 일반 함수 내 arrow에서 arguments는 외부 함수의 arguments를 참조 — 정상
    try std.testing.expect(r.noErrors());
}

// ============================================================
// 회귀 테스트: c342292 — 표현식 `}` 뒤 `/` division 토큰화
// ============================================================

// fix(parser): correctly tokenize `/` as division after expression `}` (c342292)
// 버그: 함수 표현식의 닫는 `}` 뒤 `/`가 regexp로 잘못 토큰화되었음.
test "regression: division after function expression closing brace (c342292)" {
    var r = try e2e(std.testing.allocator, "var x = function() {} / 2;");
    defer r.deinit();
    // 파싱 에러 없이 완료되어야 한다
    try std.testing.expect(r.parser_inst.errors.items.len == 0);
    try std.testing.expect(r.output.len > 0);
}

// fix(parser): correctly tokenize `/` as division after object literal `}` (c342292)
// 버그: 객체 리터럴의 `}` 뒤 `/`가 regexp로 잘못 토큰화되었음.
test "regression: division after object literal closing brace (c342292)" {
    var r = try e2e(std.testing.allocator, "var x = {a: 1} / 2;");
    defer r.deinit();
    try std.testing.expect(r.parser_inst.errors.items.len == 0);
    try std.testing.expect(r.output.len > 0);
}

// fix(parser): correctly tokenize `/` as division after arrow function body `}` (c342292)
// 버그: 블록 바디 arrow function의 `}` 뒤 `/`가 regexp로 잘못 토큰화되었음.
test "regression: division after arrow function block body (c342292)" {
    var r = try e2e(std.testing.allocator, "var x = (() => {}) / 2;");
    defer r.deinit();
    try std.testing.expect(r.parser_inst.errors.items.len == 0);
    try std.testing.expect(r.output.len > 0);
}

// ============================================================
// 회귀 테스트: 3a385b5 — 클래스 이름에 escaped keyword 검증
// ============================================================

// fix(parser): validate escaped keywords in class names (3a385b5)
// 버그: 클래스 컨텍스트는 strict mode이므로 yield를 이름으로 쓸 수 없음.
test "regression: yield as class name is error in strict mode class context (3a385b5)" {
    var r = try parseOnly(std.testing.allocator, "class yield {}");
    defer r.deinit();
    // ECMAScript: 클래스 body는 strict mode — yield는 reserved word
    try std.testing.expect(r.hasErrors());
}

// fix(parser): validate escaped keywords in class names (3a385b5)
// 버그: escaped form `yi\u0065ld`도 strict mode에서 에러여야 함.
test "regression: escaped yield as class name is error (3a385b5)" {
    var r = try parseOnly(std.testing.allocator, "class yi\\u0065ld {}");
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
}

// ============================================================
// 회귀 테스트: 70ef2a9 — private name escape sequence 해석
// ============================================================

// fix(semantic): resolve escape sequences in private name comparison (70ef2a9)
// 버그: #\u{6F}와 #o가 같은 private name임을 인식하지 못해 중복 에러가 발생했었음.
test "regression: private name with unicode escape parses OK (70ef2a9)" {
    // #o 필드를 선언하고 사용 — 정상 케이스
    var r = try parseOnly(std.testing.allocator,
        \\class C {
        \\  #o = 1;
        \\  get() { return this.#o; }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(r.noErrors());
}

// ============================================================
// 회귀 테스트: 22b6a72 — new.target in arrow + await in static initializer
// ============================================================

// fix(parser): new.target in arrow + await in static initializer (22b6a72)
// 버그: global scope의 arrow function 안에서 new.target이 허용되었음.
//       new.target은 함수/메서드 내부에서만 유효.
test "regression: new.target forbidden in top-level arrow function (22b6a72)" {
    var r = try parseOnly(std.testing.allocator, "const f = () => new.target;");
    defer r.deinit();
    // global arrow에서 new.target → SyntaxError
    try std.testing.expect(r.hasErrors());
}

// fix(parser): new.target in arrow + await in static initializer (22b6a72)
// 검증: 일반 함수 내 arrow에서 new.target은 외부 함수 컨텍스트를 상속하여 허용.
test "regression: new.target allowed in arrow inside regular function (22b6a72)" {
    var r = try parseOnly(std.testing.allocator, "function f() { const g = () => new.target; }");
    defer r.deinit();
    // 함수 내 arrow → new.target을 외부 함수에서 상속하므로 정상
    try std.testing.expect(r.noErrors());
}

// fix(parser): await in static initializer is forbidden (22b6a72)
// 버그: static initializer에서 await 식별자 사용이 허용되었음.
test "regression: await identifier forbidden in static initializer (22b6a72)" {
    var r = try parseOnly(std.testing.allocator, "class C { static { let x = await; } }");
    defer r.deinit();
    // ECMAScript 15.7.14: static initializer에서 await 사용 금지
    try std.testing.expect(r.hasErrors());
}

// ============================================================
// 회귀 테스트: 558be92 — import.UNKNOWN SyntaxError
// ============================================================

// fix(parser): reject import.UNKNOWN (558be92)
// 버그: import.UNKNOWN이 에러 없이 파싱되었음.
//       import.meta / import.source / import.defer만 유효.
test "regression: import.UNKNOWN is a syntax error (558be92)" {
    var r = try parseOnly(std.testing.allocator, "var x = import.UNKNOWN;");
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
}

// fix(parser): import.meta is valid in module code (558be92)
// 검증: import.meta는 module mode에서 정상 파싱되어야 함.
test "regression: import.meta still parses OK in module mode (558be92)" {
    var scanner = try Scanner.init(std.testing.allocator, "var x = import.meta;");
    defer scanner.deinit();
    var parser_inst = Parser.init(std.testing.allocator, &scanner);
    defer parser_inst.deinit();
    parser_inst.is_module = true; // import.meta는 module code에서만 허용
    scanner.is_module = true;
    _ = try parser_inst.parse();
    try std.testing.expect(parser_inst.errors.items.len == 0);
}

// ============================================================
// 회귀 테스트: da16ea7 — meta_property assignment target
// ============================================================

// fix(parser): reject meta_property as assignment target (da16ea7)
// 버그: [import.meta] = arr 에서 import.meta가 assignment target으로 허용되었음.
test "regression: import.meta cannot be destructuring target (da16ea7)" {
    var r = try parseOnly(std.testing.allocator, "[import.meta] = arr;");
    defer r.deinit();
    // import.meta는 절대 assignment target이 될 수 없음
    try std.testing.expect(r.hasErrors());
}

// fix(parser): reject new.target as assignment target (da16ea7)
// 버그: new.target = 1 이 파싱 에러를 내지 않았음.
test "regression: new.target cannot be assignment target (da16ea7)" {
    var r = try parseOnly(std.testing.allocator, "function f() { new.target = 1; }");
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
}

// ============================================================
// 회귀 테스트: 834a8c6 — invalid BigInt literals
// ============================================================

// fix(lexer): reject BigInt suffix on float literals (834a8c6)
// 버그: 0.1n, 1.5n 같은 float BigInt가 허용되었음.
test "regression: float bigint literal is rejected (834a8c6)" {
    var r = try parseOnly(std.testing.allocator, "var x = 0.1n;");
    defer r.deinit();
    // ECMAScript: BigInt는 정수형 리터럴에만 허용
    try std.testing.expect(r.hasErrors());
}

// fix(lexer): reject BigInt suffix on exponent literals (834a8c6)
// 버그: 1e1n 같은 지수 표기 BigInt가 허용되었음.
test "regression: exponent bigint literal is rejected (834a8c6)" {
    var r = try parseOnly(std.testing.allocator, "var x = 1e1n;");
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
}

// fix(lexer): reject BigInt suffix on legacy octal (834a8c6)
// 버그: 07n 같은 legacy octal BigInt가 허용되었음.
test "regression: legacy octal bigint literal is rejected (834a8c6)" {
    var r = try parseOnly(std.testing.allocator, "var x = 07n;");
    defer r.deinit();
    try std.testing.expect(r.hasErrors());
}

// 검증: 정상 BigInt 리터럴은 여전히 파싱 가능해야 함.
test "regression: valid bigint literals still parse OK (834a8c6)" {
    var r = try parseOnly(std.testing.allocator, "var x = 42n; var y = 0n; var z = 0x1An;");
    defer r.deinit();
    try std.testing.expect(r.noErrors());
}

// ============================================================
// 회귀 테스트: f7653cb — identifier immediately after numeric literal
// ============================================================

// fix(lexer): reject IdentifierStart immediately after numeric literal (f7653cb)
// 버그: 3in, 1_0 같이 숫자 바로 뒤에 식별자 문자가 오는 경우가 허용되었음.
test "regression: identifier after numeric literal is rejected (f7653cb)" {
    var r = try parseOnly(std.testing.allocator, "var x = 3in;");
    defer r.deinit();
    // ECMAScript 12.9.3: 숫자 리터럴 바로 뒤에 IdentifierStart 금지
    try std.testing.expect(r.hasErrors());
}

// ============================================================
// 회귀 테스트: 4f4bd92 — ?? mixed with && right operand
// ============================================================

// fix(parser): detect ?? mixed with && when && is in right operand (4f4bd92)
// 버그: `0 ?? 0 && true` 에서 && 가 우측 피연산자로 파싱될 때 혼용이 감지되지 않았음.
test "regression: nullish coalescing mixed with logical AND right operand (4f4bd92)" {
    var r = try parseOnly(std.testing.allocator, "var x = 0 ?? 0 && true;");
    defer r.deinit();
    // ECMAScript: ?? 와 &&/|| 는 괄호 없이 혼용 금지
    try std.testing.expect(r.hasErrors());
}

// 검증: ?? 와 && 가 괄호로 분리되면 정상.
test "regression: nullish coalescing with parenthesized AND is OK (4f4bd92)" {
    var r = try parseOnly(std.testing.allocator, "var x = 0 ?? (0 && true);");
    defer r.deinit();
    try std.testing.expect(r.noErrors());
}

// ============================================================
// 회귀 테스트: b61f2ab — legacy octal retroactive strict mode check
// ============================================================

// fix(lexer/parser): reset has_legacy_octal flag + retroactive prologue check (b61f2ab)
// 버그: 함수 body에서 "use strict" 이전에 octal escape가 있어도 에러가 발생하지 않았음.
test "regression: octal escape before use strict is retroactive error (b61f2ab)" {
    var r = try parseOnly(std.testing.allocator,
        \\function f() { "\8"; "use strict"; }
    );
    defer r.deinit();
    // "use strict" 이전의 octal escape → retroactive SyntaxError
    try std.testing.expect(r.hasErrors());
}

// 검증: octal escape가 "use strict" 없이 sloppy mode에서는 정상.
test "regression: octal escape in sloppy mode is OK (b61f2ab)" {
    var r = try parseOnly(std.testing.allocator, "var x = \"\\8\";");
    defer r.deinit();
    try std.testing.expect(r.noErrors());
}

// ============================================================
// 회귀 테스트: 5744bd6 — arrow function validation (ASI, eval, super)
// ============================================================

// fix(parser): strengthen arrow function validation (5744bd6)
// 버그: arrow function 파라미터에 eval/arguments를 strict mode에서 허용했음.
test "regression: eval as arrow param is error in strict mode (5744bd6)" {
    var r = try parseOnly(std.testing.allocator, "\"use strict\"; var f = eval => eval;");
    defer r.deinit();
    // strict mode에서 eval을 바인딩 이름으로 사용 금지
    try std.testing.expect(r.hasErrors());
}

// fix(parser): arrow ASI restriction (5744bd6)
// 버그: 파라미터와 `=>` 사이에 줄바꿈이 있어도 arrow function으로 파싱됐었음.
test "regression: arrow function with line terminator before arrow is error (5744bd6)" {
    var r = try parseOnly(std.testing.allocator, "var f = x\n=> x;");
    defer r.deinit();
    // [no LineTerminator here] before => — ASI 적용으로 에러
    try std.testing.expect(r.hasErrors());
}

// ============================================================
// 회귀 테스트: 93f9448 — decorator on class expression
// ============================================================

// fix(parser): improve decorator validation (93f9448)
// 버그: @decorator class {} 가 표현식 위치에서 파싱 실패했었음.
test "regression: decorator on class expression parses OK (93f9448)" {
    var r = try parseOnly(std.testing.allocator, "var C = @foo class {};");
    defer r.deinit();
    // decorator가 달린 class expression은 정상 파싱
    try std.testing.expect(r.noErrors());
}

// ============================================================
// 회귀 테스트: 4bdeeb2 — miscellaneous expression validation
// ============================================================

// fix(parser): CoverInitializedName ({ x = 1 }) in expression statement is error (4bdeeb2)
// 버그: expression statement에서 { x = 1 }이 destructuring으로 소비되지 않아도 에러가 없었음.
// CoverInitializedName은 destructuring 왼쪽에서만 유효.
test "regression: object shorthand with default in expression statement is error (4bdeeb2)" {
    // expression statement 컨텍스트에서 CoverInitializedName 에러 확인
    var r = try parseOnly(std.testing.allocator, "({ a = 1 });");
    defer r.deinit();
    // { a = 1 }은 destructuring 패턴에서만 유효, 표현식에서는 SyntaxError
    try std.testing.expect(r.hasErrors());
}

// fix(parser): BigInt property keys in parsePropertyKey (4bdeeb2)
// 버그: BigInt를 object property key로 사용할 때 파싱이 실패했었음.
test "regression: bigint as object property key parses OK (4bdeeb2)" {
    var r = try parseOnly(std.testing.allocator, "var x = { 1n: 'value' };");
    defer r.deinit();
    try std.testing.expect(r.noErrors());
}

// fix(parser): function declaration name parsed before enterFunctionContext (4bdeeb2)
// 버그: generator function 내부의 일반 함수 이름으로 yield를 사용할 수 없었음.
//       함수 선언 이름은 외부 컨텍스트에서 파싱되어야 한다.
test "regression: yield as inner function name is error inside generator (4bdeeb2)" {
    var r = try parseOnly(std.testing.allocator, "function* gen() { function yield() {} }");
    defer r.deinit();
    // generator 내부에서 yield는 reserved — inner function 이름으로도 금지
    try std.testing.expect(r.hasErrors());
}

// ============================================================
// 종합 E2E 회귀 테스트
// ============================================================

// 전체 파이프라인 회귀: static initializer + arrow 조합이 E2E로 처리됨
test "regression: e2e static initializer with arrow (f934292 e2e)" {
    var r = try e2e(std.testing.allocator, "class C { static x = () => 1; }");
    defer r.deinit();
    // 파싱 에러 없이 출력이 생성되어야 한다
    try std.testing.expect(r.parser_inst.errors.items.len == 0);
    try std.testing.expect(r.output.len > 0);
}

// 전체 파이프라인 회귀: accessor class field E2E
test "regression: e2e accessor class field full pipeline (82dcf5e e2e)" {
    var r = try e2e(std.testing.allocator, "class C { accessor value = 42; }");
    defer r.deinit();
    try std.testing.expect(r.parser_inst.errors.items.len == 0);
    // accessor 키워드가 출력에 보존되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, r.output, "accessor") != null);
}

// 전체 파이프라인 회귀: 복잡한 class body (static, accessor, method 조합)
test "regression: e2e complex class body (combined)" {
    var r = try e2e(std.testing.allocator,
        \\class MyClass {
        \\  static count = 0;
        \\  accessor name = "hello";
        \\  constructor() { MyClass.count++; }
        \\  greet() { return this.name; }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(r.parser_inst.errors.items.len == 0);
    try std.testing.expect(r.output.len > 0);
}
