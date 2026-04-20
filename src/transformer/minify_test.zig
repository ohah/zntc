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

    minify_mod.minify(&transformer.ast, .empty);
    minify_mod.mergeDecls(&transformer.ast, null);

    var cg = Codegen.initWithOptions(a, &transformer.ast, codegen_opts);
    const result = try cg.generate(root);
    const trimmed = std.mem.trimRight(u8, result, "\n");
    try std.testing.expectEqualStrings(expected, trimmed);
}

/// merge를 두 번 호출해 idempotency 검증.
fn expectMergeIdempotent(input: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scanner = try Scanner.init(a, input);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();

    var transformer = try Transformer.init(a, &parser.ast, .{});
    const root = try transformer.transform();

    minify_mod.minify(&transformer.ast, .empty);
    minify_mod.mergeDecls(&transformer.ast, null);
    minify_mod.mergeDecls(&transformer.ast, null); // 두 번째 호출 — 결과 동일해야 함

    var cg = Codegen.initWithOptions(a, &transformer.ast, .{});
    const result = try cg.generate(root);
    const trimmed = std.mem.trimRight(u8, result, "\n");
    try std.testing.expectEqualStrings(expected, trimmed);
}

/// skip_nodes 마킹된 statement가 merge에서 제외되는지 검증.
/// `skip_substrs` 각 요소는 source 내 substring — 매칭되는 statement의 span 범위를
/// 가진 노드를 skip으로 마킹한 뒤 mergeDecls를 실행한다. 검증은 program 최상위
/// statement list의 요소 개수 + 병합된 선언의 declarator 개수로 수행한다.
fn expectMergeWithSkip(
    input: []const u8,
    skip_substrs: []const []const u8,
    expected_top_stmt_count: usize,
    expected_first_decl_declarator_count: ?usize,
) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scanner = try Scanner.init(a, input);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();

    var transformer = try Transformer.init(a, &parser.ast, .{});
    _ = try transformer.transform();

    minify_mod.minify(&transformer.ast, .empty);

    var skip = try std.DynamicBitSet.initEmpty(a, transformer.ast.nodes.items.len);
    // substring의 시작 위치와 일치하는 variable_declaration을 **전부** 마킹.
    // transformer가 노드를 복제/재생성하므로 같은 span을 가진 노드가 pre/post-transform
    // 양쪽에 존재할 수 있다. 실제 활성 program 리스트가 가리키는 노드는 후자.
    for (skip_substrs) |needle| {
        const pos = std.mem.indexOf(u8, input, needle) orelse continue;
        const start: u32 = @intCast(pos);
        for (transformer.ast.nodes.items, 0..) |n, i| {
            if (n.tag != .variable_declaration) continue;
            if (n.span.start == start) skip.set(i);
        }
    }

    minify_mod.mergeDecls(&transformer.ast, &skip);

    // program 노드 찾기 (codegen이 쓰는 마지막 .program)
    var prog_idx: ?u32 = null;
    for (transformer.ast.nodes.items, 0..) |n, i| {
        if (n.tag == .program) prog_idx = @intCast(i);
    }
    try std.testing.expect(prog_idx != null);
    const prog = transformer.ast.nodes.items[prog_idx.?];
    try std.testing.expectEqual(@as(usize, expected_top_stmt_count), prog.data.list.len);

    if (expected_first_decl_declarator_count) |count| {
        const stmts = transformer.ast.extra_data.items[prog.data.list.start .. prog.data.list.start + prog.data.list.len];
        for (stmts) |raw_ni| {
            const n = transformer.ast.nodes.items[raw_ni];
            if (n.tag != .variable_declaration) continue;
            const decl_len = transformer.ast.extra_data.items[n.data.extra + 2];
            try std.testing.expectEqual(count, decl_len);
            return;
        }
        try std.testing.expect(false); // variable_declaration 못 찾음
    }
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

// `!!x`는 `ToBoolean(x)` 강제변환이므로 operand가 이미 boolean일 때만 축약 안전.
// 증명 불가한 경우 유지 — oxc/esbuild/swc 모두 같은 가드 (#1577).

test "minify: !! preserved on identifier (non-boolean)" {
    try expectMinify("const x = !!y;", "const x = !!y;");
}

test "minify: !! preserved on function call" {
    // 반환 타입을 정적으로 알 수 없음
    try expectMinify("const x = !!foo();", "const x = !!foo();");
}

test "minify: !! eliminated on strict equality" {
    // a === b는 항상 boolean
    try expectMinify("const x = !!(a === b);", "const x = a === b;");
}

test "minify: !! eliminated on relational" {
    try expectMinify("const x = !!(a < b);", "const x = a < b;");
}

test "minify: !! eliminated on instanceof" {
    try expectMinify("const x = !!(a instanceof B);", "const x = a instanceof B;");
}

test "minify: !! preserved on logical AND" {
    // `a && b`는 b 값을 반환 — boolean이 아닐 수 있음
    try expectMinify("const x = !!(a && b);", "const x = !!(a && b);");
}

test "minify: triple negation reduces to single" {
    // !!!y → !y : outer 노드의 inner_operand는 `!y`이고 `!y`는 보장 boolean
    try expectMinify("const x = !!!y;", "const x = !y;");
}

// x === true / x === false 축약도 같은 이유로 가드 (#1577).
// `y = 1` 일 때 `y === true`는 false, `y`는 1 — 서로 다르다.

test "minify: x === true preserved on non-boolean x" {
    try expectMinify("const x = y === true;", "const x = y === true;");
}

test "minify: x === false preserved on non-boolean x" {
    try expectMinify("const x = y === false;", "const x = y === false;");
}

test "minify: x !== true preserved on non-boolean x" {
    try expectMinify("const x = y !== true;", "const x = y !== true;");
}

test "minify: x !== false preserved on non-boolean x" {
    try expectMinify("const x = y !== false;", "const x = y !== false;");
}

test "minify: true === x preserved on non-boolean x" {
    try expectMinify("const x = true === y;", "const x = true === y;");
}

test "minify: false === x preserved on non-boolean x" {
    try expectMinify("const x = false === y;", "const x = false === y;");
}

test "minify: (a === b) === true simplifies — boolean-typed lhs" {
    // 좌변이 비교 연산이면 boolean 보장 → 축약 가능
    try expectMinify("const x = (a === b) === true;", "const x = a === b;");
}

test "minify: (!y) === true simplifies to !y — unary ! is boolean-typed" {
    try expectMinify("const x = (!y) === true;", "const x = !y;");
}

test "minify: literal === literal still folds" {
    // 양쪽 모두 리터럴이면 foldStrictEquality에서 처리
    try expectMinify("const x = true === true;", "const x = true;");
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

// ================================================================
// Phase 5: 인접한 같은-kind 선언 merge (#1588)
// ================================================================
//
// `var a=1; var b=2;` → `var a=1,b=2;` — 선언당 4-6 바이트 절감.
// 같은 block scope 내 연속된 동일 kind(var/var, let/let, const/const)만 대상.
// 다른 kind 섞임, 중간 statement, export decl은 merge 중단.

test "merge decls: 연속된 const 두 개" {
    try expectMinify(
        "const a = 1; const b = 2;",
        "const a = 1,b = 2;",
    );
}

test "merge decls: 연속된 var 세 개" {
    try expectMinify(
        "var a = 1; var b = 2; var c = 3;",
        "var a = 1,b = 2,c = 3;",
    );
}

test "merge decls: 연속된 let" {
    try expectMinify(
        "let a = 1; let b = 2;",
        "let a = 1,b = 2;",
    );
}

test "merge decls: initializer 없는 선언 포함" {
    try expectMinify(
        "let a; let b = 2; let c;",
        "let a,b = 2,c;",
    );
}

test "merge decls: 다른 kind는 merge 안 함" {
    try expectMinify(
        "var a = 1; const b = 2;",
        "var a = 1;\nconst b = 2;",
    );
}

test "merge decls: const/let 섞임은 merge 안 함" {
    try expectMinify(
        "const a = 1; let b = 2;",
        "const a = 1;\nlet b = 2;",
    );
}

test "merge decls: 중간에 다른 statement 있으면 중단" {
    try expectMinify(
        "const a = 1; foo(); const b = 2;",
        "const a = 1;\nfoo();\nconst b = 2;",
    );
}

test "merge decls: function 선언으로 중단, 이후 재개" {
    try expectMinify(
        "const a = 1; function f() {} const b = 2; const c = 3;",
        "const a = 1;\nfunction f() {\n}\nconst b = 2,c = 3;",
    );
}

test "merge decls: export const는 merge 안 함 (export 구문 보존)" {
    try expectMinify(
        "export const a = 1; export const b = 2;",
        "export const a = 1;\nexport const b = 2;",
    );
}

test "merge decls: block scope 내부에서도 동작" {
    try expectMinify(
        "{ const a = 1; const b = 2; }",
        "{\n\tconst a = 1,b = 2;\n}",
    );
}

test "merge decls: 함수 body 내부에서도 동작" {
    try expectMinify(
        "function f() { var a = 1; var b = 2; }",
        "function f() {\n\tvar a = 1,b = 2;\n}",
    );
}

test "merge decls: destructuring 포함 선언 merge" {
    // codegen은 shorthand destructuring을 `{ b:b }` 형태로 전개해 출력 — 동작 확인 차원에서 유지.
    try expectMinify(
        "const a = 1; const { b } = obj;",
        "const a = 1,{ b:b } = obj;",
    );
}

test "merge decls: 세 개가 모두 같은 kind이면 하나로" {
    try expectMinify(
        "const x = new Foo(); const y = Symbol(); const z = new Set();",
        "const x = new Foo(),y = Symbol(),z = new Set();",
    );
}

test "merge decls: using도 merge — dispose LIFO 순서가 동일" {
    // `using a = f(); using b = g();` → dispose 스택 [a, b], block 끝에서 b→a 순 pop
    // `using a = f(), b = g();` → declarator 좌→우로 스택에 추가, 동일하게 b→a
    // 따라서 dispose 시맨틱 동일 → 안전하게 merge
    try expectMinify(
        "{ using a = f(); using b = g(); }",
        "{\n\tusing a = f(),b = g();\n}",
    );
}

test "merge decls: var는 merge 하되 사이 if는 차단" {
    try expectMinify(
        "var a = 1; if (x) y(); var b = 2; var c = 3;",
        "var a = 1;\nif (x)y();\nvar b = 2,c = 3;",
    );
}

// ================================================================
// Phase 5b: Edge cases (#1588)
// ================================================================

test "merge decls: for-init의 선언은 주변 var와 무관" {
    // for-statement의 init은 program 리스트의 entry이며 variable_declaration이 아니라
    // for-statement 자체로 감싸짐. 앞뒤 var 선언은 for로 차단되어 merge 안 됨.
    try expectMinify(
        "var a = 1; for (var i = 0; i < 3; i++) {} var b = 2;",
        "var a = 1;\nfor (var i = 0; i < 3; i++) {\n}\nvar b = 2;",
    );
}

test "merge decls: 중첩 block 각자 독립 merge" {
    try expectMinify(
        "{ const a = 1; { const b = 2; const c = 3; } const d = 4; }",
        "{\n\tconst a = 1;\n\t{\n\t\tconst b = 2,c = 3;\n\t}\n\tconst d = 4;\n}",
    );
}

test "merge decls: TypeScript 타입 어노테이션이 erase된 뒤에도 merge" {
    // transformer가 TS 타입 어노테이션을 제거하므로 codegen 시점엔 순수 JS 선언만 남음.
    // merge 대상 판별은 kind만 보므로 영향 없음.
    try expectMinify(
        "const a: number = 1; const b: string = \"x\";",
        "const a = 1,b = \"x\";",
    );
}

test "merge decls: arrow function body의 block 내부 merge" {
    try expectMinify(
        "const f = () => { var a = 1; var b = 2; };",
        "const f = () => {\n\tvar a = 1,b = 2;\n};",
    );
}

test "merge decls: try block 내부 merge" {
    try expectMinify(
        "try { const a = 1; const b = 2; } catch (e) {}",
        "try {\n\tconst a = 1,b = 2;\n} catch (e) {\n}",
    );
}

test "merge decls: catch block 내부 merge" {
    try expectMinify(
        "try {} catch (e) { const a = 1; const b = 2; }",
        "try {\n} catch (e) {\n\tconst a = 1,b = 2;\n}",
    );
}

test "merge decls: nested function은 바깥 선언 인접성을 차단" {
    // function 중간 statement는 adjacency를 끊음. 안쪽 function body는 독립 merge.
    try expectMinify(
        "const a = 1; function g() { var x = 1; var y = 2; } const b = 2;",
        "const a = 1;\nfunction g() {\n\tvar x = 1,y = 2;\n}\nconst b = 2;",
    );
}

test "merge decls: let 다음 const → kind 변화로 차단, 이후 let 재개" {
    try expectMinify(
        "let a = 1; const b = 2; let c = 3; let d = 4;",
        "let a = 1;\nconst b = 2;\nlet c = 3,d = 4;",
    );
}

test "merge decls: TDZ 순서 보존 — 후속 declarator가 앞선 declarator 참조" {
    // `const a = 1; const b = a + 1;` → merge 후에도 a가 b보다 먼저 평가됨 (좌→우)
    try expectMinify(
        "const a = 1; const b = a + 1;",
        "const a = 1,b = a + 1;",
    );
}

test "merge decls: TS declare const는 erase 후 사라져 뒤의 const만 merge" {
    // `declare const`는 ambient 선언 — transformer가 출력에서 제거. 남은 두 const만 merge.
    try expectMinify(
        "declare const a: number; const b = 1; const c = 2;",
        "const b = 1,c = 2;",
    );
}

test "merge decls: idempotent — 두 번 호출해도 결과 동일" {
    try expectMergeIdempotent(
        "const a = 1; const b = 2; const c = 3;",
        "const a = 1,b = 2,c = 3;",
    );
}

test "merge decls: idempotent — 중간 차단 후 재개 케이스도 안정" {
    try expectMergeIdempotent(
        "var a = 1; var b = 2; foo(); var c = 3; var d = 4;",
        "var a = 1,b = 2;\nfoo();\nvar c = 3,d = 4;",
    );
}

test "merge decls: skip_nodes 마킹된 선언은 자신이 merge되지 않고 주변 선언은 건너뛰어 merge" {
    // tree-shake로 b가 제거될 예정이면 codegen 시점의 논리적 출력은 [a, c] — 인접.
    // 따라서 알고리즘은 b(skip)를 건너뛰고 a와 c를 merge — 바이트 절감 효과 극대화.
    // 결과: program statement list = [a(decls=[a,c]), b(skip)], top_len=2.
    try expectMergeWithSkip(
        "const a = 1; const b = 2; const c = 3;",
        &.{"const b = 2;"},
        2,
        2,
    );
}

test "merge decls: skip_nodes로 중간 선언 제외 시 주변 3개 모두 merge" {
    // [a, b(skip), c, d] → skip된 b는 그대로 남고, a/c/d가 한 선언으로 병합.
    // program = [a(decls=[a,c,d]), b(skip)], top_len=2, a의 declarator 수=3.
    try expectMergeWithSkip(
        "const a = 1; const b = 2; const c = 3; const d = 4;",
        &.{"const b = 2;"},
        2,
        3,
    );
}

test "merge decls: skip_nodes가 kind 차이가 있는 경계에서는 merge 차단" {
    // a(const) + b(let, skip) + c(const) — skip된 b는 어차피 merge 대상이 아님.
    // 그러나 a와 c는 둘 다 const이고, skip된 b를 건너뛰면 인접한 const 쌍.
    // 알고리즘은 skip을 통과해 a+c를 merge.
    try expectMergeWithSkip(
        "const a = 1; let b = 2; const c = 3;",
        &.{"let b = 2;"},
        2,
        2,
    );
}

// ================================================================
// Dead Store Elimination — Unused Declaration (#1644 PR1)
// ================================================================

const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

/// Semantic analyzer 를 포함한 minify 파이프라인. dead store pass 가 활성화된다.
/// 함수 body 안에 코드를 넣어야 top-level 제외 규칙을 피할 수 있다 — 헬퍼가 자동 래핑.
fn expectMinifyDead(body: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 함수 본문으로 감싸서 로컬 스코프 안의 선언으로 만듬 (top-level 제외 규칙 우회).
    // 외부에서 run 을 호출하므로 run 자체는 reference_count > 0 → 제거 안 됨.
    const wrapped = try std.fmt.allocPrint(a, "function run(){{{s}}}run();", .{body});

    var scanner = try Scanner.init(a, wrapped);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    const root = try transformer.transform();

    const ctx: minify_mod.MinifyCtx = .{
        .symbols = analyzer.symbols.items,
        .symbol_ids = transformer.symbol_ids.items,
        .scopes = analyzer.scopes.items,
        .unresolved_globals = null,
    };
    minify_mod.minify(&transformer.ast, ctx);
    minify_mod.mergeDecls(&transformer.ast, null);

    var cg = Codegen.initWithOptions(a, &transformer.ast, .{});
    const result = try cg.generate(root);
    const trimmed = std.mem.trimRight(u8, result, "\n");
    try std.testing.expectEqualStrings(expected, trimmed);
}

// ---- 제거 가능 (함수 local, unused, pure init) ----

test "dead store: unused let with literal init 제거" {
    try expectMinifyDead("let x = 1;", "function run() {\n\t;\n}\nrun();");
}

test "dead store: unused const with literal init 제거" {
    try expectMinifyDead("const x = 1;", "function run() {\n\t;\n}\nrun();");
}

test "dead store: unused var with literal init 제거" {
    try expectMinifyDead("var x = 1;", "function run() {\n\t;\n}\nrun();");
}

test "dead store: unused let init 없음 — 제거" {
    try expectMinifyDead("let x;", "function run() {\n\t;\n}\nrun();");
}

test "dead store: unused let with string literal 제거" {
    try expectMinifyDead("let x = \"secret\";", "function run() {\n\t;\n}\nrun();");
}

test "dead store: unused let with member access (pure) 제거 — 연쇄로 o 도 제거" {
    // obj.prop 은 purity 관점 pure. x 제거 시 o 의 ref_count 가 0 → 같은 pass 안에서
    // o 가 아직 방문 안 된 상태면 연쇄 제거됨 (oxc fixed-point 효과를 단일 pass 로 부분 달성).
    try expectMinifyDead(
        "const o = { a: 1 }; let x = o.a;",
        "function run() {\n\t;\n\t;\n}\nrun();",
    );
}

test "dead store: unused let with pure binary 제거" {
    try expectMinifyDead("let x = 1 + 2;", "function run() {\n\t;\n}\nrun();");
}

// ---- 제거 금지 — 사용됨 ----

test "dead store: read 1회 — 유지" {
    try expectMinifyDead(
        "let x = 1; console.log(x);",
        "function run() {\n\tlet x = 1;\n\tconsole.log(x);\n}\nrun();",
    );
}

test "dead store: write (reassign) — 유지 (write_count 증가)" {
    try expectMinifyDead(
        "let x = 1; x = 2;",
        "function run() {\n\tlet x = 1;\n\tx = 2;\n}\nrun();",
    );
}

test "dead store: compound assign — 유지" {
    try expectMinifyDead(
        "let x = 1; x += 2;",
        "function run() {\n\tlet x = 1;\n\tx += 2;\n}\nrun();",
    );
}

test "dead store: update expression — 유지" {
    try expectMinifyDead(
        "let x = 0; x++;",
        "function run() {\n\tlet x = 0;\n\tx++;\n}\nrun();",
    );
}

// ---- 제거 금지 — init 불순 ----

test "dead store: unused let with impure call — 유지" {
    // helper() 는 @__PURE__ 없으면 불순. 강등(→ expression_statement)은 PR1.5 범위
    try expectMinifyDead(
        "let x = helper();",
        "function run() {\n\tlet x = helper();\n}\nrun();",
    );
}

test "dead store: unused let with @__PURE__ call — 제거" {
    try expectMinifyDead(
        "let x = /*#__PURE__*/ helper();",
        "function run() {\n\t;\n}\nrun();",
    );
}

// ---- 제거 금지 — 안전성 체크리스트 ----

test "dead store: using declaration — 유지 (Symbol.dispose side-effect)" {
    try expectMinifyDead(
        "using x = getResource();",
        "function run() {\n\tusing x = getResource();\n}\nrun();",
    );
}

test "dead store: await using — 유지" {
    // await 은 async function 안에서만 유효해서 이 테스트는 별도 래퍼 필요
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "async function run(){await using x = getResource();}run();";
    var scanner = try Scanner.init(a, src);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    const root = try transformer.transform();
    const ctx: minify_mod.MinifyCtx = .{
        .symbols = analyzer.symbols.items,
        .symbol_ids = transformer.symbol_ids.items,
        .scopes = analyzer.scopes.items,
        .unresolved_globals = null,
    };
    minify_mod.minify(&transformer.ast, ctx);
    var cg = Codegen.initWithOptions(a, &transformer.ast, .{});
    const result = try cg.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, result, "await using x") != null);
}

test "dead store: destructuring binding — 유지 (pattern 은 getter 호출 가능)" {
    try expectMinifyDead(
        "const { x } = { x: 1 };",
        "function run() {\n\tconst { x:x } = { x: 1 };\n}\nrun();",
    );
}

test "dead store: array destructuring — 유지" {
    try expectMinifyDead(
        "const [x] = [1];",
        "function run() {\n\tconst [x] = [1];\n}\nrun();",
    );
}

test "dead store: declarator 2개 — 유지 (부분 제거는 PR 범위 밖)" {
    try expectMinifyDead(
        "let x = 1, y = 2;",
        "function run() {\n\tlet x = 1,y = 2;\n}\nrun();",
    );
}

test "dead store: eval 포함 스코프 — 유지 (direct eval 이 동적 lookup)" {
    try expectMinifyDead(
        "const veryLongPasswordVar = \"secret\"; return eval(\"veryLongPasswordVar\");",
        "function run() {\n\tconst veryLongPasswordVar = \"secret\";\n\treturn eval(\"veryLongPasswordVar\");\n}\nrun();",
    );
}

test "dead store: for (let i=0;...) 의 i — 유지 (for-loop binding, #1647)" {
    try expectMinifyDead(
        "for (let i = 0; i < 3; i++) { break; }",
        "function run() {\n\tfor (let i = 0; i < 3; i++) {\n\t\tbreak;\n\t}\n}\nrun();",
    );
}

test "dead store: for-of 의 binding 은 body 미사용이어도 유지 (#1647)" {
    // for-of binding 을 제거하면 `for (of arr)` 로 구문 붕괴
    try expectMinifyDead(
        "for (const x of [1,2,3]) { break; }",
        "function run() {\n\tfor (const x of [1, 2, 3]) {\n\t\tbreak;\n\t}\n}\nrun();",
    );
}

test "dead store: for-in 의 binding 유지 (#1647)" {
    try expectMinifyDead(
        "for (const k in {a:1}) { break; }",
        "function run() {\n\tfor (const k in { a: 1 }) {\n\t\tbreak;\n\t}\n}\nrun();",
    );
}

// for-await-of 케이스는 async function 래퍼 안에서만 유효하고 codegen 경로도 다름.
// 통합 테스트 (`tests/integration/tests/downlevel-edge.test.ts` - "for-await-of break +
// async iterator return()") 가 회귀를 검증한다.

test "dead store: top-level const 는 tree-shaker 영역 — 유지" {
    // 함수 래핑 없이 직접 top-level 로 — scope_id == 0 가드 검증
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "const x = 1;";
    var scanner = try Scanner.init(a, src);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    const root = try transformer.transform();
    const ctx: minify_mod.MinifyCtx = .{
        .symbols = analyzer.symbols.items,
        .symbol_ids = transformer.symbol_ids.items,
        .scopes = analyzer.scopes.items,
        .unresolved_globals = null,
    };
    minify_mod.minify(&transformer.ast, ctx);
    var cg = Codegen.initWithOptions(a, &transformer.ast, .{});
    const result = try cg.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 1") != null);
}

// ---- reference_count decrement 검증 ----

test "dead store: 제거 시 init 내부 식별자 reference_count 감산" {
    // `let y = 1; let x = y;` 에서 x 제거 시 y 의 reference_count 가 1 → 0 이 되어야 함.
    // (fixed-point loop 가 도입되면 다음 pass 에서 y 도 제거되는 기반.)
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "function run(){let y = 1; let x = y;}run();";
    var scanner = try Scanner.init(a, src);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    _ = try transformer.transform();

    // 초기: x 는 0 ref, y 는 1 ref (x 의 init 에서 읽힘)
    var y_ref_before: u32 = 0;
    for (analyzer.symbols.items) |sym| {
        const name = sym.nameText(parser.ast.source);
        if (std.mem.eql(u8, name, "y")) y_ref_before = sym.reference_count;
    }
    try std.testing.expectEqual(@as(u32, 1), y_ref_before);

    const ctx: minify_mod.MinifyCtx = .{
        .symbols = analyzer.symbols.items,
        .symbol_ids = transformer.symbol_ids.items,
        .scopes = analyzer.scopes.items,
        .unresolved_globals = null,
    };
    minify_mod.minify(&transformer.ast, ctx);

    // 제거 후: x 가 사라지면서 y 의 reference_count 도 1 → 0
    var y_ref_after: u32 = 0;
    for (analyzer.symbols.items) |sym| {
        const name = sym.nameText(parser.ast.source);
        if (std.mem.eql(u8, name, "y")) y_ref_after = sym.reference_count;
    }
    try std.testing.expectEqual(@as(u32, 0), y_ref_after);
}

// ================================================================
// PR1.5: Unused Expression Simplify (#1644)
// ================================================================

// ---- 제거 가능 (expression_statement 축약) ----

test "expr simplify: 리터럴 statement — empty 로 축약" {
    try expectMinifyDead("1;", "function run() {\n\t;\n}\nrun();");
}

test "expr simplify: string literal statement 축약" {
    try expectMinifyDead("\"x\";", "function run() {\n\t;\n}\nrun();");
}

test "expr simplify: pure binary statement 축약" {
    try expectMinifyDead("1 + 2;", "function run() {\n\t;\n}\nrun();");
}

test "expr simplify: pure unary (! / typeof) 축약" {
    try expectMinifyDead("!0;", "function run() {\n\t;\n}\nrun();");
}

test "expr simplify: local identifier read statement 축약" {
    // local binding 이면 제거 안전. unresolved 는 ReferenceError 가능 → 유지.
    try expectMinifyDead(
        "let x = 1; x;",
        "function run() {\n\t;\n\t;\n}\nrun();",
    );
}

test "expr simplify: @__PURE__ call statement 축약" {
    try expectMinifyDead(
        "/*#__PURE__*/ helper();",
        "function run() {\n\t;\n}\nrun();",
    );
}

// ---- 제거 금지 (getter / ReferenceError / side-effect) ----

test "expr simplify: unresolved identifier statement — 유지 (ReferenceError 가능)" {
    try expectMinifyDead(
        "unknownGlobal;",
        "function run() {\n\tunknownGlobal;\n}\nrun();",
    );
}

test "expr simplify: member access statement — 유지 (getter 위험)" {
    try expectMinifyDead(
        "obj.prop;",
        "function run() {\n\tobj.prop;\n}\nrun();",
    );
}

test "expr simplify: impure call statement — 유지" {
    try expectMinifyDead(
        "helper();",
        "function run() {\n\thelper();\n}\nrun();",
    );
}

test "expr simplify: delete expression — 유지 (side-effect)" {
    try expectMinifyDead(
        "delete obj.x;",
        "function run() {\n\tdelete obj.x;\n}\nrun();",
    );
}

// ---- sequence_expression 확장 (마지막 원소 제외 pure 제거) ----

test "expr simplify: sequence 의 중간 리터럴 제거" {
    // `(1, 2, foo())` 의 pre-fold 는 assignment 같은 곳에서만 등장 — expression_statement 자체는 pure
    // 이면 a 에서 empty 로 바뀐다. 이 테스트는 sequence 가 dead store 와 함께 쓰이는 경우 확인.
    try expectMinifyDead(
        "let x = (1, 2, 3);",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "expr simplify: sequence 의 중간 impure 는 유지" {
    // `(foo(), bar())` 의 foo() 는 side-effect → 유지 필요.
    // statement 로 쓰일 수 없어서 let init 으로 래핑.
    try expectMinifyDead(
        "let x = (foo(), bar());",
        "function run() {\n\tlet x = (foo(),bar());\n}\nrun();",
    );
}
