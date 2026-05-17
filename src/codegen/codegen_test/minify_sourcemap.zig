const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;
const e2eCJS = helpers.e2eCJS;
const e2eJSX = helpers.e2eJSX;
const e2eFull = helpers.e2eFull;
const e2eWithOptions = helpers.e2eWithOptions;
const e2eSourceMap = helpers.e2eSourceMap;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;
const SourceMapTestResult = helpers.SourceMapTestResult;
const Scanner = helpers.Scanner;
const Parser = helpers.Parser;

// ============================================================
// 삼항 연산자 + 화살표 함수 (#446)
// ============================================================

test "ternary with arrow function body containing parens" {
    // d3-array cumsum 패턴: ? v => (expr) : v => (expr)
    // 파서가 에러 없이 파싱해야 함
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, "const f = true ? v => (v + 1) : v => (v - 1);");
    var parser = Parser.init(allocator, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "ternary with arrow function — d3 cumsum pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\function cumsum(values, valueof) {
        \\  var sum = 0, index = 0;
        \\  return Float64Array.from(values, valueof === undefined
        \\    ? v => (sum += +v || 0)
        \\    : v => (sum += +valueof(v, index++, values) || 0));
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

// ============================================================
// #491: for 루프 body 내 변수 선언 세미콜론 (minify)
// ============================================================

test "Minify: for-loop body var has semicolon" {
    // for (var i=0;...) { var x=1; console.log(x); } → "var x=1;" 세미콜론 필수
    var r = try e2eWithOptions(std.testing.allocator, "for (var i = 0; i < 3; i++) { var x = i; console.log(x); }", .{ .minify_whitespace = true });
    defer r.deinit();
    // "var x=i;" 다음에 세미콜론이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=i;") != null);
}

test "Minify: for-loop body let has semicolon" {
    var r = try e2eWithOptions(std.testing.allocator, "for (let i = 0; i < 3; i++) { let y = i * 2; console.log(y); }", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let y=i*2;") != null);
}

test "Minify: for-of body var has semicolon" {
    var r = try e2eWithOptions(std.testing.allocator, "for (const x of [1,2,3]) { var y = x; console.log(y); }", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var y=x;") != null);
}

test "Minify: omits trailing semicolon before block boundary" {
    var r = try e2eWithOptions(std.testing.allocator, "function f() { let x = 1; x++; } f();", .{ .minify_whitespace = true, .minify_syntax = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(){let x=1;x++}f();", r.output);
}

test "Minify: keeps empty for body semicolon before block boundary" {
    var r = try e2eWithOptions(std.testing.allocator, "function f() { try { for (; a; b++); } catch (e) {} }", .{ .minify_whitespace = true, .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(;a;b++);}") != null);
}

test "Minify: keeps nested empty for body semicolon before block boundary" {
    var r = try e2eWithOptions(std.testing.allocator, "function f() { try { if (a) b(); else for (; c; d++); } catch (e) {} }", .{ .minify_whitespace = true, .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "else for(;c;d++);}") != null);
}

test "Minify: keeps semicolon between adjacent block statements" {
    var r = try e2eWithOptions(std.testing.allocator, "for (var i = 0; i < 3; i++) { var x = i; console.log(x); }", .{ .minify_whitespace = true, .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=i;console.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(x)}") != null);
}

test "Minify: preserves ASI-sensitive boundaries inside block" {
    var r = try e2eWithOptions(std.testing.allocator,
        \\function f(a) {
        \\  "use strict";
        \\  if (a) return /x/.test(a);
        \\  throw { value: [a] };
        \\}
    , .{ .minify_whitespace = true, .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"use strict\";if") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return /x/.test(a);throw") != null);
    try std.testing.expect(std.mem.endsWith(u8, r.output, "throw{value:[a]}}"));
}

test "Minify: omits trailing class field semicolon before class body boundary" {
    var r = try e2eWithOptions(std.testing.allocator, "class Foo { x = 1; static { foo(); } static y = 2; }", .{ .minify_whitespace = true, .minify_syntax = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{x=1;static{foo()}static y=2}", r.output);
}

// ============================================================
// #493: template literal 내 식별자 rename
// ============================================================

test "Minify: template literal preserves identifier references" {
    // template literal 내 ${expr} 식별자가 정상 출력되어야 한다.
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1; const s = `val=${x}`;", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "`val=${x}`") != null);
}

test "Minify: template literal with multiple expressions" {
    var r = try e2eWithOptions(std.testing.allocator, "const a = 1; const b = 2; const s = `${a}+${b}`;", .{ .minify_whitespace = true });
    defer r.deinit();
    // 표현식이 올바르게 emit됨 (backtick + interpolation 구조 유지)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${a}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${b}") != null);
}

test "Minify: simple template literal without substitution" {
    var r = try e2eWithOptions(std.testing.allocator, "const s = `hello world`;", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "`hello world`") != null);
}

// ============================================================
// Source Map accuracy tests
// ============================================================

test "SourceMap: variable declaration maps to correct position" {
    var r = try e2eSourceMap(std.testing.allocator, "const x = 1;");
    defer r.deinit();
    // 매핑이 존재해야 한다
    try std.testing.expect(r.mappings.len > 0);
    // "const" → 원본 0행 0열
    try r.expectMappingAt("const", 0, 0);
}

test "SourceMap: multi-line source maps each line" {
    var r = try e2eSourceMap(std.testing.allocator, "const a = 1;\nconst b = 2;\n");
    defer r.deinit();
    try std.testing.expect(r.mappings.len >= 2);
    // 첫 줄: "const a" → 0행 0열
    try r.expectMappingAt("const a", 0, 0);
    // 둘째 줄: "const b" → 1행 0열
    try r.expectMappingAt("const b", 1, 0);
}

test "SourceMap: function declaration position" {
    var r = try e2eSourceMap(std.testing.allocator, "function foo() { return 1; }");
    defer r.deinit();
    try std.testing.expect(r.mappings.len > 0);
    // "function" → 0행 0열
    try r.expectMappingAt("function", 0, 0);
}

test "SourceMap: export all re-export has source mapping" {
    var r = try e2eSourceMap(std.testing.allocator, "export * from './foo';");
    defer r.deinit();
    // 소스 경로가 출력에 있어야 함 (A-1 버그 수정 검증)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"./foo\"") != null);
    // "export" → 0행 0열
    try r.expectMappingAt("export", 0, 0);
}

test "SourceMap: JSON contains version 3" {
    var r = try e2eSourceMap(std.testing.allocator, "const x = 1;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.source_map_json, "\"version\":3") != null);
}

test "SourceMap: JSON contains source file" {
    var r = try e2eSourceMap(std.testing.allocator, "const x = 1;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.source_map_json, "\"input.ts\"") != null);
}

test "SourceMap: JSON contains non-empty mappings" {
    var r = try e2eSourceMap(std.testing.allocator, "const x = 1;\nconst y = 2;\n");
    defer r.deinit();
    // mappings 필드가 빈 문자열이 아닌지
    try std.testing.expect(std.mem.indexOf(u8, r.source_map_json, "\"mappings\":\"\"") == null);
}

test "SourceMap: TS type stripping produces empty output" {
    var r = try e2eSourceMap(std.testing.allocator, "type Foo = string;");
    defer r.deinit();
    // 타입 선언은 출력이 없어야 한다
    try std.testing.expectEqualStrings("", r.output);
}

test "SourceMap: second line offset accuracy" {
    // 2행째 코드의 원본 위치가 정확히 매핑되는지
    var r = try e2eSourceMap(std.testing.allocator, "const a = 1;\nconst b = foo();");
    defer r.deinit();
    // "foo" → 원본 1행, 열은 "const b = " 다음 = 10
    try r.expectMappingAt("foo", 1, 10);
}

test "Codegen CJS: export all as namespace" {
    // export * as ns from './foo' → CJS에서는 Object.assign으로 처리
    // 현재 CJS 모드에서 binary.right만 출력하므로 namespace 이름은 무시됨
    var r = try e2eCJS(std.testing.allocator, "export * as ns from './foo';");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "require(\"./foo\")") != null);
}

test "SourceMap: multiple export all re-exports" {
    var r = try e2eSourceMap(std.testing.allocator, "export * from './a';\nexport * from './b';\n");
    defer r.deinit();
    // 두 소스 경로 모두 출력에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"./a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"./b\"") != null);
    // 매핑이 2줄 이상
    try std.testing.expect(r.mappings.len >= 2);
}

test "SourceMap: export all as namespace has mapping" {
    var r = try e2eSourceMap(std.testing.allocator, "export * as utils from './utils';");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"./utils\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "utils") != null);
    try r.expectMappingAt("export", 0, 0);
}

test "SourceMap: import default specifier identifier mapping" {
    var r = try e2eSourceMap(std.testing.allocator, "import foo from \"./mod\";");
    defer r.deinit();
    // foo 식별자가 col 7 에서 시작하므로 원본 col 7 에 매핑되어야 한다.
    try r.expectMappingAt("foo", 0, 7);
}

test "SourceMap: import namespace specifier identifier mapping" {
    var r = try e2eSourceMap(std.testing.allocator, "import * as ns from \"./mod\";");
    defer r.deinit();
    // ns 식별자는 col 12 에서 시작.
    try r.expectMappingAt("ns", 0, 12);
}

test "SourceMap: export specifier rename target identifier mapping" {
    var r = try e2eSourceMap(std.testing.allocator, "const a = 1;\nexport { a as b };");
    defer r.deinit();
    // export { a as b } — `b` 는 line 1, col 14 에서 시작.
    try r.expectMappingAt("b }", 1, 14);
}

test "SourceMap: enum members map to their source line" {
    // multi-line enum 이 single-line IIFE 로 emit 되어도 각 멤버가 자기 source line 으로 매핑되어야 함.
    const src =
        \\enum Color {
        \\  Red = "r",
        \\  Green = "g",
        \\}
    ;
    var r = try e2eSourceMap(std.testing.allocator, src);
    defer r.deinit();
    // 멤버 시작 emit 이 source line 으로 anchor.
    try r.expectMappingAt("Color[\"Red\"]", 1, 2);
    try r.expectMappingAt("Color[\"Green\"]", 2, 2);
    // IIFE trailing (`return X;})...`) 은 enum 이름 위치 (line 0, col 5) 로 anchor —
    // 마지막 멤버 segment 로의 fallback 방지.
    try r.expectMappingAt("return Color", 0, 5);
}

// ================================================================
