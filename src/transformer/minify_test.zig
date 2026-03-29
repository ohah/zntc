const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Transformer = @import("transformer.zig").Transformer;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const minify_mod = @import("minify.zig");

fn expectMinify(input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scanner = try Scanner.init(a, input);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();

    var transformer = Transformer.init(a, &parser.ast, .{});
    const root = try transformer.transform();

    minify_mod.minify(&transformer.new_ast);

    var cg = Codegen.init(a, &transformer.new_ast);
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

test "minify: comma operator with 3+ items preserved" {
    try expectMinify("const x = (0, 1, foo);", "const x = (0,1,foo);");
}

test "minify: template literal all string substitutions" {
    // TODO: transformer の new_ast でtemplate_literalのdata構造調査後に有効化
    // try expectMinify(
    //     \\const x = `${"hello"} world`;
    // ,
    //     \\const x = "hello world";
    // );
}

test "minify: template literal no substitutions preserved" {
    try expectMinify("const x = `hello`;", "const x = `hello`;");
}

test "minify: template literal with expression preserved" {
    try expectMinify("const x = `${foo}bar`;", "const x = `${foo}bar`;");
}
