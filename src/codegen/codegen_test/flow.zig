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
    try std.testing.expectEqualStrings("function f(x){return\"\";}", r.output);
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

test "Flow: tuple type [T, U] stripped" {
    var r = try e2eFlow(std.testing.allocator, "let x: [number, string] = [1, 'a'];");
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=[1,\"a\"];", r.output);
}

test "Flow: labeled tuple element stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type Pair = [first: number, second: string];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: optional labeled tuple element stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T = [name?: string, count: number];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: labeled tuple with generic ReadonlyArray (metro Server.js regression)" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T = ReadonlyArray<[pathnamePrefix: string, normalizedRootDir: string]>;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: variance +/- labeled tuple stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T = [+a: number, -b: string];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: variance readonly/writeonly labeled tuple stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T = [readonly a: number, writeonly b: string];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: rest tuple element stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T = [number, ...Array<string>];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: rest tuple element with label stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T = [first: number, ...rest: Array<string>];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: readonly used as plain type identifier (not variance)" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type Readonly = string;\ntype T = [readonly, number];\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

// ================================================================
// Conditional + infer (Hermes parity)
// ================================================================

test "Flow: simple conditional type stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T<X> = X extends string ? 1 : 0;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: conditional with infer T stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type Unwrap<X> = X extends Array<infer U> ? U : X;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: conditional with infer T extends Bound stripped" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type S<X> = X extends infer Y extends string ? Y : never;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: nested conditional (true branch)" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T<X> = X extends string ? (X extends 'a' ? 1 : 2) : 3;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: nested conditional (false branch)" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T<X> = X extends string ? 1 : X extends number ? 2 : 3;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: parenthesized conditional inside extends type" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T<X> = X extends (Y extends Z ? A : B) ? 1 : 0;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: infer in array element position" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type First<X> = X extends [infer H, ...infer T] ? H : never;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: infer with constrained Bound inside parens" {
    var r = try e2eFlow(
        std.testing.allocator,
        "type T<X> = X extends (infer Y extends number) ? Y : 0;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

// ================================================================
// declare export dispatch (Hermes parseDeclareExportFlow parity)
// 모듈 컨텍스트에서만 valid 하므로 e2eFlowModule 사용.
// ================================================================

test "Flow: declare export opaque type stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export opaque type ID: string;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export class stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export class Foo<T> { bar(x: T): void; }\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export function stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export function f(x: number): string;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export var stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export var foo: number;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export interface stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export interface IFoo { bar: string; }\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export default class stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export default class Foo { bar(): void; }\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export default function stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export default function f(): string;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export default type expression stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export default Array<string>;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export named re-export stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export { Foo, Bar };\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export named re-export with from stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export { Foo } from \"./bar\";\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export star from stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export * from \"./bar\";\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export component stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export component Foo(name: string);\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export hook stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export hook useFoo(name: string): number;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: mixed declare export sequence stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        \\declare export type A = string;
        \\declare export class B { f(): void; }
        \\declare export function c(): A;
        \\declare export default A;
        \\let x = 1;
        ,
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export enum stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export enum Color { Red, Green, Blue }\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export let stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export let foo: number;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export const stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export const foo: number;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export default async function stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export default async function f(): Promise<string>;\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export type star from stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export type * from \"./bar\";\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
}

test "Flow: declare export type named re-export from stripped" {
    var r = try e2eFlowModule(
        std.testing.allocator,
        "declare export type { Foo } from \"./bar\";\nlet x = 1;",
    );
    defer r.deinit();
    try std.testing.expectEqualStrings("let x=1;", r.output);
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

// ===== Flow enum (#2401) — codegen e2e =====
// `babel-plugin-transform-flow-enums` 동작 동등: `flow-enums-runtime` package
// 의 callable / Mirrored helper 사용 — 결과 object 가 cast / members / getName
// 같은 helper API 보유 (RN core 의 `X.cast(value)` 호출 호환).

test "Flow enum: default (symbol) → flow-enums-runtime callable with Symbol values" {
    var r = try e2eFlow(std.testing.allocator,
        \\enum Status { Active, Inactive }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const Status=require(\"flow-enums-runtime\")({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Active:Symbol(\"Active\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Inactive:Symbol(\"Inactive\")") != null);
}

test "Flow enum: of string + all defaulted → Mirrored" {
    var r = try e2eFlow(std.testing.allocator,
        \\enum Color of string { Red, Blue }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const Color=require(\"flow-enums-runtime\").Mirrored([\"Red\",\"Blue\"]);") != null);
}

test "Flow enum: of string with explicit init → callable with string values" {
    var r = try e2eFlow(std.testing.allocator,
        \\enum Color of string { Red = 'red', Blue = 'blue' }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const Color=require(\"flow-enums-runtime\")({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Red:\"red\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Blue:\"blue\"") != null);
}

test "Flow enum: of number → callable with number values" {
    var r = try e2eFlow(std.testing.allocator,
        \\enum Level of number { Low = 1, High = 10 }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const Level=require(\"flow-enums-runtime\")({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Low:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "High:10") != null);
}

test "Flow enum: of boolean → callable" {
    var r = try e2eFlow(std.testing.allocator,
        \\enum Toggle of boolean { On = true, Off = false }
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const Toggle=require(\"flow-enums-runtime\")({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "On:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Off:false") != null);
}

test "Flow enum: usage — member access / cast helper 호출 정합" {
    // `flow-enums-runtime` callable 결과는 RN core 의 `X.cast(value)` 호출 호환.
    // 본 테스트는 codegen 단계만 — 실제 cast 호출 동작은 flow-enums-runtime 의 책임.
    var r = try e2eFlow(std.testing.allocator,
        \\enum Color of string { Red = 'red' }
        \\const x = Color.Red;
        \\const y = Color.cast('red');
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const x=Color.Red") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const y=Color.cast(\"red\")") != null);
}

// ================================================================
// Match expression — 정밀 lowering 동작 검증 (substring)
// ================================================================

test "Flow match: literal + wildcard → if (_m===lit) / catch-all" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { 1 => "a", _ => "b" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return\"b\"") != null);
}

test "Flow match: OR pattern → t1 || t2" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { 1 | 2 | 3 => "x", _ => "y" };
    );
    defer r.deinit();
    // 1|2|3 이 bitwise 가 아니라 === OR 체인으로 lower 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===1||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===2||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===3") != null);
}

test "Flow match: binding pattern → let x = _m" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { const x => x };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return x") != null);
}

test "Flow match: guard → binding 후 if (cond)" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { const n if (n > 10) => n, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let n=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "n>10") != null);
}

test "Flow match: as pattern → 추가 binding" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { 1 as one => one, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let one=") != null);
}

test "Flow match: member pattern → _m === Member" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { Status.Active => 1, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===Status.Active") != null);
}

test "Flow match: null/true literal pattern → _m === lit" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { null => "n", true => "t", _ => "w" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===true") != null);
}

test "Flow match: negative unary in OR (-1 | -2) keeps | as separator" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { -1 | -2 => "neg", _ => "o" };
    );
    defer r.deinit();
    // `-1 | -2` 가 bitwise 가 아니라 `_m===-1 || _m===-2` 로 lower.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=== -1||") != null or
        std.mem.indexOf(u8, r.output, "===-1||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "-2") != null);
}

test "Flow match: as-binding wrapping OR ((1|2) as x)" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { (1 | 2) as x => x, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===1||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let x=") != null);
}

test "Flow match: nested OR in parens ((1|2)|3)" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { (1 | 2) | 3 => "x", _ => "y" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===1||") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "===3") != null);
}

test "Flow match: object pattern → typeof guard + key in + value" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { {a: 1} => "o", _ => "w" };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "typeof") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"a\" in") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[\"a\"]===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "return\"o\"") != null);
}

test "Flow match: object shorthand binding → let from member" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { {const x} => x, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"x\" in") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let x=") != null);
}

test "Flow match: object rest → Object.assign + delete" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { {a: 1, ...const rest} => rest, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "delete ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let rest=") != null);
}

test "Flow match: array pattern → Array.isArray + length + index" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { [1, const x] => x, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Array.isArray(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".length===2") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "[0]===1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let x=") != null);
}

test "Flow match: array rest → length >= N + slice" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { [1, ...const t] => t, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".length>=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".slice(1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let t=") != null);
}

test "Flow match: instance pattern → S instanceof Ctor && body" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { Point {x: const px} => px, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "instanceof Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let px=") != null);
}

test "Flow match: nested object/array binding" {
    var r = try e2eFlow(std.testing.allocator,
        \\const r = match (v) { {pt: [const x, const y]} => x + y, _ => 0 };
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"pt\" in") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Array.isArray(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let x=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "let y=") != null);
}

test "Flow: bare this-param function type alias fully stripped" {
    var r = try e2eFlow(std.testing.allocator, "type Fn = (this: Foo, x: number) => void;");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Flow: this-param function type — with usage stripped" {
    var r = try e2eFlow(std.testing.allocator, "type Fn = (this: Foo, x: number) => void; let f: Fn = (function () {});");
    defer r.deinit();
    try std.testing.expectEqualStrings("let f=(function(){});", r.output);
}

test "Flow: this-param inline function type annotation stripped" {
    var r = try e2eFlow(std.testing.allocator, "let cb: (this: Window, e: number) => void = (function () {});");
    defer r.deinit();
    try std.testing.expectEqualStrings("let cb=(function(){});", r.output);
}
