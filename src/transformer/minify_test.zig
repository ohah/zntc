const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Transformer = @import("transformer.zig").Transformer;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const minify_mod = @import("minify.zig");

fn expectMinify(input: []const u8, expected: []const u8) !void {
    return expectMinifyOpts(input, expected, .{});
}

/// `--minify` 플래그 시 codegen peephole(`true`→`!0`, `undefined`→`(void 0)`)까지 적용된 결과 비교.
fn expectMinifySyntax(input: []const u8, expected: []const u8) !void {
    return expectMinifyOpts(input, expected, .{ .minify_syntax = true });
}

fn expectMinifyOpts(
    input: []const u8,
    expected: []const u8,
    codegen_opts: @import("../codegen/codegen.zig").CodegenOptions,
) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scanner = try Scanner.init(a, input);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();

    var transformer = try Transformer.init(a, &parser.ast, .{});
    const root = try transformer.transform();

    minify_mod.minify(&transformer.ast);

    var cg = Codegen.initWithOptions(a, &transformer.ast, codegen_opts);
    const result = try cg.generate(root);
    const trimmed = std.mem.trimRight(u8, result, "\n");
    try std.testing.expectEqualStrings(expected, trimmed);
}

// ================================================================
// Phase 1: Constant Folding
// ================================================================

test "minify: numeric addition" {
    try expectMinify("const x = 1 + 2;", "const x = 3;");
}

test "minify: numeric subtraction" {
    try expectMinify("const x = 10 - 3;", "const x = 7;");
}

test "minify: numeric multiplication" {
    try expectMinify("const x = 6 * 7;", "const x = 42;");
}

test "minify: numeric division" {
    try expectMinify("const x = 10 / 2;", "const x = 5;");
}

test "minify: numeric modulo" {
    try expectMinify("const x = 10 % 3;", "const x = 1;");
}

test "minify: numeric exponentiation" {
    try expectMinify("const x = 2 ** 3;", "const x = 8;");
}

test "minify: bitwise or" {
    try expectMinify("const x = 3 | 4;", "const x = 7;");
}

test "minify: bitwise and" {
    try expectMinify("const x = 7 & 3;", "const x = 3;");
}

test "minify: bitwise xor" {
    try expectMinify("const x = 5 ^ 3;", "const x = 6;");
}

test "minify: string concatenation" {
    try expectMinify(
        \\const x = "hello" + " world";
    ,
        \\const x = "hello world";
    );
}

test "minify: string concat with single quotes preserves inner double quote (#1565 회귀)" {
    // 내부에 `"`를 가진 single-quote 쌍끼리 concat 시 foldStringConcat이 raw 바이트를
    // double quote로 재포장하면 escape 누락으로 hermesc가 구문 오류를 뱉던 회귀 사례.
    // 양쪽 quote 일치 조건으로 single quote 쌍끼리 안전히 접은 뒤, codegen 정규화가
    // double quote로 바꾸면서 내부 `"`를 정상 escape 처리한다.
    try expectMinify(
        \\const x = 'a "native" ' + 'b';
    ,
        \\const x = "a \"native\" b";
    );
}

test "minify: string concat with different quotes aborts fold (#1565)" {
    // single + double 혼합은 escape 변환이 필요하므로 fold 포기 — 이항식이 유지된다.
    // codegen은 각 리터럴을 double quote로 정규화하지만 `+` 연산은 그대로.
    try expectMinify(
        \\const x = 'a "x" ' + "b";
    ,
        \\const x = "a \"x\" " + "b";
    );
}

test "minify: string concat with single quotes + escaped single quote (#1565)" {
    // 내부에 `\'`가 있는 single-quote 쌍을 fold한 뒤 codegen이 double quote로 정규화하면
    // `\'`가 불필요해져 평범한 `'`로 돌아간다. 결과는 여전히 유효한 JS.
    try expectMinify(
        \\const x = 'a\'b' + 'c';
    ,
        \\const x = "a'bc";
    );
}

test "minify: unary not true" {
    try expectMinify("const x = !true;", "const x = false;");
}

test "minify: unary not false" {
    try expectMinify("const x = !false;", "const x = true;");
}

test "minify: unary not zero" {
    try expectMinify("const x = !0;", "const x = true;");
}

test "minify: unary not nonzero" {
    try expectMinify("const x = !42;", "const x = false;");
}

test "minify: typeof string literal" {
    try expectMinify(
        \\const x = typeof "hello";
    ,
        \\const x = "string";
    );
}

test "minify: typeof number literal" {
    try expectMinify("const x = typeof 42;", "const x = \"number\";");
}

test "minify: typeof boolean literal" {
    try expectMinify("const x = typeof true;", "const x = \"boolean\";");
}

test "minify: typeof null" {
    try expectMinify("const x = typeof null;", "const x = \"object\";");
}

test "minify: strict equality numbers" {
    try expectMinify("const x = 1 === 1;", "const x = true;");
}

test "minify: strict inequality numbers" {
    try expectMinify("const x = 1 !== 2;", "const x = true;");
}

test "minify: strict equality strings" {
    try expectMinify(
        \\const x = "a" === "b";
    ,
        "const x = false;",
    );
}

test "minify: strict equality booleans" {
    try expectMinify("const x = true === true;", "const x = true;");
}

test "minify: division by zero not folded" {
    try expectMinify("const x = 1 / 0;", "const x = 1 / 0;");
}

test "minify: non-literal not folded" {
    try expectMinify("const x = a + b;", "const x = a + b;");
}

// ================================================================
// Phase 2: Dead Code Elimination
// ================================================================

test "minify: conditional true" {
    try expectMinify(
        \\const x = true ? "yes" : "no";
    ,
        \\const x = "yes";
    );
}

test "minify: conditional false" {
    try expectMinify(
        \\const x = false ? "yes" : "no";
    ,
        \\const x = "no";
    );
}

test "minify: logical and true" {
    try expectMinify("const x = true && foo;", "const x = foo;");
}

test "minify: logical and false" {
    try expectMinify("const x = false && foo;", "const x = false;");
}

test "minify: logical or true" {
    try expectMinify("const x = true || foo;", "const x = true;");
}

test "minify: logical or false" {
    try expectMinify("const x = false || foo;", "const x = foo;");
}

test "minify: nullish coalescing null" {
    try expectMinify(
        \\const x = null ?? "default";
    ,
        \\const x = "default";
    );
}

test "minify: while false removed" {
    try expectMinify("while (false) { console.log(1); }", ";");
}

test "minify: if true keeps then" {
    try expectMinify(
        "if (true) { console.log(1); } else { console.log(2); }",
        "{\n\tconsole.log(1);\n}",
    );
}

test "minify: if false keeps else" {
    try expectMinify(
        "if (false) { console.log(1); } else { console.log(2); }",
        "{\n\tconsole.log(2);\n}",
    );
}

test "minify: if false no else becomes empty" {
    try expectMinify("if (false) { console.log(1); }", ";");
}

// ================================================================
// Phase 3: Boolean Simplification
// ================================================================

test "minify: double negation elimination" {
    try expectMinify("const x = !!y;", "const x = y;");
}

test "minify: double negation with expression" {
    try expectMinify("const x = !!foo();", "const x = foo();");
}

test "minify: x === true simplifies to x" {
    try expectMinify("const x = y === true;", "const x = y;");
}

test "minify: x === false simplifies to !x" {
    try expectMinify("const x = y === false;", "const x = !y;");
}

test "minify: x !== true simplifies to !x" {
    try expectMinify("const x = y !== true;", "const x = !y;");
}

test "minify: x !== false simplifies to x" {
    try expectMinify("const x = y !== false;", "const x = y;");
}

test "minify: true === x simplifies to x" {
    try expectMinify("const x = true === y;", "const x = y;");
}

test "minify: false === x simplifies to !x" {
    try expectMinify("const x = false === y;", "const x = !y;");
}

test "minify: literal === literal not simplified here" {
    // 양쪽 모두 리터럴이면 foldStrictEquality에서 처리
    try expectMinify("const x = true === true;", "const x = true;");
}

test "minify: triple negation reduces to single" {
    try expectMinify("const x = !!!y;", "const x = !y;");
}

// ================================================================
// Phase 4: Comma Operator + Template Literal Folding
// ================================================================

test "minify: comma operator with literal lhs" {
    try expectMinify("const x = (0, foo);", "const x = (foo);");
}

test "minify: comma operator with string lhs" {
    try expectMinify(
        \\const x = ("unused", bar);
    ,
        "const x = (bar);",
    );
}

test "minify: comma operator with non-literal lhs preserved" {
    try expectMinify("const x = (a(), foo);", "const x = (a(),foo);");
}

test "minify: comma operator with 3+ literal items simplified" {
    try expectMinify("const x = (0, 1, foo);", "const x = (foo);");
}

test "minify: comma operator mixed keeps non-literal" {
    try expectMinify("const x = (0, a(), foo);", "const x = (a(),foo);");
}

// ================================================================
// Peephole: undefined → (void 0) (minify_syntax only, #1552)
// ================================================================

test "minify_syntax: undefined → (void 0)" {
    try expectMinifySyntax("const x = undefined;", "const x = (void 0);");
}

test "minify_syntax: undefined 비교" {
    try expectMinifySyntax(
        "const x = a === undefined;",
        "const x = a === (void 0);",
    );
}

test "minify_syntax: undefined.x 치환 시 parens로 안전 유지" {
    // `undefined.x`를 bare `void 0.x`로 바꾸면 `void (0.x)`로 오파싱.
    // `(void 0)` 형태 유지로 member access가 정확히 `(void 0).x`가 된다.
    try expectMinifySyntax(
        "const x = undefined.foo;",
        "const x = (void 0).foo;",
    );
}

test "minify_syntax: undefined() call" {
    try expectMinifySyntax(
        "try { undefined(); } catch(e) {}",
        "try {\n\t(void 0)();\n} catch (e) {\n}",
    );
}

test "minify_syntax 없음: undefined 보존" {
    // minify_syntax 꺼져 있으면 바꾸지 않음 — 디버깅 가독성 유지.
    try expectMinify("const x = undefined;", "const x = undefined;");
}
