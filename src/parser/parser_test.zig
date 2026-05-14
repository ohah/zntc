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

const VariableDeclarationKind = ast_mod.VariableDeclarationKind;

fn firstVariableDeclaration(parser: *Parser) ast_mod.Node {
    // 첫 번째 variable_declaration 노드를 찾음 (program/block/function 위치 무관).
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .variable_declaration) return node;
    }
    unreachable;
}

fn parseAndGetKind(src: []const u8) !VariableDeclarationKind {
    var scanner = try Scanner.init(std.testing.allocator, src);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
    const decl = firstVariableDeclaration(&parser);
    return parser.ast.variableDeclarationKind(decl);
}

test "Parser: variableDeclarationKind — var" {
    try std.testing.expectEqual(VariableDeclarationKind.@"var", try parseAndGetKind("var x = 1;"));
}

test "Parser: variableDeclarationKind — let" {
    try std.testing.expectEqual(VariableDeclarationKind.let, try parseAndGetKind("let x = 1;"));
}

test "Parser: variableDeclarationKind — const" {
    try std.testing.expectEqual(VariableDeclarationKind.@"const", try parseAndGetKind("const x = 1;"));
}

test "Parser: variableDeclarationKind — using" {
    try std.testing.expectEqual(VariableDeclarationKind.using, try parseAndGetKind("{ using x = null; }"));
}

test "Parser: variableDeclarationKind — await using" {
    try std.testing.expectEqual(VariableDeclarationKind.await_using, try parseAndGetKind("async function f() { await using x = null; }"));
}

test "VariableDeclarationKind: isLexical / isUsing helpers" {
    try std.testing.expect(!VariableDeclarationKind.@"var".isLexical());
    try std.testing.expect(VariableDeclarationKind.let.isLexical());
    try std.testing.expect(VariableDeclarationKind.@"const".isLexical());
    try std.testing.expect(VariableDeclarationKind.using.isLexical());
    try std.testing.expect(VariableDeclarationKind.await_using.isLexical());

    try std.testing.expect(!VariableDeclarationKind.let.isUsing());
    try std.testing.expect(VariableDeclarationKind.using.isUsing());
    try std.testing.expect(VariableDeclarationKind.await_using.isUsing());
}

test "VariableDeclarationKind: wire-compat numeric values" {
    // 모든 consumer가 의존하는 wire 값. 변경 금지.
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(VariableDeclarationKind.@"var"));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(VariableDeclarationKind.let));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(VariableDeclarationKind.@"const"));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(VariableDeclarationKind.using));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(VariableDeclarationKind.await_using));
}

test "VariableDeclarationKind: fromU32 unknown values fall back to var" {
    try std.testing.expectEqual(VariableDeclarationKind.@"var", VariableDeclarationKind.fromU32(99));
}

fn findFirstNodeWithTag(parser: *Parser, tag: Tag) ast_mod.Node {
    for (parser.ast.nodes.items) |node| {
        if (node.tag == tag) return node;
    }
    unreachable;
}

fn parseAndGetParamCount(src: []const u8, tag: Tag) !usize {
    var scanner = try Scanner.init(std.testing.allocator, src);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
    const fn_node = findFirstNodeWithTag(&parser, tag);
    return parser.ast.functionParams(fn_node).len;
}

test "Ast.functionParams: function declaration — 0/1/N params" {
    try std.testing.expectEqual(@as(usize, 0), try parseAndGetParamCount("function f() {}", .function_declaration));
    try std.testing.expectEqual(@as(usize, 1), try parseAndGetParamCount("function f(a) {}", .function_declaration));
    try std.testing.expectEqual(@as(usize, 3), try parseAndGetParamCount("function f(a, b, c) {}", .function_declaration));
}

test "Ast.functionParams: function expression" {
    try std.testing.expectEqual(@as(usize, 2), try parseAndGetParamCount("var f = function(a, b) {};", .function_expression));
}

test "Ast.functionParams: arrow function — 0/1/N + 정규화 검증" {
    // arrow는 formal_parameters로 정규화됨 (#1283). 헬퍼가 unwrap 처리.
    try std.testing.expectEqual(@as(usize, 0), try parseAndGetParamCount("var f = () => 1;", .arrow_function_expression));
    try std.testing.expectEqual(@as(usize, 1), try parseAndGetParamCount("var f = x => x;", .arrow_function_expression));
    try std.testing.expectEqual(@as(usize, 1), try parseAndGetParamCount("var f = (x) => x;", .arrow_function_expression));
    try std.testing.expectEqual(@as(usize, 3), try parseAndGetParamCount("var f = (a, b, c) => a;", .arrow_function_expression));
}

test "Ast.functionParams: arrow with destructuring/rest/default" {
    try std.testing.expectEqual(@as(usize, 2), try parseAndGetParamCount("var f = ({a}, [b]) => a;", .arrow_function_expression));
    try std.testing.expectEqual(@as(usize, 2), try parseAndGetParamCount("var f = (a, ...rest) => a;", .arrow_function_expression));
    try std.testing.expectEqual(@as(usize, 2), try parseAndGetParamCount("var f = (a = 1, b = 2) => a;", .arrow_function_expression));
}

test "Ast.functionParams: method definition" {
    try std.testing.expectEqual(@as(usize, 2), try parseAndGetParamCount("class C { m(a, b) {} }", .method_definition));
}

test "Ast.functionParams: async/generator function" {
    try std.testing.expectEqual(@as(usize, 1), try parseAndGetParamCount("async function f(x) {}", .function_declaration));
    try std.testing.expectEqual(@as(usize, 1), try parseAndGetParamCount("function* g(x) {}", .function_declaration));
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

test "Parser: TS non-null assertion followed by division" {
    // non-null assertion `!` 뒤의 `/`가 regex가 아닌 division으로 파싱되어야 한다
    const cases = [_][]const u8{
        "const z = x > y! / 2;",
        "const z = y! / 2;",
        "const z = y! / 2 + 1;",
        "const z = foo()! / bar;",
        "const z = arr[0]! / len;",
        "const z = a.b! / c.d;",
        "const z = (x as number)! / 2;",
    };
    for (cases) |source| {
        var scanner = try Scanner.init(std.testing.allocator, source);
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    }
}

test "Parser: prefix logical NOT with regex" {
    // prefix `!` 뒤의 `/`는 regex로 파싱되어야 한다 (non-null assertion과 구분)
    const cases = [_][]const u8{
        "const x = !/test/;",
        "const x = !/test/.test('a');",
        "if (!/pattern/) {}",
    };
    for (cases) |source| {
        var scanner = try Scanner.init(std.testing.allocator, source);
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    }
}

test "Parser: TS type predicate in function type literal" {
    // 함수 타입 리터럴의 return type에서 type predicate (`value is Type`)가 파싱되어야 한다
    const cases = [_][]const u8{
        // object type 내부 메서드 시그니처
        "type X = { determine: (value: object) => value is string; };",
        // 변수 타입
        "let guard: (x: unknown) => x is number;",
        // 제네릭 함수 타입
        "type Guard<T> = <U>(value: U) => value is T;",
        // 빈 괄호 + type predicate (this is Type)
        "type X = { isReady: () => this is Ready; };",
        // 단일 파라미터 shorthand
        "type F = (x) => x is string;",
        // asserts predicate
        "type F = (x: unknown) => asserts x is string;",
        // asserts without is
        "type F = (x: unknown) => asserts x;",
        // 다중 파라미터 함수 타입
        "type F = (a: unknown, b: unknown) => a is string;",
        // intersection/union과 함께
        "type X = { check: (v: any) => v is Foo } & { other: number };",
        // 중첩 함수 타입
        "type F = (f: (x: any) => x is string) => boolean;",
    };
    for (cases) |source| {
        var scanner = try Scanner.init(std.testing.allocator, source);
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    }
}

test "Parser: TS function type property signature in .ts mode" {
    try expectNoParseErrorWithExt(
        \\type X = { create: (target: string) => string; };
    , ".ts");
}

test "Parser: TS interface getter / setter signature" {
    // `@reduxjs/toolkit` 의 `createSlice.ts` 같은 패턴이 `isContextual("get")` 의
    // identifier-only check 로 fail 하던 회귀 가드. scanner 가 `get`/`set` 을
    // `.kw_get`/`.kw_set` 으로 토큰화하므로 token kind 로 비교해야 한다.
    try expectNoParseErrorWithExt("export interface S { get x(): string; }", ".ts");
    try expectNoParseErrorWithExt("export interface S { set x(v: string); }", ".ts");
    try expectNoParseErrorWithExt("export interface S { get x(): string; set x(v: string); }", ".ts");
    // generic return type 도 처리.
    try expectNoParseErrorWithExt("export interface S<T> { get items(): Array<T>; }", ".ts");
    // type literal 안에서도 동일.
    try expectNoParseErrorWithExt("type X = { get x(): string; set x(v: string); };", ".ts");
    // static / readonly modifier 와 조합.
    try expectNoParseErrorWithExt("export interface S { static get x(): string; }", ".ts");
    try expectNoParseErrorWithExt("export interface S { readonly x: string; }", ".ts");
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

test "Parser: TS parameter property with contextual keyword name" {
    // `@shopify/react-native-skia` 의 `CanvasKitWebGLBufferImpl.ts` 같은 패턴이
    // `next == .identifier` 만 체크하던 condition 에서 fail. parameter property
    // modifier 다음 param name 으로 contextual keyword (source/async/from/of 등)
    // 가 와도 binding 으로 받아야 한다.
    try expectNoParseErrorWithExt("class C { constructor(private source: number) {} }", ".ts");
    try expectNoParseErrorWithExt("class C { constructor(public async: string) {} }", ".ts");
    try expectNoParseErrorWithExt("class C { constructor(public a: string, private source: number) {} }", ".ts");
    try expectNoParseErrorWithExt("class C { constructor(readonly defer: number) {} }", ".ts");
    try expectNoParseErrorWithExt("class C { constructor(public override target: string) {} }", ".ts");
    // destructuring 패턴 + modifier 도 같은 condition 안 — 기존 동작 회귀 가드.
    try expectNoParseErrorWithExt("class C { constructor(public { x, y }: Point) {} }", ".ts");
    try expectNoParseErrorWithExt("class C { constructor(readonly [a, b]: number[]) {} }", ".ts");
}

test "Parser: TS generic class method named get/set" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\class QueryCache {
        \\  get<T>(queryHash: string): Query<T> | undefined {
        \\    return this.queries.get(queryHash) as Query<T> | undefined
        \\  }
        \\  set<T>(queryHash: string, value: Query<T>): void {
        \\    this.queries.set(queryHash, value)
        \\  }
        \\}
    );
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

test "Parser: yield in non-generator function (module) emits clear diagnostic (#2210)" {
    var scanner = try Scanner.init(std.testing.allocator, "function notGen() { yield 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    // 명확한 진단 emit + yield 키워드 위치 정확.
    try std.testing.expect(parser.errors.items.len > 0);
    var found = false;
    for (parser.errors.items) |err| {
        if (err.code) |c| if (c == .yield_outside_generator) {
            found = true;
            // yield 키워드 위치는 'function notGen() { ' 다음 = offset 20
            try std.testing.expectEqual(@as(u32, 20), err.span.start);
            break;
        };
    }
    try std.testing.expect(found);
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

test "Parser: super?.() is syntax error" {
    var scanner = try Scanner.init(std.testing.allocator, "class C extends B { test() { return super?.(); } }");
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
/// found, labels, hint 필드를 검증할 수 있다.
const ErrorCheck = struct {
    message: ?[]const u8 = null,
    message_contains: ?[]const u8 = null,
    has_found: ?bool = null,
    /// labels 배열이 비어 있는지 여부
    has_labels: ?bool = null,
    /// 라벨 중 하나가 이 message와 일치해야 함
    label_message: ?[]const u8 = null,
    has_hint: ?bool = null,
    hint: ?[]const u8 = null,
};

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

        if (check.has_found) |hf| try std.testing.expectEqual(hf, err.found != null);
        if (check.has_labels) |hl| try std.testing.expectEqual(hl, err.labels.len > 0);
        if (check.label_message) |lm| {
            var found_label = false;
            for (err.labels) |l| {
                if (l.message) |m| {
                    if (std.mem.eql(u8, m, lm)) {
                        found_label = true;
                        break;
                    }
                }
            }
            try std.testing.expect(found_label);
        }
        if (check.has_hint) |hh| try std.testing.expectEqual(hh, err.hint != null);
        if (check.hint) |h| {
            try std.testing.expect(err.hint != null);
            try std.testing.expectEqualStrings(h, err.hint.?);
        }
        return;
    }
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

test "ErrorMsg: bracket matching label for paren" {
    try expectParseError("function f(a, b ]", .{
        .message = ")",
        .has_labels = true,
        .label_message = "opening '(' is here",
    });
}

test "ErrorMsg: bracket matching label for curly" {
    try expectParseError("if (true) { var x = 1;", .{
        .message = "}",
        .has_labels = true,
        .label_message = "opening '{' is here",
    });
}

test "ErrorMsg: bracket matching label for bracket" {
    try expectParseError("var a = [1, 2", .{
        .message = "]",
        .has_labels = true,
        .label_message = "opening '[' is here",
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
    var has_labels = false;
    for (parser.errors.items) |err| {
        if (err.labels.len > 0) {
            has_labels = true;
            break;
        }
    }
    try std.testing.expect(has_labels);
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

fn expectParseErrorWithExt(source: []const u8, ext: []const u8, check: ErrorCheck) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(ext);

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);

    for (parser.errors.items) |err| {
        const msg_match = if (check.message) |m| std.mem.eql(u8, err.message, m) else true;
        const contains_match = if (check.message_contains) |c| std.mem.indexOf(u8, err.message, c) != null else true;
        if (msg_match and contains_match) return;
    }
    return error.TestUnexpectedResult;
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

// ============================================================
// `.js`/`.jsx` 가 ESM (import/export) 을 받도록 — esbuild/swc/rollup 와 정렬.
// date-fns 4.x 같은 ESM-only `.js` 패키지 통과 회귀 보호.
// ============================================================

test ".js: top-level export const → module 로 파싱" {
    try expectNoParseErrorWithExt(
        \\export const x = 1;
    , ".js");
}

test ".js: top-level import → module 로 파싱" {
    try expectNoParseErrorWithExt(
        \\import { format } from "date-fns";
        \\console.log(format);
    , ".js");
}

test ".js: export function 도 module 로 파싱" {
    try expectNoParseErrorWithExt(
        \\export function add(a, b) { return a + b; }
    , ".js");
}

test ".js: 순수 script (module.exports) 도 그대로 동작" {
    try expectNoParseErrorWithExt(
        \\module.exports = { x: 1 };
    , ".js");
}

test ".jsx: top-level export default JSX 도 module 로 파싱" {
    try expectNoParseErrorWithExt(
        \\export default function App() { return null; }
    , ".jsx");
}

test ".cjs: ESM export 는 여전히 거부 (Node CJS 컨벤션 유지)" {
    try expectParseErrorWithExt(
        \\export const x = 1;
    , ".cjs", .{ .message_contains = "module code" });
}

test ".cts: ESM 구문 허용 — TS 가 module.exports 로 transpile (tsc 정책)" {
    try expectNoParseErrorWithExt(
        \\export const x: number = 1;
    , ".cts");
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

test "Flow: nested generic ending in >> (regression #2420)" {
    // Why: `<T: $Keys<U>>` 의 닫힘 `>>` 가 lexer 에서 단일 shift_right 토큰. skipBalanced
    // 가 angle context 에서 multi-char close 를 감지 못 하면 depth 가 0 까지 안 떨어져
    // EOF 까지 소비 → outer parser 깨짐. rn EventEmitter.js 트리거.
    // parseObjectType → parseFlowTypeMember → skipBalanced 경로 강제 위해 object type literal.
    try expectNoParseErrorFlow(
        \\type MyEmitter<T> = {
        \\  addListener<TEvent: $Keys<T>>(eventType: TEvent): mixed,
        \\};
    );
}

test "Flow: triple-nested generic ending in >>> (regression #2420)" {
    // shift_right3 (`>>>`) — 3 close. shift_right 와 동일 메커니즘.
    try expectNoParseErrorFlow(
        \\type Outer<A> = {
        \\  fn<T: Map<Set<List<A>>>>(x: T): void,
        \\};
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

test "Flow+JSX: JSX member expression" {
    try expectNoParseErrorFlowJSX("<Foo.Bar />;");
    try expectNoParseErrorFlowJSX("<Foo.Bar baz={1}>hello</Foo.Bar>;");
    try expectNoParseErrorFlowJSX("<A.B.C />;");
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

test "Flow: contextual keywords as function-type param names" {
    // react-native-blob-util codegenSpecs (`+stat: (target: string, callback: (...) => void) => void;`)
    // 같은 RN TurboModule spec 패턴이 fail 하던 회귀 가드.
    // 1번째 param.
    try expectNoParseErrorFlow("type T = (target: string, b: () => void) => void;");
    try expectNoParseErrorFlow("type T = (meta: string, b: () => void) => void;");
    try expectNoParseErrorFlow("type T = (async: string, b: () => void) => void;");
    try expectNoParseErrorFlow("type T = (from: string, b: () => void) => void;");
    try expectNoParseErrorFlow("type T = (of: string, b: () => void) => void;");
    // 2번째 이후 param 위치 (parseParenOrFunctionType 의 comma-loop 경로).
    try expectNoParseErrorFlow("type T = (x: string, target: () => void) => void;");
    try expectNoParseErrorFlow("type T = (x: string, of: number, target: () => void) => void;");
    // interface method 의 nested function-type param (실제 trigger 케이스).
    try expectNoParseErrorFlow(
        \\interface Spec {
        \\    +stat: (target: string, callback: (value: Array<any>) => void) => void;
        \\}
    );
    // optional param (`name?: Type`) 변형도 함께.
    try expectNoParseErrorFlow("type T = (target?: string, b?: () => void) => void;");
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

test "Flow: match call expression is not match syntax" {
    try expectNoParseErrorFlow("const out = (match(value, callback = /x/));");
    try expectNoParseErrorFlow(
        \\function f(value, callback) {
        \\  switch (match(value, callback = /(::plac\w+|:read-\w+)/)) {
        \\    case ':read-only':
        \\      break;
        \\  }
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

test "TS: typed arrow with default-value parameters" {
    // @shopify/react-native-skia 의 `vec = (x = 0, y?: number) => ...` 같은 패턴이
    // `isTypedArrowFunction` detection 에서 fail 하던 회귀 가드.
    // default 첫 param + optional/plain typed 두 번째.
    try expectNoParseErrorWithExt("const f = (x = 0, y?: number) => 0;", ".ts");
    try expectNoParseErrorWithExt("const f = (x = 0, y: number) => 0;", ".ts");
    // default 두 번째 param + typed 세 번째.
    try expectNoParseErrorWithExt("const f = (a, b = 1, c: string) => 0;", ".ts");
    // default expression 의 nested literal 통과 — paren / brace / bracket skip 검증.
    try expectNoParseErrorWithExt("const f = (x = Math.max(1, 2), y?: number) => 0;", ".ts");
    try expectNoParseErrorWithExt("const f = (x = { a: 1 }, y: number) => 0;", ".ts");
    try expectNoParseErrorWithExt("const f = (x = [1, 2, 3], y: number) => 0;", ".ts");
    // 단일 param + default + return type annotation.
    try expectNoParseErrorWithExt("const f = (x = 0): number => x;", ".ts");
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

test "Flow: typed arrow restores return type context before body" {
    try expectNoParseErrorFlow(
        \\const f = (x: number) => {
        \\  const cb = (resolve: A => B) => resolve;
        \\};
    );
    try expectNoParseErrorFlow(
        \\const g = <T>(x: T) => {
        \\  const cb = (resolve: A => B) => resolve;
        \\};
    );
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

// async arrow: 내부 arrow 의 파라미터에서도 'await' 식별자 금지
// (ECMA §sec-async-arrow-function-definitions)
// ============================================================

test "Async arrow: nested arrow ident param 'await' is error" {
    try expectParseError("async(a = await => {}) => {};", .{ .message_contains = "await" });
}

test "Async arrow: nested arrow rest param 'await' is error" {
    try expectParseError("async(a = (...await) => {}) => {};", .{ .message_contains = "await" });
}

test "Async arrow: nested arrow ident 'await' (with preceding statement)" {
    // 이전 statement 가 있어도 파서 상태가 올바르게 유지되어야 한다.
    try expectParseError("var x = 1; async(a = await => {}) => {};", .{ .message_contains = "await" });
}

// ============================================================
// Object literal: private identifier 금지 (ECMA §sec-method-definitions-static-semantics-early-errors)
// 모든 method definition variant 와 shorthand 에서 PrivateIdentifier 는 early SyntaxError.
// ============================================================

test "Object literal: private shorthand method is error" {
    try expectParseError("var o = { #m() {} };", .{ .message_contains = "Private identifier" });
}

test "Object literal: private generator method is error" {
    try expectParseError("var o = { *#m() {} };", .{ .message_contains = "Private identifier" });
}

test "Object literal: private async method is error" {
    try expectParseError("var o = { async #m() {} };", .{ .message_contains = "Private identifier" });
}

test "Object literal: private async generator method is error" {
    try expectParseError("var o = { async *#m() {} };", .{ .message_contains = "Private identifier" });
}

test "Object literal: private getter is error" {
    try expectParseError("var o = { get #m() {} };", .{ .message_contains = "Private identifier" });
}

test "Object literal: private setter is error" {
    try expectParseError("var o = { set #m(x) {} };", .{ .message_contains = "Private identifier" });
}

test "Object literal inside class field: private generator is error" {
    try expectParseError("class C { field = { *#m() {} } }", .{ .message_contains = "Private identifier" });
}

test "Object literal inside class field: private async is error" {
    try expectParseError("class C { field = { async #m() {} } }", .{ .message_contains = "Private identifier" });
}

// ============================================================
// TS object type literal: computed property key (#1767)
// ============================================================

test "TS object type: computed property key with symbol ref" {
    try expectNoParseErrorWithExt(
        \\declare const sym: unique symbol;
        \\interface A { [sym]: string; }
    , ".ts");
}

test "TS object type: optional computed property key" {
    try expectNoParseErrorWithExt(
        \\declare const sym: unique symbol;
        \\interface A { [sym]?: boolean; }
    , ".ts");
}

test "TS object type: computed property key in intersection type" {
    try expectNoParseErrorWithExt(
        \\const polyfillSymbol = Symbol.for('test');
        \\function f(fetch: Function & { [polyfillSymbol]?: boolean }) { return fetch; }
    , ".ts");
}

test "TS object type: computed property key in type literal" {
    try expectNoParseErrorWithExt(
        \\const s = Symbol();
        \\type T = { [s]?: boolean };
    , ".ts");
}

test "TS object type: index signature still parses" {
    try expectNoParseErrorWithExt(
        \\interface Dict { [key: string]: number; }
        \\interface RO { readonly [i: number]: string; }
    , ".ts");
}

test "TS object type: mapped type still parses" {
    try expectNoParseErrorWithExt(
        \\type Partial<T> = { [K in keyof T]?: T[K] };
        \\type Readonly<T> = { readonly [K in keyof T]: T[K] };
    , ".ts");
}

test "TS object type: mix of index signature and plain members" {
    try expectNoParseErrorWithExt(
        \\type Mixed = {
        \\  [key: string]: any;
        \\  normal: number;
        \\  readonly ro?: string;
        \\};
    , ".ts");
}

// Error recovery — TS 공식 `isUnambiguouslyIndexSignature` 가 parse 는 통과시키는 케이스들.
// ZNTC 는 tsc 수준의 semantic checker 가 없으므로, invalid syntax 가 조용히 통과하지
// 않도록 parser 단에서 diagnostic 을 찍고 토큰은 skip 해서 나머지 파싱은 계속한다.

test "TS index signature: optional param `[k?: T]: V` is error" {
    try expectParseErrorWithExt(
        \\interface D { [k?: string]: number; }
    , ".ts", .{ .message_contains = "question mark" });
}

test "TS index signature: optional param without type `[k?]: V` is error" {
    try expectParseErrorWithExt(
        \\interface D { [k?]: number; }
    , ".ts", .{ .message_contains = "question mark" });
}

test "TS index signature: modifier `public` before param is error" {
    try expectParseErrorWithExt(
        \\interface D { [public k: string]: number; }
    , ".ts", .{ .message_contains = "Modifiers cannot appear" });
}

test "TS index signature: modifier `private` before param is error" {
    try expectParseErrorWithExt(
        \\interface D { [private k: string]: number; }
    , ".ts", .{ .message_contains = "Modifiers cannot appear" });
}

test "TS index signature: modifier `protected` before param is error" {
    try expectParseErrorWithExt(
        \\interface D { [protected k: string]: number; }
    , ".ts", .{ .message_contains = "Modifiers cannot appear" });
}

test "TS object type: computed key with member access `[ns.k]`" {
    try expectNoParseErrorWithExt(
        \\declare const ns: { k: unique symbol };
        \\interface A { [ns.k]: string; }
    , ".ts");
}

// ============================================================
// TS property signature 의 key/type/flags 보존 (#2348 PR #3a-1)
// ============================================================
//
// transformer 가 ts_property_signature 를 통째로 strip 하지만, codegen plugin
// (#2348 § 4) 이 view config 빌드를 위해 key/type/flags 가 필요하므로 파서가
// extras 에 보존한다. 본 테스트는 strip 동작 (transformer_test.zig) 과 별개로
// 파서 단위에서 layout 이 올바른지 검증.

const ts_mod = @import("ts.zig");

/// 파싱 결과 — TS / Flow 공통. Scanner / Parser 를 heap allocator 로 박아 안정된
/// 주소 보장 (`Parser` 가 `*Scanner` 포인터를 들고 있는데 stack 에 두면 함수 반환
/// 시 dangling — `transformer_test.zig:200` 와 동일 패턴).
const ParsedSource = struct {
    scanner: *Scanner,
    parser: *Parser,
    alloc: std.mem.Allocator,

    fn deinit(self: *ParsedSource) void {
        self.parser.deinit();
        self.alloc.destroy(self.parser);
        self.scanner.deinit();
        self.alloc.destroy(self.scanner);
    }
};

const ParseMode = enum { ts, flow };

fn parseSource(alloc: std.mem.Allocator, source: []const u8, mode: ParseMode) !ParsedSource {
    const scanner = try alloc.create(Scanner);
    errdefer alloc.destroy(scanner);
    scanner.* = try Scanner.init(alloc, source);
    errdefer scanner.deinit();

    const parser = try alloc.create(Parser);
    errdefer alloc.destroy(parser);
    parser.* = Parser.init(alloc, scanner);
    errdefer parser.deinit();

    switch (mode) {
        .ts => parser.configureFromExtension(".ts"),
        .flow => parser.is_flow = true,
    }
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    return .{ .scanner = scanner, .parser = parser, .alloc = alloc };
}

fn parseTs(alloc: std.mem.Allocator, source: []const u8) !ParsedSource {
    return parseSource(alloc, source, .ts);
}

/// 첫 번째 property signature 의 (key, type_ann, flags) 추출. TS / Flow 공통 layout.
const PropSig = struct {
    key: ast_mod.NodeIndex,
    type_ann: ast_mod.NodeIndex,
    flags: ts_mod.PropertySignatureFlags,
};

fn extractFirstPropSig(parser: *Parser, tag: Tag) PropSig {
    for (parser.ast.nodes.items) |node| {
        if (node.tag != tag) continue;
        const e = node.data.extra;
        return .{
            .key = @enumFromInt(parser.ast.extra_data.items[e]),
            .type_ann = @enumFromInt(parser.ast.extra_data.items[e + 1]),
            .flags = ts_mod.PropertySignatureFlags.fromU32(parser.ast.extra_data.items[e + 2]),
        };
    }
    std.debug.panic("BUG: test source has no node with tag {s}", .{@tagName(tag)});
}

test "TS property signature: preserves key + type + zero flags" {
    var r = try parseTs(std.testing.allocator, "interface A { color: string }");
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .ts_property_signature);
    try std.testing.expect(sig.key != .none);
    try std.testing.expect(sig.type_ann != .none);
    try std.testing.expectEqual(ts_mod.PropertySignatureFlags.NONE, sig.flags);

    // parsePropertyKey 는 .identifier_reference 반환 (`expression.zig:1879`). type 은 ts_string_keyword.
    try std.testing.expectEqual(Tag.identifier_reference, r.parser.ast.getNode(sig.key).tag);
    try std.testing.expectEqual(Tag.ts_string_keyword, r.parser.ast.getNode(sig.type_ann).tag);
}

test "TS property signature: optional `?` sets flags.optional" {
    var r = try parseTs(std.testing.allocator, "interface A { color?: string }");
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .ts_property_signature);
    try std.testing.expect(sig.flags.optional);
    try std.testing.expect(!sig.flags.readonly);
}

test "TS property signature: readonly sets flags.readonly" {
    var r = try parseTs(std.testing.allocator, "interface A { readonly color: string }");
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .ts_property_signature);
    try std.testing.expect(sig.flags.readonly);
    try std.testing.expect(!sig.flags.optional);
}

test "TS property signature: readonly + optional both flags set" {
    var r = try parseTs(std.testing.allocator, "interface A { readonly color?: string }");
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .ts_property_signature);
    try std.testing.expect(sig.flags.optional);
    try std.testing.expect(sig.flags.readonly);
}

test "TS property signature: missing type annotation has type_ann=none" {
    // interface 의 `key;` 또는 `key?;` — 타입 어노테이션 없이도 유효.
    var r = try parseTs(std.testing.allocator, "interface A { color }");
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .ts_property_signature);
    try std.testing.expectEqual(ast_mod.NodeIndex.none, sig.type_ann);
}

test "TS property signature: type alias body preserves all members" {
    var r = try parseTs(std.testing.allocator,
        \\type Props = {
        \\  color: string;
        \\  size?: number;
        \\  readonly disabled: boolean;
        \\};
    );
    defer r.deinit();

    var prop_count: usize = 0;
    var seen_color = false;
    var seen_size = false;
    var seen_disabled = false;

    for (r.parser.ast.nodes.items) |node| {
        if (node.tag != .ts_property_signature) continue;
        prop_count += 1;
        const e = node.data.extra;
        const key_idx: ast_mod.NodeIndex = @enumFromInt(r.parser.ast.extra_data.items[e]);
        const flags = ts_mod.PropertySignatureFlags.fromU32(r.parser.ast.extra_data.items[e + 2]);

        const key_node = r.parser.ast.getNode(key_idx);
        const name = r.parser.ast.getText(key_node.data.string_ref);

        if (std.mem.eql(u8, name, "color")) {
            seen_color = true;
            try std.testing.expectEqual(ts_mod.PropertySignatureFlags.NONE, flags);
        } else if (std.mem.eql(u8, name, "size")) {
            seen_size = true;
            try std.testing.expect(flags.optional);
        } else if (std.mem.eql(u8, name, "disabled")) {
            seen_disabled = true;
            try std.testing.expect(flags.readonly);
        }
    }

    try std.testing.expectEqual(@as(usize, 3), prop_count);
    try std.testing.expect(seen_color);
    try std.testing.expect(seen_size);
    try std.testing.expect(seen_disabled);
}

// ============================================================
// Flow property signature 보존 (#2348 PR #3a-2)
// ============================================================
//
// Flow object body 가 brace-skip 되던 동작을 실제 멤버 파싱으로 교체.
// flow_property_signature 노드가 [key, type_ann, flags] 보존.

fn parseFlow(alloc: std.mem.Allocator, source: []const u8) !ParsedSource {
    return parseSource(alloc, source, .flow);
}

test "Flow property signature: preserves key + type + zero flags" {
    var r = try parseFlow(std.testing.allocator,
        \\type Props = { color: string };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    try std.testing.expect(sig.key != .none);
    try std.testing.expect(sig.type_ann != .none);
    try std.testing.expectEqual(ts_mod.PropertySignatureFlags.NONE, sig.flags);

    // parseSimpleIdentifier 는 .binding_identifier 반환 (binding.zig).
    try std.testing.expectEqual(Tag.binding_identifier, r.parser.ast.getNode(sig.key).tag);
    try std.testing.expectEqual(Tag.flow_string_keyword, r.parser.ast.getNode(sig.type_ann).tag);
}

test "Flow property signature: optional `?` sets flags.optional" {
    var r = try parseFlow(std.testing.allocator,
        \\type Props = { color?: string };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    try std.testing.expect(sig.flags.optional);
    try std.testing.expect(!sig.flags.readonly);
}

test "Flow property signature: covariant `+` sets flags.readonly" {
    var r = try parseFlow(std.testing.allocator,
        \\type Props = { +color: string };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    try std.testing.expect(sig.flags.readonly);
    try std.testing.expect(!sig.flags.optional);
}

test "Flow property signature: contravariant `-` produces no flag" {
    // 현재 PropertySignatureFlags 에 contravariant 비트 없음 — drop (codegen 미사용).
    var r = try parseFlow(std.testing.allocator,
        \\type Props = { -color: string };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    try std.testing.expectEqual(ts_mod.PropertySignatureFlags.NONE, sig.flags);
}

test "Flow object type: empty inexact `{}` has empty member list" {
    var r = try parseFlow(std.testing.allocator,
        \\type Empty = {};
    );
    defer r.deinit();

    var found_object_type = false;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag != .flow_object_type) continue;
        found_object_type = true;
        try std.testing.expectEqual(@as(u32, 0), node.data.list.len);
    }
    try std.testing.expect(found_object_type);
}

test "Flow exact object type: empty `{||}` has empty member list" {
    // pipe2 토큰 처리 정상 확인.
    var r = try parseFlow(std.testing.allocator,
        \\type Empty = {||};
    );
    defer r.deinit();

    var found_exact = false;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag != .flow_exact_object_type) continue;
        found_exact = true;
        try std.testing.expectEqual(@as(u32, 0), node.data.list.len);
    }
    try std.testing.expect(found_exact);
}

test "Flow object type: multiple members all preserved with flags" {
    var r = try parseFlow(std.testing.allocator,
        \\type Props = {|
        \\  color: string,
        \\  size?: number,
        \\  +disabled: boolean,
        \\|};
    );
    defer r.deinit();

    var prop_count: usize = 0;
    var seen_color = false;
    var seen_size = false;
    var seen_disabled = false;

    for (r.parser.ast.nodes.items) |node| {
        if (node.tag != .flow_property_signature) continue;
        prop_count += 1;
        const e = node.data.extra;
        const key_idx: ast_mod.NodeIndex = @enumFromInt(r.parser.ast.extra_data.items[e]);
        const flags = ts_mod.PropertySignatureFlags.fromU32(r.parser.ast.extra_data.items[e + 2]);

        const name = r.parser.ast.getText(r.parser.ast.getNode(key_idx).data.string_ref);

        if (std.mem.eql(u8, name, "color")) {
            seen_color = true;
            try std.testing.expectEqual(ts_mod.PropertySignatureFlags.NONE, flags);
        } else if (std.mem.eql(u8, name, "size")) {
            seen_size = true;
            try std.testing.expect(flags.optional);
        } else if (std.mem.eql(u8, name, "disabled")) {
            seen_disabled = true;
            try std.testing.expect(flags.readonly);
        }
    }

    try std.testing.expectEqual(@as(usize, 3), prop_count);
    try std.testing.expect(seen_color);
    try std.testing.expect(seen_size);
    try std.testing.expect(seen_disabled);
}

test "Flow object type: contextual keyword as property key (`get`)" {
    // get/set/class/interface 등은 .kw_* 토큰이라 단순 .identifier 체크로는 누락됨.
    // 실제 RN spec 에서 흔함 (`{ get: () => T }` — react-native Utilities/defineLazyObjectProperty).
    var r = try parseFlow(std.testing.allocator,
        \\type X = { get: T };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    const name = r.parser.ast.getText(r.parser.ast.getNode(sig.key).data.string_ref);
    try std.testing.expectEqualStrings("get", name);
}

test "Flow object type: reserved keyword as property key (`delete`)" {
    // delete/class/if 등 reserved keyword 도 property 이름. parseSimpleIdentifier
    // 의 checkKeywordBinding 검사를 우회해서 직접 binding_identifier 노드 생성 — 회귀 가드.
    var r = try parseFlow(std.testing.allocator,
        \\type X = { delete?: T };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    const name = r.parser.ast.getText(r.parser.ast.getNode(sig.key).data.string_ref);
    try std.testing.expectEqualStrings("delete", name);
    try std.testing.expect(sig.flags.optional);
}

test "Flow object type: string literal as property key (`'aria-label'`)" {
    // RN Button.js 의 `'aria-label'?: ?string` 형태.
    var r = try parseFlow(std.testing.allocator,
        \\type X = { 'aria-label'?: string };
    );
    defer r.deinit();

    const sig = extractFirstPropSig(r.parser, .flow_property_signature);
    try std.testing.expectEqual(Tag.string_literal, r.parser.ast.getNode(sig.key).tag);
    try std.testing.expect(sig.flags.optional);
}

test "Flow object type: generic method signature skipped (`foo<T>(): R`)" {
    // RN ReactNativeTypes.js 의 `findHostInstance_DEPRECATED<T: Foo>(arg: T): R` 형태.
    // 제네릭 type param `<...>` + paren `(...)` 둘 다 method 표시.
    var r = try parseFlow(std.testing.allocator,
        \\type X = { foo<T>(arg: T): R };
    );
    defer r.deinit();

    var prop_count: usize = 0;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag == .flow_property_signature) prop_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), prop_count);
}

test "Flow object type: spread `...Type` is skipped (not in member list)" {
    // `...ViewProps` 같은 spread 는 PR #3a-2 스코프 밖이라 silent skip.
    // codegen (#3b) 이 RN ViewProps 등을 자체 처리하므로 의도적.
    var r = try parseFlow(std.testing.allocator,
        \\type Props = {| color: string, ...Other |};
    );
    defer r.deinit();

    var prop_count: usize = 0;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag == .flow_property_signature) prop_count += 1;
    }
    // spread 는 skip → color 만 남음.
    try std.testing.expectEqual(@as(usize, 1), prop_count);
}

// ===== Flow enum (#2401) — parser 인식 테스트 =====

fn flowEnumDeclCount(r: *const ParsedSource) usize {
    var count: usize = 0;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag == .flow_enum_declaration) count += 1;
    }
    return count;
}

fn flowEnumMemberCount(r: *const ParsedSource) usize {
    var count: usize = 0;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag == .flow_enum_member) count += 1;
    }
    return count;
}

test "Flow enum: default (no `of`) — symbol-typed implicit" {
    var r = try parseFlow(std.testing.allocator,
        \\enum Status {
        \\  Active,
        \\  Inactive,
        \\}
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), flowEnumDeclCount(&r));
    try std.testing.expectEqual(@as(usize, 2), flowEnumMemberCount(&r));
}

test "Flow enum: `of string` with literal initializers" {
    var r = try parseFlow(std.testing.allocator,
        \\enum Color of string {
        \\  Red = 'red',
        \\  Blue = 'blue',
        \\}
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), flowEnumDeclCount(&r));
    try std.testing.expectEqual(@as(usize, 2), flowEnumMemberCount(&r));
}

test "Flow enum: `of number` / `of boolean`" {
    var r = try parseFlow(std.testing.allocator,
        \\enum Level of number { Low = 1, High = 10 }
        \\enum Toggle of boolean { On = true, Off = false }
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), flowEnumDeclCount(&r));
    try std.testing.expectEqual(@as(usize, 4), flowEnumMemberCount(&r));
}

test "Flow enum: open enum with `...,` ellipsis (members only — ellipsis skipped)" {
    var r = try parseFlow(std.testing.allocator,
        \\enum Status {
        \\  Active,
        \\  ...,
        \\}
    );
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 1), flowEnumDeclCount(&r));
    try std.testing.expectEqual(@as(usize, 1), flowEnumMemberCount(&r));
}

test "Flow enum: TS mode 에서는 일반 ts_enum_declaration" {
    var r = try parseTs(std.testing.allocator,
        \\enum Status {
        \\  Active,
        \\  Inactive,
        \\}
    );
    defer r.deinit();
    var ts_count: usize = 0;
    for (r.parser.ast.nodes.items) |node| {
        if (node.tag == .ts_enum_declaration) ts_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ts_count);
    try std.testing.expectEqual(@as(usize, 0), flowEnumDeclCount(&r));
}
