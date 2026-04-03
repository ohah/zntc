const std = @import("std");
const codegen_mod = @import("codegen.zig");
const Codegen = codegen_mod.Codegen;
const CodegenOptions = codegen_mod.CodegenOptions;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const transformer_mod = @import("../transformer/transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const Mapping = @import("sourcemap.zig").Mapping;

/// Arena 기반 테스트 결과. deinit()으로 모든 메모리를 일괄 해제.
const TestResult = struct {
    output: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

/// 소스맵 테스트 결과. output + mappings 접근 가능.
const SourceMapTestResult = struct {
    output: []const u8,
    mappings: []const Mapping,
    source_map_json: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *SourceMapTestResult) void {
        self.arena.deinit();
    }

    /// 출력에서 target 문자열의 시작 위치에 매핑이 존재하는지 확인.
    /// 매핑의 original_column이 expected_src_col과 일치하는지도 검증.
    fn expectMappingAt(self: *const SourceMapTestResult, target: []const u8, expected_src_line: u32, expected_src_col: u32) !void {
        // 출력에서 target의 위치 (줄/열) 계산
        const pos = std.mem.indexOf(u8, self.output, target) orelse
            return error.TargetNotFound;
        var gen_line: u32 = 0;
        var gen_col: u32 = 0;
        for (self.output[0..pos]) |c| {
            if (c == '\n') {
                gen_line += 1;
                gen_col = 0;
            } else {
                gen_col += 1;
            }
        }
        // 해당 출력 위치에 가장 가까운 매핑 찾기
        var best: ?Mapping = null;
        for (self.mappings) |m| {
            if (m.generated_line == gen_line and m.generated_column <= gen_col) {
                if (best == null or m.generated_column > best.?.generated_column) {
                    best = m;
                }
            }
        }
        const m = best orelse return error.NoMappingFound;
        try std.testing.expectEqual(expected_src_line, m.original_line);
        try std.testing.expectEqual(expected_src_col, m.original_column);
    }
};

/// 소스맵 활성화 e2e. 매핑 결과에 접근 가능.
fn e2eSourceMap(backing_allocator: std.mem.Allocator, source: []const u8) !SourceMapTestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();

    var t = Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.new_ast, .{ .sourcemap = true });
    cg.line_offsets = scanner.line_offsets.items;
    try cg.addSourceFile("input.ts");
    const output = try cg.generate(root);
    const json = try cg.generateSourceMap("output.js") orelse "";
    const json_copy = try allocator.dupe(u8, json);

    // 매핑을 arena에 복사
    const mappings = if (cg.sm_builder) |*sm|
        try allocator.dupe(Mapping, sm.mappings.items)
    else
        &[_]Mapping{};

    return .{
        .output = output,
        .mappings = mappings,
        .source_map_json = json_copy,
        .arena = arena,
    };
}

/// 기본 e2e: minify 모드 (기존 테스트 호환)
fn e2e(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .minify_whitespace = true });
}

fn e2eCJS(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .module_format = .cjs, .minify_whitespace = true });
}

fn e2eJSX(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{}, .{ .minify_whitespace = true }, ".tsx");
}

/// 풀 옵션 e2e. ext로 확장자 지정 (".ts" 기본, ".tsx"면 JSX 모드).
/// Arena로 전체 파이프라인을 실행. output은 arena 메모리를 가리키므로
/// TestResult.deinit() 전에 사용해야 한다.
fn e2eFull(backing_allocator: std.mem.Allocator, source: []const u8, t_options: TransformOptions, cg_options: CodegenOptions, ext: []const u8) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(ext);
    _ = try parser.parse();

    var t = Transformer.init(allocator, &parser.ast, t_options);
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.new_ast, cg_options);
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

fn e2eWithOptions(allocator: std.mem.Allocator, source: []const u8, cg_options: CodegenOptions) !TestResult {
    return e2eFull(allocator, source, .{}, cg_options, ".ts");
}

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

// ============================================================
// E2E Tests: Class
// ============================================================

test "Codegen: class basic" {
    var r = try e2e(std.testing.allocator, "class Foo {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}", r.output);
}

test "Codegen: class extends" {
    var r = try e2e(std.testing.allocator, "class Foo extends Bar {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo extends Bar{}", r.output);
}

test "Codegen: class static method" {
    var r = try e2e(std.testing.allocator, "class Foo { static bar() { return 1; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static bar(){return 1;}}", r.output);
}

test "Codegen: class getter setter" {
    var r = try e2e(std.testing.allocator, "class Foo { get x() { return 1; } set x(v) {} }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{get x(){return 1;}set x(v){}}", r.output);
}

test "Codegen: class private field" {
    var r = try e2e(std.testing.allocator, "class Foo { #x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{#x=1;}", r.output);
}

// ============================================================
// E2E Tests: Arrow Function
// ============================================================

test "Codegen: arrow no params" {
    var r = try e2e(std.testing.allocator, "const f = () => 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=()=>1;", r.output);
}

test "Codegen: arrow single param" {
    // esbuild 호환: 단일 파라미터도 항상 괄호로 감싸기
    var r = try e2e(std.testing.allocator, "const f = x => x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(x)=>x;", r.output);
}

test "Codegen: arrow block body" {
    var r = try e2e(std.testing.allocator, "const f = (a, b) => { return a + b; };");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(a,b)=>{return a + b;};", r.output);
}

test "Codegen: arrow rest param" {
    var r = try e2e(std.testing.allocator, "const f = (...args) => args;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(...args)=>args;", r.output);
}

// ============================================================
// E2E Tests: Async/Await
// ============================================================

test "Codegen: async function" {
    var r = try e2e(std.testing.allocator, "async function foo() { return 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("async function foo(){return 1;}", r.output);
}

test "Codegen: await expression" {
    var r = try e2e(std.testing.allocator, "async function foo() { const x = await bar(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("async function foo(){const x=await bar();}", r.output);
}

test "Codegen: async arrow" {
    var r = try e2e(std.testing.allocator, "const f = async () => await x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=async ()=>await x;", r.output);
}

// ============================================================
// E2E Tests: Generator
// ============================================================

test "Codegen: generator function" {
    var r = try e2e(std.testing.allocator, "function* gen() { yield 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function* gen(){yield 1;}", r.output);
}

test "Codegen: yield star" {
    var r = try e2e(std.testing.allocator, "function* gen() { yield* other(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function* gen(){yield* other();}", r.output);
}

// ============================================================
// E2E Tests: Destructuring
// ============================================================

test "Codegen: array destructuring" {
    var r = try e2e(std.testing.allocator, "const [a, b] = [1, 2];");
    defer r.deinit();
    try std.testing.expectEqualStrings("const [a,b]=[1,2];", r.output);
}

test "Codegen: object destructuring" {
    // binding_property always emits key:value (shorthand is not collapsed)
    var r = try e2e(std.testing.allocator, "const { x, y } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {x:x,y:y}=obj;", r.output);
}

test "Codegen: nested destructuring" {
    var r = try e2e(std.testing.allocator, "const { a: { b } } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {a:{b:b}}=obj;", r.output);
}

test "Codegen: destructuring with default" {
    var r = try e2e(std.testing.allocator, "const { x = 1 } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {x:x=1}=obj;", r.output);
}

// ============================================================
// E2E Tests: Template Literal
// ============================================================

test "Codegen: template literal basic" {
    var r = try e2e(std.testing.allocator, "const x = `hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello`;", r.output);
}

test "Codegen: template literal with expression" {
    var r = try e2e(std.testing.allocator, "const x = `hello ${name}!`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello ${name}!`;", r.output);
}

// ============================================================
// E2E Tests: For-of / For-in
// ============================================================

test "Codegen: for-of" {
    var r = try e2e(std.testing.allocator, "for (const x of arr) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){}", r.output);
}

test "Codegen: for-in" {
    var r = try e2e(std.testing.allocator, "for (const k in obj) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const k in obj){}", r.output);
}

// ============================================================
// E2E Tests: Spread
// ============================================================

test "Codegen: array spread" {
    var r = try e2e(std.testing.allocator, "const x = [...a, ...b];");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=[...a,...b];", r.output);
}

test "Codegen: object spread" {
    var r = try e2e(std.testing.allocator, "const x = { ...a, ...b };");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...a,...b};", r.output);
}

test "Codegen: function call spread" {
    var r = try e2e(std.testing.allocator, "foo(...args);");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo(...args);", r.output);
}

// ============================================================
// E2E Tests: Optional Chaining / Nullish
// ============================================================

test "Codegen: optional chaining" {
    var r = try e2e(std.testing.allocator, "const x = a?.b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a?.b;", r.output);
}

test "Codegen: nullish coalescing" {
    var r = try e2e(std.testing.allocator, "const x = a ?? b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

test "Codegen: optional chaining method call" {
    var r = try e2e(std.testing.allocator, "const x = a?.foo();");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a?.foo();", r.output);
}

// ============================================================
// E2E Tests: Logical Assignment
// ============================================================

test "Codegen: logical and assign" {
    var r = try e2e(std.testing.allocator, "a &&= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a&&=b;", r.output);
}

test "Codegen: logical or assign" {
    var r = try e2e(std.testing.allocator, "a ||= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a||=b;", r.output);
}

test "Codegen: nullish assign" {
    var r = try e2e(std.testing.allocator, "a ??= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a??=b;", r.output);
}

// ============================================================
// E2E Tests: Import/Export
// ============================================================

test "Codegen: import default" {
    var r = try e2e(std.testing.allocator, "import foo from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import foo from \"./foo\";", r.output);
}

test "Codegen: import named" {
    var r = try e2e(std.testing.allocator, "import { a, b } from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import {a,b} from \"./foo\";", r.output);
}

test "Codegen: import namespace" {
    var r = try e2e(std.testing.allocator, "import * as ns from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import * as ns from \"./foo\";", r.output);
}

test "Codegen: export named" {
    // export_specifier uses writeNodeSpan which preserves trailing space from source
    var r = try e2e(std.testing.allocator, "export { a, b };");
    defer r.deinit();
    try std.testing.expectEqualStrings("export {a,b };", r.output);
}

test "Codegen: export default function" {
    var r = try e2e(std.testing.allocator, "export default function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("export default function foo(){}", r.output);
}

test "Codegen: export all re-export" {
    var r = try e2e(std.testing.allocator, "export * from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("export * from \"./foo\";", r.output);
}

test "Codegen: export all as namespace" {
    var r = try e2e(std.testing.allocator, "export * as ns from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("export * as ns from \"./foo\";", r.output);
}

// ============================================================
// E2E Tests: JSX → React.createElement
// ============================================================

test "Codegen: JSX self-closing" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=/* @__PURE__ */ React.createElement(\"div\",null);", r.output);
}

test "Codegen: JSX element with children" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>hello</div>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=/* @__PURE__ */ React.createElement(\"div\",null,\"hello\");", r.output);
}

test "Codegen: JSX fragment" {
    var r = try e2eJSX(std.testing.allocator, "const x = <>hello</>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=/* @__PURE__ */ React.createElement(React.Fragment,null,\"hello\");", r.output);
}

// --- JSX: closing tag 뒤 텍스트 (children 모드 복원) ---

test "JSX: text after closing child element" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p><code>x</code> text</p>;");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const x=/* @__PURE__ */ React.createElement(\"p\",null,/* @__PURE__ */ React.createElement(\"code\",null,\"x\"),\" text\");",
        r.output,
    );
}

test "JSX: text between two child elements" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p><b>a</b> and <i>b</i></p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" and \"") != null);
}

test "JSX: multiple inline elements" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p>Edit <code>src/App.tsx</code> and save to test <code>HMR</code></p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"Edit \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" and save to test \"") != null);
}

test "JSX: nested elements with text at every level" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>before <span>inner</span> after</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"before \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"inner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" after\"") != null);
}

test "JSX: self-closing child followed by text" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p><br /> hello</p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" hello\"") != null);
}

test "JSX: expression then text after child" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p><b>{x}</b> rest</p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" rest\"") != null);
}

// --- JSX: fragment children 모드 ---

test "JSX: fragment with mixed children" {
    var r = try e2eJSX(std.testing.allocator, "const x = <>text <b>bold</b> more</>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"text \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"bold\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" more\"") != null);
}

test "JSX: nested fragment inside element" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div><>a<b>x</b>c</></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"c\"") != null);
}

// --- JSX: 복잡한 실전 패턴 ---

test "JSX: Vite-style multi-attribute + nested" {
    var r = try e2eJSX(std.testing.allocator,
        \\const x = <section id="main">
        \\  <a href="https://example.com" target="_blank">
        \\    Learn more
        \\  </a>
        \\</section>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"https://example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"_blank\"") != null);
}

test "JSX: SVG with use element" {
    var r = try e2eJSX(std.testing.allocator,
        \\const x = <svg className="icon"><use href="/icons.svg#doc" /></svg>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"svg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"use\"") != null);
}

test "JSX: deeply nested children with text" {
    var r = try e2eJSX(std.testing.allocator,
        \\const x = <div><ul><li><a href="#">link</a> desc</li></ul></div>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"link\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" desc\"") != null);
}

test "JSX: sibling elements in fragment" {
    var r = try e2eJSX(std.testing.allocator,
        \\const x = <><h1>title</h1><p>body</p></>;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"body\"") != null);
}

test "JSX: expression between elements" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p>count: {n} items</p>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"count: \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" items\"") != null);
}

test "JSX: empty expression container" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>{}</div>;");
    defer r.deinit();
    try std.testing.expect(r.output.len > 0);
}

test "JSX: spread attribute" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div {...props}>child</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"child\"") != null);
}

test "JSX: component with children" {
    var r = try e2eJSX(std.testing.allocator, "const x = <App><Header />content</App>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "App") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Header") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"content\"") != null);
}

// ============================================================
// E2E Tests: Token splitting (>> → > + >, >= → > + = etc.)
// ============================================================

test "Codegen: nested generic >> splits correctly" {
    var r = try e2e(std.testing.allocator, "let x: Array<Array<number>>");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x;", r.output);
}

test "Codegen: arrow with >= split (): A<T>=> 0" {
    var r = try e2e(std.testing.allocator, "(): A<T>=> 0");
    defer r.deinit();
    try std.testing.expectEqualStrings("()=>0;", r.output);
}

test "Codegen: triple nested generic >>>" {
    var r = try e2e(std.testing.allocator, "let x: A<B<C<number>>>");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x;", r.output);
}

// ============================================================
// E2E Tests: Namespace with export
// ============================================================

test "Codegen: namespace with export const" {
    var r = try e2e(std.testing.allocator, "namespace Foo { export const x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Foo;((Foo) => {Foo.x=1;})(Foo || (Foo = {}));",
        r.output,
    );
}

test "Codegen: namespace with export function" {
    var r = try e2e(std.testing.allocator, "namespace Foo { export function bar() {} }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Foo;((Foo) => {function bar(){}Foo.bar=bar;})(Foo || (Foo = {}));",
        r.output,
    );
}

test "Codegen: namespace export reference substitution" {
    var r = try e2e(std.testing.allocator, "namespace ns { export let L1 = 1; console.log(L1); }");
    defer r.deinit();
    // export된 변수의 참조가 ns.L1으로 치환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.L1)") != null);
    // 선언부는 치환되면 안 됨 (let L1 = 1, not let ns.L1 = 1)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let ns.L1") == null);
}

test "Codegen: namespace export reference — multiple exports" {
    var r = try e2e(std.testing.allocator, "namespace ns { export let a = 1, b = 2; console.log(a + b); }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.a + ns.b)") != null);
}

test "Codegen: namespace export reference — function" {
    var r = try e2e(std.testing.allocator, "namespace ns { export function foo() {} console.log(foo); }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.foo)") != null);
}

test "Codegen: namespace export var — direct property assignment (no local var)" {
    // Bug 1 fix: reserved word (await, yield) as export var name should not emit local variable.
    // export let foo = 1 → ns.foo=1; (not let foo=1;ns.foo=foo;)
    var r = try e2e(std.testing.allocator, "namespace x { export let foo = 1, bar = foo; }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var x;((x) => {x.foo=1;x.bar=x.foo;})(x || (x = {}));",
        r.output,
    );
}

test "Codegen: namespace export declare — reference rewriting" {
    // Bug 2 fix: export declare const L1 → references to L1 should be rewritten to ns.L1.
    var r = try e2e(std.testing.allocator, "namespace ns { export declare const L1; console.log(L1); }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log(ns.L1)") != null);
}

test "Codegen: namespace nested export mutation — uses property access" {
    // Bug 3 fix: mutations to exported vars should use ns.prop, not stale local.
    // foo += foo → B.foo += B.foo (not foo += B.foo)
    var r = try e2e(std.testing.allocator, "namespace A { export namespace B { export let foo = 1; foo += foo } }");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "B.foo+=B.foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "B.foo=1") != null);
}

// ============================================================
// E2E Tests: TS type assertions (stripped)
// ============================================================

test "Codegen: as expression stripped" {
    var r = try e2e(std.testing.allocator, "const x = value as string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

test "Codegen: satisfies expression stripped" {
    var r = try e2e(std.testing.allocator, "const x = value satisfies T;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

test "Codegen: non-null assertion stripped" {
    var r = try e2e(std.testing.allocator, "const x = value!;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

// ============================================================
// E2E Tests: CJS module format
// ============================================================

test "Codegen CJS: import named" {
    var r = try e2eCJS(std.testing.allocator, "import { foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo}=require(\"./bar\");", r.output);
}

test "Codegen CJS: import named with rename" {
    // ESM `as` → CJS `:` 변환: import { X as Y } → const {X:Y}=require(...)
    var r = try e2eCJS(std.testing.allocator, "import { Commands as ViewCommands } from './view';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {Commands:ViewCommands}=require(\"./view\");", r.output);
}

test "Codegen CJS: import named multiple with rename" {
    // 여러 named import 중 일부만 rename
    var r = try e2eCJS(std.testing.allocator, "import { foo, bar as baz, qux } from './mod';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo,bar:baz,qux}=require(\"./mod\");", r.output);
}

test "Codegen CJS: import named same name" {
    // imported == local (rename 없음) — `:` 출력하지 않음
    var r = try e2eCJS(std.testing.allocator, "import { foo as foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo}=require(\"./bar\");", r.output);
}

test "Codegen CJS: import default" {
    var r = try e2eCJS(std.testing.allocator, "import bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require(\"./bar\").default;", r.output);
}

test "Codegen CJS: import namespace" {
    var r = try e2eCJS(std.testing.allocator, "import * as bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require(\"./bar\");", r.output);
}

test "Codegen CJS: export all" {
    var r = try e2eCJS(std.testing.allocator, "export * from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("Object.assign(exports,require(\"./bar\"));", r.output);
}

test "Codegen CJS: re-export named" {
    var r = try e2eCJS(std.testing.allocator, "export { foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.foo=require(\"./bar\").foo;", r.output);
}

test "Codegen CJS: re-export default" {
    var r = try e2eCJS(std.testing.allocator, "export { default } from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.default=require(\"./foo\").default;", r.output);
}

test "Codegen CJS: re-export default as named" {
    var r = try e2eCJS(std.testing.allocator, "export { default as Foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.Foo=require(\"./bar\").default;", r.output);
}

test "Codegen CJS: re-export named as default" {
    var r = try e2eCJS(std.testing.allocator, "export { foo as default } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.default=require(\"./bar\").foo;", r.output);
}

test "Codegen CJS: export named function" {
    var r = try e2eCJS(std.testing.allocator, "export function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo(){}exports.foo=foo;", r.output);
}

test "Codegen CJS + ES5: export default class" {
    // export default class Foo { } → ES5 function + module.exports=Foo;
    var r = try e2eFull(std.testing.allocator, "export default class Foo { constructor() {} }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) }, .{ .minify_whitespace = true, .module_format = .cjs }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "module.exports=Foo;") != null);
    // module.exports=; (빈 값) 금지
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "module.exports=;"), null);
}

test "Codegen CJS + ES5: export default anonymous class" {
    var r = try e2eFull(std.testing.allocator, "export default class { constructor() {} }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) }, .{ .minify_whitespace = true, .module_format = .cjs }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "module.exports=_Class;") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "module.exports=;"), null);
}

test "Codegen CJS + ES5: export default class with extends" {
    var r = try e2eFull(std.testing.allocator, "export default class CustomEvent extends Event { constructor(type) { super(type); } }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) }, .{ .minify_whitespace = true, .module_format = .cjs }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "module.exports=CustomEvent;") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "module.exports=;"), null);
}

// ============================================================
// E2E Tests: Formatted output
// ============================================================

test "Codegen formatted: function declaration" {
    var r = try e2eWithOptions(std.testing.allocator, "function foo() { return 1; }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo() {\n\treturn 1;\n}\n", r.output);
}

test "Codegen formatted: class with method" {
    var r = try e2eWithOptions(std.testing.allocator, "class Foo { bar() {} }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo {\n\tbar() {\n\t}\n}\n", r.output);
}

test "Codegen formatted: spaces indent" {
    var r = try e2eWithOptions(std.testing.allocator, "if (x) { return 1; }", .{ .indent_char = .space, .indent_width = 2 });
    defer r.deinit();
    try std.testing.expectEqualStrings("if (x) {\n  return 1;\n}\n", r.output);
}

// ================================================================
// import.meta polyfill tests
// ================================================================

test "import.meta: ESM keeps import.meta as-is" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .esm });
    defer r.deinit();
    try std.testing.expectEqualStrings("const m=import.meta;", r.output);
}

test "import.meta: CJS node — standalone import.meta" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    // CJS node: import.meta → full polyfill object
    try std.testing.expectEqualStrings(
        "const m={url:require(\"url\").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename};",
        r.output,
    );
}

test "import.meta: CJS browser — standalone import.meta" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    // CJS browser: import.meta → {}
    try std.testing.expectEqualStrings("const m={};", r.output);
}

test "import.meta.url: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const u=require(\"url\").pathToFileURL(__filename).href;",
        r.output,
    );
}

test "import.meta.url: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=\"\";", r.output);
}

test "import.meta.dirname: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const d = import.meta.dirname;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings("const d=__dirname;", r.output);
}

test "import.meta.dirname: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const d = import.meta.dirname;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const d=\"\";", r.output);
}

test "import.meta.filename: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const f = import.meta.filename;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=__filename;", r.output);
}

test "import.meta.filename: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const f = import.meta.filename;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=\"\";", r.output);
}

test "import.meta.url: ESM keeps as-is" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .esm });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=import.meta.url;", r.output);
}

test "import.meta: replace_import_meta with node platform" {
    // 번들러가 replace_import_meta를 설정하는 경우 (non-ESM 번들)
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .replace_import_meta = true, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const u=require(\"url\").pathToFileURL(__filename).href;",
        r.output,
    );
}

test "import.meta: replace_import_meta with browser platform" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .replace_import_meta = true, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=\"\";", r.output);
}

test "import.meta: unknown property CJS node falls through to polyfill" {
    // import.meta.env 등 알려지지 않은 프로퍼티 → import.meta polyfill + .env
    var r = try e2eWithOptions(std.testing.allocator, "const e = import.meta.env;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    // 알려지지 않은 프로퍼티는 import.meta 폴리필 뒤에 .prop이 붙어야 함
    try std.testing.expectEqualStrings(
        "const e={url:require(\"url\").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename}.env;",
        r.output,
    );
}

test "import.meta: unknown property CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const e = import.meta.env;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const e={}.env;", r.output);
}

// ============================================================
// ES Downlevel Tests (--target)
// ============================================================

fn e2eTarget(allocator: std.mem.Allocator, source: []const u8, target: TransformOptions.compat.ESTarget) !TestResult {
    return e2eFull(allocator, source, .{ .unsupported = TransformOptions.compat.fromESTarget(target) }, .{ .minify_whitespace = true }, ".ts");
}

// --- ?? (nullish coalescing) ---

test "ES2020: ?? simple identifier" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a!=null?a:b;", r.output);
}

test "ES2020: ?? side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "const x = foo() ?? b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;const x=(_a=foo())!=null?_a:b;", r.output);
}

test "ES2020: ?? no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

test "ES2020: ?? no transform on es2020" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a??b;", r.output);
}

// --- ?. (optional chaining) ---

test "ES2020: ?. member" {
    var r = try e2eTarget(std.testing.allocator, "a?.b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a.b;", r.output);
}

test "ES2020: ?. computed" {
    var r = try e2eTarget(std.testing.allocator, "a?.[0];", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a[0];", r.output);
}

test "ES2020: ?. call" {
    var r = try e2eTarget(std.testing.allocator, "a?.();", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a();", r.output);
}

test "ES2020: ?. side effect (temp var)" {
    var r = try e2eTarget(std.testing.allocator, "foo()?.bar;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;(_a=foo())==null?void 0:_a.bar;", r.output);
}

test "ES2020: ?. chain continuation" {
    var r = try e2eTarget(std.testing.allocator, "a?.b.c;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a==null?void 0:a.b.c;", r.output);
}

test "ES2020: ?. no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "a?.b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("a?.b;", r.output);
}

// --- ??= (nullish assignment) ---

test "ES2021: ??= to es2020" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a??(a=b);", r.output);
}

test "ES2021: ??= to es2019 (double lowering)" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("a!=null?a:(a=b);", r.output);
}

test "ES2021: ??= no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "a ??= b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("a??=b;", r.output);
}

// --- ||= &&= (logical assignment) ---

test "ES2021: ||=" {
    var r = try e2eTarget(std.testing.allocator, "a ||= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a||(a=b);", r.output);
}

test "ES2021: &&=" {
    var r = try e2eTarget(std.testing.allocator, "a &&= b;", .es2020);
    defer r.deinit();
    try std.testing.expectEqualStrings("a&&(a=b);", r.output);
}

test "ES2021: ||= no transform on es2021" {
    var r = try e2eTarget(std.testing.allocator, "a ||= b;", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("a||=b;", r.output);
}

// --- ** (exponentiation) ---

test "ES2016: ** to Math.pow" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .es2015);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Math.pow(a,b);", r.output);
}

test "ES2016: **= to Math.pow assignment" {
    var r = try e2eTarget(std.testing.allocator, "a **= b;", .es2015);
    defer r.deinit();
    try std.testing.expectEqualStrings("a=Math.pow(a,b);", r.output);
}

test "ES2016: ** no transform on es2016" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .es2016);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a**b;", r.output);
}

test "ES2016: ** no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ** b;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a**b;", r.output);
}

test "ES2016: **= no transform on es2016" {
    var r = try e2eTarget(std.testing.allocator, "a **= b;", .es2016);
    defer r.deinit();
    try std.testing.expectEqualStrings("a**=b;", r.output);
}

// --- catch binding (ES2019) ---

test "ES2019: optional catch binding" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(_unused){y;}", r.output);
}

test "ES2019: catch with binding preserved" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch (e) { y; }", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch(e){y;}", r.output);
}

test "ES2019: optional catch no transform on es2019" {
    var r = try e2eTarget(std.testing.allocator, "try { x; } catch { y; }", .es2019);
    defer r.deinit();
    try std.testing.expectEqualStrings("try{x;}catch{y;}", r.output);
}

// --- ES2022: class static block ---

test "ES2022: static block to IIFE" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { console.log(\"init\"); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}(()=>{console.log(\"init\");})();", r.output);
}

test "ES2022: static block no transform on es2022" {
    // static_block은 writeNodeSpan으로 소스를 그대로 복사하므로 공백이 유지됨
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .es2022);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\")}}", r.output);
}

test "ES2022: static block no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{console.log(\"init\")}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{console.log(\"init\")}}", r.output);
}

test "ES2022: multiple static blocks" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { a(); } method() {} static { b(); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{method(){}}(()=>{a();})();(()=>{b();})();", r.output);
}

test "ES2022: static block with methods preserved" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { method() { return 1; } static { init(); } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{method(){return 1;}}(()=>{init();})();", r.output);
}

// --- ES2017: async/await → generator ---

test "ES2017: async function declaration" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { return await bar(); }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export function foo(){return __async(function*(){return (yield bar());}).call(this);}", r.output);
}

test "ES2017: async arrow block body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => { await x; };", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){(yield x);}).call(this);", r.output);
}

test "ES2017: async arrow expression body" {
    var r = try e2eFull(std.testing.allocator, "export const f = async () => await x;", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export const f=()=>__async(function*(){return (yield x);}).call(this);", r.output);
}

test "ES2017: no transform on es2017" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { await x; }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2017) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export async function foo(){await x;}", r.output);
}

test "ES2017: no transform on esnext" {
    var r = try e2eFull(std.testing.allocator, "export async function foo() { await x; }", .{ .unsupported = TransformOptions.compat.fromESTarget(.esnext) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export async function foo(){await x;}", r.output);
}

test "ES2017: non-async function unchanged" {
    var r = try e2eFull(std.testing.allocator, "export function foo() { return 1; }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es2016) }, .{ .minify_whitespace = true }, ".mts");
    defer r.deinit();
    try std.testing.expectEqualStrings("export function foo(){return 1;}", r.output);
}

// --- ES5: async → state machine (async_await + generator 둘 다 unsupported) ---

/// ES5 async state machine 변환의 공통 검증.
/// function*/yield 없고, __async/__generator가 있어야 함.
fn expectAsyncStateMachine(output: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, output, "__async") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "function*") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "yield") == null);
}

test "ES5: async function → __async + __generator state machine" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return await bar(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state") != null);
}

test "ES5: async function with multiple awaits" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var x = await a(); await b(x); return x; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES5: async arrow block body → state machine" {
    var r = try e2eTarget(std.testing.allocator, "var f = async () => { await x; };", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async arrow expression body → state machine" {
    var r = try e2eTarget(std.testing.allocator, "var f = async () => await x;", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async function with if/await" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { if (x) { await a(); } await b(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with destructuring var hoisting" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var {a, b} = await getObj(); return a + b; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    // destructuring은 개별 identifier로 호이스팅: var a, b; (not var {a, b};)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a,b") != null or
        std.mem.indexOf(u8, r.output, "var a, b") != null);
    // destructuring 패턴이 초기화 없이 나오면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var {") == null);
}

// --- yield/await in expression position ---

test "ES5: await in if condition (logical AND)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { if (x && (await check())) { doSomething(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES5: await in if condition (logical OR)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { if (x || (await fallback())) { run(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in if condition (simple)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { if (await check()) { run(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in while condition" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { while (await hasNext()) { process(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in for test condition" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { for (var i = 0; await check(i); i++) { run(i); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in return expression (nested in call)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return bar(await x); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: multiple awaits in call args" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { bar(await x, await y); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in binary expression" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return (await a) + (await b); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in unary expression (negation)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { if (!(await check())) { fallback(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in ternary expression" {
    var r = try e2eTarget(std.testing.allocator, "async function foo(x) { return x ? await a() : await b(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: double await (await (await nested()))" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return await (await getPromise()); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in var init (nested in call)" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var x = bar(await y); return x; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
}

test "ES5: generator with yield in if condition" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(x) { if (x && (yield check())) { run(); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: generator with yield in return expression" {
    var r = try e2eTarget(std.testing.allocator, "function* gen() { return foo(yield x); }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: await in object literal" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return {x: await a, y: await b}; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in template literal" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return `hello ${await name()}`; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in spread element" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return bar(...await getArgs()); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: await in member expression (a.b.method(await x))" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { if (a.b && (await a.c())) { run(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: multiple awaits in array literal use temp vars" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { return [await a, await b]; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
    // 각 yield 결과가 temp 변수에 저장되어야 함 (직접 _state.sent() 중복 호출 방지)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=_state.sent()") != null or
        std.mem.indexOf(u8, r.output, "= _state.sent()") != null);
}

test "ES5: class async method → state machine (RN KeyboardAvoidingView pattern)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  async bar(x) {
        \\    if (x && (await check())) { return 0; }
        \\    const y = await compute(x);
        \\    return y;
        \\  }
        \\}
    , .es5);
    defer r.deinit();
    // class async method도 state machine으로 변환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
    // async 키워드가 메서드 선언에 남아있으면 안 됨 (async function은 __async 헬퍼 제외)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async function") == null);
}

test "ES5: class static async method → state machine" {
    var r = try e2eTarget(std.testing.allocator, "class Foo { static async fetch() { return await getData(); } }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: destructuring default parameter with spread (AnimatedImplementation pattern)" {
    var r = try e2eTarget(std.testing.allocator, "function foo() { return {...x}; }\nfunction bar({a = 1, b = true} = {}) { return a; }", .es5);
    defer r.deinit();
    // spread + destructuring default parameter → 크래시 없이 출력
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "ES5: destructuring default parameter in function" {
    var r = try e2eTarget(std.testing.allocator, "function loop(animation, {iterations = -1, reset = true} = {}) { return iterations; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
    // destructuring은 var {iterations, reset} = _ref 형태로 분해
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
}

test "ES5: generator with destructuring var hoisting" {
    var r = try e2eTarget(std.testing.allocator, "function* gen() { var {x, y} = yield getObj(); return x; }", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var {") == null);
}

test "ES5: __async runtime ES5 compatibility" {
    const rt = @import("../bundler/runtime_helpers.zig");
    // ES5 런타임 상수에 arrow function / rest params가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5, "=>") == null);
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5, "...") == null);
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5_MIN, "=>") == null);
    try std.testing.expect(std.mem.indexOf(u8, rt.ASYNC_RUNTIME_ES5_MIN, "...") == null);
    // ES5 타겟에서 es5_compat가 설정되는지 확인
    var r = try e2eTarget(std.testing.allocator, "async function foo() { await bar(); }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

// --- ES5: 추가 async/generator edge cases ---

test "ES5: async with try/catch + await" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { try { await a(); } catch(e) { await b(e); } finally { await c(); } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with do-while + await in condition" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { var i = 0; do { i++; } while (await check(i)); return i; }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: class async arrow field" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  _update = async () => {
        \\    const x = await getData();
        \\    this.setState({data: x});
        \\  };
        \\}
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES5: class with async method + non-async method" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  sync() { return 1; }
        \\  async asyncMethod() { return await bar(); }
        \\  static staticSync() { return 2; }
        \\}
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype.sync") != null);
}

test "ES5: async with while(true) + await + break" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { while (true) { var x = await next(); if (!x) break; } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with switch + await" {
    var r = try e2eTarget(std.testing.allocator,
        \\async function foo(type) {
        \\  switch (type) {
        \\    case 'a': await handleA(); break;
        \\    case 'b': await handleB(); break;
        \\    default: await handleDefault();
        \\  }
        \\}
    , .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: async with labeled break + await" {
    var r = try e2eTarget(std.testing.allocator, "async function foo() { outer: for (var i = 0; i < 3; i++) { if (await check(i)) break outer; } }", .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

test "ES5: nested async functions" {
    var r = try e2eTarget(std.testing.allocator,
        \\async function outer() {
        \\  async function inner() { return await bar(); }
        \\  return await inner();
        \\}
    , .es5);
    defer r.deinit();
    try expectAsyncStateMachine(r.output);
}

// --- ES2018: object spread ---

test "ES2018: spread only" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},obj);", r.output);
}

test "ES2018: props then spread" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, ...obj };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({a:1},obj);", r.output);
}

test "ES2018: spread then props" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},obj,{b:2});", r.output);
}

test "ES2018: mixed spread" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, ...obj, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({a:1},obj,{b:2});", r.output);
}

test "ES2018: multiple spreads" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...a, ...b };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=Object.assign({},a,b);", r.output);
}

test "ES2018: no transform on es2018" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .es2018);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...obj};", r.output);
}

test "ES2018: no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x = { ...obj };", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...obj};", r.output);
}

test "ES2018: no spread - no transform" {
    var r = try e2eTarget(std.testing.allocator, "const x = { a: 1, b: 2 };", .es2017);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={a:1,b:2};", r.output);
}

// --- ES2022: class static block ---

test "ES2022: static block this → class name" {
    // class Foo { static { this.x = 1; } }
    // → class Foo {} (() => { Foo.x = 1; })();
    var r = try e2eTarget(std.testing.allocator, "class Foo { static { this.x = 1; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}(()=>{Foo.x=1;})();", r.output);
}

test "ES2022: static block this in nested function not replaced" {
    // 일반 함수 안의 this는 치환하면 안 됨 (자체 this 바인딩)
    var r = try e2eTarget(std.testing.allocator, "class Bar { static { function f() { return this; } } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Bar{}(()=>{function f(){return this;}})();", r.output);
}

test "ES2022: static block this in arrow replaced" {
    // arrow function은 this 상속 → 치환 대상
    var r = try e2eTarget(std.testing.allocator, "class Baz { static { const f = () => this.x; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Baz{}(()=>{const f=()=>Baz.x;})();", r.output);
}

test "ES2022: static block anonymous class - this not replaced" {
    // 익명 클래스: 클래스 이름이 없으므로 this 그대로
    var r = try e2eTarget(std.testing.allocator, "var x = class { static { this.y = 1; } };", .es2021);
    defer r.deinit();
    // 익명 클래스는 this 치환 안 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.y") != null);
}

test "ES2022: static block this - no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static{this.x=1;}}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static{this.x=1;}}", r.output);
}

test "ES2022: multiple static blocks with this" {
    var r = try e2eTarget(std.testing.allocator, "class A { static { this.x = 1; } static { this.y = 2; } }", .es2021);
    defer r.deinit();
    try std.testing.expectEqualStrings("class A{}(()=>{A.x=1;})();(()=>{A.y=2;})();", r.output);
}

// --- ES2015: template literal ---

test "ES2015: no-substitution template" {
    var r = try e2eTarget(std.testing.allocator, "var x=`hello`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"hello\";", r.output);
}

test "ES2015: template with substitution" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\" + b + \"c\";", r.output);
}

test "ES2015: template empty head" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\" + a;", r.output);
}

test "ES2015: template multiple substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`${a}${b}`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\" + a + b;", r.output);
}

test "ES2015: template with text between substitutions" {
    var r = try e2eTarget(std.testing.allocator, "var x=`a${b}c${d}e`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"a\" + b + \"c\" + d + \"e\";", r.output);
}

test "ES2015: empty template" {
    var r = try e2eTarget(std.testing.allocator, "var x=``;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=\"\";", r.output);
}

test "ES2015: template no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "const x=`hello`;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello`;", r.output);
}

// --- tagged template ---

test "tagged template: basic" {
    var r = try e2e(std.testing.allocator, "foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo`hello`;", r.output);
}

test "tagged template: with substitution" {
    var r = try e2e(std.testing.allocator, "foo`hello ${x} world`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo`hello ${x} world`;", r.output);
}

test "tagged template: after var declaration" {
    var r = try e2e(std.testing.allocator, "var x;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("var x;foo`hello`;", r.output);
}

test "tagged template: after let declaration" {
    var r = try e2e(std.testing.allocator, "let x=1;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;foo`hello`;", r.output);
}

test "tagged template: after function declaration" {
    var r = try e2e(std.testing.allocator, "function f(){}foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(){}foo`hello`;", r.output);
}

test "tagged template: as identifier as tag" {
    var r = try e2e(std.testing.allocator, "as`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("as`hello`;", r.output);
}

test "tagged template: member expression tag" {
    var r = try e2e(std.testing.allocator, "foo.bar`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo.bar`hello`;", r.output);
}

test "tagged template: no-substitution after expression statement" {
    var r = try e2e(std.testing.allocator, "1;foo`hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("1;foo`hello`;", r.output);
}

// --- ES2015: shorthand property ---

test "ES2015: shorthand property expansion" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,y};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:x,y:y};", r.output);
}

test "ES2015: mixed shorthand and full property" {
    var r = try e2eTarget(std.testing.allocator, "var o={x:1,y};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x:1,y:y};", r.output);
}

test "ES2015: shorthand no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={x,y};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={x,y};", r.output);
}

// --- ES2015: computed property ---

test "ES2015: computed property lowering" {
    var r = try e2eTarget(std.testing.allocator, "var o={a:1,[k]:v,b:2};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={a:1},_a[k]=v,_a.b=2,_a);", r.output);
}

test "ES2015: computed property only" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k]:v};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var o=(_a={},_a[k]=v,_a);", r.output);
}

test "ES2015: no computed - no transform" {
    var r = try e2eTarget(std.testing.allocator, "var o={a:1,b:2};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={a:1,b:2};", r.output);
}

test "ES2015: computed no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var o={[k]:v};", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var o={[k]:v};", r.output);
}

// --- ES2015: default/rest parameters ---

test "ES2015: default parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1){return x;}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){x=x===void 0?1:x;return x;}", r.output);
}

test "ES2015: rest parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f(a,...rest){return rest;}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(a){var rest=[].slice.call(arguments,1);return rest;}", r.output);
}

test "ES2015: default + rest combined" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1,...rest){}", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){x=x===void 0?1:x;var rest=[].slice.call(arguments,1);}", r.output);
}

test "ES2015: params no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "function f(x=1,...rest){}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x=1,...rest){}", r.output);
}

// --- ES2015: spread ---

test "ES2015: spread in call" {
    var r = try e2eTarget(std.testing.allocator, "f(...arr);", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("f.apply(void 0,arr);", r.output);
}

test "ES2015: spread in call with args" {
    var r = try e2eTarget(std.testing.allocator, "f(a,...arr);", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("f.apply(void 0,[].concat([a],arr));", r.output);
}

test "ES2015: spread in array" {
    var r = try e2eTarget(std.testing.allocator, "var x=[...arr,1];", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=[].concat(arr,[1]);", r.output);
}

test "ES2015: spread no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "f(...arr);", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("f(...arr);", r.output);
}

test "ES2015: spread in new expression" {
    var r = try e2eTarget(std.testing.allocator, "new Foo(...args);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.bind.apply") != null);
}

// --- ES2015: arrow function ---

test "ES2015: arrow expression body" {
    var r = try e2eTarget(std.testing.allocator, "var f=()=>42;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(){return 42;};", r.output);
}

test "ES2015: arrow with param" {
    var r = try e2eTarget(std.testing.allocator, "var f=x=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x + 1;};", r.output);
}

test "ES2015: arrow with parens param" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>x+1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x + 1;};", r.output);
}

test "ES2015: arrow block body" {
    var r = try e2eTarget(std.testing.allocator, "var f=(x)=>{return x;};", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(x){return x;};", r.output);
}

test "ES2015: arrow multiple params" {
    var r = try e2eTarget(std.testing.allocator, "var f=(a,b)=>a+b;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=function(a,b){return a + b;};", r.output);
}

test "ES2015: arrow no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var f=()=>42;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var f=()=>42;", r.output);
}

// --- ES2015: for-of ---

test "ES2015: for-of with const" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){f(x);}", .es5);
    defer r.deinit();
    // _a=index, _b=array, postfix increment
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_b.length") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x=_b[_a]") != null);
    // postfix _a++ (not prefix ++_a)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a++") != null);
}

test "ES2015: for-of with expression left" {
    var r = try e2eTarget(std.testing.allocator, "for(x of arr){}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "for(") != null);
}

test "ES2015: for-of no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){}", r.output);
}

// --- ES2015: destructuring ---

test "ES2015: object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,a=_a.a,b=_a.b;", r.output);
}

test "ES2015: array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var [x,y]=arr;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=arr,x=_a[0],y=_a[1];", r.output);
}

test "ES2015: destructuring rename" {
    var r = try e2eTarget(std.testing.allocator, "var {a:c}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,c=_a.a;", r.output);
}

test "ES2015: destructuring default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1}=obj;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var _a;var _a=obj,a=_a.a===void 0?1:_a.a;", r.output);
}

test "ES2015: destructuring no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "var {a,b}=obj;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("var {a:a,b:b}=obj;", r.output);
}

test "ES2015: assignment object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "({a,b}=obj);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a=_a.a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "b=_a.b") != null);
}

test "ES2015: assignment array destructuring" {
    var r = try e2eTarget(std.testing.allocator, "([x,y]=arr);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=arr") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=_a[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y=_a[1]") != null);
}

test "ES2015: assignment destructuring with default" {
    var r = try e2eTarget(std.testing.allocator, "({a=1,b}=obj);", .es5);
    defer r.deinit();
    // a = _ref.a === void 0 ? 1 : _ref.a
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0?1:") != null);
}

test "ES2015: assignment array destructuring with default" {
    var r = try e2eTarget(std.testing.allocator, "([x=1,y]=arr);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0?1:") != null);
}

// --- ES2015: let/const → var ---

test "ES2015: let to var" {
    var r = try e2eTarget(std.testing.allocator, "let x=1;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var x=1;", r.output);
}

test "ES2015: const to var" {
    var r = try e2eTarget(std.testing.allocator, "const y=2;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var y=2;", r.output);
}

test "ES2015: var stays var" {
    var r = try e2eTarget(std.testing.allocator, "var z=3;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var z=3;", r.output);
}

test "ES2015: let/const no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "let x=1;const y=2;", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;const y=2;", r.output);
}

// --- ES2015: class ---

test "ES2015: class with constructor and methods" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{constructor(x){this.x=x;}method(){return this.x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Foo(x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_Foo.prototype.method=function()") != null);
}

test "ES2015: class with static method" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static create(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_Foo.create=function()") != null);
}

test "ES2015: empty class" {
    var r = try e2eTarget(std.testing.allocator, "class Empty{}", .es5);
    defer r.deinit();
    // class → IIFE: var Empty = (function() { function Empty() {} return Empty; })()
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var Empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Empty()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return _Empty") != null);
}

test "ES2015: class with instance field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{x=1;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
}

test "ES2015: class with static field" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{static y=2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Foo()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.y=2") != null);
}

test "ES2015: class no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "class Foo{}", .esnext);
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}", r.output);
}

// --- ES2015: generator ---

test "ES2015: basic generator" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator with return" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;return 42;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [2,42]") != null);
}

test "ES2015: generator with for loop yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){for(var i=0;i<3;i++){yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
    // 조건 부정: !(i<3)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!(i<3)") != null or
        std.mem.indexOf(u8, r.output, "!(i < 3)") != null);
}

test "ES2015: generator with if yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(x){if(x){yield 1;}yield 2;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,2]") != null);
}

test "ES2015: generator no transform on esnext" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield 1;}", .esnext);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") == null);
}

test "ES2015: generator var hoisting with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var x=yield 1;return x;}", .es5);
    defer r.deinit();
    // var x가 switch 밖에 호이스팅됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var x") != null);
    // x = _state.sent()
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
    // generator 플래그 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function*") == null);
}

test "ES2015: generator var hoisting without yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var a=1;yield a;}", .es5);
    defer r.deinit();
    // var a가 호이스팅됨, case 안에는 a=1 assignment만
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,a]") != null);
}

test "ES2015: generator yield*" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){yield* [1,2];}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [5,[1,2]]") != null);
}

test "ES2015: generator do-while with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){var i=0;do{yield i;i++;}while(i<3);}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
    // do-while: body 먼저, 조건으로 점프
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i<3") != null or
        std.mem.indexOf(u8, r.output, "i < 3") != null);
}

test "ES2015: generator try/catch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){yield e;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.sent()") != null);
}

test "ES2015: generator try/catch/finally with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* gen(){try{yield 1;}catch(e){f(e);}finally{cleanup();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_state.trys.push") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [7]") != null); // endfinally
    try std.testing.expect(std.mem.indexOf(u8, r.output, "cleanup()") != null);
}

// ============================================================
// ES2015 다운레벨링 추가 테스트
// ============================================================

// --- class extends/super ---

test "ES2015: class extends with super()" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{constructor(x){super(x);this.x=x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "P.call(this,x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(_C,P)") != null);
}

test "ES2015: class extends default constructor" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "P.apply(this,arguments)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends(_C,P)") != null);
}

test "ES2015: super.method() call" {
    var r = try e2eTarget(std.testing.allocator, "class C extends P{m(){return super.m();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "P.prototype.m.call(this)") != null);
}

// --- class getter/setter ---

test "ES2015: class getter/setter paired" {
    var r = try e2eTarget(std.testing.allocator, "class F{get v(){return 1;}set v(x){}}", .es5);
    defer r.deinit();
    // 하나의 Object.defineProperty로 합쳐져야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty") != null);
    // "get:" 와 "set:" 가 같은 호출 안에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "get:function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "set:function(x)") != null);
}

test "ES2015: class static getter" {
    var r = try e2eTarget(std.testing.allocator, "class F{static get n(){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.defineProperty(_F") != null);
}

// --- class expression ---

test "ES2015: class expression simple" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Class()") != null);
}

test "ES2015: class expression with method" {
    var r = try e2eTarget(std.testing.allocator, "const F=class{m(){return 1;}};", .es5);
    defer r.deinit();
    // IIFE 패턴
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return __Class") != null);
}

test "ES2015: class expression with extends" {
    var r = try e2eTarget(std.testing.allocator, "const F=class extends P{m(){}};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "(function()") != null);
}

// --- class private field ---

test "ES2015: class private field WeakMap" {
    var r = try e2eTarget(std.testing.allocator, "class F{#x=1;g(){return this.#x;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "new WeakMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.set(this,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.get(this)") != null);
}

test "ES2015: class private field set" {
    var r = try e2eTarget(std.testing.allocator, "class F{#x=0;s(v){this.#x=v;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_x.set(this,v)") != null);
}

// --- destructuring rest ---

test "ES2015: destructuring object rest" {
    var r = try e2eTarget(std.testing.allocator, "var {a,...r}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"a\"]") != null);
}

test "ES2015: destructuring array rest" {
    var r = try e2eTarget(std.testing.allocator, "var [a,...r]=arr;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".slice(1)") != null);
}

// --- generator labeled break/continue ---

test "ES2015: generator labeled break" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)break outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // break outer → return [3, N] (end label로 점프)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [3,") != null);
}

test "ES2015: generator labeled continue" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){outer:for(var i=0;i<3;i++){if(i===1)continue outer;yield i;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // continue outer → return [3, N] (update label로 점프 → i++ 실행)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "i++") != null);
}

// --- generator switch yield ---

test "ES2015: generator switch with yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){switch(x){case 1:yield 'a';break;default:yield 'b';}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // switch → if-else 체인으로 분해
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,\"a\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,\"b\"]") != null);
}

// --- static block ES5 ---

test "ES2015: static block in class declaration" {
    var r = try e2eTarget(std.testing.allocator, "class F{static v;static{F.v=42;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.v=42") != null);
}

// --- arrow this capture in class method ---

test "ES2015: arrow this capture in class method" {
    var r = try e2eTarget(std.testing.allocator, "class F{x=1;g(){var fn=()=>this.x;return fn();}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x") != null);
}

// --- arrow edge cases ---

test "ES2015: arrow returning object literal" {
    var r = try e2eTarget(std.testing.allocator, "var f = () => ({ x: 1 });", .es5);
    defer r.deinit();
    // 객체 리터럴 반환 시 괄호 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x:1") != null);
}

test "ES2015: arrow with destructuring param" {
    var r = try e2eTarget(std.testing.allocator, "var f = ({x,y}) => x+y;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function(") != null);
}

test "ES2015: nested arrow this capture" {
    var r = try e2eTarget(std.testing.allocator, "function outer(){var f=()=>{var g=()=>this.x;};}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _this=this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this.x") != null);
}

test "ES2015: arrow in object method preserves this" {
    var r = try e2eTarget(std.testing.allocator, "var obj={m(){return ()=>this;}};", .es5);
    defer r.deinit();
    // arrow → function 변환 + _this 참조
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_this") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function()") != null);
}

// --- destructuring edge cases ---

test "ES2015: nested object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a:{b}}=obj;", .es5);
    defer r.deinit();
    // 중첩 구조분해 → 임시 변수 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
}

test "ES2015: array in object destructuring" {
    var r = try e2eTarget(std.testing.allocator, "var {a:[x,y]}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]") != null);
}

test "ES2015: destructuring function parameter" {
    var r = try e2eTarget(std.testing.allocator, "function f({a,b}){return a+b;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function f(") != null);
}

test "ES2015: destructuring with computed key" {
    var r = try e2eTarget(std.testing.allocator, "var k='x';var {[k]:v}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

test "ES2015: destructuring with string key uses bracket notation" {
    // 하이픈 포함 문자열 키: _ref["aria-busy"] (bracket), _ref.ariaBusy (dot) 아님
    var r = try e2eTarget(std.testing.allocator,
        \\var {"aria-busy":busy,"aria-checked":checked}=obj;
    , .es5);
    defer r.deinit();
    // bracket notation 사용 확인
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"aria-busy\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"aria-checked\"]") != null);
    // dot notation이 아닌지 확인
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, ".\"aria-busy\""), null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, ".\"aria-checked\""), null);
}

test "ES2015: destructuring with string key and default uses bracket notation" {
    // 문자열 키 + 기본값: _ref["aria-busy"] === void 0 ? false : _ref["aria-busy"]
    var r = try e2eTarget(std.testing.allocator,
        \\var {"aria-busy":busy=false}=obj;
    , .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"aria-busy\"]") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, ".\"aria-busy\""), null);
}

test "ES2015: for-of with destructuring" {
    var r = try e2eTarget(std.testing.allocator, "for(const [k,v] of arr){}", .es5);
    defer r.deinit();
    // for-of → index loop, const → var
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".length") != null);
}

// --- class edge cases ---

test "ES2015: class with computed method" {
    var r = try e2eTarget(std.testing.allocator, "var k='m';class F{[k](){return 1;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _F()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
}

test "ES2015: class with computed method uses bracket notation" {
    // [Symbol.iterator]() → prototype[Symbol.iterator] = function() (dot 없이)
    var r = try e2eTarget(std.testing.allocator, "class F{[Symbol.iterator](){return this;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype[Symbol.iterator]") != null);
    // prototype.[Symbol.iterator] (잘못된 dot notation) 금지
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "prototype.["), null);
}

test "ES2015: static computed field uses bracket notation" {
    var r = try e2eTarget(std.testing.allocator, "var k='x';class F{static [k]=1;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F[k]=1") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "F.[k]"), null);
}

test "ES2015: instance computed field uses bracket notation" {
    var r = try e2eTarget(std.testing.allocator, "var k='tag';class F{[k]='foo';}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this[k]") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "this.[k]"), null);
}

test "ES2015: class with multiple fields" {
    var r = try e2eTarget(std.testing.allocator, "class F{a=1;b='hi';c=true;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.b=\"hi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.c=true") != null);
}

test "ES2015: class constructor with super and field" {
    var r = try e2eTarget(std.testing.allocator, "class B{x=0;}class D extends B{y=1;constructor(){super();this.z=2;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.y=1") != null);
}

// --- generator edge cases ---

test "ES2015: generator with while yield" {
    var r = try e2eTarget(std.testing.allocator, "function* g(){var i=0;while(i<3){yield i;i++;}}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [4,i]") != null);
}

test "ES2015: generator expression" {
    var r = try e2eTarget(std.testing.allocator, "var g=function*(){yield 1;yield 2;};", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
}

test "ES2015: generator with multiple return" {
    var r = try e2eTarget(std.testing.allocator, "function* g(x){if(x>0){return 'pos';}yield 0;return 'neg';}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__generator") != null);
    // yield 0 → [4, 0], return "neg" → [2, "neg"]
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return [2,\"neg\"]") != null);
}

// --- for-of edge cases ---

test "ES2015: for-of with let" {
    var r = try e2eTarget(std.testing.allocator, "for(let x of arr){f(x);}", .es5);
    defer r.deinit();
    // let → var + for-of → index loop
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

test "ES2015: for-of with break" {
    var r = try e2eTarget(std.testing.allocator, "for(const x of arr){if(x>1)break;}", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "break") != null);
}

// --- spread edge cases ---

test "ES2015: spread in new with apply" {
    var r = try e2eTarget(std.testing.allocator, "new Foo(...args);", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "apply") != null or std.mem.indexOf(u8, r.output, "concat") != null);
}

test "ES2015: spread multiple arrays" {
    var r = try e2eTarget(std.testing.allocator, "var x=[...a,...b,...c];", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "concat") != null);
}

// --- template literal edge cases ---

test "ES2015: template with expression" {
    var r = try e2eTarget(std.testing.allocator, "var s=`${a+b} = ${c}`;", .es5);
    defer r.deinit();
    // 백틱 → 문자열 연결
    try std.testing.expect(std.mem.indexOf(u8, r.output, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\" = \"") != null or std.mem.indexOf(u8, r.output, "' = '") != null);
}

test "ES2015: template nested" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a${`b${c}`}d`;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "+") != null);
}

test "ES2015: template with actual newline" {
    var r = try e2eTarget(std.testing.allocator, "var s=`hello\nworld`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"hello\\nworld\";", r.output);
}

test "ES2015: template with newline and substitution" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a\n${b}\nc`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\n\" + b + \"\\nc\";", r.output);
}

test "ES2015: template with carriage return" {
    var r = try e2eTarget(std.testing.allocator, "var s=`a\r\nb`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\r\\nb\";", r.output);
}

test "ES2015: template with U+2028 line separator" {
    // U+2028 (UTF-8: 0xE2 0x80 0xA8) — 템플릿에서는 유효, ES5 문자열에서는 줄바꿈 취급
    var r = try e2eTarget(std.testing.allocator, "var s=`a\xe2\x80\xa8b`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\u2028b\";", r.output);
}

test "ES2015: template with U+2029 paragraph separator" {
    // U+2029 (UTF-8: 0xE2 0x80 0xA9)
    var r = try e2eTarget(std.testing.allocator, "var s=`a\xe2\x80\xa9b`;", .es5);
    defer r.deinit();
    try std.testing.expectEqualStrings("var s=\"a\\u2029b\";", r.output);
}

// --- combined features ---

test "ES2015: class with generator method" {
    var r = try e2eTarget(std.testing.allocator, "class F{*gen(){yield 1;}}", .es5);
    defer r.deinit();
    // class → function + prototype
    try std.testing.expect(std.mem.indexOf(u8, r.output, "prototype") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "gen") != null);
}

test "ES2015: destructuring with spread and default" {
    var r = try e2eTarget(std.testing.allocator, "var {a=1,...rest}=obj;", .es5);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__rest") != null or std.mem.indexOf(u8, r.output, "hasOwnProperty") != null);
}

test "ES2015: multiple let in for-of" {
    var r = try e2eTarget(std.testing.allocator, "for(const [a,b] of items){let sum=a+b;f(sum);}", .es5);
    defer r.deinit();
    // const/let → var, for-of → index loop, destructuring → temp
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var") != null);
}

// --- ES2020 edge cases ---

test "ES2020: ?? nested" {
    var r = try e2eTarget(std.testing.allocator, "const x = a ?? b ?? c;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "ES2020: ?. deep chain" {
    var r = try e2eTarget(std.testing.allocator, "a?.b?.c?.d;", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

test "ES2020: ?. with method call" {
    var r = try e2eTarget(std.testing.allocator, "obj?.method(1,2);", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

test "ES2020: ?? with ?. combined" {
    var r = try e2eTarget(std.testing.allocator, "const x = a?.b ?? 'default';", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "==null?void 0") != null);
}

// --- ES2021 edge cases ---

test "ES2021: ??= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ??= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

test "ES2021: ||= with member expression" {
    var r = try e2eTarget(std.testing.allocator, "obj.x ||= 5;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "obj.x") != null);
}

// --- ES2022 edge cases ---

test "ES2022: static block with side effects" {
    var r = try e2eTarget(std.testing.allocator, "class F{static count=0;static{F.count++;}}", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.count++") != null or std.mem.indexOf(u8, r.output, "F.count+=1") != null);
}

// --- temp var hoisting ---

test "ES2020: temp var hoisted for ?? in function" {
    var r = try e2eTarget(std.testing.allocator, "function f(){return foo()??bar;}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_a=foo()") != null);
}

test "ES2020: temp var hoisted for ?. in function" {
    var r = try e2eTarget(std.testing.allocator, "function f(){return foo()?.bar;}", .es2019);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _a") != null);
}

// --- ES2021 ---

test "ES2021: &&= logical assignment" {
    var r = try e2eTarget(std.testing.allocator, "let a=1;a&&=10;", .es2020);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "a&&(a=10)") != null);
}

// --- ES2022 → es2021 ---

test "ES2022: static block to IIFE (target=es2021)" {
    var r = try e2eTarget(std.testing.allocator, "class F{static{F.v=1;}}", .es2021);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "F.v=1") != null);
}

// --- useDefineForClassFields=false ---

test "useDefineForClassFields=false: instance to constructor" {
    var r = try e2eFull(std.testing.allocator, "class Foo{x=1;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
    // x=1 은 class body에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo{x=1") == null);
}

test "useDefineForClassFields=false: static field outside class" {
    var r = try e2eFull(std.testing.allocator, "class Foo{static z=2;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.z=2") != null);
    // static z=2 는 class body에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "static") == null);
}

test "useDefineForClassFields=false: multiple static assignments ordered" {
    var r = try e2eFull(std.testing.allocator, "class Foo{static a=1;static b=2;}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.a=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Foo.b=2") != null);
    // a가 b보다 먼저
    const a_pos = std.mem.indexOf(u8, r.output, "Foo.a=1").?;
    const b_pos = std.mem.indexOf(u8, r.output, "Foo.b=2").?;
    try std.testing.expect(a_pos < b_pos);
}

test "useDefineForClassFields=false: method preserved" {
    var r = try e2eFull(std.testing.allocator, "class Foo{x=1;method(){return this.x;}}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "method()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.x=1") != null);
}

test "useDefineForClassFields=false: no-init fields removed" {
    var r = try e2eFull(std.testing.allocator, "class Foo{y;static w;method(){}}", .{ .use_define_for_class_fields = false }, .{ .minify_whitespace = true }, ".ts");
    defer r.deinit();
    // y, w 모두 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "method") != null);
    // class body에 y, w가 없어야 함 (method만 있음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, ";y") == null);
}

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

// ================================================================
// Flow Type Stripping Tests
// ================================================================

/// Flow e2e: Flow 모드로 파싱+변환 (script 모드).
fn e2eFlow(backing_allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFlowImpl(backing_allocator, source, false);
}

/// Flow e2e: Flow 모드로 파싱+변환 (module 모드 — export/import 포함 소스용).
fn e2eFlowModule(backing_allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFlowImpl(backing_allocator, source, true);
}

fn e2eFlowImpl(backing_allocator: std.mem.Allocator, source: []const u8, is_module: bool) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    parser.is_flow = true;
    if (is_module) {
        parser.is_module = true;
        scanner.is_module = true;
    }
    _ = try parser.parse();

    var t = Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.new_ast, .{ .minify_whitespace = true });
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

test "Flow: basic type annotation stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: string = 'hello';");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=\"hello\";", r.output);
}

test "Flow: number type annotation stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: number = 42;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=42;", r.output);
}

test "Flow: nullable type ?string stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: ?string = null;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=null;", r.output);
}

test "Flow: mixed type stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: mixed = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: empty type stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: empty = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: generic type Array<number> stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: Array<number> = [];");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=[];", r.output);
}

test "Flow: function param and return type stripped" {
    var r = try e2eFlow(std.testing.allocator, "function f(x: number): string { return ''; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){return \"\";}", r.output);
}

test "Flow: type alias declaration stripped" {
    var r = try e2eFlow(std.testing.allocator, "type ID = string;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: nullable with union ?string | number stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: ?string | number = null;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=null;", r.output);
}

test "Flow: union type A | B stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: string | number = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: intersection type A & B stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: A & B = {};");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x={};", r.output);
}

test "Flow: boolean (bool alias) stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: bool = true;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=true;", r.output);
}

test "Flow: array type T[] stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: number[] = [];");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=[];", r.output);
}

test "Flow: type alias with generic stripped" {
    var r = try e2eFlow(std.testing.allocator, "type List<T> = Array<T>;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: opaque type stripped" {
    var r = try e2eFlow(std.testing.allocator, "opaque type ID = string;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: opaque type with supertype stripped" {
    var r = try e2eFlow(std.testing.allocator, "opaque type ID: string = string;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: opaque type with generic stripped" {
    var r = try e2eFlow(std.testing.allocator, "opaque type Box<T>: T = T;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: object type with variance stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: { +name: string, -age: number } = {};");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x={};", r.output);
}

test "Flow: nested object type stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: { a: { b: number } } = {};");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x={};", r.output);
}

test "Flow: covariant type parameter stripped" {
    var r = try e2eFlow(std.testing.allocator, "type ReadOnly<+T> = T;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: export opaque type stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "export opaque type ID: string = string;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: import type stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "import type { Foo } from 'bar';\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: import typeof default stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "import typeof Foo from 'bar';\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: import typeof namespace stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "import typeof * as ns from 'bar';\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: export type re-export stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "export type { Foo } from 'bar';\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: import typeof named stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "import typeof { Foo, Bar } from 'bar';\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare function stripped" {
    var r = try e2eFlow(std.testing.allocator, "declare function foo(x: number): string;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare var stripped" {
    var r = try e2eFlow(std.testing.allocator, "declare var x: number;\nlet y = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let y=1;", r.output);
}

test "Flow: declare class stripped" {
    var r = try e2eFlow(std.testing.allocator, "declare class Foo { bar(): void; }\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare module.exports stripped" {
    var r = try e2eFlow(std.testing.allocator, "declare module.exports: typeof EventEmitter;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: interface declaration stripped" {
    var r = try e2eFlow(std.testing.allocator, "interface Foo { x: number; y: string; }\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: interface extends stripped" {
    var r = try e2eFlow(std.testing.allocator, "interface Foo extends Bar, Baz { x: number; }\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export type stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "declare export type ID = string;\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: as type cast stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x = {} as Foo;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x={};", r.output);
}

test "Flow: chained as cast stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x = y as Foo as Bar;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=y;", r.output);
}

test "Flow: parenthesized as cast stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x = (y as Foo);");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=y;", r.output);
}

// ================================================================
// Flow Comment Types (/*:: */ and /*: */)
// ================================================================

test "Flow: block comment type /*:: type */ stripped" {
    var r = try e2eFlow(std.testing.allocator, "/*:: type ID = string; */\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: inline comment type /*: Type */ stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x /*: number */ = 42;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=42;", r.output);
}

test "Flow: block comment import type stripped" {
    var r = try e2eFlowModule(std.testing.allocator, "/*:: import type {Foo} from 'bar'; */\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: non-flow file ignores flow comments" {
    // @flow pragma 없으면 /*:: */는 일반 주석으로 처리
    var r = try e2e(std.testing.allocator, "/*:: type ID = string; */\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: empty block comment /*::*/ is harmless" {
    var r = try e2eFlow(std.testing.allocator, "/*::*/\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: multiply inside flow comment" {
    var r = try e2eFlow(std.testing.allocator, "/*:: type X = 2; */\nlet y = 3 * 4;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let y=3*4;", r.output);
}

test "Flow: consecutive flow comments" {
    var r = try e2eFlow(std.testing.allocator, "/*:: type A = string; */ /*:: type B = number; */\nlet x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

// ================================================================
// Flow TypeCast, Exact Object, %checks
// ================================================================

test "Flow: TypeCast (expr: Type) stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x = (null: any);");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=null;", r.output);
}

test "Flow: TypeCast object (expr: Type) stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x = (obj: Foo);");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=obj;", r.output);
}

test "Flow: exact object type {| |} stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: {| name: string |} = {};");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x={};", r.output);
}

test "Flow: empty exact object type {||} stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: {||} = {};");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x={};", r.output);
}

test "Flow: %checks predicate stripped" {
    var r = try e2eFlow(std.testing.allocator, "function f(x: mixed): boolean %checks { return true; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function f(x){return true;}", r.output);
}

// ================================================================
// Flow Metro Smoke Test — Metro RN 실제 패턴 통합 테스트
// ================================================================

test "Flow: Metro smoke — full module with all Flow features" {
    // Metro 실제 코드에서 추출한 대표 패턴 조합
    const source =
        \\import type {ConfigT, InputConfigT} from './types';
        \\import typeof * as TransformerType from '../index';
        \\import getDefaultConfig from './defaults';
        \\
        \\type ID = string;
        \\opaque type RevisionId: string = string;
        \\
        \\interface SnippetError extends Error {
        \\  code: string;
        \\  filename: string;
        \\}
        \\
        \\declare function add(a: number, b: number): number;
        \\declare var __DEV__: boolean;
        \\declare class EventEmitter {
        \\  on(event: string): void;
        \\}
        \\
        \\function greet(name: string, age: ?number): string {
        \\  const greeting: string = "Hello";
        \\  const result = ({}: any) as ConfigT;
        \\  const items: Array<number> = [1, 2, 3];
        \\  const map: Map<string, number> = new Map();
        \\  return greeting;
        \\}
        \\
        \\export type {ConfigT};
        \\export default greet;
    ;
    var r = try e2eFlowModule(std.testing.allocator, source);
    defer r.deinit();
    // 모든 타입 어노테이션, type/opaque/interface/declare가 제거되고
    // import type/typeof도 제거됨. 런타임 코드만 남아야 함.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import type") == null); // type imports 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import typeof") == null); // typeof imports 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "getDefaultConfig") != null); // 값 import 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function greet") != null); // 함수 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "string") == null); // 타입 모두 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "interface") == null); // interface 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "declare") == null); // declare 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "export default greet") != null); // default export 유지
}

// ============================================================
// 엔진 타겟 통합 테스트
// ============================================================

const compat = TransformOptions.compat;

fn e2eEngine(allocator: std.mem.Allocator, source: []const u8, targets: []const compat.EngineVersion) !TestResult {
    return e2eFull(allocator, source, .{ .unsupported = compat.unsupportedFeatures(targets) }, .{ .minify_whitespace = true }, ".ts");
}

// --- 엔진 타겟: arrow function ---

test "engine target: chrome48 → arrow 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const f = () => 1;", &.{.{ .engine = .chrome, .major = 48 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function") != null);
}

test "engine target: chrome49 → arrow 유지" {
    var r = try e2eEngine(std.testing.allocator, "const f = () => 1;", &.{.{ .engine = .chrome, .major = 49 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=>") != null);
}

// --- 엔진 타겟: nullish coalescing ---

test "engine target: chrome79 → ?? 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{.{ .engine = .chrome, .major = 79 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "engine target: chrome80 → ?? 유지" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{.{ .engine = .chrome, .major = 80 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "??") != null);
}

// --- 엔진 타겟: optional chaining ---

test "engine target: chrome90 → ?. 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const x = a?.b;", &.{.{ .engine = .chrome, .major = 90 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "engine target: chrome91 → ?. 유지" {
    var r = try e2eEngine(std.testing.allocator, "const x = a?.b;", &.{.{ .engine = .chrome, .major = 91 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "?.") != null);
}

// --- 엔진 타겟: async/await ---

test "engine target: chrome54 → async 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "async function foo() { await x; }", &.{.{ .engine = .chrome, .major = 54 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") != null);
}

test "engine target: chrome55 → async 유지" {
    var r = try e2eEngine(std.testing.allocator, "async function foo() { await x; }", &.{.{ .engine = .chrome, .major = 55 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") == null);
}

// --- 엔진 타겟: 복합 타겟 교집합 ---

test "engine target: chrome91+safari13 → safari가 ?? 미지원이므로 다운레벨링" {
    // chrome91: ?? 지원 (80), safari13.0: ?? 미지원 (13.1부터)
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{
        .{ .engine = .chrome, .major = 91 },
        .{ .engine = .safari, .major = 13, .minor = 0 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "engine target: chrome91+safari13.1 → 둘 다 ?? 지원, 유지" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{
        .{ .engine = .chrome, .major = 91 },
        .{ .engine = .safari, .major = 13, .minor = 1 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "??") != null);
}

// --- 엔진 타겟: feature 독립성 (한 feature만 다운레벨링, 나머지 유지) ---

test "engine target: chrome80 → ??는 유지하지만 ?.는 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b; const y = c?.d;", &.{
        .{ .engine = .chrome, .major = 80 },
    });
    defer r.deinit();
    // ?? (chrome80 지원) → 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "??") != null);
    // ?. (chrome91 미만) → 다운레벨링
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

// --- 엔진 타겟: safari minor 버전 정밀도 ---

test "engine target: safari11.0 → object spread 미지원 (11.1부터)" {
    var r = try e2eEngine(std.testing.allocator, "const x = { ...obj };", &.{
        .{ .engine = .safari, .major = 11, .minor = 0 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") != null);
}

test "engine target: safari11.1 → object spread 지원" {
    var r = try e2eEngine(std.testing.allocator, "const x = { ...obj };", &.{
        .{ .engine = .safari, .major = 11, .minor = 1 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...") != null);
}

// ============================================================
// JSX Runtime 모드 테스트
// ============================================================

fn e2eJSXAutomatic(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{}, .{
        .jsx_runtime = .automatic,
        .jsx_import_source = "react",
    }, ".tsx");
}

fn e2eJSXDev(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eFull(allocator, source, .{}, .{
        .jsx_runtime = .automatic_dev,
        .jsx_import_source = "react",
        .jsx_filename = "test.tsx",
    }, ".tsx");
}

test "JSX automatic: simple element" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div id=\"app\">hello</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "id: \"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { jsx as _jsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"react/jsx-runtime\"") != null);
}

test "JSX automatic: multiple children uses jsxs" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div><span>a</span><span>b</span></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { jsx as _jsx, jsxs as _jsxs") != null);
}

test "JSX automatic: fragment" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <><span>a</span><span>b</span></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(_Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Fragment as _Fragment") != null);
}

test "JSX automatic: key is separated from props" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <App key=\"k\" name=\"zts\" />;");
    defer r.deinit();
    // key는 3번째 인수로 분리
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{ name: \"zts\" }, \"k\"") != null);
    // key는 props에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "key:") == null);
}

test "JSX automatic: self-closing no children" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <br />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"br\", {})") != null);
}

test "JSX automatic: custom import source" {
    var r = try e2eFull(std.testing.allocator, "const x = <div />;", .{}, .{
        .jsx_runtime = .automatic,
        .jsx_import_source = "preact",
    }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"preact/jsx-runtime\"") != null);
}

test "JSX dev: source info included" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div>hello</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName: \"test.tsx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "lineNumber: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "columnNumber: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"react/jsx-dev-runtime\"") != null);
}

test "JSX dev: isStaticChildren true for multiple children" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div><a/><b/></div>;");
    defer r.deinit();
    // 다수 children → isStaticChildren = true
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", true, {") != null);
}

test "JSX dev: isStaticChildren false for single child" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div><a/></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", false, {") != null);
}

test "JSX classic: custom factory" {
    var r = try e2eFull(std.testing.allocator, "const x = <div />;", .{}, .{
        .minify_whitespace = true,
        .jsx_factory = "h",
        .jsx_fragment = "Fragment",
    }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "h(\"div\"") != null);
    // React.createElement가 아닌 h 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement") == null);
}

test "JSX classic: custom fragment factory" {
    var r = try e2eFull(std.testing.allocator, "const x = <>hello</>;", .{}, .{
        .minify_whitespace = true,
        .jsx_factory = "h",
        .jsx_fragment = "Fragment",
    }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "h(Fragment,") != null);
}

// --- automatic 모드: 누락 케이스 ---

test "JSX automatic: spread attribute" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div {...props} id=\"a\" />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "id: \"a\"") != null);
}

test "JSX automatic: nested elements" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div><span><b>deep</b></span></div>;");
    defer r.deinit();
    // 바깥: 단일 child → _jsx, 안쪽도 단일 → _jsx
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"deep\"") != null);
}

test "JSX automatic: expression child" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div>{value}</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: value") != null);
}

test "JSX automatic: text and element mixed children" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <p>hello <b>world</b></p>;");
    defer r.deinit();
    // 다수 children → _jsxs + children 배열
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(\"p\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"hello \"") != null);
}

test "JSX automatic: component (uppercase tag)" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <MyComponent title=\"t\">child</MyComponent>;");
    defer r.deinit();
    // 대문자 태그는 문자열이 아닌 식별자로 출력
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(MyComponent") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"MyComponent\"") == null);
}

test "JSX automatic: empty fragment" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(_Fragment, {})") != null);
}

test "JSX automatic: classic mode does NOT inject import" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import {") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement") != null);
}

test "JSX automatic: no JSX usage means no import" {
    // JSX가 없는 파일에서는 import 미주입
    var r = try e2eFull(std.testing.allocator, "const x = 42;", .{}, .{
        .jsx_runtime = .automatic,
        .jsx_import_source = "react",
    }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import {") == null);
}

// --- dev 모드: 누락 케이스 ---

test "JSX dev: key in dev mode" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <Item key=\"k\" id=\"1\" />;");
    defer r.deinit();
    // key는 3번째 인수, props에서 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{ id: \"1\" }, \"k\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "key:") == null);
}

test "JSX dev: fragment with children" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <><a/><b/></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(_Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", true, {") != null);
}

test "JSX dev: empty element has correct source info" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <br />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(\"br\", {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName: \"test.tsx\"") != null);
}

test "JSX dev: custom import source" {
    var r = try e2eFull(std.testing.allocator, "const x = <div />;", .{}, .{
        .jsx_runtime = .automatic_dev,
        .jsx_import_source = "preact",
        .jsx_filename = "app.tsx",
    }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"preact/jsx-dev-runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName: \"app.tsx\"") != null);
}

// --- classic 모드: 누락 케이스 ---

test "JSX classic: spread attribute preserved" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div {...props} />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement") != null);
}

test "JSX classic: expression child" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>{val}</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement(\"div\",null,val)") != null);
}

test "JSX classic: component uppercase" {
    var r = try e2eJSX(std.testing.allocator, "const x = <App name=\"z\" />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement(App,{name:\"z\"})") != null);
    // App은 문자열이 아닌 식별자
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"App\"") == null);
}

// ============================================================
// None-node safety: transformer/codegen must not crash on .none NodeIndex
// These tests ensure Flow type stripping produces valid AST without
// index-out-of-bounds panics (previously crashed with index 4294967295).
// ============================================================

test "Flow: import typeof does not crash" {
    // import typeof * as Foo from './bar' — Flow type-only import, should be stripped
    var r = try e2eFlowModule(std.testing.allocator,
        \\import typeof * as Foo from './bar';
        \\console.log("hello");
    );
    defer r.deinit();
    // import typeof should be removed, only console.log remains
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log") != null);
}

test "Flow: import typeof named does not crash" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\import typeof { Foo, Bar } from './baz';
        \\export const x = 1;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=1") != null);
}

test "Flow: type alias with object type does not crash codegen" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\type Props = { name: string, age: number };
        \\const x = 42;
    );
    defer r.deinit();
    // Flow type alias should be stripped
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Props") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "42") != null);
}

test "Flow: mixed import type and value import does not crash" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\import typeof * as API from './api';
        \\import { useState } from 'react';
        \\const x = useState(0);
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "useState") != null);
}

test "Flow: class with typed methods does not crash transformer" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\class Foo {
        \\  bar(x: string): number { return 1; }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "bar") != null);
}

// ============================================================
// Private Method (#method → WeakSet + standalone function)
// ============================================================

test "private method: es2021 → WeakSet + standalone function (class preserved)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  method() { return this.#bar(); }
        \\}
    , .es2021);
    defer r.deinit();
    // WeakSet 선언
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _bar=new WeakSet") != null);
    // standalone function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _bar_fn()") != null);
    // class 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo") != null);
    // brand check init
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_bar)") != null);
    // brand check get + .call
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet(this,_bar,_bar_fn).call(this)") != null);
}

test "private method: es5 → WeakSet + function + prototype" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  method() { return this.#bar(); }
        \\}
    , .es5);
    defer r.deinit();
    // class → function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _Foo()") != null);
    // WeakSet
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _bar=new WeakSet") != null);
    // prototype method
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_Foo.prototype.method=function()") != null);
    // brand check
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_bar)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet(this,_bar,_bar_fn).call(this)") != null);
}

test "private method: multiple methods" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  #baz(x: number) { return x + 1; }
        \\  method() { return this.#bar() + this.#baz(2); }
        \\}
    , .es2021);
    defer r.deinit();
    // 두 WeakSet
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _bar=new WeakSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "var _baz=new WeakSet") != null);
    // 두 standalone function
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _bar_fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function _baz_fn(x)") != null);
    // 호출부에 인자 전달
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodGet(this,_baz,_baz_fn).call(this,2)") != null);
}

test "private method: with existing constructor (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Greeter {
        \\  name: string;
        \\  constructor(name: string) { this.name = name; }
        \\  #format() { return "Hello, " + this.name; }
        \\  greet() { return this.#format(); }
        \\}
    , .es2021);
    defer r.deinit();
    // constructor에 init 주입
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_format)") != null);
    // 기존 constructor body 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.name=name") != null);
}

test "private method: with extends generates super() (es2021)" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Base { value = 10; }
        \\class Child extends Base {
        \\  #helper() { return this.value; }
        \\  run() { return this.#helper(); }
        \\}
    , .es2021);
    defer r.deinit();
    // extends가 있고 constructor가 없을 때 super(...args) 포함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "super(...args)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__classPrivateMethodInit(this,_helper)") != null);
}

test "private method: es2022 target preserves original" {
    var r = try e2eTarget(std.testing.allocator,
        \\class Foo {
        \\  #bar() { return 1; }
        \\  method() { return this.#bar(); }
        \\}
    , .es2022);
    defer r.deinit();
    // 원본 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#bar()") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "this.#bar()") != null);
    // WeakSet 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "WeakSet") == null);
}
