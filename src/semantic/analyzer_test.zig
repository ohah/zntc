const std = @import("std");
const analyzer_mod = @import("analyzer.zig");
const SemanticAnalyzer = analyzer_mod.SemanticAnalyzer;
const Diagnostic = analyzer_mod.Diagnostic;
const symbol_mod = @import("symbol.zig");
const SymbolKind = symbol_mod.SymbolKind;
const Parser = @import("../parser/parser.zig").Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;

test "SemanticAnalyzer: var declaration creates symbol" {
    var scanner = try Scanner.init(std.testing.allocator, "var x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.symbols.items.len == 1);
    try std.testing.expectEqual(SymbolKind.variable_var, ana.symbols.items[0].kind);
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: let redeclaration is error" {
    var scanner = try Scanner.init(std.testing.allocator, "let x = 1; let x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: var redeclaration is allowed" {
    var scanner = try Scanner.init(std.testing.allocator, "var x = 1; var x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: function declaration creates symbol" {
    var scanner = try Scanner.init(std.testing.allocator, "function foo() {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.symbols.items.len >= 1);
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: scopes are created" {
    var scanner = try Scanner.init(std.testing.allocator, "{ let x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    // global + block = 최소 2개 스코프
    try std.testing.expect(ana.scopes.items.len >= 2);
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: let and var conflict is error" {
    var scanner = try Scanner.init(std.testing.allocator, "let x = 1; var x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: const redeclaration is error" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = 1; const x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

// ============================================================
// Private Name 검증 테스트
// ============================================================

test "SemanticAnalyzer: declared private name is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { #x = 1; foo() { this.#x; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: undeclared private name is error" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { foo() { this.#x; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private name outside class is error" {
    var scanner = try Scanner.init(std.testing.allocator, "this.#x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private method is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "class C { #foo() {} bar() { this.#foo(); } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: nested class private name" {
    // 내부 class에서 외부 class의 private name 접근은 불가
    var scanner = try Scanner.init(std.testing.allocator, "class Outer { #x; foo() { class Inner { bar() { this.#y; } } } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    // #y는 어디에도 선언 안 됨 → 에러
    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: inner class can access outer private name" {
    var scanner = try Scanner.init(std.testing.allocator, "class Outer { #x; foo() { class Inner { bar() { this.#x; } } } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    // #x는 Outer에 선언됨 → 에러 없음
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: duplicate private method is error" {
    // 같은 이름의 private method 두 번 선언 → 에러
    var scanner = try Scanner.init(std.testing.allocator, "class C { #m() {} #m() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: duplicate private field is error" {
    // 같은 이름의 private field 두 번 선언 → 에러
    var scanner = try Scanner.init(std.testing.allocator, "class C { #x; #x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private getter+setter pair is valid" {
    // getter와 setter 쌍은 중복이 아님
    var scanner = try Scanner.init(std.testing.allocator, "class C { get #x() { return 1; } set #x(v) {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: private method+getter duplicate is error" {
    // method와 getter는 쌍이 아님 → 에러
    var scanner = try Scanner.init(std.testing.allocator, "class C { #m() {} get #m() { return 1; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private name in object literal method is error" {
    // 객체 리터럴에서 private name 메서드는 SyntaxError
    // 이 테스트는 method_definition key 순회 + private_identifier 검출이 동작하는지 확인
    var scanner = try Scanner.init(std.testing.allocator, "var o = { #m() {} };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    // 파서 또는 semantic 중 하나 이상에서 에러가 발생해야 함
    var semantic_errors: usize = 0;
    if (parser.errors.items.len == 0) {
        var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
        defer ana.deinit();
        try ana.analyze();
        semantic_errors = ana.errors.items.len;
    }
    const total_errors = parser.errors.items.len + semantic_errors;
    try std.testing.expect(total_errors > 0);
}

test "SemanticAnalyzer: call expression args are visited" {
    // 함수 호출 인자 내부의 함수 표현식이 스코프를 생성하는지 확인
    var scanner = try Scanner.init(std.testing.allocator, "f(function() { let x = 1; });");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    // 에러 없이 분석 완료 (스코프: global + function)
    try std.testing.expect(ana.errors.items.len == 0);
    try std.testing.expect(ana.scopes.items.len >= 2);
}

test "SemanticAnalyzer: template literal expressions are visited" {
    // 템플릿 리터럴 내부 표현식이 순회되는지 확인
    var scanner = try Scanner.init(std.testing.allocator, "let x = `${function() { let y = 1; }()}`;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    // 에러 없이 분석 완료
    try std.testing.expect(ana.errors.items.len == 0);
}

// ============================================================
// Hoisting 테스트
// ============================================================

test "SemanticAnalyzer: var in nested block is same function scope" {
    // var x = 1; { var x = 2; }
    // var는 함수 스코프에서 호이스팅되므로 같은 스코프에 이미 있어도 재선언 허용
    var scanner = try Scanner.init(std.testing.allocator, "var x = 1; { var x = 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: let in nested block is separate scope" {
    // let x = 1; { let x = 2; }
    // 내부 블록의 let x는 별도 블록 스코프에 선언되므로 충돌 없음
    var scanner = try Scanner.init(std.testing.allocator, "let x = 1; { let x = 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: var hoisting in function" {
    // function f() { return x; var x = 1; }
    // var는 함수 최상단으로 호이스팅되므로 return x; 이후에 선언되어도 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "function f() { return x; var x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

// ============================================================
// Function 스코프 테스트
// ============================================================

test "SemanticAnalyzer: same let name in different functions is valid" {
    // function f() { let x = 1; } function g() { let x = 2; }
    // 서로 다른 함수 스코프이므로 충돌 없음
    var scanner = try Scanner.init(std.testing.allocator, "function f() { let x = 1; } function g() { let x = 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: parameter and let redeclaration is error" {
    // function f(x) { let x = 1; }
    // 파라미터 x와 let x는 같은 함수 스코프 — 충돌
    var scanner = try Scanner.init(std.testing.allocator, "function f(x) { let x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: parameter and var redeclaration is valid" {
    // function f(x) { var x = 1; }
    // 파라미터 x와 var x는 공존 가능 (ECMAScript 허용)
    var scanner = try Scanner.init(std.testing.allocator, "function f(x) { var x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

// ============================================================
// For loop 테스트
// ============================================================

test "SemanticAnalyzer: for loop with let is valid" {
    // for(let i=0; i<10; i++) { let j = i; }
    // for 문이 블록 스코프를 생성하고 let i는 그 스코프에 선언됨
    var scanner = try Scanner.init(std.testing.allocator, "for(let i=0; i<10; i++) { let j = i; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: same let name in separate for loops is valid" {
    // for(let i=0;;){} for(let i=0;;){}
    // 각 for 문이 별도 블록 스코프를 생성하므로 충돌 없음
    var scanner = try Scanner.init(std.testing.allocator, "for(let i=0; i<1; i++){} for(let i=0; i<2; i++){}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

// ============================================================
// Import 재선언 테스트
// ============================================================

test "SemanticAnalyzer: import binding redeclared with let is error" {
    // import { x } from 'a'; let x = 1;
    // import 바인딩은 모든 재선언과 충돌
    var scanner = try Scanner.init(std.testing.allocator, "import { x } from 'a'; let x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: import binding redeclared with var is error" {
    // import { x } from 'a'; var x = 1;
    // import 바인딩은 var 재선언과도 충돌
    var scanner = try Scanner.init(std.testing.allocator, "import { x } from 'a'; var x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

// ============================================================
// Catch 바인딩 테스트
// ============================================================

test "SemanticAnalyzer: catch binding shadowed by let is error" {
    // try {} catch(e) { let e = 1; }
    // catch 파라미터 e와 같은 catch body 블록의 let e는 충돌
    var scanner = try Scanner.init(std.testing.allocator, "try {} catch(e) { let e = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: catch binding shadowed by var is valid" {
    // try {} catch(e) { var e = 1; }
    // var는 catch 바깥으로 호이스팅되므로 catch 파라미터와 충돌하지 않음
    var scanner = try Scanner.init(std.testing.allocator, "try {} catch(e) { var e = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

// ============================================================
// Switch case 테스트
// ============================================================

test "SemanticAnalyzer: duplicate let in switch block is error" {
    // switch (x) { case 1: let y = 1; break; case 2: let y = 2; break; }
    // switch body는 하나의 블록 스코프 — 같은 이름의 let은 충돌
    var scanner = try Scanner.init(std.testing.allocator, "switch (x) { case 1: let y = 1; break; case 2: let y = 2; break; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: duplicate var in switch block is valid" {
    // switch (x) { case 1: var y = 1; break; case 2: var y = 2; break; }
    // var는 함수 스코프로 호이스팅되므로 switch block 내 중복 선언 허용
    var scanner = try Scanner.init(std.testing.allocator, "switch (x) { case 1: var y = 1; break; case 2: var y = 2; break; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

// ============================================================
// Generator / Async 테스트
// ============================================================

test "SemanticAnalyzer: let inside generator is valid" {
    // function* g() { let x = 1; }
    // generator 내부는 별도 함수 스코프 — let 선언 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "function* g() { let x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: let inside async function is valid" {
    // async function f() { let x = 1; }
    // async 함수 내부는 별도 함수 스코프 — let 선언 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "async function f() { let x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: generator duplicate params is error" {
    // function* g(a, a) {}
    // generator는 UniqueFormalParameters 적용 — 중복 파라미터 에러
    var scanner = try Scanner.init(std.testing.allocator, "function* g(a, a) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: async function duplicate params is error" {
    // async function f(a, a) {}
    // async function은 UniqueFormalParameters 적용 — 중복 파라미터 에러
    var scanner = try Scanner.init(std.testing.allocator, "async function f(a, a) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

// ============================================================
// Class 표현식 테스트
// ============================================================

test "SemanticAnalyzer: named class expression is valid" {
    // let C = class C { constructor() {} }
    // 클래스 표현식의 이름은 자체 스코프에만 등록 — 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "let C = class C { constructor() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: static and instance private field with same name is error" {
    // class C { #x = 1; static #x = 2; }
    // ECMAScript: static/instance 동시 선언 불가 — checker에서 검증
    var scanner = try Scanner.init(std.testing.allocator, "class C { #x = 1; static #x = 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

// ============================================================
// Diagnostic kind + 에러 메시지 검증
// ============================================================

test "SemanticAnalyzer: errors have kind=semantic" {
    var scanner = try Scanner.init(std.testing.allocator, "let x = 1; let x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
    try std.testing.expectEqual(Diagnostic.Kind.semantic, ana.errors.items[0].kind);
}

test "SemanticAnalyzer: redeclaration error message contains identifier name" {
    var scanner = try Scanner.init(std.testing.allocator, "let foo = 1; let foo = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, ana.errors.items[0].message, "foo") != null);
}

test "SemanticAnalyzer: duplicate export name is semantic error" {
    var scanner = try Scanner.init(std.testing.allocator, "export const a = 1; export const a = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.is_module = true;
    try ana.analyze();

    // 재선언 에러 또는 중복 export 에러가 있어야 함
    try std.testing.expect(ana.errors.items.len > 0);
    try std.testing.expectEqual(Diagnostic.Kind.semantic, ana.errors.items[0].kind);
}

test "SemanticAnalyzer: valid code has no semantic errors" {
    const cases = [_][]const u8{
        "let x = 1; let y = 2;",
        "function f() { let x = 1; } function g() { let x = 2; }",
        "{ let x = 1; } { let x = 2; }",
        "var x = 1; var x = 2;", // var은 재선언 허용
    };
    for (cases) |src| {
        var scanner = try Scanner.init(std.testing.allocator, src);
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();
        _ = try parser.parse();

        var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
        defer ana.deinit();
        try ana.analyze();

        try std.testing.expectEqual(@as(usize, 0), ana.errors.items.len);
    }
}

// ============================================================
// Reference Tracking 테스트
// ============================================================

/// 테스트 헬퍼: 소스 코드를 파싱+분석하여 특정 이름의 심볼 reference_count를 반환.
/// 같은 이름의 심볼이 여러 개이면 배열 순서대로(선언 순) 반환.
fn getRefCounts(source: []const u8, target_name: []const u8, out: *[8]u32) usize {
    var scanner = Scanner.init(std.testing.allocator, source) catch return 0;
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = parser.parse() catch return 0;

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze() catch return 0;

    var count: usize = 0;
    for (ana.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), target_name)) {
            if (count < 8) out[count] = sym.reference_count;
            count += 1;
        }
    }
    return count;
}

test "Reference: read reference increases count" {
    // const x = 1; f(x);  → x는 f(x)에서 1번 참조
    var counts: [8]u32 = undefined;
    const n = getRefCounts("const x = 1; f(x);", "x", &counts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 1), counts[0]);
}

test "Reference: write reference (assignment)" {
    // let x; x = 1;  → x는 1번 참조 (assignment LHS)
    var counts: [8]u32 = undefined;
    const n = getRefCounts("let x; x = 1;", "x", &counts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 1), counts[0]);
}

test "Reference: scope chain resolution" {
    // const x = 1; { f(x); }  → inner scope에서 outer x 참조
    var counts: [8]u32 = undefined;
    const n = getRefCounts("const x = 1; { f(x); }", "x", &counts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 1), counts[0]);
}

test "Reference: shadowing — inner shadows outer" {
    // const x = 1; { const x = 2; f(x); }  → inner x: 1 ref, outer x: 0 ref
    var counts: [8]u32 = undefined;
    const n = getRefCounts("const x = 1; { const x = 2; f(x); }", "x", &counts);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 0), counts[0]); // outer x: 미참조
    try std.testing.expectEqual(@as(u32, 1), counts[1]); // inner x: f(x)에서 1번
}

test "Reference: unreferenced symbol has count 0" {
    // const x = 1;  → x는 선언만 있고 참조 없음
    var counts: [8]u32 = undefined;
    const n = getRefCounts("const x = 1;", "x", &counts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 0), counts[0]);
}

test "Reference: compound assignment counts as reference" {
    // let x = 0; x += 1;  → x는 1번 참조 (compound assignment)
    var counts: [8]u32 = undefined;
    const n = getRefCounts("let x = 0; x += 1;", "x", &counts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 1), counts[0]);
}

test "Reference: update expression counts as reference" {
    // let x = 0; x++;  → x는 1번 참조 (update expression)
    var counts: [8]u32 = undefined;
    const n = getRefCounts("let x = 0; x++;", "x", &counts);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u32, 1), counts[0]);
}

// ============================================================
// Enum predeclare & export binding
// ============================================================

const AnalyzeResult = struct {
    scanner: Scanner,
    parser: Parser,
    analyzer: SemanticAnalyzer,

    fn deinit(self: *AnalyzeResult) void {
        self.analyzer.deinit();
        self.parser.deinit();
        self.scanner.deinit();
    }
};

fn analyzeModule(source: []const u8) !AnalyzeResult {
    var scanner = try Scanner.init(std.testing.allocator, source);
    errdefer scanner.deinit();
    scanner.is_module = true;
    var parser = Parser.init(std.testing.allocator, &scanner);
    errdefer parser.deinit();
    parser.is_ts = true;
    parser.is_module = true;
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    ana.is_module = true;
    errdefer ana.deinit();
    try ana.analyze();
    return .{ .scanner = scanner, .parser = parser, .analyzer = ana };
}

fn analyzeNoErrors(source: []const u8) !void {
    var r = try analyzeModule(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.parser.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), r.analyzer.errors.items.len);
}

fn analyzeHasError(source: []const u8, needle: []const u8) !void {
    var r = try analyzeModule(source);
    defer r.deinit();
    for (r.analyzer.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, needle) != null) return;
    }
    return error.TestUnexpectedResult;
}

test "Enum: re-export via export specifier" {
    try analyzeNoErrors("enum Direction { Up, Down }\nexport { Direction };");
}

test "Enum: re-export with alias" {
    try analyzeNoErrors("enum Fruit { Apple }\nexport { Fruit as F };");
}

test "Enum: export enum declaration" {
    try analyzeNoErrors("export enum Color { Red, Green }");
}

test "Enum: default export" {
    try analyzeNoErrors("enum Status { Active }\nexport default Status;");
}

test "Enum: mixed re-export with class and var" {
    try analyzeNoErrors(
        \\enum Dir { Up }
        \\class Store {}
        \\const name = "x";
        \\export { Dir, Store, name };
    );
}

test "Enum: const enum re-export" {
    try analyzeNoErrors("const enum Color { Red }\nexport { Color };");
}

test "Enum: string enum re-export" {
    try analyzeNoErrors(
        \\enum HttpMethod { Get = "GET", Post = "POST" }
        \\export { HttpMethod };
    );
}

test "Enum: used in expression after declaration" {
    try analyzeNoErrors("enum Dir { Up = 0 }\nconst d = Dir.Up;\nexport { d };");
}

test "Enum: undefined export still errors" {
    try analyzeHasError("export { Nonexistent };", "not defined");
}

// ====================================================================
// Private Name 시맨틱 체크
// ====================================================================

test "Private: field read/write is allowed" {
    try analyzeNoErrors(
        \\class C {
        \\  #x = 1;
        \\  test() {
        \\    console.log(this.#x);
        \\    this.#x = 2;
        \\  }
        \\}
    );
}

test "Private: method assignment is error" {
    try analyzeHasError(
        \\class C {
        \\  #method() { return 1; }
        \\  test() {
        \\    this.#method = 5;
        \\  }
        \\}
    , "Cannot assign to private method");
}

test "Private: method read is allowed" {
    try analyzeNoErrors(
        \\class C {
        \\  #method() { return 1; }
        \\  test() {
        \\    this.#method();
        \\  }
        \\}
    );
}

test "Private: getter-only assignment is error" {
    try analyzeHasError(
        \\class C {
        \\  get #x() { return 1; }
        \\  test() {
        \\    this.#x = 5;
        \\  }
        \\}
    , "It only has a getter");
}

test "Private: getter-only read is allowed" {
    try analyzeNoErrors(
        \\class C {
        \\  get #x() { return 1; }
        \\  test() {
        \\    console.log(this.#x);
        \\  }
        \\}
    );
}

test "Private: setter-only read is error" {
    try analyzeHasError(
        \\class C {
        \\  set #x(v) {}
        \\  test() {
        \\    console.log(this.#x);
        \\  }
        \\}
    , "It only has a setter");
}

test "Private: setter-only assignment is allowed" {
    try analyzeNoErrors(
        \\class C {
        \\  set #x(v) {}
        \\  test() {
        \\    this.#x = 5;
        \\  }
        \\}
    );
}

test "Private: getter+setter pair allows read and write" {
    try analyzeNoErrors(
        \\class C {
        \\  get #x() { return 1; }
        \\  set #x(v) {}
        \\  test() {
        \\    console.log(this.#x);
        \\    this.#x = 5;
        \\  }
        \\}
    );
}

test "Private: undeclared private name is error" {
    try analyzeHasError(
        \\class C {
        \\  test() {
        \\    this.#unknown;
        \\  }
        \\}
    , "must be declared");
}

test "Private: duplicate private field is error" {
    try analyzeHasError(
        \\class C {
        \\  #x = 1;
        \\  #x = 2;
        \\}
    , "has already been declared");
}

test "Private: update expression on method is error" {
    try analyzeHasError(
        \\class C {
        \\  #method() {}
        \\  test() { this.#method++; }
        \\}
    , "Cannot assign to private method");
}

test "Private: update expression on field is allowed" {
    try analyzeNoErrors(
        \\class C {
        \\  #x = 1;
        \\  test() { this.#x++; }
        \\}
    );
}

// ============================================================
// Top-Level Await + target 검증
// ============================================================

/// es_target을 지정하여 분석하는 헬퍼.
fn analyzeModuleWithTarget(source: []const u8, target: @import("../transformer/compat.zig").ESTarget) !AnalyzeResult {
    var scanner = try Scanner.init(std.testing.allocator, source);
    errdefer scanner.deinit();
    scanner.is_module = true;
    var parser = Parser.init(std.testing.allocator, &scanner);
    errdefer parser.deinit();
    parser.is_ts = true;
    parser.is_module = true;
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    ana.is_module = true;
    ana.es_target = target;
    ana.unsupported = @import("../transformer/compat.zig").fromESTarget(target);
    errdefer ana.deinit();
    try ana.analyze();
    return .{ .scanner = scanner, .parser = parser, .analyzer = ana };
}

test "TLA: await at top-level emits error when target < es2022" {
    var r = try analyzeModuleWithTarget(
        \\const x = await fetch('/');
    , .es2021);
    defer r.deinit();

    // 에러가 1개 발생해야 함
    try std.testing.expect(r.analyzer.errors.items.len > 0);
    const err = r.analyzer.errors.items[0];
    try std.testing.expect(std.mem.indexOf(u8, err.message, "Top-level await") != null);
    try std.testing.expectEqual(Diagnostic.Kind.semantic, err.kind);
    // hint는 PR #1441부터 Code.help()가 담당 (진단엔 미포함, 렌더러가 주입)
    try std.testing.expectEqual(@import("../error_codes.zig").Code.top_level_await_target, err.code.?);
}

test "TLA: await at top-level no error when target >= es2022" {
    var r = try analyzeModuleWithTarget(
        \\const x = await fetch('/');
    , .es2022);
    defer r.deinit();

    // 시맨틱 에러 없어야 함
    try std.testing.expectEqual(@as(usize, 0), r.analyzer.errors.items.len);
}

test "TLA: await at top-level no error when target is null (unspecified)" {
    // analyzeModule()은 es_target = null (기본값)
    var r = try analyzeModule(
        \\const x = await fetch('/');
    );
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.analyzer.errors.items.len);
}

test "TLA: await inside async function no error regardless of target" {
    var r = try analyzeModuleWithTarget(
        \\async function load() {
        \\  const x = await fetch('/');
        \\  return x;
        \\}
    , .es2021);
    defer r.deinit();

    // async 함수 내부의 await는 TLA가 아니므로 에러 없음
    try std.testing.expectEqual(@as(usize, 0), r.analyzer.errors.items.len);
}

test "TLA: for-await-of at top-level emits error when target < es2022" {
    var r = try analyzeModuleWithTarget(
        \\for await (const x of stream) { console.log(x); }
    , .es2020);
    defer r.deinit();

    try std.testing.expect(r.analyzer.errors.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, r.analyzer.errors.items[0].message, "Top-level await") != null);
}

test "TLA: for-await-of at top-level no error when target >= es2022" {
    var r = try analyzeModuleWithTarget(
        \\for await (const x of stream) { console.log(x); }
    , .es2022);
    defer r.deinit();

    try std.testing.expectEqual(@as(usize, 0), r.analyzer.errors.items.len);
}
