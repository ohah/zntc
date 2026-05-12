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
    var r = try e2e(std.testing.allocator, "return;");
    defer r.deinit();
    try std.testing.expectEqualStrings("return;", r.output);
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
    try std.testing.expectEqualStrings("module.exports=class Foo{greet(){return \"hi\";}};", r.output);
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
