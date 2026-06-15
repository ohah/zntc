const std = @import("std");
const analyzer_mod = @import("analyzer.zig");
const SemanticAnalyzer = analyzer_mod.SemanticAnalyzer;
const Diagnostic = analyzer_mod.Diagnostic;
const symbol_mod = @import("symbol.zig");
const SymbolKind = symbol_mod.SymbolKind;
const ScopeId = @import("scope.zig").ScopeId;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
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

test "SemanticAnalyzer: class method body inherits strict — duplicate block function is error (#4414)" {
    // class body 는 항상 strict(10.2.1) 이고 strict 는 하향 sticky 다. sloppy 파일이라도
    // 메서드 body 안 블록에서 중복 function 선언은 거부되어야 한다(Annex B 미적용).
    var scanner = try Scanner.init(std.testing.allocator, "class C { m() { { function f(){} function f(){} } } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: sloppy block duplicate function is allowed (Annex B, #4414 control)" {
    // 대조군: class 밖 sloppy 블록은 strict 가 아니므로 Annex B B.3.2 로 허용되어야 한다.
    var scanner = try Scanner.init(std.testing.allocator, "{ function f(){} function f(){} }");
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

test "SemanticAnalyzer: numeric literal const_value stores raw literal text" {
    const src =
        \\const dec = 123;
        \\const exp = 1e3;
        \\const hex = 0x10;
        \\const neg = -1;
        \\const big = 1n;
        \\const expr = 1 + 2;
    ;
    var scanner = try Scanner.init(std.testing.allocator, src);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    var saw_dec = false;
    var saw_exp = false;
    var saw_hex = false;
    var saw_neg = false;
    var saw_big = false;
    var saw_expr = false;
    for (ana.symbols.items, 0..) |sym, sym_idx| {
        const name = sym.nameText(parser.ast.source);
        const text = ana.numeric_const_texts.get(@intCast(sym_idx)) orelse "";
        if (std.mem.eql(u8, name, "dec")) {
            saw_dec = true;
            try std.testing.expectEqual(symbol_mod.ConstValue.Kind.number, sym.const_kind);
            try std.testing.expectEqualStrings("123", text);
        } else if (std.mem.eql(u8, name, "exp")) {
            saw_exp = true;
            try std.testing.expectEqual(symbol_mod.ConstValue.Kind.number, sym.const_kind);
            try std.testing.expectEqualStrings("1e3", text);
        } else if (std.mem.eql(u8, name, "hex")) {
            saw_hex = true;
            try std.testing.expectEqual(symbol_mod.ConstValue.Kind.number, sym.const_kind);
            try std.testing.expectEqualStrings("0x10", text);
        } else if (std.mem.eql(u8, name, "neg")) {
            saw_neg = true;
            try std.testing.expectEqual(symbol_mod.ConstValue.Kind.none, sym.const_kind);
        } else if (std.mem.eql(u8, name, "big")) {
            saw_big = true;
            try std.testing.expectEqual(symbol_mod.ConstValue.Kind.none, sym.const_kind);
        } else if (std.mem.eql(u8, name, "expr")) {
            saw_expr = true;
            try std.testing.expectEqual(symbol_mod.ConstValue.Kind.none, sym.const_kind);
        }
    }
    try std.testing.expect(saw_dec and saw_exp and saw_hex and saw_neg and saw_big and saw_expr);
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

const AnalyzeOpts = struct { module: bool = true, ts: bool = true };

fn analyzeWith(source: []const u8, opts: AnalyzeOpts) !AnalyzeResult {
    var scanner = try Scanner.init(std.testing.allocator, source);
    errdefer scanner.deinit();
    scanner.is_module = opts.module;
    var parser = Parser.init(std.testing.allocator, &scanner);
    errdefer parser.deinit();
    if (opts.ts) parser.source_mode = .ts;
    parser.is_module = opts.module;
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    ana.is_module = opts.module;
    errdefer ana.deinit();
    try ana.analyze();
    return .{ .scanner = scanner, .parser = parser, .analyzer = ana };
}

fn analyzeModule(source: []const u8) !AnalyzeResult {
    return analyzeWith(source, .{});
}

fn analyzeScript(source: []const u8) !AnalyzeResult {
    return analyzeWith(source, .{ .module = false, .ts = false });
}

fn analyzeNoErrors(source: []const u8) !void {
    var r = try analyzeModule(source);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.parser.errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), r.analyzer.errors.items.len);
}

fn expectAnalyzeError(r: *AnalyzeResult, needle: []const u8) !void {
    for (r.analyzer.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, needle) != null) return;
    }
    return error.TestUnexpectedResult;
}

fn analyzeHasError(source: []const u8, needle: []const u8) !void {
    var r = try analyzeModule(source);
    defer r.deinit();
    try expectAnalyzeError(&r, needle);
}

fn analyzeScriptHasError(source: []const u8, needle: []const u8) !void {
    var r = try analyzeScript(source);
    defer r.deinit();
    try expectAnalyzeError(&r, needle);
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

test "Enum: export enum declaration marks exported symbol" {
    var r = try analyzeModule("export enum Color { Red, Green }");
    defer r.deinit();

    try std.testing.expect(r.analyzer.exported_names.contains("Color"));

    var found = false;
    for (r.analyzer.symbols.items) |sym| {
        if (!std.mem.eql(u8, sym.nameText(r.parser.ast.source), "Color")) continue;
        found = true;
        try std.testing.expect(sym.decl_flags.is_exported);
    }
    try std.testing.expect(found);
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

test "#4398 export binding: 함수 파라미터 이름은 module export 를 만족 못함" {
    // x 는 함수 파라미터(함수 스코프) 일 뿐 module-scope binding 이 아니므로
    // export { x } 는 에러여야 한다. 과거엔 모든 스코프 심볼을 이름으로 스캔해
    // 파라미터를 hit → false-negative (에러 미발생).
    try analyzeHasError("function f(x) { return x; }\nexport { x };", "not defined");
}

test "#4398 export binding: 중첩 로컬 이름도 module export 를 만족 못함" {
    try analyzeHasError("function f() { let inner = 1; return inner; }\nexport { inner };", "not defined");
}

test "#4398 export binding: forward module-scope 선언/import 는 여전히 valid" {
    // 모듈 스코프 binding 의 forward 참조(선언이 export 뒤) 는 유효 — 회귀 가드.
    try analyzeNoErrors("export { y };\nlet y = 1;");
    try analyzeNoErrors("export { Z };\nimport { Z } from \"./m\";");
}

/// 정확히 N 번째 alloc 만 실패시키는 테스트용 allocator. std.testing.FailingAllocator 는
/// fail_index 이후 *모든* alloc 을 실패시켜, catch 가 삼킨 직후의 try-alloc 까지 실패→error
/// 로 cascade 되므로 "삼킴" 자체를 격리하지 못한다. 이건 한 번만 실패시키고 나머지는 통과.
const OneShotFailAllocator = struct {
    child: std.mem.Allocator,
    fail_at: usize,
    count: usize = 0,

    fn allocator(self: *OneShotFailAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = oafAlloc,
            .resize = oafResize,
            .remap = oafRemap,
            .free = oafFree,
        } };
    }
    fn oafAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(ctx));
        const cur = self.count;
        self.count += 1;
        if (cur == self.fail_at) return null; // 이 번째 alloc 만 실패
        return self.child.rawAlloc(n, alignment, ra);
    }
    fn oafResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, alignment, new_len, ra);
    }
    fn oafRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }
    fn oafFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneShotFailAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }
};

test "#4400 analyzer: 분석 중 allocation 실패는 OutOfMemory 로 표면화 (silent swallow 금지)" {
    // symbol/reference/const 기록의 allocation 실패가 누락된 채 성공 반환되면 import
    // elision / mangler liveness 가 잘못된 입력을 받아 silent miscompile 위험. 과거
    // catch {} 가 이를 삼켰다. 이제 어느 allocation 하나가 실패해도(그게 catch-site 여도)
    // analyze() 는 반드시 error.OutOfMemory 를 반환해야 한다.
    //
    // references 는 analyze() 가 nodes/4 만큼 미리 예약하므로, catch-site(references.append)
    // 가 실제 grow-alloc 하도록 참조 밀집(같은 변수 다수 사용) 소스를 쓴다.
    // `undeclaredGlobal;` 로 addUnresolvedReference 의 dupe/put catch-site 도 커버.
    const source =
        "let a = 1;\n" ++
        "undeclaredGlobal;\n" ++
        ("a;\n" ** 60);

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    // 1) 실패 없는 run 으로 analyzer 의 총 alloc 횟수 측정.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    {
        var ana = SemanticAnalyzer.init(counting.allocator(), &parser.ast);
        defer ana.deinit();
        try ana.analyze();
    }
    const total = counting.allocations;
    try std.testing.expect(total > 0);

    // 2) 각 alloc 을 *하나씩* 실패시킨다 — catch-site 든 try-site 든 전부 OutOfMemory.
    //    한 곳이라도 success 면 그 alloc 실패가 조용히 삼켜졌다는 뜻(RED).
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var oaf = OneShotFailAllocator{ .child = std.testing.allocator, .fail_at = i };
        var ana = SemanticAnalyzer.init(oaf.allocator(), &parser.ast);
        defer ana.deinit();
        try std.testing.expectError(error.OutOfMemory, ana.analyze());
    }
}

// ====================================================================
// D5: import type declaration + 다른 import → export 검증
// ====================================================================
// `@expo/log-box` 의 `LogBox.ts` 같은 패턴이 fail 하던 회귀 가드.
// parser 가 `import type { ... }` 전체 AST 를 drop 하던 게 root cause —
// declaration 자체에 is_type_only flag 만 두고 specifier 들의 binding 정보는
// 보존해야 같은 file 안의 다른 (value) import 와 함께 있을 때 export 검증
// 이 그 binding 을 인식한다.

test "Export: forward ref to default/namespace import binding (D20 #3310)" {
    // @grpc/grpc-js src/index.ts 패턴 — `export { X };` 가 X 를 바인딩하는
    // default/namespace import 보다 소스상 앞. ECMAScript: import 는 module top
    // hoist 라 valid (webpack/rollup/babel/tsc/swc 통과). 단일 패스 analyzer 가
    // forward import 를 못 찾아 ZNTC1201 오진단하던 회귀.
    try analyzeNoErrors(
        \\export { Deadline };
        \\import Deadline from './deadline';
    );
    try analyzeNoErrors(
        \\export { ns };
        \\import * as ns from './mod';
    );
    // default + named 혼재 forward
    try analyzeNoErrors(
        \\export { a, b };
        \\import a from './a';
        \\import { b } from './b';
    );
    // 정상 순서 (import 가 export 앞) — regression guard
    try analyzeNoErrors(
        \\import Deadline from './deadline';
        \\export { Deadline };
    );
}

test "Export: undefined name still errors (D20 negative guard)" {
    // 정공법 symbol 등록이 진짜 미정의 export 까지 통과시키면 안 됨.
    var r = try analyzeModule(
        \\export { totallyMissing };
    );
    defer r.deinit();
    try expectAnalyzeError(&r, "totallyMissing");
}

test "Import: forward value use resolves to hoisted import binding (D20)" {
    // RFC #3310 정공법 고유 범위 — analyzer 가 import 를 1st-pass hoisted symbol
    // 로 등록하므로 forward `export {}` 뿐 아니라 import 보다 소스상 앞선 value
    // use 도 resolve (이전 read-only side-table 은 export specifier 만 커버했음).
    // ECMAScript: import 는 module top hoist 라 valid.
    try analyzeNoErrors(
        \\console.log(foo);
        \\import foo from './foo';
    );
    try analyzeNoErrors(
        \\const x = ns.y;
        \\import * as ns from './m';
    );
    try analyzeNoErrors(
        \\export default function () { return helper(); }
        \\import { helper } from './h';
    );
}

test "Import: redeclared with let/const/function/class is error (D20 PR-2 spec-correct)" {
    // RFC #3310 정공법: analyzer 가 import 를 1st-pass hoisted symbol 로 정식
    // 등록하면서 `import {x}; let x` 류 ECMAScript LexicallyDeclaredNames 위반을
    // spec-correct 하게 검출 (Babel/tsc/swc/rollup/webpack 모두 Duplicate
    // declaration). #3311 read-only side-table 방식은 symbol 미생성이라 이 케이스를
    // 못 잡았는데, PR-1 정공법이 개선. 이 회귀 가드는 PR-3 (side-table 제거) 후에도
    // 정공법 symbol 경로로 유지되어야 한다.
    try analyzeHasError(
        \\import { x } from './m';
        \\let x = 1;
    , "already been declared");
    try analyzeHasError(
        \\import x from './m';
        \\const x = 1;
    , "already been declared");
    try analyzeHasError(
        \\import * as x from './m';
        \\function x() {}
    , "already been declared");
    try analyzeHasError(
        \\import { x } from './m';
        \\class x {}
    , "already been declared");
    // 역방향 (binding 이 import 보다 앞) 도 대칭으로 검출
    try analyzeHasError(
        \\let x = 1;
        \\import { x } from './m';
    , "already been declared");
}

test "Import: type-only + namespace value from same source — export resolves" {
    try analyzeNoErrors(
        \\import type { Foo } from './x';
        \\import * as ns from './x';
        \\export { Foo };
        \\const _ = ns;
    );
}

test "Import: type-only + default value from same source — export resolves" {
    try analyzeNoErrors(
        \\import type { Foo } from './x';
        \\import baz from './x';
        \\export { Foo };
        \\const _ = baz;
    );
}

test "Import: type-only + namespace from different source — export resolves" {
    try analyzeNoErrors(
        \\import type { Foo } from './x';
        \\import * as ns from './y';
        \\export { Foo };
        \\const _ = ns;
    );
}

test "Import: type-only default declaration — export resolves" {
    try analyzeNoErrors(
        \\import type Foo from './x';
        \\import * as ns from './x';
        \\export { Foo };
        \\const _ = ns;
    );
}

test "Import: type-only specifier is still a binding (no runtime use enforced here)" {
    // type-only binding 을 value 로 쓰면 codegen 단계에서 not-defined runtime error 가
    // 되지만, semantic 단계에선 binding 으로 인정되어 unresolved 가 아니다 — TS 와 동일.
    // value 검증은 transformer Phase D / linker 가 별도 단계에서 처리.
    try analyzeNoErrors(
        \\import type { Foo } from './x';
        \\import baz from './x';
        \\const _ = Foo;
        \\const __ = baz;
    );
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

// Private method/getter-only/setter-only 의 read/write 정합성은 ECMA §7.3.30
// PrivateSet / §7.3.29 PrivateGet 의 런타임 TypeError 이다. nested class 에서는
// 합법적인 shadowing 이 가능하므로 static 단계에서 차단하지 않는다.

test "Private: method assignment parses (runtime TypeError)" {
    try analyzeNoErrors(
        \\class C {
        \\  #method() { return 1; }
        \\  test() {
        \\    this.#method = 5;
        \\  }
        \\}
    );
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

test "Private: getter-only assignment parses (runtime TypeError)" {
    try analyzeNoErrors(
        \\class C {
        \\  get #x() { return 1; }
        \\  test() {
        \\    this.#x = 5;
        \\  }
        \\}
    );
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

test "Private: setter-only read parses (runtime TypeError)" {
    try analyzeNoErrors(
        \\class C {
        \\  set #x(v) {}
        \\  test() {
        \\    console.log(this.#x);
        \\  }
        \\}
    );
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

test "Private: update expression on method parses (runtime TypeError)" {
    try analyzeNoErrors(
        \\class C {
        \\  #method() {}
        \\  test() { this.#method++; }
        \\}
    );
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
    parser.source_mode = .ts;
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

// ============================================================
// ClassExpression name binding (#1592)
// ============================================================
// ECMAScript 15.7.14: ClassExpression의 name은 class body scope에
// lexical binding되어 body 내부에서 self-reference로 보이고,
// 외부 scope에서는 보이지 않는다.

test "ClassExpression: name registered as class_decl in class body scope (#1592)" {
    var scanner = try Scanner.init(std.testing.allocator, "const c = class Foo {};");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
    // `c` + `Foo` = 2 심볼이 있어야 함 (Foo가 심볼로 등록됐음을 검증)
    var found_foo = false;
    for (ana.symbols.items) |sym| {
        if (sym.kind == .class_decl) {
            const name = sym.nameText(parser.ast.source);
            if (std.mem.eql(u8, name, "Foo")) found_foo = true;
        }
    }
    try std.testing.expect(found_foo);
}

test "ClassExpression: self-reference in body increments reference_count (#1592)" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const c = class Foo {
        \\  m() { return Foo; }
        \\};
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
    var foo_ref_count: u32 = 0;
    var foo_found = false;
    for (ana.symbols.items) |sym| {
        if (sym.kind == .class_decl) {
            const name = sym.nameText(parser.ast.source);
            if (std.mem.eql(u8, name, "Foo")) {
                foo_found = true;
                foo_ref_count = sym.reference_count;
            }
        }
    }
    try std.testing.expect(foo_found);
    // body 내부 `Foo` 참조 정확히 1회 — body scope 바깥은 이 심볼에 해소되지 않아야 함
    try std.testing.expectEqual(@as(u32, 1), foo_ref_count);
}

test "ClassExpression: name without self-reference has reference_count 0 (#1592)" {
    var scanner = try Scanner.init(std.testing.allocator, "const c = class Foo { m() { return 1; } };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
    for (ana.symbols.items) |sym| {
        if (sym.kind == .class_decl) {
            const name = sym.nameText(parser.ast.source);
            if (std.mem.eql(u8, name, "Foo")) {
                try std.testing.expectEqual(@as(u32, 0), sym.reference_count);
                return;
            }
        }
    }
    try std.testing.expect(false); // Foo 심볼이 있어야 함
}

test "ClassExpression: name scoped to class body — not visible outside (#1592)" {
    // class body 바깥의 `Foo`는 ClassExpression name을 참조할 수 없다 (별개 scope).
    // 번들 시 body scope를 벗어난 참조는 별개 심볼이거나 unresolved.
    var scanner = try Scanner.init(std.testing.allocator,
        \\const c = class Foo { m() { return Foo; } };
        \\const outer = Foo;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    // body 내부 Foo: reference_count >= 1, body 외부 Foo: 별개 심볼(unresolved) 이거나
    // 같은 Foo에 바인딩되지 않아야 함.
    // 검증: class_decl Foo의 ref_count는 body 내부 참조(1회)만 반영.
    for (ana.symbols.items) |sym| {
        if (sym.kind == .class_decl) {
            const name = sym.nameText(parser.ast.source);
            if (std.mem.eql(u8, name, "Foo")) {
                // outer Foo 참조가 이 심볼로 resolve되면 ref_count == 2가 됨.
                // 정확한 lexical binding이면 ref_count == 1.
                try std.testing.expectEqual(@as(u32, 1), sym.reference_count);
                return;
            }
        }
    }
    try std.testing.expect(false);
}

// ============================================================
// FunctionExpression name binding
// ============================================================

test "FunctionExpression: self-reference resolves to inner function name" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const fn = function Foo(value = Foo) {
        \\  return Foo;
        \\};
        \\const outer = Foo;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expectEqual(@as(usize, 0), ana.errors.items.len);
    var function_name_refs: u32 = 0;
    var found = false;
    for (ana.symbols.items) |sym| {
        if (sym.kind.isFunctionLike() and std.mem.eql(u8, sym.nameText(parser.ast.source), "Foo")) {
            found = true;
            function_name_refs = sym.reference_count;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(u32, 2), function_name_refs);
}

test "FunctionExpression: parameter shadows inner function name" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const fn = function Foo(Foo = Foo) {
        \\  return Foo;
        \\};
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    try std.testing.expectEqual(@as(usize, 0), ana.errors.items.len);
    var function_name_refs: u32 = 0;
    var parameter_refs: u32 = 0;
    for (ana.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "Foo")) {
            if (sym.kind.isFunctionLike()) {
                function_name_refs = sym.reference_count;
            } else if (sym.kind == .parameter) {
                parameter_refs = sym.reference_count;
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 0), function_name_refs);
    try std.testing.expectEqual(@as(u32, 2), parameter_refs);
}

// ============================================================
// per-reference 배열 (references) 테스트
// ============================================================

const RefFixture = struct {
    scanner: Scanner,
    parser: Parser,
    ana: SemanticAnalyzer,

    const Options = struct { jsx: bool = false };

    fn init(source: []const u8) !RefFixture {
        return initOpts(source, .{});
    }

    fn initOpts(source: []const u8, opts: Options) !RefFixture {
        var scanner = try Scanner.init(std.testing.allocator, source);
        errdefer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        errdefer parser.deinit();
        parser.is_jsx = opts.jsx;
        _ = try parser.parse();
        var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
        errdefer ana.deinit();
        try ana.analyze();
        return .{ .scanner = scanner, .parser = parser, .ana = ana };
    }

    fn deinit(self: *RefFixture) void {
        self.ana.deinit();
        self.parser.deinit();
        self.scanner.deinit();
    }

    /// 주어진 이름으로 선언된 심볼을 가리키는 references 항목만 필터.
    fn collectRefs(self: *const RefFixture, target_name: []const u8, out: *std.ArrayList(symbol_mod.Reference)) !void {
        for (self.ana.references.items) |r| {
            const sym_idx = @intFromEnum(r.symbol_id);
            if (sym_idx >= self.ana.symbols.items.len) continue;
            const name = self.ana.symbols.items[sym_idx].nameText(self.parser.ast.source);
            if (std.mem.eql(u8, name, target_name)) {
                try out.append(std.testing.allocator, r);
            }
        }
    }
};

test "references: read + write 각각 기록" {
    var fx = try RefFixture.init("let x = 1; x = 2; f(x);");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("x", &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    var write_seen: usize = 0;
    var read_seen: usize = 0;
    for (refs.items) |r| {
        if (r.flags.write) write_seen += 1;
        if (r.flags.read) read_seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), write_seen);
    try std.testing.expectEqual(@as(usize, 1), read_seen);
}

test "references: node_index 로 AST 위치 역참조" {
    var fx = try RefFixture.init("const y = 1; g(y);");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("y", &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    const node = fx.parser.ast.getNode(refs.items[0].node_index);
    const text = fx.parser.ast.source[node.span.start..node.span.end];
    try std.testing.expectEqualStrings("y", text);
    try std.testing.expect(refs.items[0].flags.read and !refs.items[0].flags.write);
}

test "references: arrow parameter default records imported value use" {
    var fx = try RefFixture.init("import { value } from './dep'; const f = (x = value) => x;");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("value", &refs);

    var read_seen = false;
    for (refs.items) |r| {
        if (r.flags.read and !r.flags.write and r.isValueUse()) {
            read_seen = true;
            break;
        }
    }
    try std.testing.expect(read_seen);

    for (fx.ana.symbols.items) |sym| {
        const name = sym.nameText(fx.parser.ast.source);
        if (std.mem.eql(u8, name, "value")) {
            try std.testing.expectEqual(@as(u32, 1), sym.reference_count);
            return;
        }
    }
    try std.testing.expect(false);
}

test "references: unresolved (전역) 은 기록 안 됨" {
    var fx = try RefFixture.init("console.log(1);");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("console", &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

test "references: reference_count 와 정합" {
    var fx = try RefFixture.init("const x = 1; f(x); g(x); h(x);");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("x", &refs);

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
    for (refs.items) |r| try std.testing.expect(r.flags.read and !r.flags.write);

    for (fx.ana.symbols.items) |sym| {
        const name = sym.nameText(fx.parser.ast.source);
        if (std.mem.eql(u8, name, "x")) {
            try std.testing.expectEqual(@as(u32, 3), sym.reference_count);
        }
    }
}

test "references: scope_id 가 참조 발생 위치" {
    // inner block 에서 outer let 참조 — 기록된 scope_id 는 block scope여야 함.
    var fx = try RefFixture.init("let x = 1; { f(x); }");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("x", &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    // x 가 선언된 scope 는 program scope (첫 번째). 참조는 block scope 에서 발생.
    const ref_scope = refs.items[0].scope_id;
    const decl_scope = fx.ana.symbols.items[@intFromEnum(refs.items[0].symbol_id)].scope_id;
    try std.testing.expect(!std.meta.eql(ref_scope, decl_scope));
}

test "references: compound assign 은 read+write 동시 기록" {
    // PR C: `x += 1` → `{read=true, write=true}`. 이전에는 write 만 set.
    var fx = try RefFixture.init("let x = 1; x += 2;");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("x", &refs);

    // 1 read/write combined (compound) — 초기 선언의 read 는 없음.
    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expect(refs.items[0].flags.read);
    try std.testing.expect(refs.items[0].flags.write);
}

test "references: pure assign 은 write 만" {
    // `x = 1` (초기 선언 아님) → write 만 set.
    var fx = try RefFixture.init("let x = 1; x = 2;");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("x", &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expect(!refs.items[0].flags.read);
    try std.testing.expect(refs.items[0].flags.write);
}

test "references: update expression 은 read+write" {
    // `x++`, `++x`, `x--`, `--x` 모두 read+write.
    var fx = try RefFixture.init("let x = 0; x++; ++x;");
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("x", &refs);

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    for (refs.items) |r| {
        try std.testing.expect(r.flags.read);
        try std.testing.expect(r.flags.write);
    }
}

test "references: enable_stmt_info 시 top-level 선언에 declare flag 기록" {
    // PR B: `stmt_declared` 중간 캐시 제거 후, buildFromSemantic 이 references 의 declare flag 로
    // declared_symbols 를 재구성하는지 검증. enable_stmt_info 꺼져 있으면 declare ref 는 생성 안 됨.
    const source = "let x = 1; f(x);";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.enable_stmt_info = true;
    try ana.analyze();

    var declare_count: usize = 0;
    var read_count: usize = 0;
    for (ana.references.items) |r| {
        const sym = ana.symbols.items[@intFromEnum(r.symbol_id)];
        if (!std.mem.eql(u8, sym.nameText(parser.ast.source), "x")) continue;
        if (r.flags.declare) declare_count += 1;
        if (r.flags.read) read_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), declare_count);
    try std.testing.expectEqual(@as(usize, 1), read_count);
}

// ============================================================
// #1669: scope-wide declare ref + per-scope stmt index + Symbol 확장
// ============================================================

test "#1669: 함수 body 내부 선언도 declare ref 로 기록" {
    // 이전에는 top-level (scope_id==0) 선언만 `flags.declare` 로 기록됐으나, #1669 이후
    // 모든 scope 의 선언을 기록한다. bundler stmt_info 는 scope_id==0 만 bucket 에 분배.
    const source = "function f() { const y = 2; return y; }";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.enable_stmt_info = true;
    try ana.analyze();

    var y_declare_count: usize = 0;
    var y_declare_scope: u32 = 0;
    for (ana.references.items) |r| {
        if (!r.flags.declare) continue;
        const sym = ana.symbols.items[@intFromEnum(r.symbol_id)];
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "y")) {
            y_declare_count += 1;
            y_declare_scope = @intFromEnum(r.scope_id);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), y_declare_count);
    try std.testing.expect(y_declare_scope != 0); // 함수 scope (top-level 아님)
}

test "#1669: per-scope stmt_idx 는 함수 body 내부에서 0 부터 재시작" {
    // `current_stmt_idx` 가 scope 별로 0..N 을 할당하는지 검증. 함수 body 내부의 선언은
    // scope_stmt_idx 가 함수 body 기준 0-based. top-level stmt_idx (`stmt_idx`) 는 별도 유지.
    const source = "const a = 1;\nfunction f() {\n  const b = 2;\n  const c = 3;\n}\n";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.enable_stmt_info = true;
    try ana.analyze();

    var b_scope_idx: u32 = std.math.maxInt(u32);
    var c_scope_idx: u32 = std.math.maxInt(u32);
    for (ana.references.items) |r| {
        if (!r.flags.declare) continue;
        const sym = ana.symbols.items[@intFromEnum(r.symbol_id)];
        const name = sym.nameText(parser.ast.source);
        if (std.mem.eql(u8, name, "b")) b_scope_idx = r.scope_stmt_idx;
        if (std.mem.eql(u8, name, "c")) c_scope_idx = r.scope_stmt_idx;
    }
    try std.testing.expectEqual(@as(u32, 0), b_scope_idx);
    try std.testing.expectEqual(@as(u32, 1), c_scope_idx);
}

test "#2023: nested var predeclare records declare ref at function body stmt index" {
    const source = "function f() {\n  const a = 1;\n  if (true) { var hoisted = 2; }\n}\n";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.enable_stmt_info = true;
    try ana.analyze();

    var declare_count: usize = 0;
    var scope_stmt_idx: u32 = std.math.maxInt(u32);
    var declared_scope: ScopeId = .none;
    for (ana.references.items) |r| {
        if (!r.flags.declare) continue;
        const sym = ana.symbols.items[@intFromEnum(r.symbol_id)];
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "hoisted")) {
            declare_count += 1;
            scope_stmt_idx = r.scope_stmt_idx;
            declared_scope = r.scope_id;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), declare_count);
    try std.testing.expectEqual(@as(u32, 1), scope_stmt_idx);
    try std.testing.expect(!declared_scope.isNone());
}

test "block function predeclare maps declaration node to var-scope symbol" {
    const source =
        \\function f() {
        \\  if (true) {
        \\    Box = {
        \\      install: function(error) { addException(error); },
        \\      addException: addException,
        \\    };
        \\    function addException(error) {}
        \\  }
        \\}
    ;
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    try ana.analyze();

    var decl_sym: ?u32 = null;
    var seen_ref_count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, i| {
        if (node.tag == .function_declaration) {
            const name_idx: NodeIndex = @enumFromInt(parser.ast.extra_data.items[node.data.extra]);
            if (name_idx.isNone()) continue;
            const name_node = parser.ast.getNode(name_idx);
            if (name_node.tag != .binding_identifier) continue;
            const text = parser.ast.getText(name_node.data.string_ref);
            if (!std.mem.eql(u8, text, "addException")) continue;
            decl_sym = ana.symbol_ids.items[@intFromEnum(name_idx)] orelse return error.MissingAddExceptionDeclSymbol;
            continue;
        }

        if (node.tag != .identifier_reference) continue;
        const text = parser.ast.getText(node.data.string_ref);
        if (!std.mem.eql(u8, text, "addException")) continue;
        const ref_sym = ana.symbol_ids.items[i] orelse continue;
        if (decl_sym) |expected| try std.testing.expectEqual(expected, ref_sym);
        seen_ref_count += 1;
    }

    try std.testing.expect(decl_sym != null);
    try std.testing.expect(seen_ref_count >= 1);
}

test "#2023: predeclared lexical bindings record declare ref once" {
    const source = "function f() {\n  {\n    let x = 1;\n    const { y = x } = obj;\n  }\n}\n";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.enable_stmt_info = true;
    try ana.analyze();

    var x_declare_count: usize = 0;
    var y_declare_count: usize = 0;
    var x_scope_stmt_idx: u32 = std.math.maxInt(u32);
    var y_scope_stmt_idx: u32 = std.math.maxInt(u32);
    for (ana.references.items) |r| {
        if (!r.flags.declare) continue;
        const sym = ana.symbols.items[@intFromEnum(r.symbol_id)];
        const name = sym.nameText(parser.ast.source);
        if (std.mem.eql(u8, name, "x")) {
            x_declare_count += 1;
            x_scope_stmt_idx = r.scope_stmt_idx;
        }
        if (std.mem.eql(u8, name, "y")) {
            y_declare_count += 1;
            y_scope_stmt_idx = r.scope_stmt_idx;
        }
    }

    try std.testing.expectEqual(@as(usize, 1), x_declare_count);
    try std.testing.expectEqual(@as(usize, 1), y_declare_count);
    try std.testing.expectEqual(@as(u32, 0), x_scope_stmt_idx);
    try std.testing.expectEqual(@as(u32, 1), y_scope_stmt_idx);
}

test "#2037 regression: top-level nested var is predeclared for forward nested function refs" {
    const source =
        \\{
        \\  var api = function() { return helper(); };
        \\  var helper = function() { return 42; };
        \\}
    ;
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.is_module = true;
    ana.enable_stmt_info = true;
    try ana.analyze();

    try std.testing.expect(!ana.unresolved_references.contains("helper"));

    var helper_ref_count: ?u32 = null;
    for (ana.symbols.items) |sym| {
        if (std.mem.eql(u8, sym.nameText(parser.ast.source), "helper")) {
            helper_ref_count = sym.reference_count;
            break;
        }
    }
    try std.testing.expect(helper_ref_count != null);
    try std.testing.expect(helper_ref_count.? > 0);
}

// ============================================================
// #1660: block / switch / module / nested-block 에서 var 와 lexical 이름 충돌
// (ECMA §sec-block-static-semantics-early-errors / §sec-switch-statement-static-semantics-early-errors
//  / §sec-module-semantics-static-semantics-early-errors)
// ============================================================

test "Redecl: block var vs function" {
    try analyzeHasError("{ var f; function f() {} }", "already been declared");
}

test "Redecl: block function vs lexical declaration" {
    try analyzeHasError("{ function f() {} let f; }", "already been declared");
}

test "Redecl: block generator vs function declaration" {
    try analyzeHasError("{ function* f() {} function f() {} }", "already been declared");
}

test "Redecl: block class vs function declaration" {
    try analyzeHasError("{ class f {} function f() {} }", "already been declared");
}

// sloppy (script) 모드에서도 test262 block-scope 같은-이름 function-like redecl
// 케이스가 검출되어야 한다. predeclareVarDeclsRecursive 가 generator/async 를
// `.function_decl` 로 잘못 등록하던 회귀 (#2714) 방어용.
test "Redecl(script): block generator vs function declaration" {
    try analyzeScriptHasError("{ function* f() {} function f() {} }", "already been declared");
}

test "Redecl(script): block async generator vs function declaration" {
    try analyzeScriptHasError("{ async function* f() {} function f() {} }", "already been declared");
}

test "Redecl(script): block async function vs function declaration" {
    try analyzeScriptHasError("{ async function f() {} function f() {} }", "already been declared");
}

test "Redecl: nested block var vs outer function" {
    try analyzeHasError("{ { var f; } function f() {} }", "already been declared");
}

test "Redecl: function body nested block let vs var" {
    try analyzeHasError("function x() { { let f; var f; } }", "already been declared");
}

test "Redecl: function body nested block var vs let" {
    try analyzeHasError("function x() { { var f; let f; } }", "already been declared");
}

test "Redecl: function body nested block function vs var" {
    try analyzeHasError("function x() { { function f() {}; var f; } }", "already been declared");
}

test "Redecl: switch var vs function" {
    try analyzeHasError("switch (0) { case 1: var f; default: function f() {} }", "already been declared");
}

test "Redecl: module top-level duplicate function" {
    try analyzeHasError("function x() {} function x() {}", "already been declared");
}

test "Redecl: strict IIFE block const vs var" {
    try analyzeHasError("(function() { 'use strict'; { const f = 1; var f; } })", "already been declared");
}

// ============================================================
// JSX member tag root resolution
// ============================================================

// JSX `<ns.Comp />` root resolved regardless of case — otherwise propagateSymbolId
// copies null → bundler skips rename → ReferenceError (ExpoRoot.js case).
test "JSX: lowercase root of <ns.Comp/> resolves as variable ref" {
    var fx = try RefFixture.initOpts(
        "var ns = require('x'); function F() { return <ns.Comp />; }",
        .{ .jsx = true },
    );
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("ns", &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expect(refs.items[0].flags.read);
}

test "JSX: lowercase root of nested <a.b.Comp/> resolves" {
    var fx = try RefFixture.initOpts(
        "var a = { b: { Comp: function () {} } }; function F() { return <a.b.Comp />; }",
        .{ .jsx = true },
    );
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("a", &refs);

    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expect(refs.items[0].flags.read);
}

// Bare `<div />` stays an intrinsic — guards the member-branch fix from over-reaching.
test "JSX: bare lowercase tag <div/> is intrinsic, not a variable ref" {
    var fx = try RefFixture.initOpts(
        "var div = 1; function F() { return <div />; }",
        .{ .jsx = true },
    );
    defer fx.deinit();

    var refs: std.ArrayList(symbol_mod.Reference) = .empty;
    defer refs.deinit(std.testing.allocator);
    try fx.collectRefs("div", &refs);

    try std.testing.expectEqual(@as(usize, 0), refs.items.len);
}

// ============================================================
// #2474 catch_names dynamic — 회귀 가드
// ============================================================

test "#2474 regression: catch destructure duplicate at index 17+ — diagnostic emitted" {
    // 이전 16-stack-cap 시 17번째 binding 부터 names 배열에 push 안 됨. 두 개의 동일
    // 이름 (예: k16, k16) 이 모두 17+ 위치라면 둘 다 names 에 못 들어가 redeclaration 검사
    // 자체가 비교 base 를 못 가져 silent 누락. dynamic ArrayList 로 전환 후 정상 검출.
    //
    // array_pattern 사용 (object pattern 의 binding_property 분기는 본 PR 범위 외).
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "try {} catch ([");
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        if (i > 0) try src.appendSlice(a, ", ");
        try src.print(a, "k{d}", .{i});
    }
    // 17번째와 18번째에 동일 이름 k16. 16-stack 이면 둘 다 names 에 못 들어감 → 진단 누락.
    try src.appendSlice(a, ", k16, k16]) {}");

    var r = try analyzeModule(src.items);
    defer r.deinit();
    var found = false;
    for (r.analyzer.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Identifier 'k16' has already been declared") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "#2483 regression: catch ({a, a}) — duplicate diagnostic emitted" {
    // collectAndCheckCatchBindings 가 object_pattern 의 binding_property 분기를 처리해야 함.
    // 이전: object_property / assignment_target_property_identifier 만 인식 → binding_property 는 else 로 빠져
    // 재귀해도 switch 의 binding_property case 가 없어 silent skip → duplicate 진단 누락.
    var r = try analyzeModule("try {} catch ({a, a}) {}");
    defer r.deinit();
    var found = false;
    for (r.analyzer.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Identifier 'a' has already been declared") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "#2483 regression: catch ({a}) { let a = 1; } — body conflict diagnostic emitted" {
    // checkCatchBodyConflicts 가 동작하려면 catch_names 가 채워져야 한다.
    // binding_property 가 silent skip 되면 catch_names 비어 conflict 검사 불가.
    var r = try analyzeModule("try {} catch ({a}) { let a = 1; }");
    defer r.deinit();
    var found = false;
    for (r.analyzer.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Identifier 'a' has already been declared") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "#2474 regression: 20-element catch destructure conflicts with body let — diagnostic emitted" {
    // checkCatchBodyConflicts 가 16 초과 binding 도 검사하는지 확인.
    // 17번째 binding 인 `k16` 이 body 의 let `k16` 와 conflict. 16-stack 이면 k16 이 catch_names 에 없음.
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "try {} catch ([");
    var i: u32 = 0;
    while (i < 17) : (i += 1) {
        if (i > 0) try src.appendSlice(a, ", ");
        try src.print(a, "k{d}", .{i});
    }
    try src.appendSlice(a, "]) { let k16 = 1; }");

    var r = try analyzeModule(src.items);
    defer r.deinit();
    var found = false;
    for (r.analyzer.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "Identifier 'k16' has already been declared") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "SemanticAnalyzer: bundle-mode member-target with none object does not OOB (#4271)" {
    // `().x = 1` 류 error-recovery 입력에서 member-target 의 object 가 .none 으로
    // 언래핑되어 checkImportMutation 이 getNode(.none) → OOB panic 하던 회귀.
    // 가드 적용 후에는 panic 없이 완료되어야 한다.
    const sources = [_][]const u8{
        "().x = 1;",
        "delete ().x;",
        "().x++;",
        "import * as ns from \"m\"; ().x = ns;",
    };
    for (sources) |src| {
        var scanner = try Scanner.init(std.testing.allocator, src);
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();
        _ = parser.parse() catch continue; // 파서가 완전히 거부하면 이 케이스 스킵
        var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
        defer ana.deinit();
        ana.check_import_mutation = true; // 번들 모드에서만 검사 활성
        ana.analyze() catch {}; // analyzer 에러는 무관 — 핵심은 OOB panic 부재
    }
}
