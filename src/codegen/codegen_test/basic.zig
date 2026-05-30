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
const Scanner = helpers.Scanner;
const Parser = helpers.Parser;
const Transformer = helpers.Transformer;
const Codegen = helpers.Codegen;
const TestResult = helpers.TestResult;
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const LinkingMetadata = @import("../../bundler/linker.zig").LinkingMetadata;

test "Codegen: empty program" {
    var r = try e2e(std.testing.allocator, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: variable declaration" {
    var r = try e2e(std.testing.allocator, "const x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: type stripped" {
    var r = try e2e(std.testing.allocator, "type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: JS with TS stripped" {
    var r = try e2e(std.testing.allocator, "const x = 1; type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: return statement" {
    // D16: top-level return 은 module (TS spec) 에서 invalid 라 function 안으로 wrap.
    var r = try e2e(std.testing.allocator, "function f(){return;}");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(){return;}", r.output);
}

test "Codegen: enum IIFE" {
    var r = try e2e(std.testing.allocator, "enum Color { Red, Green, Blue }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Color = /* @__PURE__ */ ((Color) => {Color[Color[\"Red\"]=0]=\"Red\";Color[Color[\"Green\"]=1]=\"Green\";Color[Color[\"Blue\"]=2]=\"Blue\";return Color;})(Color || {});",
        r.output,
    );
}

test "Codegen: namespace IIFE" {
    var r = try e2e(std.testing.allocator, "namespace Foo { const x = 1; }");
    defer r.deinit();
    // 내부 const는 export 아니므로 Foo.x = x 없음
    try std.testing.expectEqualStrings(
        "var Foo;((Foo) => {const x=1;})(Foo || (Foo = {}));",
        r.output,
    );
}

test "Codegen CJS: export const" {
    var r = try e2eCJS(std.testing.allocator, "export const x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;exports.x=x;", r.output);
}

test "Codegen CJS: export default" {
    var r = try e2eCJS(std.testing.allocator, "export default 42;");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=42;", r.output);
}

test "Codegen: TS export = primitive → module.exports = primitive" {
    var r = try e2e(std.testing.allocator, "export = 42;");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=42;", r.output);
}

test "Codegen: TS export = identifier → module.exports = identifier" {
    var r = try e2e(std.testing.allocator,
        \\const value = 42;
        \\export = value;
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("const value=42;module.exports=value;", r.output);
}

test "Codegen: TS export = class expression → module.exports = class" {
    var r = try e2e(std.testing.allocator, "export = class Foo { greet() { return 'hi'; } };");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=class Foo{greet(){return\"hi\";}};", r.output);
}

test "Codegen: TS export = function expression → module.exports = function" {
    var r = try e2e(std.testing.allocator, "export = function add(a: number, b: number) { return a + b; };");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=function add(a,b){return a+b;};", r.output);
}

test "Codegen: TS export = require().default cherry-pick" {
    var r = try e2e(std.testing.allocator, "export = require('foo').default;");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=require(\"foo\").default;", r.output);
}

test "Codegen: drop debugger" {
    var r = try e2eFull(std.testing.allocator, "debugger; const x = 1;", .{ .drop_debugger = true }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: drop console" {
    var r = try e2eFull(std.testing.allocator, "console.log(1); const x = 1;", .{ .drop_console = true }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: drop console preserves required statement bodies" {
    var r = try e2eFull(
        std.testing.allocator,
        "for (var x of xs) console.log(x); while (ok) console.log(ok); if (cond) console.log('then'); else keep(); label: console.log('label'); do console.log('body'); while (ok);",
        .{ .drop_console = true },
        .{ .minify_whitespace = true },
        ".ts",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("for(var x of xs);while(ok);if(cond);else keep();label:;do ;while(ok);", r.output);
}

test "Codegen: formatted output with tab" {
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1;", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", r.output);
}

test "Codegen: formatted output with spaces" {
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1;", .{ .indent_char = .space, .indent_width = 4 });
    defer r.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", r.output);
}

test "Codegen: enum with initializer" {
    var r = try e2e(std.testing.allocator, "enum Status { Active = 1, Inactive = 0 }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Status = /* @__PURE__ */ ((Status) => {Status[Status[\"Active\"]=1]=\"Active\";Status[Status[\"Inactive\"]=0]=\"Inactive\";return Status;})(Status || {});",
        r.output,
    );
}

fn e2eEnumWithRename(backing_allocator: std.mem.Allocator, source: []const u8, renamed: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = parser.source_mode == .ts;
    analyzer.is_flow = parser.is_flow;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    const root = try transformer.transform();

    const root_node = transformer.ast.getNode(root);
    const list = root_node.data.list;
    var enum_name_idx: NodeIndex = .none;
    for (transformer.ast.extra_data.items[list.start .. list.start + list.len]) |raw_idx| {
        const stmt_idx: NodeIndex = @enumFromInt(raw_idx);
        const stmt = transformer.ast.getNode(stmt_idx);
        if (stmt.tag == .ts_enum_declaration) {
            enum_name_idx = @enumFromInt(transformer.ast.extra_data.items[stmt.data.extra]);
            break;
        }
    }
    if (enum_name_idx.isNone()) return error.MissingEnumDeclaration;
    const enum_symbol_id = transformer.symbol_ids.items[@intFromEnum(enum_name_idx)] orelse return error.MissingEnumSymbol;

    const skip = try std.DynamicBitSet.initEmpty(allocator, transformer.ast.nodes.items.len);
    var renames: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    try renames.put(allocator, enum_symbol_id, renamed);
    var md: LinkingMetadata = .{
        .skip_nodes = skip,
        .renames = renames,
        .final_exports = null,
        .symbol_ids = transformer.symbol_ids.items,
        .allocator = allocator,
    };
    defer md.deinit();

    var cg = Codegen.initWithOptions(allocator, transformer.ast, .{
        .minify_whitespace = true,
        .esm_var_assign_only = true,
        .linking_metadata = &md,
    });
    const output = try cg.generate(root);
    return .{ .output = output, .arena = arena };
}

test "Codegen: enum IIFE uses renamed binding in esm assignment mode" {
    var r = try e2eEnumWithRename(std.testing.allocator, "enum RuntimeKind { ReactNative = 1, UI = 2 }", "Tv");
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "Tv = /* @__PURE__ */") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ")(Tv || {});") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "RuntimeKind = /* @__PURE__ */") == null);
}

test "Codegen: const enum removed" {
    var r = try e2e(std.testing.allocator, "const enum Dir { Up, Down }");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

// --- enum re-export (semantic analyzer에서 enum을 symbol로 등록) ---

test "Codegen: enum re-export via export specifier" {
    var r = try e2e(std.testing.allocator, "enum Direction { Up, Down }\nexport { Direction };");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Direction") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export") != null);
}

test "Codegen: enum re-export with alias" {
    var r = try e2e(std.testing.allocator, "enum Fruit { Apple, Banana }\nexport { Fruit as FruitEnum };");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Fruit as FruitEnum") != null);
}

test "Codegen: enum default export" {
    var r = try e2e(std.testing.allocator, "enum Status { Active, Inactive }\nexport default Status;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export default Status") != null);
}

test "Codegen: export enum declaration" {
    var r = try e2e(std.testing.allocator, "export enum Color { Red = 'RED', Green = 'GREEN' }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export var Color") != null);
}

test "Codegen: enum + class + var mixed re-export" {
    var r = try e2e(std.testing.allocator,
        \\enum Direction { Up, Down }
        \\class Store { constructor() {} }
        \\const name = "test";
        \\export { Direction, Store, name };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Direction") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Store") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "name") != null);
}

test "Codegen: const enum re-export is stripped" {
    var r = try e2e(std.testing.allocator, "const enum Color { Red, Green }\nexport { Color };");
    defer r.deinit();
    // const enum은 삭제되지만 export specifier는 남을 수 있음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Color[Color") == null);
}

test "Codegen: string enum re-export" {
    var r = try e2e(std.testing.allocator,
        \\enum HttpMethod { Get = "GET", Post = "POST", Put = "PUT", Delete = "DELETE" }
        \\export { HttpMethod };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"GET\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"DELETE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export") != null);
}

// #1564 Case 1 회귀 가드: for init 안에 중첩된 for/for-in이 끝나면서
// in_for_init 플래그를 false로 덮어쓰면, 바깥 for의 VariableDeclaration이
// 자체적으로 세미콜론을 찍어 `;;`이 중복 출력되는 문제. save/restore로 해결.
test "Codegen #1564: nested for-in inside outer for-init preserves in_for_init" {
    var r = try e2e(std.testing.allocator,
        \\for (var r, e = (function(n) { var m = {}; for (var k in n) m[k] = n[k]; return m; })({}), u = 0; !r; ) { r = true; }
    );
    defer r.deinit();
    // `;;` (for init 뒤에 세미콜론 2개) 가 절대 출력되지 않아야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";;") == null);
}

test "Codegen #1564: nested classic-for inside outer for-init preserves in_for_init" {
    var r = try e2e(std.testing.allocator,
        \\for (var a = (function() { for (var i = 0; i < 1; i++) {} return 0; })(), b = 1; a < 2; ) { a++; }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";;") == null);
}

test "Codegen #1564: triple-nested for-in inside IIFE in outer for-init" {
    // 3중 중첩: outer for init → IIFE body → 인접한 두 for-in
    // 내부 for-in이 각각 종료할 때마다 in_for_init을 덮어쓰지 않아야 한다.
    var r = try e2e(std.testing.allocator,
        \\for (var r, e = (function(n) { var a = []; for (var x in n) for (var y in n[x]) a.push(x+y); return a; })({p:{q:1}}), u = 0; u < e.length; u++) { }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";;") == null);
}

test "Codegen #1564: for-of inside outer for-init preserves in_for_init" {
    // for-in뿐 아니라 for-of도 같은 플래그를 사용하므로 동일 경로 회귀 확인.
    var r = try e2e(std.testing.allocator,
        \\for (var r = 0, arr = (function() { var out = []; for (var v of [1,2,3]) out.push(v); return out; })(), n = arr.length; r < n; r++) { }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";;") == null);
}

test "Codegen: for-init context does not leak into nested function body" {
    var r = try e2eWithOptions(
        std.testing.allocator,
        "for (var a = function () { var b = g(); if (Object(b) === b) { return b; } return this; }, i = 0; i < 1; i++) {}",
        .{ .minify_whitespace = true, .minify_syntax = true },
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "g()return") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var b=g();return") != null);
}

test "Codegen #1564: let/const mixed with nested for-in" {
    // `let`, `const` kind도 VariableDeclaration emit 경로를 공유하므로 동일 가드.
    var r = try e2e(std.testing.allocator,
        \\for (let r = 0, e = (function(n) { const m = {}; for (const k in n) m[k] = n[k]; return m; })({a:1}), keys = Object.keys(e); r < keys.length; r++) { }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";;") == null);
}

// ============================================================
// Peephole (#1552 P3): minify_syntax — boolean 축약
// ============================================================

test "Codegen minify_syntax: true → !0, false → !1" {
    var r = try e2eWithOptions(
        std.testing.allocator,
        "const a = true; const b = false; if (a) console.log(b);",
        .{ .minify_syntax = true },
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!1") != null);
    // 식별자 true/false 자체가 출력에 없어야
    try std.testing.expect(std.mem.indexOf(u8, r.output, "= true") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "= false") == null);
}

test "Codegen minify_syntax off: boolean 리터럴 유지 (anti-regression)" {
    var r = try e2eWithOptions(
        std.testing.allocator,
        "const a = true;",
        .{},
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!0") == null);
}

test "Codegen: 원본 소스의 !0/!1은 minify_syntax와 무관하게 유지" {
    // 안티 회귀: 소스가 이미 `!0`(unary_expression)이면 boolean_literal 분기를
    // 타지 않으므로 변형이 없어야 한다.
    var r = try e2eWithOptions(
        std.testing.allocator,
        "const x = !0; const y = !1;",
        .{ .minify_syntax = true },
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!1") != null);
}

// ============================================================
// #3097: binary `+` / `-` 연산자 공백 — minify_whitespace 시 tight
//   `a + b` → `a+b`, 단 `+`/`-` 다음에 `+`/`-`/`++`/`--` 로 시작하는 RHS 가
//   오면 `++`/`--` 로 토큰이 잘못 합쳐지므로 한 칸만 삽입.
// ============================================================

test "Codegen #3097: minify 시 binary +/- tight" {
    var r = try e2e(std.testing.allocator, "var z = a + b - c;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a+b-c;", r.output);
}

test "Codegen #3097: minify 시 * / 는 기존대로 tight (anti-regression)" {
    var r = try e2e(std.testing.allocator, "var z = a * b / c;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a*b/c;", r.output);
}

test "Codegen #3097: + 다음 unary + 는 한 칸 (a+ +b)" {
    var r = try e2e(std.testing.allocator, "var z = a + +b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a+ +b;", r.output);
}

test "Codegen #3097: - 다음 unary - 는 한 칸 (a- -b)" {
    var r = try e2e(std.testing.allocator, "var z = a - -b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a- -b;", r.output);
}

test "Codegen #3097: + 다음 unary - 는 공백 불필요 (a+-b)" {
    var r = try e2e(std.testing.allocator, "var z = a + -b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a+-b;", r.output);
}

test "Codegen #3097: - 다음 unary + 는 공백 불필요 (a-+b)" {
    var r = try e2e(std.testing.allocator, "var z = a - +b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a-+b;", r.output);
}

test "Codegen #3097: + 다음 prefix ++ 는 한 칸 (a+ ++b)" {
    var r = try e2e(std.testing.allocator, "var z = a + ++b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a+ ++b;", r.output);
}

test "Codegen #3097: - 다음 prefix -- 는 한 칸 (a- --b)" {
    var r = try e2e(std.testing.allocator, "var z = a - --b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a- --b;", r.output);
}

test "Codegen #3097: postfix ++ 좌측은 공백 불필요 (a+++b == (a++)+b)" {
    var r = try e2e(std.testing.allocator, "var z = a++ + b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a+++b;", r.output);
}

test "Codegen #3097: 더 높은 우선순위 RHS 의 leftmost 가 unary - (a- -b*c)" {
    var r = try e2e(std.testing.allocator, "var z = a - -b * c;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=a- -b*c;", r.output);
}

test "Codegen #3097: non-minify 는 ` + ` 공백 유지 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "var z = a + b;", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("var z = a + b;\n", r.output);
}

// ============================================================
// #3098: const → let 다운그레이드 — minify_syntax 시 함수/블록 스코프 const 도
//   3자 `let` 으로. `using` / `await using` 은 disposal 의미가 달라 그대로.
// ============================================================

test "Codegen #3098: minify_syntax 시 const → let" {
    var r = try e2eWithOptions(std.testing.allocator, "{ const x = 1; }", .{ .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let x = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const") == null);
}

test "Codegen #3098: minify_syntax off → const 유지 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "{ const x = 1; }", .{});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const x = 1") != null);
}

test "Codegen #3098: let / var 는 그대로 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "{ let a = 1; var b = 2; }", .{ .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let a = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var b = 2") != null);
}

test "Codegen #3098: for-of const → let" {
    var r = try e2eWithOptions(std.testing.allocator, "for (const x of arr) console.log(x);", .{ .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for (let x of arr)") != null);
}

test "Codegen #3098: using 은 const 로 안 바뀜 (그대로 using)" {
    var r = try e2eWithOptions(std.testing.allocator, "{ using x = getResource(); }", .{ .minify_syntax = true });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "using x = getResource()") != null);
}

// ============================================================
// #3096: single-param arrow 의 불필요한 괄호 제거 — minify_whitespace 시
//   `(x) => ...` → `x => ...`. 단일 plain identifier 파라미터일 때만
//   (default / rest / destructuring / 0개 / 2개+ 는 괄호 유지).
// ============================================================

test "Codegen #3096: minify 시 single-param arrow 괄호 제거" {
    var r = try e2e(std.testing.allocator, "var f = (x) => x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=x=>x;", r.output);
}

test "Codegen #3096: 이미 괄호 없는 single-param 은 그대로 (anti-regression)" {
    var r = try e2e(std.testing.allocator, "var f = x => x + 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=x=>x+1;", r.output);
}

test "Codegen #3096: 0개 파라미터는 () 유지" {
    var r = try e2e(std.testing.allocator, "var f = () => 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=()=>1;", r.output);
}

test "Codegen #3096: 2개 이상 파라미터는 () 유지" {
    var r = try e2e(std.testing.allocator, "var f = (a, b) => a;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=(a,b)=>a;", r.output);
}

test "Codegen #3096: rest 파라미터는 () 유지" {
    var r = try e2e(std.testing.allocator, "var f = (...args) => args;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=(...args)=>args;", r.output);
}

test "Codegen #3096: default 파라미터는 () 유지" {
    var r = try e2e(std.testing.allocator, "var f = (x = 1) => x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=(x=1)=>x;", r.output);
}

test "Codegen #3096: destructuring 파라미터는 () 유지" {
    var r = try e2e(std.testing.allocator, "var f = ({ x }) => x;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "f=({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "})=>x") != null);
}

test "Codegen #3096: async single-param 은 괄호 제거하되 async 공백 유지" {
    var r = try e2e(std.testing.allocator, "var f = async (x) => x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=async x=>x;", r.output);
}

test "Codegen #3096: non-minify 는 (x) 유지 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "var f = (x) => x;", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("var f = (x) => x;\n", r.output);
}

// ============================================================
// #3094: single-statement block 의 불필요한 `{}` 제거 — minify_whitespace 시
//   `if(x){f()}` → `if(x)f()`. 본문이 출력되는 statement 1개뿐이고 그게
//   expression/return/throw/break/continue/debugger/var 일 때만 (let/const/class/
//   function 선언 · if/for/while 류 · 빈 block · 2개+ 는 `{}` 유지).
// ============================================================

test "Codegen #3094: if 본문 단일 statement → {} 제거" {
    var r = try e2e(std.testing.allocator, "if (a) { f(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a)f();", r.output);
}

test "Codegen #3094: if/else 양쪽 단일 statement → {} 제거" {
    var r = try e2e(std.testing.allocator, "if (a) { f(); } else { g(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a)f();else g();", r.output);
}

test "Codegen #3094: if/else return → return c;else return d;" {
    var r = try e2e(std.testing.allocator, "function h(){ if (a) { return 1; } else { return 2; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(a)return 1;else return 2;}", r.output);
}

test "Codegen #3094: var 선언은 본문으로 valid → {} 제거" {
    var r = try e2e(std.testing.allocator, "if (a) { var x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a)var x=1;", r.output);
}

test "Codegen #3094: let 선언은 {} 유지 (lexical decl)" {
    var r = try e2e(std.testing.allocator, "if (a) { let x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a){let x=1;}", r.output);
}

test "Codegen #3094: class 선언은 {} 유지" {
    var r = try e2e(std.testing.allocator, "if (a) { class C {} }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "if(a){class C") != null);
}

test "Codegen #3094: for 본문 단일 statement → {} 제거" {
    var r = try e2e(std.testing.allocator, "for (;;) { f(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(;;)f();", r.output);
}

test "Codegen #3094: for-of 본문 → {} 제거" {
    var r = try e2e(std.testing.allocator, "for (const x of arr) { g(x); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr)g(x);", r.output);
}

test "Codegen #3094: while 본문 → {} 제거" {
    var r = try e2e(std.testing.allocator, "while (c) { f(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("while(c)f();", r.output);
}

test "Codegen #3094: 2개 이상 statement 는 {} 유지" {
    var r = try e2e(std.testing.allocator, "if (a) { f(); g(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a){f();g();}", r.output);
}

test "Codegen #3094: 본문이 if statement 면 {} 유지 (dangling-else 회피, 보수적)" {
    var r = try e2e(std.testing.allocator, "if (a) { if (b) c(); } else d();");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a){if(b)c();}else d();", r.output);
}

test "Codegen #3094: 빈 block 은 {} 유지" {
    var r = try e2e(std.testing.allocator, "if (a) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a){}", r.output);
}

test "Codegen #3094: throw 본문 → {} 제거" {
    var r = try e2e(std.testing.allocator, "if (a) { throw e; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a)throw e;", r.output);
}

test "Codegen #3094: 중첩 — for 안 if 안 expr" {
    var r = try e2e(std.testing.allocator, "for (const x of arr) { if (x) { use(x); } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){if(x)use(x);}", r.output);
}

test "Codegen #3094: non-minify 는 {} 유지 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "if (a) { f(); }", .{});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{") != null);
}

test "Codegen #3094: break/continue 본문 → {} 제거" {
    var r = try e2e(std.testing.allocator, "for (;;) { if (a) { break; } else { continue; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(;;){if(a)break;else continue;}", r.output);
}

// ============================================================
// #3095: if/return 평탄화 — minify_syntax 시 `if(c){return A}else{return B}` →
//   `return c?A:B;`. c 가 paren 없이 ?: test 자리에 올 수 있고 A/B 가 sequence
//   (comma) 가 아닐 때만. else-if 체인은 미지원 (else 분기가 다시 변환됨).
// ============================================================

fn e2eMinAll(allocator: std.mem.Allocator, source: []const u8) !helpers.TestResult {
    return e2eWithOptions(allocator, source, .{ .minify_whitespace = true, .minify_syntax = true });
}

test "Codegen #3095: if/else return block → return c?A:B" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { return 1; } else { return 2; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return c?1:2}", r.output);
}

test "Codegen #3095: bare return 양쪽도 → return c?A:B" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) return a; else return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return c?a:b}", r.output);
}

test "Codegen #3095: member / logical cond 안전" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (x.y && z) return a; else return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return x.y&&z?a:b}", r.output);
}

test "Codegen #3095: assignment cond 는 변환 안 함 (paren 필요)" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (a = b) return x; else return y; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(a=b)return x;else return y}", r.output);
}

test "Codegen #3095: 한쪽이 return 아니면 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { return 1; } else { f(); } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return 1;else f()}", r.output);
}

test "Codegen #3095: return 인자 없으면 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { return; } else { return 2; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return;else return 2}", r.output);
}

test "Codegen #3095: else 없으면 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { return 1; } g(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return 1;g()}", r.output);
}

test "Codegen #3109: else-if return 체인 전체를 ternary 로 (right-assoc)" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (a) return 1; else if (b) return 2; else return 3; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return a?1:b?2:3}", r.output);
}

test "Codegen #3109: return arg 가 conditional 이어도 paren 불필요" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (a) return x ? y : z; else return 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return a?x?y:z:1}", r.output);
}

test "Codegen #3109: 체인 중간 cond 가 unsafe(assignment) 면 전체 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (a) return 1; else if (c = d) return 2; else return 3; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(a)return 1;else if(c=d)return 2;else return 3}", r.output);
}

test "Codegen #3109: 체인 마지막 else 가 return 아니면 전체 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (a) return 1; else if (b) return 2; else f(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(a)return 1;else if(b)return 2;else f()}", r.output);
}

test "Codegen #3095: cond 앞 leading comment 가 있어도 return ASI 안 됨 (minify_syntax only)" {
    // legal comment 는 minify_whitespace 없으면 보존되며 newline 을 끼움 → emitNode 로
    // 그대로 emit 하면 `return /*!c*/\n c?1:2` 가 되어 ASI 로 `return;` — emitNoLineTerminatorOperand 로 방지.
    var r = try e2eWithOptions(std.testing.allocator, "function h(){ if (/*! note */ c) return 1; else return 2; }", .{ .minify_syntax = true });
    defer r.deinit();
    // `return` 과 cond 사이에 newline 이 없어야 함 (ASI 방지)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "?") != null);
}

test "Codegen #3095: minify_syntax off → 변환 안 함 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "function h(){ if (c) { return 1; } else { return 2; } }", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return 1;else return 2;}", r.output);
}

// ============================================================
// #3107: if → 논리/삼항 식 변환 — minify_syntax 시
//   `if(c){a()}else{b()}` → `c?a():b();`, `if(c){a()}` → `c&&a();`.
//   양쪽 본문이 단일 expression statement 이고 paren-safety 충족 시만.
// ============================================================

test "Codegen #3107: if/else expr → c?a():b()" {
    var r = try e2eMinAll(std.testing.allocator, "if (c) { a(); } else { b(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("c?a():b();", r.output);
}

test "Codegen #3107: bare expr 양쪽도 → c?a():b()" {
    var r = try e2eMinAll(std.testing.allocator, "if (c) a(); else b();");
    defer r.deinit();
    try std.testing.expectEqualStrings("c?a():b();", r.output);
}

test "Codegen #3107: 양쪽 assignment → c?x=1:x=2" {
    var r = try e2eMinAll(std.testing.allocator, "if (c) x = 1; else x = 2;");
    defer r.deinit();
    try std.testing.expectEqualStrings("c?x=1:x=2;", r.output);
}

test "Codegen #3107: else 없음 → c&&a()" {
    var r = try e2eMinAll(std.testing.allocator, "if (c) { a(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("c&&a();", r.output);
}

test "Codegen #3107: bare 본문 else 없음 → c&&a()" {
    var r = try e2eMinAll(std.testing.allocator, "if (x.y) a();");
    defer r.deinit();
    try std.testing.expectEqualStrings("x.y&&a();", r.output);
}

test "Codegen #3107: logical cond 은 ?: test 로는 안전 (x.y&&z?a():b())" {
    var r = try e2eMinAll(std.testing.allocator, "if (x.y && z) a(); else b();");
    defer r.deinit();
    try std.testing.expectEqualStrings("x.y&&z?a():b();", r.output);
}

test "Codegen #3107: logical cond + else 없음 은 && 변환 안 함 (paren 필요)" {
    var r = try e2eMinAll(std.testing.allocator, "if (a || b) f();");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(a||b)f();", r.output);
}

test "Codegen #3107: 본문이 assignment + else 없음 은 && 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "if (c) x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(c)x=1;", r.output);
}

test "Codegen #3107: 본문이 logical expr + else 없음 은 && 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "if (c) a || b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(c)a||b;", r.output);
}

test "Codegen #3107: if-else multi-expr block — ternary 로 합침 (S6)" {
    // S6: minify_syntax 시 if-else 의 양쪽 본문이 expression statement (single 또는
    // multi-expr block) 면 `c?(a,b):x;` ternary 로 합침. comma sequence 는 paren 보호.
    var r = try e2eMinAll(std.testing.allocator, "if (c) { a(); b(); } else { x(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("c?(a(),b()):x();", r.output);
}

test "Codegen: do-while 본문 multi-expr block — sequence unwrap + 키워드 spacing" {
    // do-while 도 emits_braces 체크에 multi-expr unwrap 가드 — 안 하면 `dof(),g();while`
    // 처럼 `do` 와 첫 식별자가 fuse → 미선언 변수 호출 (회귀 #M11).
    var r = try e2eMinAll(std.testing.allocator, "do { f(); g(); } while (c);");
    defer r.deinit();
    try std.testing.expectEqualStrings("do f(),g();while(c);", r.output);
}

test "Codegen #3107: else-if 체인 — 안쪽부터 부분 적용" {
    var r = try e2eMinAll(std.testing.allocator, "if (p) a(); else if (q) b(); else f();");
    defer r.deinit();
    try std.testing.expectEqualStrings("if(p)a();else q?b():f();", r.output);
}

test "Codegen #3107: 한쪽이 expr 아니면(return) 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { a(); } else { return 1; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)a();else return 1}", r.output);
}

test "Codegen #3107: minify_syntax off → 변환 안 함 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "if (c) a(); else b();", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("if(c)a();else b();", r.output);
}

// ============================================================
// #3111: do-while 본문 / if(true)·if(false) DCE 분기 의 single-statement {} 제거
//   (#3094 후속 — emitStatementBody 인프라 재사용).
// ============================================================

test "Codegen #3111: do-while 본문 단일 statement → {} 제거" {
    var r = try e2e(std.testing.allocator, "do { f(); } while (c);");
    defer r.deinit();
    try std.testing.expectEqualStrings("do f();while(c);", r.output);
}

test "Codegen #3111: do-while 2개 statement 면 {} 유지" {
    var r = try e2e(std.testing.allocator, "do { f(); g(); } while (c);");
    defer r.deinit();
    try std.testing.expectEqualStrings("do{f();g();}while(c);", r.output);
}

test "Codegen #3111: do-while let 본문은 {} 유지" {
    var r = try e2e(std.testing.allocator, "do { let x = 1; } while (c);");
    defer r.deinit();
    try std.testing.expectEqualStrings("do{let x=1;}while(c);", r.output);
}

test "Codegen #3111: if(true) DCE 분기 {} 제거" {
    var r = try e2e(std.testing.allocator, "if (true) { f(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("f();", r.output);
}

test "Codegen #3111: if(false)/else DCE 분기 {} 제거" {
    var r = try e2e(std.testing.allocator, "if (false) { bad(); } else { g(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("g();", r.output);
}

test "Codegen: string literal DCE decodes unicode escapes" {
    var r = try e2e(std.testing.allocator, "if (\"Ā\" !== \"\\u0100\") { console.error(\"bad\"); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: string literal DCE decodes hex escapes" {
    var r = try e2e(std.testing.allocator, "if (\"\\x41\" === \"A\") { good(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("good();", r.output);
}

test "Codegen #3111: if(true) DCE 분기 let 은 {} 유지" {
    var r = try e2e(std.testing.allocator, "if (true) { let x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("{let x=1;}", r.output);
}

test "Codegen #3111: non-minify 는 do {} 유지 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "do { f(); } while (c);", .{});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{") != null);
}

// ============================================================
// #3110: list-level — `if(c)return A;` 바로 다음 형제가 `return B;` 면 `return c?A:B;`.
//   (early-return inversion 등 나머지 list-level 평탄화는 후속.)
// ============================================================

test "Codegen #3110: if-return + 다음 return → return c?A:B" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) return a; return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return c?a:b}", r.output);
}

test "Codegen #3110: block then-branch도 → return c?A:B" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { return a; } return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return c?a:b}", r.output);
}

test "Codegen #3110: member cond" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (x.y) return 1; return 2; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return x.y?1:2}", r.output);
}

test "Codegen #3110: assignment cond 는 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c = d) return a; return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c=d)return a;return b}", r.output);
}

test "Codegen #3110: then-branch 2개 statement 면 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) { return a; x(); } return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c){return a;x()}return b}", r.output);
}

test "Codegen #3110: if 에 else 가 있으면 list-level 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) return a; else d(); return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return a;else d();return b}", r.output);
}

test "Codegen #3110: return; (인자 없음) 은 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) return; return b; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return;return b}", r.output);
}

test "Codegen #3110: 다음 형제가 return 아니면 변환 안 함" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) return a; f(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return a;f()}", r.output);
}

test "Codegen #3110: return 뒤 dead code 는 그대로 (별도 DCE)" {
    var r = try e2eMinAll(std.testing.allocator, "function h(){ if (c) return a; return b; x(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){return c?a:b;x()}", r.output);
}

test "Codegen #3110: minify_syntax off → 변환 안 함 (anti-regression)" {
    var r = try e2eWithOptions(std.testing.allocator, "function h(){ if (c) return a; return b; }", .{ .minify_whitespace = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("function h(){if(c)return a;return b;}", r.output);
}
