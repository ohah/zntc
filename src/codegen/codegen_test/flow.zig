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
const e2eFlow = helpers.e2eFlow;
const e2eFlowModule = helpers.e2eFlowModule;

// Flow Type Stripping Tests
// ================================================================

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

test "Flow: covariant class property stripped (static + instance)" {
    // Flow의 +prop: Type 은 타입 전용 선언 — 런타임 코드에 남으면 안 됨.
    // static +INDEX: 1; → 완전히 제거 (static INDEX; 로 변환하면 안 됨)
    var r = try e2eFlow(std.testing.allocator, "class Foo{static +INDEX:1;+name:string;#real;constructor(){this.#real=1;}}");
    defer r.deinit();
    // covariant 프로퍼티는 제거, private field와 constructor는 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "INDEX") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "#real") != null);
}

test "Flow: contravariant class property stripped" {
    var r = try e2eFlow(std.testing.allocator, "class Foo{-writable:boolean;bar(){return 1;}}");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "writable") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "bar") != null);
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
