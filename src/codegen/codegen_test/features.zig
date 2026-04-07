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
    try std.testing.expectEqualStrings("const x=React.createElement(\"div\",null);", r.output);
}

test "Codegen: JSX element with children" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>hello</div>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=React.createElement(\"div\",null,\"hello\");", r.output);
}

test "Codegen: JSX fragment" {
    var r = try e2eJSX(std.testing.allocator, "const x = <>hello</>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=React.createElement(React.Fragment,null,\"hello\");", r.output);
}

// --- JSX: closing tag 뒤 텍스트 (children 모드 복원) ---

test "JSX: text after closing child element" {
    var r = try e2eJSX(std.testing.allocator, "const x = <p><code>x</code> text</p>;");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const x=React.createElement(\"p\",null,React.createElement(\"code\",null,\"x\"),\" text\");",
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
