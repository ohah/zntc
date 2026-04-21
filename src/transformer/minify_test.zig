const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Transformer = @import("transformer.zig").Transformer;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const minify_mod = @import("minify.zig");
const NodeIndex = @import("../parser/ast.zig").NodeIndex;

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

    minify_mod.minify(transformer.ast, .empty, a, root);
    minify_mod.mergeDecls(transformer.ast, null);

    var cg = Codegen.initWithOptions(a, transformer.ast, codegen_opts);
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

    minify_mod.minify(transformer.ast, .empty, a, root);
    minify_mod.mergeDecls(transformer.ast, null);
    minify_mod.mergeDecls(transformer.ast, null); // 두 번째 호출 — 결과 동일해야 함

    var cg = Codegen.initWithOptions(a, transformer.ast, .{});
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
    const root = try transformer.transform();

    minify_mod.minify(transformer.ast, .empty, a, root);

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

    minify_mod.mergeDecls(transformer.ast, &skip);

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
    minify_mod.minify(transformer.ast, ctx, a, root);
    minify_mod.mergeDecls(transformer.ast, null);

    var cg = Codegen.initWithOptions(a, transformer.ast, .{});
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

test "dead store: read 1회 + literal init — Phase 2 inline" {
    // #1666 Phase 2: single-use + constant-expr init → inline. 기존 테스트는 dead-store
    // pass 가 단일 read 를 보존함을 검증했지만, 동일 파이프라인에 Phase 2 inline 이
    // 같이 돌기 때문에 출력은 inlined 형태가 된다. dead-store 의 "read>=1 보존" 규약
    // 자체는 여전히 유효 (인라인이 먼저 일어나 decl 이 empty_statement 로 교체되고,
    // dead-store 는 이 empty 에 개입하지 않는 구조).
    try expectMinifyDead(
        "let x = 1; console.log(x);",
        "function run() {\n\t;\n\tconsole.log(1);\n}\nrun();",
    );
}

test "dead store: read 1회 + 비-constant init — 보존 (inline 조건 미충족)" {
    // Phase 2+3 inline 은 init 이 constant-expression 일 때만 동작. 식별자 의존이
    // 있는 init (예: 파라미터) 은 inline 제외 → 원래 dead-store "read>=1 보존" 경로.
    try expectMinifyDead(
        "function f(n) { let x = n; return x; } f(1);",
        "function run() {\n\tfunction f(n) {\n\t\tlet x = n;\n\t\treturn x;\n\t}\n\tf(1);\n}\nrun();",
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
    minify_mod.minify(transformer.ast, ctx, a, root);
    var cg = Codegen.initWithOptions(a, transformer.ast, .{});
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
    minify_mod.minify(transformer.ast, ctx, a, root);
    var cg = Codegen.initWithOptions(a, transformer.ast, .{});
    const result = try cg.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 1") != null);
}

// ---- reference_count decrement 검증 ----

test "dead store: cascading — y dead 여부는 x 제거의 감산으로 결정" {
    // `let y = 1; let x = y;` 에서 x 제거 → init 내부 y reference 감산 → 다음 iter 에서
    // y 도 제거. minify 는 `sym.reference_count` 를 뮤테이션하지 않고 내부 delta 로만
    // 관리한다 (#번개 실측: 캐시된 semantic 에 감산이 누적되면 rebuild 마다 live 선언이
    // 지워진다). 따라서 "감산됐음" 을 외부 reference_count 로 검증할 수 없고, 최종
    // AST 가 y 도 empty_statement 인지로 확인한다.
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
    const root = try transformer.transform();

    // 초기: y 의 reference_count 가 1 (x 의 init 에서 읽힘)
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
    minify_mod.minify(transformer.ast, ctx, a, root);

    // minify 는 sem.reference_count 를 뮤테이션하지 않아야 한다 (rebuild 누적 감산 방지).
    var y_ref_after: u32 = 0;
    for (analyzer.symbols.items) |sym| {
        const name = sym.nameText(parser.ast.source);
        if (std.mem.eql(u8, name, "y")) y_ref_after = sym.reference_count;
    }
    try std.testing.expectEqual(@as(u32, 1), y_ref_after);

    // 최종 AST: x 와 y 둘 다 empty_statement 여야 함 (cascading dead-store 동작).
    var codegen = Codegen.init(a, transformer.ast);
    defer codegen.deinit();
    const output = try codegen.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, output, "let x") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "let y") == null);
}

// ================================================================
// PR1.5: Unused Expression Simplify (#1644)
// ================================================================

// ---- 제거 가능 (expression_statement 축약) ----

test "expr simplify: 리터럴 statement — empty 로 축약" {
    try expectMinifyDead("1;", "function run() {\n\t;\n}\nrun();");
}

test "expr simplify: string literal statement 축약 (non-prologue)" {
    // 선두 `1;` 로 directive prologue 를 종료 — 뒤 `"x";` 는 .directive 가 아닌 일반
    // expression_statement 로 파싱되어 unused simplify 대상이 된다.
    try expectMinifyDead("1; \"x\";", "function run() {\n\t;\n\t;\n}\nrun();");
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

// ================================================================
// Fixed-Point Loop (#1650)
// ================================================================
//
// 각 pass (fold / simplify / dead store) 결과가 다음 pass 의 제거 기회를 만들어
// `let y = 1; let x = y;` 같은 체인에서 연쇄 dead 가 수렴한다 (1 iter: x 제거 +
// y.ref 1→0 감산, 2 iter: y 제거). `max_fixpoint_iterations = 3` 상한.

test "fixed-point: let y=1; let x=y; — 2 iter 수렴" {
    try expectMinifyDead(
        "let y = 1; let x = y;",
        "function run() {\n\t;\n\t;\n}\nrun();",
    );
}

test "fixed-point: let y=1+2; let x=y; — fold + 연쇄 dead" {
    try expectMinifyDead(
        "let y = 1 + 2; let x = y;",
        "function run() {\n\t;\n\t;\n}\nrun();",
    );
}

test "fixed-point: let y = \"a\" + \"b\"; let x = y; — 문자열 concat 연쇄" {
    try expectMinifyDead(
        "let y = \"a\" + \"b\"; let x = y;",
        "function run() {\n\t;\n\t;\n}\nrun();",
    );
}

test "fixed-point: 3-단 연쇄 (z→y→x) — max 안에 수렴" {
    try expectMinifyDead(
        "let z = 1; let y = z; let x = y;",
        "function run() {\n\t;\n\t;\n\t;\n}\nrun();",
    );
}

test "fixed-point: 사용 중인 chain — Phase 2 inline 이 연쇄 축약" {
    // #1666 Phase 2+3: y=1 (literal) → x 초기식 y 위치에 inline (y decl 제거).
    // 다음 iter: x=1 도 literal init → console.log(x) 에 inline. 두 번의 fixed-point
    // iteration 을 거쳐 `console.log(1)` 만 남음.
    try expectMinifyDead(
        "let y = 1; let x = y; console.log(x);",
        "function run() {\n\t;\n\t;\n\tconsole.log(1);\n}\nrun();",
    );
}

// ================================================================
// Unused Expression In-Place Simplify (#1650 step 2 — c/d)
// ================================================================
//
// statement / sequence 비마지막 원소 자리에서 결과값이 버려지므로 short-circuit 의미만
// 보존되면 내부 부분 제거가 안전. fixed-point loop 로 연쇄됨.
// 대부분 테스트가 `foo()` / `bar()` 같은 unresolved identifier call (impure) 을 써서
// dead store 연쇄를 차단하고 rewrite 자체를 검증한다.

// ---- c.1 conditional → logical rewrite ----

test "unused: foo() ? pure : bar() → foo() || bar()" {
    try expectMinifyDead(
        "foo() ? 1 : bar();",
        "function run() {\n\tfoo() || bar();\n}\nrun();",
    );
}

test "unused: foo() ? bar() : pure → foo() && bar()" {
    try expectMinifyDead(
        "foo() ? bar() : 1;",
        "function run() {\n\tfoo() && bar();\n}\nrun();",
    );
}

test "unused: foo() ? pure : pure → foo()" {
    // b, c 둘 다 removable — test 로 교체 후 test 는 impure 라 유지
    try expectMinifyDead(
        "foo() ? 1 : 2;",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: pure ? pure : pure → empty" {
    try expectMinifyDead(
        "1 ? 2 : 3;",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: foo() ? bar() : baz() → 그대로 (둘 다 impure)" {
    try expectMinifyDead(
        "foo() ? bar() : baz();",
        "function run() {\n\tfoo() ? bar() : baz();\n}\nrun();",
    );
}

// ---- c.2 logical simplify ----

test "unused: foo() && pure → foo()" {
    try expectMinifyDead(
        "foo() && 42;",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: foo() || pure → foo()" {
    try expectMinifyDead(
        "foo() || 1;",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: foo() ?? pure → foo()" {
    try expectMinifyDead(
        "foo() ?? 42;",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: foo() && bar() → 그대로 (right impure)" {
    try expectMinifyDead(
        "foo() && bar();",
        "function run() {\n\tfoo() && bar();\n}\nrun();",
    );
}

// ---- c.3 binary 비교 ----

test "unused: foo() === pure → foo()" {
    try expectMinifyDead(
        "foo() === 1;",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: pure < foo() → foo()" {
    try expectMinifyDead(
        "1 < foo();",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: foo() == bar() → 그대로 (둘 다 impure)" {
    try expectMinifyDead(
        "foo() == bar();",
        "function run() {\n\tfoo() == bar();\n}\nrun();",
    );
}

// ---- d template literal ----

test "unused: `static`; → empty" {
    try expectMinifyDead(
        "`hello`;",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: `a ${pure} c` — substitution 모두 pure → empty" {
    try expectMinifyDead(
        "`a ${1 + 2} c`;",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: `a ${foo()} b` — substitution impure → 유지" {
    try expectMinifyDead(
        "`a ${foo()} b`;",
        "function run() {\n\t`a ${foo()} b`;\n}\nrun();",
    );
}

// ---- 안전성: RHS 자리에선 rewrite 안 됨 ----

test "unused: assignment RHS 의 conditional 은 rewrite 안 됨" {
    // `x = foo() ? 1 : 2;` 은 결과값이 x 에 할당되므로 건드리면 안 됨 — RHS 는 statement 자리 아님
    try expectMinifyDead(
        "let x = foo() ? 1 : 2; console.log(x);",
        "function run() {\n\tlet x = foo() ? 1 : 2;\n\tconsole.log(x);\n}\nrun();",
    );
}

// ---- 안전성: conditional rewrite 시 logical operand 에 paren 자동 삽입 ----

test "unused: conditional kept operand 가 assignment → paren 삽입 rewrite (mobx 회귀)" {
    // `foo() ? pure : x = bar()` 의 alt 는 AssignmentExpression (paren 없이 허용).
    // `foo() || (x = bar())` 로 재작성해야 `||` 우측 grammar 만족.
    // 실제 mobx 번들의 `(_a = annotations) != null ? _a : (annotations = ...)` 회귀 가드.
    try expectMinifyDead(
        "let x = 0; foo() ? 1 : x = bar(); console.log(x);",
        "function run() {\n\tlet x = 0;\n\tfoo() || (x = bar());\n\tconsole.log(x);\n}\nrun();",
    );
}

test "unused: conditional alt_rem 의 cons 가 assignment → paren 삽입" {
    try expectMinifyDead(
        "let x = 0; foo() ? x = bar() : 1; console.log(x);",
        "function run() {\n\tlet x = 0;\n\tfoo() && (x = bar());\n\tconsole.log(x);\n}\nrun();",
    );
}

test "unused: conditional kept operand 가 sequence → paren 삽입" {
    try expectMinifyDead(
        "foo() ? 1 : (bar(), baz());",
        "function run() {\n\tfoo() || (bar(),baz());\n}\nrun();",
    );
}

// ================================================================
// Unused Multi-Element Rewrite — Array / New / Object (#1650 follow-up)
// ================================================================
//
// pure 원소는 drop, impure 는 sequence 로 flatten. spread / getter/proxy 위험은 가드.

// ---- ArrayExpression ----

test "unused: [1, 2, 3]; → empty" {
    try expectMinifyDead(
        "[1, 2, 3];",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: [foo(), 1, bar()]; → pure drop, impure sequence" {
    try expectMinifyDead(
        "[foo(), 1, bar()];",
        "function run() {\n\tfoo(),bar();\n}\nrun();",
    );
}

test "unused: [foo(), 1]; → single impure 로 축약" {
    try expectMinifyDead(
        "[foo(), 1];",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: []; → empty" {
    try expectMinifyDead(
        "[];",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: [...x]; — spread 있으면 rewrite 포기" {
    // spread 는 iterator protocol 호출 side-effect — 축약 자체가 의미 변경
    try expectMinifyDead(
        "[...foo()];",
        "function run() {\n\t[...foo()];\n}\nrun();",
    );
}

// ---- NewExpression ----

test "unused: /*#__PURE__*/ new X(1, 2); → empty" {
    try expectMinifyDead(
        "/*#__PURE__*/ new X(1, 2);",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: /*#__PURE__*/ new X(foo(), 1, bar()); → pure drop sequence" {
    try expectMinifyDead(
        "/*#__PURE__*/ new X(foo(), 1, bar());",
        "function run() {\n\tfoo(),bar();\n}\nrun();",
    );
}

test "unused: new X(1, 2); — @__PURE__ 없으면 유지" {
    try expectMinifyDead(
        "new X(1, 2);",
        "function run() {\n\tnew X(1, 2);\n}\nrun();",
    );
}

test "unused: /*#__PURE__*/ pure(foo()); — CallExpression 동일 처리" {
    try expectMinifyDead(
        "/*#__PURE__*/ pure(foo());",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

// ---- ObjectExpression ----

test "unused: {a: 1, b: 2}; → empty" {
    try expectMinifyDead(
        "({a: 1, b: 2});",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: {a: foo(), b: 1}; → impure sequence" {
    try expectMinifyDead(
        "({a: foo(), b: 1});",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: {[foo()]: 1, b: bar()}; → computed key + value impure 모두 추출" {
    // sequence 로 축약됨. paren unwrap 은 sequence 의 leading 원소 (foo() — call, identifier
    // callee) 가 safe 라 unwrap 허용 → `foo(),bar();`.
    try expectMinifyDead(
        "({[foo()]: 1, b: bar()});",
        "function run() {\n\tfoo(),bar();\n}\nrun();",
    );
}

test "unused: {...x}; — spread 유지" {
    // `...x` 의 x 는 iterator/proxy trap 가능 → 보존. object literal 은 statement 시작에
    // paren 필수 (block 과 모호) — paren 도 유지.
    try expectMinifyDead(
        "({...foo()});",
        "function run() {\n\t({ ...foo() });\n}\nrun();",
    );
}

test "unused: {m() {}}; → method 값은 function_expression 이라 removable" {
    try expectMinifyDead(
        "({m() {}});",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: {[foo()]() {}}; → computed key side-effect 보존" {
    // method 자체는 drop 가능하지만 `[foo()]` key expression 은 객체 생성 시 evaluate → 보존.
    try expectMinifyDead(
        "({[foo()]() {}});",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

test "unused: /*#__PURE__*/ super(x, y) — derived constructor semantic 필수 호출, drop 금지" {
    // super() 는 binding 역할 (this 접근 전 필수). `@__PURE__` 로도 drop 하면 ReferenceError.
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "class A extends B { constructor() { /*#__PURE__*/ super(x, y); } }";
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
    minify_mod.minify(transformer.ast, ctx, a, root);
    var cg = Codegen.initWithOptions(a, transformer.ast, .{});
    const result = try cg.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, result, "super(x, y)") != null);
}

// ================================================================
// TemplateLiteral Partial Rewrite (#1650 step 2/d 확장)
// ================================================================
//
// substitution 중 Symbol 가능성이 있으면 전체 유지 (ToString TypeError 보존).
// 모두 non-symbol 이면 pure 는 drop, impure 는 sequence / single 로 축약.

test "unused: `${pure-literal} ${call}`; → call 만 남은 새 template" {
    // 1 + 2 는 canBeSymbol=false + pure → drop. foo() 는 canBeSymbol=true → pending flush 로
    // 새 template literal 에 감싸짐. 기존 literal quasi (space) 는 재구성 시 버려짐.
    try expectMinifyDead(
        "`${1 + 2} ${foo()}`;",
        "function run() {\n\t`${foo()}`;\n}\nrun();",
    );
}

test "unused: `${call1} ${call2}`; — 모든 substitution Symbol 가능 → 원본 유지 (rewrite 이득 없음)" {
    // 둘 다 canBeSymbol=true → pending 에만 쌓임. dropped_or_split=false → mutation 안 함.
    // fixed-point 무한 재생성 방지 가드.
    try expectMinifyDead(
        "`${foo()} ${bar()}`;",
        "function run() {\n\t`${foo()} ${bar()}`;\n}\nrun();",
    );
}

test "unused: `${pure} ${call}`; → pure drop 되며 template 재구성" {
    // 한쪽이라도 drop 되면 dropped_or_split=true → template 재구성. pure quasi 버려져 축약.
    try expectMinifyDead(
        "`${1} ${foo()}`;",
        "function run() {\n\t`${foo()}`;\n}\nrun();",
    );
}

test "unused: `${Symbol()}`; — Symbol 가능 → 전체 유지" {
    // Symbol() 호출 결과는 Symbol — ToString 호출 시 TypeError. template literal 유지.
    try expectMinifyDead(
        "`${Symbol()}`;",
        "function run() {\n\t`${Symbol()}`;\n}\nrun();",
    );
}

test "unused: `${x}`; — local identifier 는 Symbol 가능 (보수적 유지)" {
    try expectMinifyDead(
        "let x = 1; `${x}`; console.log(x);",
        "function run() {\n\tlet x = 1;\n\t`${x}`;\n\tconsole.log(x);\n}\nrun();",
    );
}

test "unused: `${1 + 2}${true}`; → 모두 non-symbol pure → empty" {
    try expectMinifyDead(
        "`${1 + 2}${true}`;",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: `static`; → empty (substitution 없음, 기존)" {
    try expectMinifyDead(
        "`hello`;",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: `${a ? 1 : 2}`; — conditional 양쪽 non-symbol → drop" {
    try expectMinifyDead(
        "`${true ? 1 : 2}`;",
        "function run() {\n\t;\n}\nrun();",
    );
}

test "unused: `${foo() ? 1 : 2}`; — conditional test impure 는 보존됨" {
    // conditional 의 test 는 simplifyUnusedInPlace 재귀로 축약됨
    try expectMinifyDead(
        "`${foo() ? 1 : 2}`;",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

// ================================================================
// IIFE 회귀 가드 (#1664 E2E 회귀)
// ================================================================
//
// `(function(){})();` 같은 IIFE 는 paren 이 statement 시작 시 파싱 모호성 회피 목적.
// unwrapRedundantStmtParen 이 call_expression 만 보고 unwrap 하면 callee 의
// function_expression 이 그대로 statement 시작 → anonymous function declaration → syntax error.
// isSafeStmtLead 가 leading operand chain 까지 재귀 판정해야 함.

test "unused: (function(){})(args); — IIFE paren 유지 (leading function_expression)" {
    try expectMinifyDead(
        "(function(name){return name;})(\"x\");",
        "function run() {\n\t(function(name) {\n\t\treturn name;\n\t})(\"x\");\n}\nrun();",
    );
}

test "unused: (class X{})(); — class callee 도 paren 유지" {
    try expectMinifyDead(
        "(class X {})();",
        "function run() {\n\t(class X {\n\t})();\n}\nrun();",
    );
}

test "unused: (() => 1)(); — arrow callee 도 paren 유지" {
    try expectMinifyDead(
        "(() => 1)();",
        "function run() {\n\t(() => 1)();\n}\nrun();",
    );
}

test "unused: (foo.bar)(); — call callee 자리 paren 은 minify 범위 밖" {
    // `(foo.bar)()` 의 paren 은 callee 자리 — statement 시작 모호성과 무관. 내 unwrap 은
    // expression_statement 의 operand 자리 paren 만 대상 → 이 paren 은 그대로.
    try expectMinifyDead(
        "(foo.bar)();",
        "function run() {\n\t(foo.bar)();\n}\nrun();",
    );
}

test "unused: ({v} = o); — object destructuring assignment 은 paren 유지 ({ block 모호)" {
    // LHS 가 object_assignment_target 이면 unwrap 시 `{v} = o;` — `{` 가 block 시작으로 파싱.
    try expectMinifyDead(
        "let v, o = {v: 1}; ({v} = o); console.log(v);",
        "function run() {\n\tlet v,o = { v: 1 };\n\t({ v } = o);\n\tconsole.log(v);\n}\nrun();",
    );
}

test "unused: ([a] = arr); — array destructuring assignment 은 paren 유지" {
    try expectMinifyDead(
        "let a, arr = [1]; ([a] = arr); console.log(a);",
        "function run() {\n\tlet a,arr = [1];\n\t([a] = arr);\n\tconsole.log(a);\n}\nrun();",
    );
}

test "unused: (foo()); — 일반 call — unwrap OK" {
    try expectMinifyDead(
        "(foo());",
        "function run() {\n\tfoo();\n}\nrun();",
    );
}

// ================================================================
// Single-use Identifier Inline (#1666 Phase 2+3)
// ================================================================
//
// 조건별 positive/negative 엄격 검증. 각 테스트는 단일 조건만 위반/충족하게 설계.

// ---- Phase 2: literal init inline ----

test "inline: numeric literal const — inline" {
    try expectMinifyDead(
        "const x = 42; console.log(x);",
        "function run() {\n\t;\n\tconsole.log(42);\n}\nrun();",
    );
}

test "inline: string literal const — inline" {
    try expectMinifyDead(
        "const x = \"hi\"; console.log(x);",
        "function run() {\n\t;\n\tconsole.log(\"hi\");\n}\nrun();",
    );
}

test "inline: boolean literal const — inline" {
    try expectMinifyDead(
        "const x = true; console.log(x);",
        "function run() {\n\t;\n\tconsole.log(true);\n}\nrun();",
    );
}

test "inline: null literal — inline" {
    try expectMinifyDead(
        "const x = null; console.log(x);",
        "function run() {\n\t;\n\tconsole.log(null);\n}\nrun();",
    );
}

test "inline: let with literal — inline (const/let 모두 대상)" {
    try expectMinifyDead(
        "let x = 7; console.log(x);",
        "function run() {\n\t;\n\tconsole.log(7);\n}\nrun();",
    );
}

// ---- Phase 3: constant container inline ----

test "inline: array literal 원소 모두 리터럴 — inline" {
    try expectMinifyDead(
        "const arr = [1, 2, 3]; console.log(arr.length);",
        "function run() {\n\t;\n\tconsole.log([1, 2, 3].length);\n}\nrun();",
    );
}

test "inline: object literal 값 모두 리터럴 — inline" {
    try expectMinifyDead(
        "const cfg = { a: 1, b: 2 }; console.log(cfg);",
        "function run() {\n\t;\n\tconsole.log({ a: 1, b: 2 });\n}\nrun();",
    );
}

test "inline: nested literal container — inline" {
    try expectMinifyDead(
        "const data = [[1], { k: 2 }]; console.log(data);",
        "function run() {\n\t;\n\tconsole.log([[1], { k: 2 }]);\n}\nrun();",
    );
}

// ---- 조건 위반: 보존 ----

test "inline: var — 보존 (hoisting 이슈)" {
    try expectMinifyDead(
        "var x = 1; console.log(x);",
        "function run() {\n\tvar x = 1;\n\tconsole.log(x);\n}\nrun();",
    );
}

test "inline: 식별자 의존 init — 보존 (Phase 3 일반 expression 범위 밖)" {
    // init 에 outer variable 참조 → isConstantExpr false → inline skip.
    try expectMinifyDead(
        "function f(n) { const x = n * 2; return x; } f(1);",
        "function run() {\n\tfunction f(n) {\n\t\tconst x = n * 2;\n\t\treturn x;\n\t}\n\tf(1);\n}\nrun();",
    );
}

test "inline: 함수 호출 init — 보존 (pure 확인 불가)" {
    // call_expression 은 isConstantExpr 범위 밖.
    try expectMinifyDead(
        "const x = foo(); console.log(x);",
        "function run() {\n\tconst x = foo();\n\tconsole.log(x);\n}\nrun();",
    );
}

test "inline: shorthand property — 보존 (value 가 identifier_reference)" {
    // { a } 는 value = identifier_reference → constant expr 아님 → inline 불가.
    try expectMinifyDead(
        "function f(a) { const o = { a }; return o; } f(1);",
        "function run() {\n\tfunction f(a) {\n\t\tconst o = { a };\n\t\treturn o;\n\t}\n\tf(1);\n}\nrun();",
    );
}

test "inline: write 있음 — 보존" {
    try expectMinifyDead(
        "let x = 1; x = 2; console.log(x);",
        "function run() {\n\tlet x = 1;\n\tx = 2;\n\tconsole.log(x);\n}\nrun();",
    );
}

test "inline: 여러 번 read — 보존 (ref_count != 1)" {
    try expectMinifyDead(
        "const x = 1; console.log(x, x);",
        "function run() {\n\tconst x = 1;\n\tconsole.log(x, x);\n}\nrun();",
    );
}

test "inline: destructuring — 보존 (단일 binding_identifier 아님)" {
    try expectMinifyDead(
        "function f(arr) { const [x] = arr; return x; } f([1]);",
        "function run() {\n\tfunction f(arr) {\n\t\tconst [x] = arr;\n\t\treturn x;\n\t}\n\tf([1]);\n}\nrun();",
    );
}

test "inline: 다중 declarator — 보존 (list_len != 1)" {
    try expectMinifyDead(
        "const x = 1, y = 2; console.log(x, y);",
        "function run() {\n\tconst x = 1,y = 2;\n\tconsole.log(x, y);\n}\nrun();",
    );
}

// ---- 추가 literal 종류 ----

test "inline: bigint literal — inline" {
    try expectMinifyDead(
        "const n = 10n; console.log(n);",
        "function run() {\n\t;\n\tconsole.log(10n);\n}\nrun();",
    );
}

test "inline: regexp literal — inline" {
    try expectMinifyDead(
        "const r = /abc/g; console.log(r.source);",
        "function run() {\n\t;\n\tconsole.log(/abc/g.source);\n}\nrun();",
    );
}

test "inline: undefined keyword — 보존 (undefined 은 identifier_reference)" {
    // `undefined` 는 실제로 global identifier 참조라 isConstantExpr 에서 제외됨.
    try expectMinifyDead(
        "const x = undefined; console.log(x);",
        "function run() {\n\tconst x = undefined;\n\tconsole.log(x);\n}\nrun();",
    );
}

test "inline: static template literal — 보존 (보수적 skip)" {
    // no-substitution vs interpolated 를 extern union 런타임에서 안전 구분 어려워
    // 전체 template_literal 은 isConstantExpr 에서 false 반환.
    try expectMinifyDead(
        "const s = `hello`; console.log(s);",
        "function run() {\n\tconst s = `hello`;\n\tconsole.log(s);\n}\nrun();",
    );
}

test "inline: template with expression — 보존" {
    try expectMinifyDead(
        "function f(n) { const s = `v=${n}`; return s; } f(1);",
        "function run() {\n\tfunction f(n) {\n\t\tconst s = `v=${n}`;\n\t\treturn s;\n\t}\n\tf(1);\n}\nrun();",
    );
}

// ---- 빈 / 중첩 컨테이너 ----

test "inline: empty array — inline" {
    try expectMinifyDead(
        "const a = []; console.log(a.length);",
        "function run() {\n\t;\n\tconsole.log([].length);\n}\nrun();",
    );
}

test "inline: empty object — inline" {
    try expectMinifyDead(
        "const o = {}; console.log(o);",
        "function run() {\n\t;\n\tconsole.log({});\n}\nrun();",
    );
}

test "inline: 깊게 중첩된 literal — inline" {
    try expectMinifyDead(
        "const d = [[[[1]]], { a: [2, { b: 3 }] }]; console.log(d);",
        "function run() {\n\t;\n\tconsole.log([[[[1]]], { a: [2, { b: 3 }] }]);\n}\nrun();",
    );
}

// ---- 다양한 object key 형태 ----

test "inline: object with string key — inline" {
    try expectMinifyDead(
        "const o = { \"k\": 1 }; console.log(o);",
        "function run() {\n\t;\n\tconsole.log({ \"k\": 1 });\n}\nrun();",
    );
}

test "inline: object with numeric key — inline" {
    try expectMinifyDead(
        "const o = { 0: 1, 1: 2 }; console.log(o);",
        "function run() {\n\t;\n\tconsole.log({ 0: 1, 1: 2 });\n}\nrun();",
    );
}

test "inline: computed key — 보존" {
    // [k] 는 expression — constant expr 판정에서 제외.
    try expectMinifyDead(
        "function f(k) { const o = { [k]: 1 }; return o; } f('x');",
        "function run() {\n\tfunction f(k) {\n\t\tconst o = { [k]: 1 };\n\t\treturn o;\n\t}\n\tf(\"x\");\n}\nrun();",
    );
}

// ---- array 특이 케이스 ----

test "inline: sparse array — 보존 (보수적)" {
    // elision 을 포함한 sparse array 는 purity/constant 체크의 조합 결과 inline
    // 조건을 만족하지 않아 현재 보존. isConstantExpr 는 elision 을 skip 하지만
    // 다른 체크에서 걸릴 수 있음. 추후 Phase 확장 시 재검토.
    try expectMinifyDead(
        "const a = [1,,3]; console.log(a.length);",
        "function run() {\n\tconst a = [1, , 3];\n\tconsole.log(a.length);\n}\nrun();",
    );
}

test "inline: array with spread — 보존 (spread 는 식별자 참조)" {
    try expectMinifyDead(
        "function f(b) { const a = [1, ...b]; return a; } f([2,3]);",
        "function run() {\n\tfunction f(b) {\n\t\tconst a = [1, ...b];\n\t\treturn a;\n\t}\n\tf([2, 3]);\n}\nrun();",
    );
}

// ---- 연쇄 / fixed-point ----

test "inline: 2단계 chain — 양쪽 모두 inline" {
    try expectMinifyDead(
        "const a = 1; const b = a; console.log(b);",
        "function run() {\n\t;\n\t;\n\tconsole.log(1);\n}\nrun();",
    );
}

test "inline: 연쇄 fold 로 최종 리터럴화" {
    // a=1 → b init 의 a 위치에 1 inline → const b=1 → console.log 에 1 inline.
    // 추가로 b+2 같은 binary 는 foldBinary 가 리터럴로 접음.
    try expectMinifyDead(
        "const a = 1; const b = a; console.log(b + 2);",
        "function run() {\n\t;\n\t;\n\tconsole.log(3);\n}\nrun();",
    );
}

// ---- 스코프 / read 위치 ----

test "inline: read 가 중첩 함수 body — inline" {
    // x 의 read 가 inner arrow 안에 있어도 ref_count=1, scope_id 는 enclosing function.
    // 전체 AST 에서 유일 read 이므로 inline 대상.
    try expectMinifyDead(
        "function f() { const x = 1; return () => x; } f();",
        "function run() {\n\tfunction f() {\n\t\t;\n\t\treturn () => 1;\n\t}\n\tf();\n}\nrun();",
    );
}

test "inline: read 가 template expression 안 — inline" {
    try expectMinifyDead(
        "function f() { const x = 42; return `v=${x}`; } f();",
        "function run() {\n\tfunction f() {\n\t\t;\n\t\treturn `v=${42}`;\n\t}\n\tf();\n}\nrun();",
    );
}

// ---- 안전성 (negative) ----

test "inline: 재귀 init (self-reference) — 보존" {
    // `const f = () => f()` — init 안에 f 참조 → isConstantExpr false.
    try expectMinifyDead(
        "function g() { const f = () => f(); return f; } g();",
        "function run() {\n\tfunction g() {\n\t\tconst f = () => f();\n\t\treturn f;\n\t}\n\tg();\n}\nrun();",
    );
}

test "inline: eval 스코프 — 보존 (blocksMangling)" {
    // direct eval 이 있는 스코프 안의 선언은 동적 lookup 가능 → 보존.
    try expectMinifyDead(
        "function f() { eval(\"\"); const x = 1; return x; } f();",
        "function run() {\n\tfunction f() {\n\t\teval(\"\");\n\t\tconst x = 1;\n\t\treturn x;\n\t}\n\tf();\n}\nrun();",
    );
}

test "inline: conditional expression init — 보존 (식별자 의존 가능)" {
    try expectMinifyDead(
        "function f(c) { const x = c ? 1 : 2; return x; } f(true);",
        "function run() {\n\tfunction f(c) {\n\t\tconst x = c ? 1 : 2;\n\t\treturn x;\n\t}\n\tf(true);\n}\nrun();",
    );
}

test "inline: binary expression init — 보존 (constant fold 이후에도 expr 이면 skip)" {
    // `n + 1` — fold 후에도 binary 로 남으면 isConstantExpr 에서 제외.
    try expectMinifyDead(
        "function f(n) { const x = n + 1; return x; } f(1);",
        "function run() {\n\tfunction f(n) {\n\t\tconst x = n + 1;\n\t\treturn x;\n\t}\n\tf(1);\n}\nrun();",
    );
}

test "inline: unary expression init — 보존" {
    try expectMinifyDead(
        "function f(n) { const x = -n; return x; } f(1);",
        "function run() {\n\tfunction f(n) {\n\t\tconst x = -n;\n\t\treturn x;\n\t}\n\tf(1);\n}\nrun();",
    );
}

test "inline: new expression init — 보존" {
    try expectMinifyDead(
        "function f() { const x = new Map(); return x; } f();",
        "function run() {\n\tfunction f() {\n\t\tconst x = new Map();\n\t\treturn x;\n\t}\n\tf();\n}\nrun();",
    );
}

test "inline: this 표현식 — 보존" {
    try expectMinifyDead(
        "function f() { const t = this; return t; } f();",
        "function run() {\n\tfunction f() {\n\t\tconst t = this;\n\t\treturn t;\n\t}\n\tf();\n}\nrun();",
    );
}

// ---- 선언 형태 ----

test "inline: using 선언 — 보존 (Symbol.dispose side-effect)" {
    // using 은 단일 read 여도 Symbol.dispose 호출 side-effect 를 가지므로 inline 금지.
    try expectMinifyDead(
        "function f(r) { using x = r; return x; } f(null);",
        "function run() {\n\tfunction f(r) {\n\t\tusing x = r;\n\t\treturn x;\n\t}\n\tf(null);\n}\nrun();",
    );
}

test "inline: 배열 안에 object — inline" {
    try expectMinifyDead(
        "const data = [{ id: 1 }, { id: 2 }]; console.log(data);",
        "function run() {\n\t;\n\tconsole.log([{ id: 1 }, { id: 2 }]);\n}\nrun();",
    );
}
