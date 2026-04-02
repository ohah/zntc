const std = @import("std");
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const ast_mod = @import("ast.zig");
const Tag = ast_mod.Node.Tag;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

test "Parser: empty program" {
    var scanner = try Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
}

test "Parser: variable declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: binary expression" {
    var scanner = try Scanner.init(std.testing.allocator, "1 + 2 * 3;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const program = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, program.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: if statement" {
    var scanner = try Scanner.init(std.testing.allocator, "function f(x) { if (x) { return 1; } else { return 2; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "function add(a, b) { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: call expression" {
    var scanner = try Scanner.init(std.testing.allocator, "foo(1, 2, 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: member access" {
    var scanner = try Scanner.init(std.testing.allocator, "a.b.c;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array and object literals" {
    var scanner = try Scanner.init(std.testing.allocator, "[1, 2, 3];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: error recovery" {
    var scanner = try Scanner.init(std.testing.allocator, "@@@;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: do-while statement" {
    var scanner = try Scanner.init(std.testing.allocator, "do { x++; } while (x < 10);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-in statement" {
    var scanner = try Scanner.init(std.testing.allocator, "for (var key in obj) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-of statement" {
    var scanner = try Scanner.init(std.testing.allocator, "for (const item of arr) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch statement" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\function f(x) {
        \\  switch (x) {
        \\    case 1: break;
        \\    case 2: return 2;
        \\    default: return 0;
        \\  }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for with empty parts" {
    var scanner = try Scanner.init(std.testing.allocator, "for (;;) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch with var in case body (scratch nesting)" {
    // 이 테스트는 scratch save/restore가 올바르게 동작하는지 검증한다.
    // case 본문에 var 선언이 있으면 scratch를 중첩 사용하게 되는데,
    // save/restore 없이 clearRetainingCapacity를 쓰면 이전 case가 사라진다.
    var scanner = try Scanner.init(std.testing.allocator,
        \\switch (x) {
        \\  case 1:
        \\    var a = 1;
        \\    break;
        \\  case 2:
        \\    var b = 2;
        \\    break;
        \\  default:
        \\    break;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested call in var initializer (scratch nesting)" {
    // var x = foo(bar(1, 2), 3); — 중첩 호출에서 scratch가 안전한지 검증
    var scanner = try Scanner.init(std.testing.allocator, "var x = foo(bar(1, 2), 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-finally" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch-finally" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try without catch or finally is error" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional catch binding (ES2019)" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } catch { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (simple)" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = x => x + 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (parenthesized)" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = (a, b) => a + b;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function with block body" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = (x) => { return x * 2; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in array" {
    var scanner = try Scanner.init(std.testing.allocator, "[1, ...arr, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in call" {
    var scanner = try Scanner.init(std.testing.allocator, "foo(...args);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class declaration" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\class Foo {
        \\  constructor(x) { this.x = x; }
        \\  getX() { return this.x; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with extends" {
    var scanner = try Scanner.init(std.testing.allocator, "class Bar extends Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with static method and property" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\class Config {
        \\  static defaultValue = 42;
        \\  static create() { return 1; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const Foo = class { bar() { } };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = function(x) { return x; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array destructuring" {
    var scanner = try Scanner.init(std.testing.allocator, "const [a, b, c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: object destructuring" {
    var scanner = try Scanner.init(std.testing.allocator, "const { x, y } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with default values" {
    var scanner = try Scanner.init(std.testing.allocator, "const [a = 1, b = 2] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested destructuring" {
    var scanner = try Scanner.init(std.testing.allocator, "const { a: { b } } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with rest" {
    var scanner = try Scanner.init(std.testing.allocator, "const [first, ...rest] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function with destructuring params" {
    var scanner = try Scanner.init(std.testing.allocator, "function foo({ x, y }, [a, b]) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: duplicate param in array destructuring (strict)" {
    // strict mode에서 function f(a, [a, b]) {} 는 에러: a가 두 번 바인딩됨.
    // array_pattern 안의 이름을 collectBoundNames로 수집해야 잡을 수 있음.
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [a, b]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param in object destructuring (strict)" {
    // strict mode에서 function f(a, {a}) {} 는 에러: a가 두 번 바인딩됨.
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, {a}) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: no duplicate in different destructuring names (strict)" {
    // 이름이 다르면 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [b, c]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: duplicate param nested destructuring (strict)" {
    // 중첩 destructuring: function f(a, [{a}]) {} → a가 중복
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [{a}]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param with default value in array (strict)" {
    // default value: function f(a, [a = 1]) {} → a가 중복
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [a = 1]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param with rest in array (strict)" {
    // rest element: function f(a, [...a]) {} → a가 중복
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [...a]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param within same destructuring (generator)" {
    // generator 함수에서도 destructuring 내 중복은 에러
    // function* f([a, a]) {} → a가 중복 (generator는 항상 중복 검사)
    var scanner = try Scanner.init(std.testing.allocator, "function* f([a, a]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

// ============================================================
// Import / Export tests
// ============================================================

test "Parser: import side-effect" {
    var scanner = try Scanner.init(std.testing.allocator, "import 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default" {
    var scanner = try Scanner.init(std.testing.allocator, "import foo from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import named" {
    var scanner = try Scanner.init(std.testing.allocator, "import { a, b as c } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import namespace" {
    var scanner = try Scanner.init(std.testing.allocator, "import * as ns from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default + named" {
    var scanner = try Scanner.init(std.testing.allocator, "import React, { useState } from 'react';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default" {
    var scanner = try Scanner.init(std.testing.allocator, "export default 42;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named" {
    var scanner = try Scanner.init(std.testing.allocator, "export { a, b as c };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "export const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export all re-export" {
    var scanner = try Scanner.init(std.testing.allocator, "export * from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named re-export" {
    var scanner = try Scanner.init(std.testing.allocator, "export { foo } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default function" {
    var scanner = try Scanner.init(std.testing.allocator, "export default function foo() { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: dynamic import expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const m = import('module');");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async function declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "async function fetchData() { return await fetch(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: generator function" {
    var scanner = try Scanner.init(std.testing.allocator, "function* gen() { yield 1; yield 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: yield delegate" {
    var scanner = try Scanner.init(std.testing.allocator, "function* gen() { yield* other(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async arrow function" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = async () => { await fetch(); };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with private field and method" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\class Counter {
        \\  #count = 0;
        \\  #increment() { this.#count++; }
        \\  get value() { return this.#count; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: private field access" {
    var scanner = try Scanner.init(std.testing.allocator, "this.#name;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (array)" {
    // 배열 대입 구조분해 — 현재 array_expression + assignment로 파싱됨
    // semantic analysis에서 assignment target으로 변환 예정
    var scanner = try Scanner.init(std.testing.allocator, "[a, b] = [1, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (object)" {
    var scanner = try Scanner.init(std.testing.allocator, "({ x, y } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import.meta" {
    var scanner = try Scanner.init(std.testing.allocator, "const url = import.meta.url;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array elision [, , x]" {
    var scanner = try Scanner.init(std.testing.allocator, "const [, , x] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// TypeScript type tests
// ============================================================

test "Parser: TS variable with type annotation" {
    var scanner = try Scanner.init(std.testing.allocator, "const x: number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS function with typed params and return" {
    var scanner = try Scanner.init(std.testing.allocator, "function add(a: number, b: number): number { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS union type" {
    var scanner = try Scanner.init(std.testing.allocator, "const x: string | number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS array type" {
    var scanner = try Scanner.init(std.testing.allocator, "const arr: number[] = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type" {
    var scanner = try Scanner.init(std.testing.allocator, "const arr: Array<string> = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS as expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = value as string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS non-null assertion" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = value!;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS object type literal" {
    var scanner = try Scanner.init(std.testing.allocator, "const obj: { x: number; y: string } = { x: 1, y: 'a' };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS tuple type" {
    var scanner = try Scanner.init(std.testing.allocator, "const t: [string, number] = ['a', 1];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS typeof and keyof" {
    var scanner = try Scanner.init(std.testing.allocator, "const k: keyof typeof obj = 'x';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// TypeScript declaration tests
// ============================================================

test "Parser: TS type alias" {
    var scanner = try Scanner.init(std.testing.allocator, "type StringOrNumber = string | number;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type alias" {
    var scanner = try Scanner.init(std.testing.allocator, "type Result<T, E> = { ok: T } | { err: E };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\interface User {
        \\  name: string;
        \\  age: number;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface extends" {
    // interface Admin extends User — 단일 extends를 NodeList(len=1)로 저장
    var scanner = try Scanner.init(std.testing.allocator, "interface Admin extends User { role: string; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // program.data.list → interface 노드 접근
    const program = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, program.tag);
    // program body의 첫 번째 stmt = ts_interface_declaration
    const iface_raw = parser.ast.extra_data.items[program.data.list.start];
    const iface = parser.ast.getNode(@enumFromInt(iface_raw));
    try std.testing.expectEqual(Tag.ts_interface_declaration, iface.tag);
    // extra = [name, type_params, extends_start, extends_len, body]
    // extends User → extends_len = 1
    const extends_len = parser.ast.extra_data.items[iface.data.extra + 3];
    try std.testing.expectEqual(@as(u32, 1), extends_len);
}

test "Parser: TS interface multiple extends" {
    // interface Foo extends Bar, Baz — 다중 extends를 NodeList로 정확히 저장
    var scanner = try Scanner.init(std.testing.allocator, "interface Foo extends Bar, Baz { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    const program = parser.ast.getNode(root);
    const iface_raw = parser.ast.extra_data.items[program.data.list.start];
    const iface = parser.ast.getNode(@enumFromInt(iface_raw));
    try std.testing.expectEqual(Tag.ts_interface_declaration, iface.tag);

    // extra = [name, type_params, extends_start, extends_len, body]
    const e = iface.data.extra;
    const extends_start = parser.ast.extra_data.items[e + 2];
    const extends_len = parser.ast.extra_data.items[e + 3];
    // extends Bar, Baz → 2개
    try std.testing.expectEqual(@as(u32, 2), extends_len);

    // 두 extends 노드가 유효한 타입 노드인지 확인
    const bar = parser.ast.getNode(@enumFromInt(parser.ast.extra_data.items[extends_start]));
    const baz = parser.ast.getNode(@enumFromInt(parser.ast.extra_data.items[extends_start + 1]));
    try std.testing.expect(bar.tag != .invalid);
    try std.testing.expect(baz.tag != .invalid);
}

test "Parser: TS interface no extends" {
    // extends 없는 경우 extends_len = 0
    var scanner = try Scanner.init(std.testing.allocator, "interface Empty { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    const program = parser.ast.getNode(root);
    const iface_raw = parser.ast.extra_data.items[program.data.list.start];
    const iface = parser.ast.getNode(@enumFromInt(iface_raw));
    try std.testing.expectEqual(Tag.ts_interface_declaration, iface.tag);

    // extends 없으면 extends_len = 0
    const extends_len = parser.ast.extra_data.items[iface.data.extra + 3];
    try std.testing.expectEqual(@as(u32, 0), extends_len);
}

test "Parser: TS enum" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\enum Color {
        \\  Red,
        \\  Green = 10,
        \\  Blue
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS namespace" {
    var scanner = try Scanner.init(std.testing.allocator, "namespace Utils { const x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS declare" {
    var scanner = try Scanner.init(std.testing.allocator, "declare const VERSION: string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS abstract class" {
    var scanner = try Scanner.init(std.testing.allocator, "abstract class Shape { abstract area(): number; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type parameter with constraint and default" {
    var scanner = try Scanner.init(std.testing.allocator, "type Foo<T extends string = 'hello'> = T;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS parameter property" {
    var scanner = try Scanner.init(std.testing.allocator, "class Foo { constructor(public x: number, private y: string) { } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class" {
    var scanner = try Scanner.init(std.testing.allocator, "@Component class Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator with arguments" {
    var scanner = try Scanner.init(std.testing.allocator, "@Injectable() class Service { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class member" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  public greet(): void { }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class implements" {
    var scanner = try Scanner.init(std.testing.allocator, "class Foo implements Bar, Baz { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: static readonly member" {
    var scanner = try Scanner.init(std.testing.allocator, "class Foo { static readonly MAX = 100; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with generics" {
    var scanner = try Scanner.init(std.testing.allocator, "class Box<T> { value: T; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// JSX tests
// ============================================================

test "Parser: JSX self-closing element" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = <br />;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX element with children" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const x = <div>hello</div>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with attributes" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const x = <div className="foo" id="bar" />;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with expression" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const x = <span>{name}</span>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// --- JSX: children 모드 복원 (closing tag 뒤 텍스트) ---

fn parseJSXOk(source: []const u8) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "Parser: JSX text after closing child" {
    try parseJSXOk("const x = <p><code>x</code> text</p>;");
}

test "Parser: JSX text between two children" {
    try parseJSXOk("const x = <p><b>a</b> and <i>b</i></p>;");
}

test "Parser: JSX multiple inline code elements" {
    try parseJSXOk("const x = <p>Edit <code>src/App.tsx</code> and save to test <code>HMR</code></p>;");
}

test "Parser: JSX self-closing child then text" {
    try parseJSXOk("const x = <p><br /> hello</p>;");
}

test "Parser: JSX fragment with mixed children" {
    try parseJSXOk("const x = <>text <b>bold</b> more</>;");
}

test "Parser: JSX nested fragment" {
    try parseJSXOk("const x = <div><>a<b>x</b>c</></div>;");
}

test "Parser: JSX deeply nested text" {
    try parseJSXOk("const x = <div><ul><li><a href=\"#\">link</a> desc</li></ul></div>;");
}

test "Parser: JSX sibling elements" {
    try parseJSXOk("const x = <><h1>title</h1><p>body</p></>;");
}

test "Parser: JSX expression between elements" {
    try parseJSXOk("const x = <p>count: {n} items</p>;");
}

test "Parser: JSX SVG with use" {
    try parseJSXOk("const x = <svg className=\"icon\"><use href=\"/icons.svg#doc\" /></svg>;");
}

test "Parser: JSX multiline attributes" {
    try parseJSXOk(
        \\const x = <button
        \\  className="counter"
        \\  onClick={() => console.log('hi')}
        \\>
        \\  Click
        \\</button>;
    );
}

test "Parser: JSX Vite-style complex template" {
    try parseJSXOk(
        \\function App() {
        \\  return (
        \\    <>
        \\      <section id="center">
        \\        <div className="hero">
        \\          <img src="a.png" className="base" width="170" alt="" />
        \\        </div>
        \\        <h1>Vite + React</h1>
        \\        <div className="card">
        \\          <button onClick={() => console.log('x')}>
        \\            count is {0}
        \\          </button>
        \\        </div>
        \\      </section>
        \\      <div className="ticks"></div>
        \\      <section id="next-steps">
        \\        <svg className="icon" role="presentation">
        \\          <use href="/icons.svg#doc" />
        \\        </svg>
        \\        <h2>Documentation</h2>
        \\        <p>Edit <code>src/App.tsx</code> and save to test <code>HMR</code></p>
        \\        <ul>
        \\          <li>
        \\            <a href="https://react.dev/" target="_blank">
        \\              Learn React
        \\            </a>
        \\          </li>
        \\        </ul>
        \\      </section>
        \\    </>
        \\  );
        \\}
    );
}

test "Parser: function call with division in args" {
    // arrow lookahead가 prev_token_kind를 복구하지 않으면
    // / 가 regex로 해석되어 실패하던 버그 테스트
    const source = "truncate(x / y)";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ================================================================
// 컨텍스트 검증 테스트 (D051)
// ================================================================

test "Parser: return outside function is error" {
    var scanner = try Scanner.init(std.testing.allocator, "return 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: return inside function is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "function f() { return 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: return inside arrow function is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = () => { return 1; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break outside loop/switch is error" {
    var scanner = try Scanner.init(std.testing.allocator, "break;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: break inside loop is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "while (true) { break; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break inside switch is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "function f(x) { switch (x) { case 1: break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: continue outside loop is error" {
    var scanner = try Scanner.init(std.testing.allocator, "continue;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'continue' outside of loop", parser.errors.items[0].message);
}

test "Parser: continue inside for loop is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "for (var i = 0; i < 10; i++) { continue; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break in nested function inside loop is error" {
    // 함수 경계에서 loop 컨텍스트가 리셋되므로, 내부 함수의 break는 에러
    var scanner = try Scanner.init(std.testing.allocator, "while (true) { function f() { break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: with statement in strict mode is error" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\"use strict";
        \\with (obj) { x; }
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

test "Parser: with statement in non-strict mode is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: use strict in function body" {
    // 함수 내부 "use strict"가 strict mode를 설정하는지 확인
    var scanner = try Scanner.init(std.testing.allocator,
        \\function f() {
        \\  "use strict";
        \\  with (obj) { x; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

test "Parser: module mode is always strict" {
    var scanner = try Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

// ================================================================
// 예약어 검증 테스트
// ================================================================

test "Parser: reserved word as variable name is error" {
    var scanner = try Scanner.init(std.testing.allocator, "var var = 123;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in strict mode is error" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\"use strict";
        \\var implements = 1;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in non-strict is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "var implements = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: let as variable name is valid in non-strict" {
    var scanner = try Scanner.init(std.testing.allocator, "var let = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// 검증 로직 유닛 테스트
// ============================================================

test "Parser: ++this is invalid assignment target" {
    var scanner = try Scanner.init(std.testing.allocator, "++this;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: delete identifier in strict mode is error" {
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; delete x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: const without initializer is error" {
    var scanner = try Scanner.init(std.testing.allocator, "const x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: for-of const without init is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "for (const x of [1]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import/export only at module top-level" {
    // import in function body — error even in module
    var scanner = try Scanner.init(std.testing.allocator, "function f() { import 'x'; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: function in loop body is error" {
    var scanner = try Scanner.init(std.testing.allocator, "for (;;) function f() {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: yield is identifier outside generator" {
    var scanner = try Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is identifier in script mode" {
    var scanner = try Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is reserved in module mode" {
    var scanner = try Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: super outside method is error" {
    var scanner = try Scanner.init(std.testing.allocator, "super.x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: new.target outside function is error" {
    var scanner = try Scanner.init(std.testing.allocator, "new.target;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: object shorthand reserved word is error" {
    var scanner = try Scanner.init(std.testing.allocator, "({true});");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional chaining is not assignment target" {
    var scanner = try Scanner.init(std.testing.allocator, "x?.y = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: parenthesized destructuring is not assignment target" {
    var scanner = try Scanner.init(std.testing.allocator, "({}) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: arguments in class field initializer is error" {
    // class field에서 arguments 직접 사용 — SyntaxError
    {
        var scanner = try Scanner.init(std.testing.allocator, "var C = class { x = arguments; };");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len > 0);
    }
    // arrow function 안에서 arguments 사용 — arrow는 자체 arguments가 없으므로 SyntaxError
    {
        var scanner = try Scanner.init(std.testing.allocator, "class C { x = () => arguments; }");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len > 0);
    }
    // 일반 function 안에서 arguments 사용 — 자체 arguments 바인딩이 있으므로 OK
    {
        var scanner = try Scanner.init(std.testing.allocator, "class C { x = function() { return arguments; }; }");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len == 0);
    }
}

// ============================================================
// Cover Grammar 유닛 테스트
// ============================================================

test "CoverGrammar: rest element with initializer in array destructuring" {
    // [...x = 1] = arr → rest에 initializer 금지
    var scanner = try Scanner.init(std.testing.allocator, "[...x = 1] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    // "rest element may not have a default initializer" 에러가 포함되어야 함
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CoverGrammar: valid array destructuring" {
    // [a, b, ...c] = arr → 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "[a, b, ...c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "CoverGrammar: valid object destructuring" {
    // ({ a, b: c } = obj) → 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "({ a, b: c } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "CoverGrammar: strict mode eval assignment" {
    // "use strict"; eval = 1 → 에러
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; eval = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: parenthesized destructuring is invalid" {
    // ([x]) = 1 → parenthesized destructuring 금지
    var scanner = try Scanner.init(std.testing.allocator, "([x]) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: for-in with rest-init is error" {
    // for ([...x = 1] in obj) {} → rest-init 금지
    var scanner = try Scanner.init(std.testing.allocator, "for ([...x = 1] in obj) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CoverGrammar: arrow params rest-init is error" {
    // ([...x = 1]) => {} → rest-init 금지
    var scanner = try Scanner.init(std.testing.allocator, "([...x = 1]) => {};");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ================================================================
// 에러 메시지 품질 회귀 테스트
// oxc/swc 수준의 친절한 에러 메시지가 유지되는지 검증한다.
// ================================================================

/// 테스트 헬퍼: 특정 message를 가진 에러가 있는지 확인한다.
/// 추가로 found, related_label, hint 필드를 검증할 수 있다.
const ErrorCheck = struct {
    /// 에러 message (정확 일치)
    message: ?[]const u8 = null,
    /// 에러 message (부분 일치)
    message_contains: ?[]const u8 = null,
    /// found 필드가 non-null이어야 하는지
    has_found: ?bool = null,
    /// related_span이 non-null이어야 하는지
    has_related_span: ?bool = null,
    /// related_label 기대값 (정확 일치)
    related_label: ?[]const u8 = null,
    /// hint가 non-null이어야 하는지
    has_hint: ?bool = null,
    /// hint 기대값 (정확 일치)
    hint: ?[]const u8 = null,
};

/// 테스트 헬퍼: 소스를 파싱하고 조건에 맞는 에러가 있는지 검증한다.
fn expectParseError(source: []const u8, check: ErrorCheck) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);

    for (parser.errors.items) |err| {
        const msg_match = if (check.message) |m| std.mem.eql(u8, err.message, m) else true;
        const contains_match = if (check.message_contains) |c| std.mem.indexOf(u8, err.message, c) != null else true;
        if (!msg_match or !contains_match) continue;

        // message 매칭된 에러를 찾음 — 나머지 필드 검증
        if (check.has_found) |hf| try std.testing.expectEqual(hf, err.found != null);
        if (check.has_related_span) |hr| try std.testing.expectEqual(hr, err.related_span != null);
        if (check.related_label) |rl| {
            try std.testing.expect(err.related_label != null);
            try std.testing.expectEqualStrings(rl, err.related_label.?);
        }
        if (check.has_hint) |hh| try std.testing.expectEqual(hh, err.hint != null);
        if (check.hint) |h| {
            try std.testing.expect(err.hint != null);
            try std.testing.expectEqualStrings(h, err.hint.?);
        }
        return; // 검증 성공
    }
    // 매칭되는 에러를 못 찾음
    return error.TestUnexpectedResult;
}

/// 테스트 헬퍼: 소스를 파싱하고 에러가 없는지 검증한다.
fn expectNoParseError(source: []const u8) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "ErrorMsg: expect() shows 'found' token" {
    // `if (true]` → Expected ')' but found ']'
    try expectParseError("if (true]", .{ .message = ")", .has_found = true });
}

test "ErrorMsg: expect() shows found for curly brace" {
    // `if (true) {` → EOF에서 '}' 기대
    try expectParseError("if (true) {", .{ .message = "}", .has_found = true });
}

test "ErrorMsg: bracket matching shows related_span for paren" {
    // `function f(a, b ]` → Expected ')' but found ']', opening '(' is here
    try expectParseError("function f(a, b ]", .{
        .message = ")",
        .has_related_span = true,
        .related_label = "opening '(' is here",
    });
}

test "ErrorMsg: bracket matching shows related_span for curly" {
    // `if (true) { var x = 1;` → EOF에서 '}' 기대, opening '{' is here
    try expectParseError("if (true) { var x = 1;", .{
        .message = "}",
        .has_related_span = true,
        .related_label = "opening '{' is here",
    });
}

test "ErrorMsg: bracket matching shows related_span for bracket" {
    // `var a = [1, 2` → EOF에서 ']' 기대, opening '[' is here
    try expectParseError("var a = [1, 2", .{
        .message = "]",
        .has_related_span = true,
        .related_label = "opening '[' is here",
    });
}

test "ErrorMsg: expectSemicolon shows found and hint" {
    // `var x = 1 var y = 2` → Expected ';' but found 'var', hint: Try inserting...
    try expectParseError("var x = 1 var y = 2", .{
        .message = ";",
        .has_found = true,
        .hint = "Try inserting a semicolon here",
    });
}

test "ErrorMsg: ASI still works with newline (no false error)" {
    try expectNoParseError("var x = 1\nvar y = 2");
}

test "ErrorMsg: ASI still works with closing curly (no false error)" {
    try expectNoParseError("function f() { return 1 }");
}

test "ErrorMsg: addError backward compat (no found/hint)" {
    // 기존 addError로 추가된 에러는 found, hint가 null
    try expectParseError("'use strict'; with (obj) {}", .{
        .message_contains = "with",
        .has_found = false,
        .has_hint = false,
    });
}

test "ErrorMsg: multiple errors all have proper fields" {
    var scanner = try Scanner.init(std.testing.allocator, "function( { ) }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    for (parser.errors.items) |err| {
        try std.testing.expect(err.message.len > 0);
    }
}

test "ErrorMsg: nested brackets track correctly" {
    // 중첩 괄호: `if ([1, (2` → 에러에 related_span이 하나 이상 존재
    var scanner = try Scanner.init(std.testing.allocator, "if ([1, (2");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    var has_related = false;
    for (parser.errors.items) |err| {
        if (err.related_span != null) {
            has_related = true;
            break;
        }
    }
    try std.testing.expect(has_related);
}

test "ErrorMsg: valid code has no errors (regression)" {
    // 정상 코드는 에러가 없어야 함 — 새 기능이 false positive를 만들지 않는지
    const cases = [_][]const u8{
        "const x = [1, 2, 3];",
        "function f(a, b) { return a + b; }",
        "if (true) { console.log('yes'); } else { console.log('no'); }",
        "for (let i = 0; i < 10; i++) { }",
        "const obj = { a: 1, b: [2, 3], c: { d: 4 } };",
        "class Foo { constructor() { this.x = 1; } }",
        "const arrow = (x) => x * 2;",
        "try { throw new Error(); } catch (e) { } finally { }",
        "switch (x) { case 1: break; default: break; }",
    };
    for (cases) |src| {
        try expectNoParseError(src);
    }
}

// ================================================================
// Diagnostic 통합 + 예약어 검증 테스트
// ================================================================

test "Diagnostic: parser errors have kind=parse" {
    var scanner = try Scanner.init(std.testing.allocator, "var 123bad;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqual(Diagnostic.Kind.parse, parser.errors.items[0].kind);
}

test "ReservedWord: escaped keyword in variable binding is error" {
    // \u0066or → "for" (reserved keyword)
    try expectParseError("var \\u0066or = 1;", .{
        .message_contains = "Escape",
    });
}

test "ReservedWord: escaped strict reserved in strict mode binding is error" {
    // \u006Cet → "let" (strict mode reserved)
    try expectParseError("'use strict'; var \\u006Cet = 1;", .{
        .message_contains = "Escape",
    });
}

test "ReservedWord: escaped strict reserved in sloppy mode is OK" {
    // escaped strict reserved in sloppy mode → allowed
    try expectNoParseError("var \\u006Cet = 1;");
}

test "ReservedWord: escaped eval in strict mode assignment is error" {
    // \u0065val → "eval" — strict mode에서 assignment target 불가
    try expectParseError("'use strict'; \\u0065val = 1;", .{
        .message_contains = "eval",
    });
}

test "ReservedWord: property name can use escaped keyword" {
    // property name에서는 escaped keyword 허용 (ECMAScript IdentifierName)
    try expectNoParseError("var obj = { \\u0066or: 1 };");
}

test "ReservedWord: escaped keyword as property access is OK" {
    // member expression에서 escaped keyword는 허용
    try expectNoParseError("obj.\\u0066or;");
}

// ============================================================
// TS Arrow Function with Type Annotations (#286)
// ============================================================

test "TS arrow: basic typed params" {
    try expectNoParseError("const add = (a: number, b: number) => a + b;");
}

test "TS arrow: return type annotation" {
    try expectNoParseError("const f = (x: string): string => x.toUpperCase();");
}

test "TS arrow: optional param" {
    try expectNoParseError("const g = (a: number, b?: string) => a;");
}

test "TS arrow: destructuring with type" {
    try expectNoParseError("const f = ({x}: {x: number}) => x;");
}

test "TS arrow: rest param with type" {
    try expectNoParseError("const f = (...args: number[]) => args;");
}

test "TS arrow: async with types" {
    try expectNoParseError("const f = async (a: number): Promise<number> => a;");
}

test "TS arrow: empty params with return type" {
    try expectNoParseError("const f = (): void => {};");
}

test "TS arrow: contextual keyword as param name (get/set/number)" {
    // contextual keyword는 import default specifier와 arrow param 모두에서 식별자로 유효
    try expectNoParseError("const f = (get: number) => get;");
    try expectNoParseError("const f = (set: string) => set;");
    try expectNoParseError("const f = (number: number) => number;");
    try expectNoParseError("const f = (string: string) => string;");
    try expectNoParseError("const f = (object: any) => object;");
}

test "TS arrow: non-arrow parenthesized expression still works" {
    // TS arrow가 아닌 일반 괄호 표현식 — 기존 동작 유지
    try expectNoParseError("const x = (1 + 2) * 3;");
    try expectNoParseError("const x = (a);");
    try expectNoParseError("const x = (a, b);");
}

test "TS arrow: plain JS arrow still works" {
    try expectNoParseError("const f = (x, y) => x + y;");
    try expectNoParseError("const f = x => x;");
    try expectNoParseError("const f = () => 42;");
}

// ============================================================
// TS arrow function edge cases
// ============================================================

test "TS arrow: default value with type" {
    try expectNoParseError("const f = (x: number = 10) => x;");
}

test "TS arrow: nested arrow with types" {
    try expectNoParseError("const f = (x: number) => (y: string) => x + y;");
}

test "TS arrow: trailing comma" {
    try expectNoParseError("const f = (a: number, b: string,) => a;");
}

test "TS arrow: complex union type param" {
    try expectNoParseError("const f = (x: string | number) => x;");
}

test "TS arrow: IIFE with types" {
    try expectNoParseError("((a: number) => a + 1)(5);");
}

test "TS arrow: return type object literal" {
    try expectNoParseError("const f = (x: number): {a: number} => ({a: x});");
}

// ============================================================
// Contextual keyword binding edge cases
// ============================================================

test "binding: type/from/of/as/async as function params" {
    try expectNoParseError("function f(type, from, of, as) { return type + from + of + as; }");
    try expectNoParseError("function f(async) { return async; }");
}

test "binding: nested destructuring with defaults" {
    try expectNoParseError("const { a = 1, b = 2 } = {};");
    try expectNoParseError("const { a: { b } } = { a: { b: 1 } };");
    try expectNoParseError("const [a, , b] = [1, 2, 3];");
}

test "binding: contextual keyword as catch param" {
    try expectNoParseError("try {} catch (type) { console.log(type); }");
    try expectNoParseError("try {} catch (from) { console.log(from); }");
}

test "binding: contextual keyword as for-of variable" {
    // contextual keywords as for-of binding
    try expectNoParseError("for (const type of [1,2,3]) { console.log(type); }");
    try expectNoParseError("for (const get of [1,2,3]) { console.log(get); }");
}

// ============================================================
// static_member_expression span 테스트
// ============================================================

test "Parser: static_member_expression span excludes trailing whitespace" {
    // "a.b ;" — span은 0..3 ("a.b"), 공백과 세미콜론 포함 안 함
    var scanner = try Scanner.init(std.testing.allocator, "a.b ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // AST에서 static_member_expression 노드를 찾아 span 검증
    var found = false;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .static_member_expression) {
            // span.start == 0 ("a"의 시작), span.end == 3 ("b"의 끝)
            try std.testing.expectEqual(@as(u32, 0), node.span.start);
            try std.testing.expectEqual(@as(u32, 3), node.span.end);
            // 소스 텍스트로도 검증
            try std.testing.expectEqualStrings("a.b", parser.ast.source[node.span.start..node.span.end]);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Parser: chained static_member_expression span" {
    // "a.b.c ;" — 외부 static_member_expression의 span은 0..5 ("a.b.c")
    var scanner = try Scanner.init(std.testing.allocator, "a.b.c ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // 체인이므로 static_member_expression이 2개 있어야 함:
    //   내부: a.b (0..3), 외부: a.b.c (0..5)
    var count: usize = 0;
    var has_inner = false;
    var has_outer = false;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .static_member_expression) {
            count += 1;
            const text = parser.ast.source[node.span.start..node.span.end];
            if (std.mem.eql(u8, text, "a.b")) has_inner = true;
            if (std.mem.eql(u8, text, "a.b.c")) has_outer = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(has_inner);
    try std.testing.expect(has_outer);
}

test "Parser: static_member_expression text matches source exactly" {
    // "process.env.NODE_ENV ;" 에서
    // source[span.start..span.end] == "process.env.NODE_ENV" (공백 없이)
    var scanner = try Scanner.init(std.testing.allocator, "process.env.NODE_ENV ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // 가장 바깥 static_member_expression (span이 가장 넓은 것)의 텍스트를 검증
    var max_span_len: u32 = 0;
    var max_span_text: []const u8 = "";
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .static_member_expression) {
            const len = node.span.end - node.span.start;
            if (len > max_span_len) {
                max_span_len = len;
                max_span_text = parser.ast.source[node.span.start..node.span.end];
            }
        }
    }
    // define 매칭에 사용되는 getNodeText가 정확한 텍스트를 반환하는지 검증
    // 공백이 포함되지 않아야 함
    try std.testing.expectEqualStrings("process.env.NODE_ENV", max_span_text);
}

// ============================================================
// Destructuring default values in arrow params (cover grammar)
// ============================================================

test "CoverGrammar: arrow param destructuring with boolean defaults" {
    // { x = false, y = false } — false/true/null은 default value이지 param name이 아님
    try expectNoParseError("const f = (s, { x = false, y = false } = {}) => s;");
    try expectNoParseError("const f = (s, { x = true, y = true } = {}) => s;");
    try expectNoParseError("const f = (s, { x = null, y = null } = {}) => s;");
}

test "CoverGrammar: arrow param destructuring with identifier defaults" {
    // { x = a, y = a } — a는 default value 참조이지 param name이 아님
    try expectNoParseError("const f = (s, { x = a, y = a } = {}) => s;");
    try expectNoParseError("const f = ({ x = foo, y = foo } = {}) => s;");
}

test "CoverGrammar: arrow param destructuring with number defaults" {
    try expectNoParseError("const f = (s, { x = 1, y = 2 } = {}) => s;");
}

test "CoverGrammar: actual duplicate param names are still detected" {
    // 실제 중복 파라미터는 에러가 나야 함
    try expectParseError("const f = (x, { x } = {}) => s;", .{ .message = "Duplicate parameter name" });
}

test "CoverGrammar: arrow param single destructuring with defaults" {
    // 단일 파라미터 (sequence가 아닌 경우)
    try expectNoParseError("const f = ({ x = false, y = false } = {}) => s;");
    try expectNoParseError("const f = ({ x = false, y = false }) => s;");
}

test "CoverGrammar: literal keywords parsed as boolean_literal not identifier" {
    // true/false/null이 expression 위치에서 올바른 리터럴 노드로 파싱되는지 검증
    try expectNoParseError("const a = true;");
    try expectNoParseError("const b = false;");
    try expectNoParseError("const c = null;");
    try expectNoParseError("const obj = { true: 1, false: 2, null: 3 };");
}

// ================================================================
// 제네릭 토큰 분할 테스트 (>> → > + >, >= → > + = 등)
// ================================================================

test "TokenSplit: nested generic >> splits to > + >" {
    // Array<Array<number>> — >> 가 > > 로 분할되어야 함
    try expectNoParseError("let x: Array<Array<number>>");
}

test "TokenSplit: triple nested generic >>> splits correctly" {
    // A<B<C<number>>> — >>> 가 > > > 로 분할
    try expectNoParseError("let x: A<B<C<number>>>");
}

test "TokenSplit: >= splits to > + = in arrow return type" {
    // (): A<T>=> 0 — >= 가 > = 로 분할, arrow function으로 파싱
    try expectNoParseError("(): A<T>=> 0");
}

test "TokenSplit: nested generic in return type" {
    try expectNoParseError("let x: () => A<B<T>>");
}

test "TokenSplit: type assertion with nested generic" {
    // <Array<number>>expr — >> 분할 후 type assertion
    try expectNoParseError("let x = <Array<number>>y");
}

test "TokenSplit: generic type arguments with nested generics" {
    try expectNoParseError("type Foo = Map<string, Array<number>>");
    try expectNoParseError("type Bar = Promise<Map<string, Set<number>>>");
}

test "TokenSplit: generic function return type with nested generic" {
    try expectNoParseError("function foo(): Array<Array<number>> { return []; }");
}

test "TokenSplit: interface with nested generic members" {
    try expectNoParseError("interface Foo { bar: Map<string, Array<number>> }");
}

test "TokenSplit: type alias with conditional + nested generic" {
    try expectNoParseError("type Foo<T> = T extends Array<Array<number>> ? T : never");
}

// === yield identifier validation tests ===

test "yield: identifier in generator body should error" {
    // `void yield` in generator — yield is IdentifierReference, not YieldExpression
    // ECMAScript: IdentifierReference[Yield] cannot be "yield"
    var scanner = try Scanner.init(std.testing.allocator, "function *gen() { void yield; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    // Should have at least one error about yield
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: in strict mode should error" {
    var scanner = try Scanner.init(std.testing.allocator, "yield;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_strict_mode = true;
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: in sloppy mode should be fine" {
    var scanner = try Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "yield: expression in generator should be fine" {
    var scanner = try Scanner.init(std.testing.allocator, "function *gen() { yield 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "yield: destructuring in strict mode should error" {
    var scanner = try Scanner.init(std.testing.allocator, "for ([ x = yield ] of [[]]) ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_strict_mode = true;
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: as parameter name in generator should error" {
    // yield as parameter name in generator is forbidden
    var scanner = try Scanner.init(std.testing.allocator, "function *gen(yield) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: in module code should error" {
    // module code is always strict, so yield as identifier is forbidden
    var scanner = try Scanner.init(std.testing.allocator, "var x = yield;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;
    parser.is_strict_mode = true; // module is always strict
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: typeof yield in generator should error" {
    var scanner = try Scanner.init(std.testing.allocator, "function *gen() { typeof yield; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: as variable name in strict mode should error" {
    var scanner = try Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_strict_mode = true;
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: arrow destructuring duplicate params" {
    try expectParseError("([x, x]) => 1", .{ .message = "Duplicate parameter name" });
}

test "CoverGrammar: arrow destructuring duplicate params - object" {
    try expectParseError("({y: x, x}) => 1", .{ .message = "Duplicate parameter name" });
    try expectParseError("({a: x, b: x}) => 1", .{ .message = "Duplicate parameter name" });
    try expectParseError("({x, ...x}) => 1", .{ .message = "Duplicate parameter name" });
}

test "rest params trailing comma: arrow" {
    try expectParseError("(...a,) => {}", .{ .message_contains = "Rest parameter must be last formal parameter" });
}

test "rest params trailing comma: async arrow" {
    try expectParseError("async (...a,) => {}", .{ .message_contains = "Rest parameter must be last formal parameter" });
}

// === using / await using declaration tests ===

test "using declaration: basic" {
    try expectNoParseError("{ using x = getResource(); }");
}

test "using as identifier: assignment" {
    try expectNoParseError("using = 1;");
}

test "using as identifier: var declaration" {
    try expectNoParseError("var using = 1;");
}

test "using as identifier: function name" {
    try expectNoParseError("function using() {}");
}

test "await using in module top-level" {
    // module top-level에서 await using은 허용 (top-level await)
    var scanner = try Scanner.init(std.testing.allocator, "await using x = { };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;
    scanner.is_module = true;

    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "await using in async function" {
    try expectNoParseError("async function f() { await using x = getResource(); }");
}

// === accessor as identifier tests ===

test "accessor as identifier: var declaration" {
    try expectNoParseError("var accessor;");
}

test "accessor as identifier: let declaration" {
    try expectNoParseError("let accessor;");
}

test "accessor as identifier: const declaration" {
    try expectNoParseError("const accessor = null;");
}

test "accessor as identifier: function name" {
    try expectNoParseError("function accessor() {}");
}

test "accessor as identifier: function parameter" {
    try expectNoParseError("function foo(accessor) {}");
}

test "accessor as identifier: assignment" {
    try expectNoParseError("var accessor; accessor = 1;");
}

test "accessor as class field name" {
    // accessor;  accessor = 42;  accessor() {} — 일반 멤버 이름으로 사용
    try expectNoParseError("class C { accessor; }");
    try expectNoParseError("class C { accessor = 42; }");
    try expectNoParseError("class C { accessor() { return 42; } }");
}

test "accessor with newline in class body" {
    // accessor 뒤에 줄바꿈이 있으면 ASI → accessor는 필드 이름
    try expectNoParseError(
        \\class C {
        \\  accessor
        \\  a = 42;
        \\}
    );
}

test "accessor static with newline in class body" {
    // static accessor\n static a = 42; → accessor는 필드 이름
    try expectNoParseError(
        \\class C {
        \\  static accessor
        \\  static a = 42;
        \\}
    );
}

// ============================================================
// declare module ambient body: export/import 허용
// ============================================================

fn expectNoParseErrorWithExt(source: []const u8, ext: []const u8) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(ext);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

fn expectNoParseErrorBundler(source: []const u8, ext: []const u8) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.configureForBundler(ext);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "declare module: export inside ambient module body" {
    try expectNoParseErrorWithExt(
        \\declare module "*.css" { export default css; }
    , ".ts");
}

test "declare module: multiple statements in ambient body" {
    try expectNoParseErrorWithExt(
        \\declare module "*.svg" { const src: string; export default src; }
    , ".ts");
}

test "declare module: export in bundler mode" {
    try expectNoParseErrorBundler(
        \\declare module "*.css" { export default css; }
    , ".ts");
}

test "declare module: named exports in ambient body" {
    try expectNoParseErrorWithExt(
        \\declare module "*.module.css" {
        \\  const classes: { readonly [key: string]: string };
        \\  export default classes;
        \\}
    , ".ts");
}

// ============================================================
// JSX attribute {expr} + self-closing: regex 오스캔 방지
// ============================================================

test "JSX attr expr: self-closing in bundler mode" {
    try expectNoParseErrorBundler(
        \\function App() { return <Badge count={3} />; }
    , ".tsx");
}

test "JSX attr expr: siblings in bundler mode" {
    try expectNoParseErrorBundler(
        \\const x = <div><A a={1} /><B /></div>;
    , ".tsx");
}

test "JSX attr expr: nested components in bundler mode" {
    try expectNoParseErrorBundler(
        \\function App() {
        \\  return (
        \\    <div className={"app"}>
        \\      <Badge count={3} visible={true} />
        \\      <span>{3}</span>
        \\    </div>
        \\  );
        \\}
    , ".tsx");
}

test "JSX attr expr: self-closing in CLI mode" {
    try expectNoParseErrorWithExt(
        \\function App() { return <Badge count={3} />; }
    , ".tsx");
}

// ============================================================
// Flow + JSX 분리: --flow는 JSX를 활성화하지 않음 (Babel 동일)
// --jsx-in-js 또는 --platform=react-native가 .js에서 JSX를 활성화
// ============================================================

const FlowTestOpts = struct { jsx: bool = false, expect_error: bool = false };

fn expectFlowParseResult(source: []const u8, opts: FlowTestOpts) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_flow = true;
    parser.is_jsx = opts.jsx;
    scanner.has_flow_pragma = true;
    parser.is_module = true;
    scanner.is_module = true;
    parser.is_unambiguous = true;
    _ = try parser.parse();
    if (opts.expect_error) {
        try std.testing.expect(parser.errors.items.len > 0);
    } else {
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    }
}

fn expectNoParseErrorFlow(source: []const u8) !void {
    return expectFlowParseResult(source, .{});
}

fn expectNoParseErrorFlowJSX(source: []const u8) !void {
    return expectFlowParseResult(source, .{ .jsx = true });
}

fn expectParseErrorFlow(source: []const u8) !void {
    return expectFlowParseResult(source, .{ .expect_error = true });
}

// --- Flow 단독 (JSX 비활성) ---

test "Flow: type annotation stripped without JSX" {
    try expectNoParseErrorFlow("function foo(x: string): number { return 1; }");
}

test "Flow: nullable generic type" {
    try expectNoParseErrorFlow("var x: ?Array<number> = null;");
}

test "Flow: union type in parameter" {
    try expectNoParseErrorFlow("function f(x: string | number): void {}");
}

test "Flow: inexact object type in parameter" {
    try expectNoParseErrorFlow("function f(props: {name: string, ...}): void {}");
}

test "Flow: optional parameter with nullable" {
    try expectNoParseErrorFlow("function f(x?: ?boolean): void {}");
}

test "Flow: import type statement" {
    try expectNoParseErrorFlow("import type {Foo} from './foo';");
}

test "Flow: export type statement" {
    try expectNoParseErrorFlow("export type {Foo} from './foo';");
}

test "Flow: class with generic extends" {
    try expectNoParseErrorFlow(
        \\class MyList<T> extends React.Component<Props<T>> {
        \\  render() { return null; }
        \\}
    );
}

test "Flow: JSX rejected without is_jsx" {
    try expectParseErrorFlow("const x = <div />;");
}

// --- Flow + JSX (--jsx-in-js 또는 --platform=react-native) ---

test "Flow+JSX: basic element" {
    try expectNoParseErrorFlowJSX("const x = <div />;");
}

test "Flow+JSX: component with typed props" {
    try expectNoParseErrorFlowJSX(
        \\import * as React from 'react';
        \\function App(props: {name: string}): React.Node {
        \\  return <div>{props.name}</div>;
        \\}
    );
}

test "Flow+JSX: class component with generics" {
    try expectNoParseErrorFlowJSX(
        \\import * as React from 'react';
        \\class ImageBackground extends React.Component<{style: any}> {
        \\  render(): React.Node {
        \\    return <View style={this.props.style} />;
        \\  }
        \\}
    );
}

test "Flow+JSX: arrow with typed params returning JSX" {
    try expectNoParseErrorFlowJSX(
        \\const App = (props: {count: number}): any => {
        \\  return <span>{props.count}</span>;
        \\};
    );
}

test "Flow+JSX: nullable ref type in class" {
    try expectNoParseErrorFlowJSX(
        \\import * as React from 'react';
        \\class C extends React.Component<{}> {
        \\  _ref: ?React.ElementRef<any> = null;
        \\  _capture = (ref: null | Object) => { this._ref = ref; };
        \\  render(): React.Node { return <div ref={this._capture} />; }
        \\}
    );
}

// ============================================================
// Flow Component/Hook Syntax
// ============================================================

test "Flow: component declaration" {
    try expectNoParseErrorFlow(
        \\component Greeting(name: string) {
        \\  return name;
        \\}
    );
}

test "Flow+JSX: component with JSX body" {
    try expectNoParseErrorFlowJSX(
        \\component View(ref?: any, ...props: any) {
        \\  return <div {...props} />;
        \\}
    );
}

test "Flow: component with renders clause" {
    try expectNoParseErrorFlowJSX(
        \\component App(name: string) renders React.Node {
        \\  return <div>{name}</div>;
        \\}
    );
}

test "Flow: component with generics" {
    try expectNoParseErrorFlow(
        \\component List<T>(items: Array<T>) {
        \\  return null;
        \\}
    );
}

test "Flow: hook declaration" {
    try expectNoParseErrorFlow(
        \\hook useCounter(initial: number) {
        \\  return initial;
        \\}
    );
}

test "Flow: component type annotation" {
    try expectNoParseErrorFlow(
        \\const Foo: component(ref?: any, ...props: Props) = (props) => null;
    );
}

test "Flow: declare component" {
    try expectNoParseErrorFlow(
        \\declare component Foo(name: string) renders React.Node;
    );
}

// ============================================================
// Flow Indexed Access Type
// ============================================================

test "Flow: indexed access type" {
    try expectNoParseErrorFlow("var x: Props['key'] = null;");
}

test "Flow: nullable indexed access type" {
    try expectNoParseErrorFlow("var x: ?TextProps['accessibilityState'] = null;");
}

test "Flow: indexed access type with string literal" {
    try expectNoParseErrorFlow(
        \\const f = (x: ScrollViewMethods['scrollTo']): void => {};
    );
}

// ============================================================
// JSX Spread Attribute (regex 오스캔 수정)
// ============================================================

test "JSX spread attribute in function body" {
    try expectNoParseErrorWithExt(
        \\function View(props: any) {
        \\  return <ViewNative {...props} />;
        \\}
    , ".tsx");
}

test "JSX spread + regular attributes" {
    try expectNoParseErrorWithExt(
        \\function View(props: any) {
        \\  return <Comp {...props} extra={true} />;
        \\}
    , ".tsx");
}

// ============================================================
// Flow 함수 타입 파라미터
// ============================================================

test "Flow: function type with named params" {
    try expectNoParseErrorFlow("type F = (t: number) => number;");
}

test "Flow: function type with optional param" {
    try expectNoParseErrorFlow("type F = (callback?: ?Function) => void;");
}

test "Flow: function type with multiple params" {
    try expectNoParseErrorFlow("type F = (id: number, value: string) => void;");
}

test "Flow: shorthand function type with identifier" {
    try expectNoParseErrorFlow("type F = AnimatedNode => number;");
}

test "Flow: shorthand function type with keyword type" {
    try expectNoParseErrorFlow("type F = string => void;");
}

test "Flow: return type any does not trigger shorthand" {
    try expectNoParseErrorFlowJSX(
        \\const App = (props: {count: number}): any => {
        \\  return <span>{props.count}</span>;
        \\};
    );
}

test "Flow: generic extends constraint" {
    try expectNoParseErrorFlow(
        \\class C {
        \\  foo<T extends number | string>(x: T): T { return x; }
        \\}
    );
}

test "Flow: nested paren function type" {
    try expectNoParseErrorFlow("type X = ((err: Error) => void);");
}

test "Flow: union with paren function type" {
    try expectNoParseErrorFlow("type X = Function | ((err: Error) => void);");
}

test "Flow: conditional type" {
    try expectNoParseErrorFlow("type X<T> = T extends string ? number : boolean;");
}

test "Flow: positional function type params" {
    // () => T as positional param
    try expectNoParseErrorFlow("type X = (() => AnimatedProps, props: $ReadOnly<{[string]: mixed}>) => AnimatedProps;");
    // generic function type as positional param
    try expectNoParseErrorFlow("type X = (<T>(x: T) => T, y: number) => void;");
    // $ReadOnly<{...}> as positional param
    try expectNoParseErrorFlow("type X = ($ReadOnly<{logs: LogBoxLogs}>) => void;");
    // multiple positional params
    try expectNoParseErrorFlow("type X = ($ReadOnly<{a: number}>, string) => void;");
}

test "Flow: const type parameter" {
    try expectNoParseErrorFlow("function f<const T: {[string]: true}>(x: T): T { return x; }");
}

test "Flow: static covariant class property" {
    try expectNoParseErrorFlow("class Event { static +NONE: 0; static +AT_TARGET: 2; +bubbles: boolean; }");
}

test "Flow: match expression" {
    try expectNoParseErrorFlow(
        \\function f(mode: number): string {
        \\  return match (mode) {
        \\    0 => 'a',
        \\    1 => 'b',
        \\    _ => 'c',
        \\  };
        \\}
    );
}

test "Flow: import typeof specifier" {
    try expectNoParseErrorFlow("import {typeof VirtualizedList as VirtualizedListT} from './VirtualizedList';");
}

test "Flow: typed arrow in multi-param" {
    try expectNoParseErrorFlow("const f = (a, b: number) => a + b;");
    try expectNoParseErrorFlow("const f = (a, b, c: string) => c;");
}

test "Flow: nullable return type with arrow" {
    // ?(T) return type이 function type이 아닌 nullable paren type으로 해석되어야 함
    try expectNoParseErrorFlow(
        \\class C {
        \\  _getItem = (data: Array<ItemT>, index: number): ?(ItemT | string) => {
        \\    return data[index];
        \\  };
        \\}
    );
}

test "Flow: typed arrow in ternary consequent" {
    // (): void => {} — 삼항 안에서 typed empty-param arrow
    try expectNoParseErrorFlow("const x = true ? (): void => { return; } : null;");
    // typeof도 type keyword로 감지
    try expectNoParseErrorFlow("const x = true ? (): typeof a => { return a; } : null;");
}

test "Flow: single type param generic arrow in JSX mode" {
    // <T>() => body — JSX+Flow에서 <T> 뒤에 ( 가 오면 generic arrow로 판별
    try expectNoParseErrorFlow("const f = <T>(x: T): T => x;");
    // object method
    try expectNoParseErrorFlow("const obj = { select: <T>(spec: T): T => spec };");
}

test "Flow: type guard predicate" {
    try expectNoParseErrorFlow(
        \\function isObj(value: mixed): value is {[string]: unknown} {
        \\  return typeof value === "object";
        \\}
    );
}

test "Flow: infer in conditional type" {
    try expectNoParseErrorFlow("type X<T> = T extends Array<infer P> ? P : T;");
}

test "Flow: keyof type operator" {
    try expectNoParseErrorFlow("type K = keyof Obj;");
}

test "Flow: interface type in extends bound" {
    try expectNoParseErrorFlow("type X<O extends interface {}> = O;");
}

test "Flow: JSX comment inside element" {
    try expectNoParseErrorFlowJSX(
        \\function f() {
        \\  return (
        \\    <View
        \\      // comment
        \\      style={style}
        \\    />
        \\  );
        \\}
    );
}

test "Flow: typed arrow with return type" {
    try expectFlowParseResult(
        \\const f = (x: number): number => x;
    , .{ .jsx = true });
}

test "Flow: shorthand function type as method return" {
    try expectNoParseErrorFlow(
        \\class C {
        \\  _getInterpolation(): number => OutputT {
        \\    return null;
        \\  }
        \\}
    );
}
