import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/templates", () => {
  test("taggedTemplateStringsPlainCharactersThatArePartsOfEscapes01_ES6", async () => {
    await expectPass(
      `// @target: es6

function f(...x: any[]) {

}

f \`0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 2028 2029 0085 t v f b r n\``,
      [],
    );
  });
  test("taggedTemplateStringsPlainCharactersThatArePartsOfEscapes01", async () => {
    await expectPass(
      `// @target: es2015


function f(...x: any[]) {

}

f \`0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 2028 2029 0085 t v f b r n\``,
      [],
    );
  });
  test("taggedTemplateStringsPlainCharactersThatArePartsOfEscapes02_ES6", async () => {
    await expectPass(
      `// @target: es6

function f(...x: any[]) {

}

f \`0\${ " " }1\${ " " }2\${ " " }3\${ " " }4\${ " " }5\${ " " }6\${ " " }7\${ " " }8\${ " " }9\${ " " }10\${ " " }11\${ " " }12\${ " " }13\${ " " }14\${ " " }15\${ " " }16\${ " " }17\${ " " }18\${ " " }19\${ " " }20\${ " " }2028\${ " " }2029\${ " " }0085\${ " " }t\${ " " }v\${ " " }f\${ " " }b\${ " " }r\${ " " }n\``,
      [],
    );
  });
  test("taggedTemplateStringsPlainCharactersThatArePartsOfEscapes02", async () => {
    await expectPass(
      `// @target: es2015


\`0\${ " " }1\${ " " }2\${ " " }3\${ " " }4\${ " " }5\${ " " }6\${ " " }7\${ " " }8\${ " " }9\${ " " }10\${ " " }11\${ " " }12\${ " " }13\${ " " }14\${ " " }15\${ " " }16\${ " " }17\${ " " }18\${ " " }19\${ " " }20\${ " " }2028\${ " " }2029\${ " " }0085\${ " " }t\${ " " }v\${ " " }f\${ " " }b\${ " " }r\${ " " }n\``,
      [],
    );
  });
  test("taggedTemplateStringsTypeArgumentInference", async () => {
    await expectPass(
      `// @target: es2015


// Generic tag with one parameter
function noParams<T>(n: T) { }
noParams \`\`;

// Generic tag with parameter which does not use type parameter
function noGenericParams<T>(n: TemplateStringsArray) { }
noGenericParams \`\`;

// Generic tag with multiple type parameters and only one used in parameter type annotation
function someGenerics1a<T, U>(n: T, m: number) { }
someGenerics1a \`\${3}\`;

function someGenerics1b<T, U>(n: TemplateStringsArray, m: U) { }
someGenerics1b \`\${3}\`;

// Generic tag with argument of function type whose parameter is of type parameter type
function someGenerics2a<T>(strs: TemplateStringsArray, n: (x: T) => void) { }
someGenerics2a \`\${(n: string) => n}\`;

function someGenerics2b<T, U>(strs: TemplateStringsArray, n: (x: T, y: U) => void) { }
someGenerics2b \`\${ (n: string, x: number) => n }\`;

// Generic tag with argument of function type whose parameter is not of type parameter type but body/return type uses type parameter
function someGenerics3<T>(strs: TemplateStringsArray, producer: () => T) { }
someGenerics3 \`\${() => ''}\`;
someGenerics3 \`\${() => undefined}\`;
someGenerics3 \`\${() => 3}\`;

// 2 parameter generic tag with argument 1 of type parameter type and argument 2 of function type whose parameter is of type parameter type
function someGenerics4<T, U>(strs: TemplateStringsArray, n: T, f: (x: U) => void) { }
someGenerics4 \`\${4}\${ () => null }\`;
someGenerics4 \`\${''}\${ () => 3 }\`;
someGenerics4 \`\${ null }\${ null }\`;

// 2 parameter generic tag with argument 2 of type parameter type and argument 1 of function type whose parameter is of type parameter type
function someGenerics5<U, T>(strs: TemplateStringsArray, n: T, f: (x: U) => void) { }
someGenerics5 \`\${ 4 } \${ () => null }\`;
someGenerics5 \`\${ '' }\${ () => 3 }\`;
someGenerics5 \`\${null}\${null}\`;

// Generic tag with multiple arguments of function types that each have parameters of the same generic type
function someGenerics6<A>(strs: TemplateStringsArray, a: (a: A) => A, b: (b: A) => A, c: (c: A) => A) { }
someGenerics6 \`\${ n => n }\${ n => n}\${ n => n}\`;
someGenerics6 \`\${ n => n }\${ n => n}\${ n => n}\`;
someGenerics6 \`\${ (n: number) => n }\${ (n: number) => n }\${ (n: number) => n }\`;

// Generic tag with multiple arguments of function types that each have parameters of different generic type
function someGenerics7<A, B, C>(strs: TemplateStringsArray, a: (a: A) => A, b: (b: B) => B, c: (c: C) => C) { }
someGenerics7 \`\${ n => n }\${ n => n }\${ n => n }\`;
someGenerics7 \`\${ n => n }\${ n => n }\${ n => n }\`;
someGenerics7 \`\${(n: number) => n}\${ (n: string) => n}\${ (n: number) => n}\`;

// Generic tag with argument of generic function type
function someGenerics8<T>(strs: TemplateStringsArray, n: T): T { return n; }
var x = someGenerics8 \`\${ someGenerics7 }\`;
x \`\${null}\${null}\${null}\`;

// Generic tag with multiple parameters of generic type passed arguments with no best common type
function someGenerics9<T>(strs: TemplateStringsArray, a: T, b: T, c: T): T {
    return null;
}
var a9a = someGenerics9 \`\${ '' }\${ 0 }\${ [] }\`;
var a9a: {};

// Generic tag with multiple parameters of generic type passed arguments with multiple best common types
interface A91 {
    x: number;
    y?: string;
}
interface A92 {
    x: number;
    z?: Date;
}

var a9e = someGenerics9 \`\${ undefined }\${ { x: 6, z: new Date() } }\${ { x: 6, y: '' } }\`;
var a9e: {};

// Generic tag with multiple parameters of generic type passed arguments with a single best common type
var a9d = someGenerics9 \`\${ { x: 3 }}\${ { x: 6 }}\${ { x: 6 } }\`;
var a9d: { x: number; };

// Generic tag with multiple parameters of generic type where one argument is of type 'any'
var anyVar: any;
var a = someGenerics9 \`\${ 7 }\${ anyVar }\${ 4 }\`;
var a: any;

// Generic tag with multiple parameters of generic type where one argument is [] and the other is not 'any'
var arr = someGenerics9 \`\${ [] }\${ null }\${ undefined }\`;
var arr: any[];

`,
      [],
    );
  });
  test("taggedTemplateStringsTypeArgumentInferenceES6", async () => {
    await expectPass(
      `//@target: es6

// Generic tag with one parameter
function noParams<T>(n: T) { }
noParams \`\`;

// Generic tag with parameter which does not use type parameter
function noGenericParams<T>(n: TemplateStringsArray) { }
noGenericParams \`\`;

// Generic tag with multiple type parameters and only one used in parameter type annotation
function someGenerics1a<T, U>(n: T, m: number) { }
someGenerics1a \`\${3}\`;

function someGenerics1b<T, U>(n: TemplateStringsArray, m: U) { }
someGenerics1b \`\${3}\`;

// Generic tag with argument of function type whose parameter is of type parameter type
function someGenerics2a<T>(strs: TemplateStringsArray, n: (x: T) => void) { }
someGenerics2a \`\${(n: string) => n}\`;

function someGenerics2b<T, U>(strs: TemplateStringsArray, n: (x: T, y: U) => void) { }
someGenerics2b \`\${ (n: string, x: number) => n }\`;

// Generic tag with argument of function type whose parameter is not of type parameter type but body/return type uses type parameter
function someGenerics3<T>(strs: TemplateStringsArray, producer: () => T) { }
someGenerics3 \`\${() => ''}\`;
someGenerics3 \`\${() => undefined}\`;
someGenerics3 \`\${() => 3}\`;

// 2 parameter generic tag with argument 1 of type parameter type and argument 2 of function type whose parameter is of type parameter type
function someGenerics4<T, U>(strs: TemplateStringsArray, n: T, f: (x: U) => void) { }
someGenerics4 \`\${4}\${ () => null }\`;
someGenerics4 \`\${''}\${ () => 3 }\`;
someGenerics4 \`\${ null }\${ null }\`;

// 2 parameter generic tag with argument 2 of type parameter type and argument 1 of function type whose parameter is of type parameter type
function someGenerics5<U, T>(strs: TemplateStringsArray, n: T, f: (x: U) => void) { }
someGenerics5 \`\${ 4 } \${ () => null }\`;
someGenerics5 \`\${ '' }\${ () => 3 }\`;
someGenerics5 \`\${null}\${null}\`;

// Generic tag with multiple arguments of function types that each have parameters of the same generic type
function someGenerics6<A>(strs: TemplateStringsArray, a: (a: A) => A, b: (b: A) => A, c: (c: A) => A) { }
someGenerics6 \`\${ n => n }\${ n => n}\${ n => n}\`;
someGenerics6 \`\${ n => n }\${ n => n}\${ n => n}\`;
someGenerics6 \`\${ (n: number) => n }\${ (n: number) => n }\${ (n: number) => n }\`;

// Generic tag with multiple arguments of function types that each have parameters of different generic type
function someGenerics7<A, B, C>(strs: TemplateStringsArray, a: (a: A) => A, b: (b: B) => B, c: (c: C) => C) { }
someGenerics7 \`\${ n => n }\${ n => n }\${ n => n }\`;
someGenerics7 \`\${ n => n }\${ n => n }\${ n => n }\`;
someGenerics7 \`\${(n: number) => n}\${ (n: string) => n}\${ (n: number) => n}\`;

// Generic tag with argument of generic function type
function someGenerics8<T>(strs: TemplateStringsArray, n: T): T { return n; }
var x = someGenerics8 \`\${ someGenerics7 }\`;
x \`\${null}\${null}\${null}\`;

// Generic tag with multiple parameters of generic type passed arguments with no best common type
function someGenerics9<T>(strs: TemplateStringsArray, a: T, b: T, c: T): T {
    return null;
}
var a9a = someGenerics9 \`\${ '' }\${ 0 }\${ [] }\`;
var a9a: {};

// Generic tag with multiple parameters of generic type passed arguments with multiple best common types
interface A91 {
    x: number;
    y?: string;
}
interface A92 {
    x: number;
    z?: Date;
}

var a9e = someGenerics9 \`\${ undefined }\${ { x: 6, z: new Date() } }\${ { x: 6, y: '' } }\`;
var a9e: {};

// Generic tag with multiple parameters of generic type passed arguments with a single best common type
var a9d = someGenerics9 \`\${ { x: 3 }}\${ { x: 6 }}\${ { x: 6 } }\`;
var a9d: { x: number; };

// Generic tag with multiple parameters of generic type where one argument is of type 'any'
var anyVar: any;
var a = someGenerics9 \`\${ 7 }\${ anyVar }\${ 4 }\`;
var a: any;

// Generic tag with multiple parameters of generic type where one argument is [] and the other is not 'any'
var arr = someGenerics9 \`\${ [] }\${ null }\${ undefined }\`;
var arr: any[];

`,
      [],
    );
  });
  test("taggedTemplateStringsWithIncompatibleTypedTags", async () => {
    await expectPass(
      `// @target: es2015
interface I {
    (stringParts: TemplateStringsArray, ...rest: boolean[]): I;
    g: I;
    h: I;
    member: I;
    thisIsNotATag(x: string): void
    [x: number]: I;
}

declare var f: I;

f \`abc\`

f \`abc\${1}def\${2}ghi\`;

f \`abc\`.member

f \`abc\${1}def\${2}ghi\`.member;

f \`abc\`["member"];

f \`abc\${1}def\${2}ghi\`["member"];

f \`abc\`[0].member \`abc\${1}def\${2}ghi\`;

f \`abc\${1}def\${2}ghi\`["member"].member \`abc\${1}def\${2}ghi\`;

f \`abc\${ true }def\${ true }ghi\`["member"].member \`abc\${ 1 }def\${ 2 }ghi\`;

f.thisIsNotATag(\`abc\`);

f.thisIsNotATag(\`abc\${1}def\${2}ghi\`);
`,
      [],
    );
  });
  test("taggedTemplateStringsWithIncompatibleTypedTagsES6", async () => {
    await expectPass(
      `// @target: ES6
interface I {
    (stringParts: TemplateStringsArray, ...rest: boolean[]): I;
    g: I;
    h: I;
    member: I;
    thisIsNotATag(x: string): void
    [x: number]: I;
}

declare var f: I;

f \`abc\`

f \`abc\${1}def\${2}ghi\`;

f \`abc\`.member

f \`abc\${1}def\${2}ghi\`.member;

f \`abc\`["member"];

f \`abc\${1}def\${2}ghi\`["member"];

f \`abc\`[0].member \`abc\${1}def\${2}ghi\`;

f \`abc\${1}def\${2}ghi\`["member"].member \`abc\${1}def\${2}ghi\`;

f \`abc\${ true }def\${ true }ghi\`["member"].member \`abc\${ 1 }def\${ 2 }ghi\`;

f.thisIsNotATag(\`abc\`);

f.thisIsNotATag(\`abc\${1}def\${2}ghi\`);`,
      [],
    );
  });
  test("taggedTemplateStringsWithManyCallAndMemberExpressions", async () => {
    await expectPass(
      `// @target: es2015
interface I {
    (strs: TemplateStringsArray, ...subs: number[]): I;
    member: {
        new (s: string): {
            new (n: number): {
                new (): boolean;
            }
        }
    };
}
var f: I;

var x = new new new f \`abc\${ 0 }def\`.member("hello")(42) === true;

`,
      [],
    );
  });
  test("taggedTemplateStringsWithManyCallAndMemberExpressionsES6", async () => {
    await expectPass(
      `// @target: ES6
interface I {
    (strs: TemplateStringsArray, ...subs: number[]): I;
    member: {
        new (s: string): {
            new (n: number): {
                new (): boolean;
            }
        }
    };
}
var f: I;

var x = new new new f \`abc\${ 0 }def\`.member("hello")(42) === true;

`,
      [],
    );
  });
  test("taggedTemplateStringsWithOverloadResolution1_ES6", async () => {
    await expectPass(
      `//@target: es6
function foo(strs: TemplateStringsArray): number;
function foo(strs: TemplateStringsArray, x: number): string;
function foo(strs: TemplateStringsArray, x: number, y: number): boolean;
function foo(strs: TemplateStringsArray, x: number, y: string): {};
function foo(...stuff: any[]): any {
    return undefined;
}

var a = foo([]);             // number
var b = foo([], 1);          // string
var c = foo([], 1, 2);       // boolean
var d = foo([], 1, true);    // boolean (with error)
var e = foo([], 1, "2");     // {}
var f = foo([], 1, 2, 3);    // any (with error)

var u = foo \`\`;              // number
var v = foo \`\${1}\`;          // string
var w = foo \`\${1}\${2}\`;      // boolean
var x = foo \`\${1}\${true}\`;   // boolean (with error)
var y = foo \`\${1}\${"2"}\`;    // {}
var z = foo \`\${1}\${2}\${3}\`;  // any (with error)
`,
      [],
    );
  });
  test("taggedTemplateStringsWithOverloadResolution1", async () => {
    await expectPass(
      `// @target: es2015
function foo(strs: TemplateStringsArray): number;
function foo(strs: TemplateStringsArray, x: number): string;
function foo(strs: TemplateStringsArray, x: number, y: number): boolean;
function foo(strs: TemplateStringsArray, x: number, y: string): {};
function foo(...stuff: any[]): any {
    return undefined;
}

var a = foo([]);             // number
var b = foo([], 1);          // string
var c = foo([], 1, 2);       // boolean
var d = foo([], 1, true);    // boolean (with error)
var e = foo([], 1, "2");     // {}
var f = foo([], 1, 2, 3);    // any (with error)

var u = foo \`\`;              // number
var v = foo \`\${1}\`;          // string
var w = foo \`\${1}\${2}\`;      // boolean
var x = foo \`\${1}\${true}\`;   // boolean (with error)
var y = foo \`\${1}\${"2"}\`;    // {}
var z = foo \`\${1}\${2}\${3}\`;  // any (with error)
`,
      [],
    );
  });
  test("taggedTemplateStringsWithOverloadResolution2_ES6", async () => {
    await expectPass(
      `//@target: es6
function foo1(strs: TemplateStringsArray, x: number): string;
function foo1(strs: string[], x: number): number;
function foo1(...stuff: any[]): any {
    return undefined;
}

var a = foo1 \`\${1}\`;
var b = foo1([], 1);

function foo2(strs: string[], x: number): number;
function foo2(strs: TemplateStringsArray, x: number): string;
function foo2(...stuff: any[]): any {
    return undefined;
}

var c = foo2 \`\${1}\`;
var d = foo2([], 1);`,
      [],
    );
  });
  test("taggedTemplateStringsWithOverloadResolution2", async () => {
    await expectPass(
      `// @target: es2015

function foo1(strs: TemplateStringsArray, x: number): string;
function foo1(strs: string[], x: number): number;
function foo1(...stuff: any[]): any {
    return undefined;
}

var a = foo1 \`\${1}\`;
var b = foo1([], 1);

function foo2(strs: string[], x: number): number;
function foo2(strs: TemplateStringsArray, x: number): string;
function foo2(...stuff: any[]): any {
    return undefined;
}

var c = foo2 \`\${1}\`;
var d = foo2([], 1);`,
      [],
    );
  });
  test("taggedTemplateStringsWithOverloadResolution3_ES6", async () => {
    await expectPass(
      `//@target: es6
// Ambiguous call picks the first overload in declaration order
function fn1(strs: TemplateStringsArray, s: string): string;
function fn1(strs: TemplateStringsArray, n: number): number;
function fn1() { return null; }

var s: string = fn1 \`\${ undefined }\`;

// No candidate overloads found
fn1 \`\${ {} }\`; // Error

function fn2(strs: TemplateStringsArray, s: string, n: number): number;
function fn2<T>(strs: TemplateStringsArray, n: number, t: T): T;
function fn2() { return undefined; }

var d1: Date = fn2 \`\${ 0 }\${ undefined }\`; // contextually typed
var d2 = fn2 \`\${ 0 }\${ undefined }\`; // any

d1.foo(); // error
d2();     // no error (typed as any)

// Generic and non-generic overload where generic overload is the only candidate
fn2 \`\${ 0 }\${ '' }\`; // OK

// Generic and non-generic overload where non-generic overload is the only candidate
fn2 \`\${ '' }\${ 0 }\`; // OK

// Generic overloads with differing arity
function fn3<T>(strs: TemplateStringsArray, n: T): string;
function fn3<T, U>(strs: TemplateStringsArray, s: string, t: T, u: U): U;
function fn3<T, U, V>(strs: TemplateStringsArray, v: V, u: U, t: T): number;
function fn3() { return null; }

var s = fn3 \`\${ 3 }\`;
var s = fn3 \`\${'' }\${ 3 }\${ '' }\`;
var n = fn3 \`\${ 5 }\${ 5 }\${ 5 }\`;
var n: number;

// Generic overloads with differing arity tagging with arguments matching each overload type parameter count
var s = fn3 \`\${ 4 }\`
var s = fn3 \`\${ '' }\${ '' }\${ '' }\`;
var n = fn3 \`\${ '' }\${ '' }\${ 3 }\`;

// Generic overloads with differing arity tagging with argument count that doesn't match any overload
fn3 \`\`; // Error

// Generic overloads with constraints
function fn4<T extends string, U extends number>(strs: TemplateStringsArray, n: T, m: U);
function fn4<T extends number, U extends string>(strs: TemplateStringsArray, n: T, m: U);
function fn4(strs: TemplateStringsArray)
function fn4() { }

// Generic overloads with constraints tagged with types that satisfy the constraints
fn4 \`\${ '' }\${ 3  }\`;
fn4 \`\${ 3  }\${ '' }\`;
fn4 \`\${ 3  }\${ undefined }\`;
fn4 \`\${ '' }\${ null }\`;

// Generic overloads with constraints called with type arguments that do not satisfy the constraints
fn4 \`\${ null }\${ null }\`; // Error

// Generic overloads with constraints called without type arguments but with types that do not satisfy the constraints
fn4 \`\${ true }\${ null }\`;
fn4 \`\${ null }\${ true }\`;

// Non - generic overloads where contextual typing of function arguments has errors
function fn5(strs: TemplateStringsArray, f: (n: string) => void): string;
function fn5(strs: TemplateStringsArray, f: (n: number) => void): number;
function fn5() { return undefined; }
fn5 \`\${ (n) => n.toFixed() }\`; // will error; 'n' should have type 'string'.
fn5 \`\${ (n) => n.substr(0) }\`;

`,
      [],
    );
  });
  test("taggedTemplateStringsWithOverloadResolution3", async () => {
    await expectPass(
      `// @target: es2015

// Ambiguous call picks the first overload in declaration order
function fn1(strs: TemplateStringsArray, s: string): string;
function fn1(strs: TemplateStringsArray, n: number): number;
function fn1() { return null; }

var s: string = fn1 \`\${ undefined }\`;

// No candidate overloads found
fn1 \`\${ {} }\`; // Error

function fn2(strs: TemplateStringsArray, s: string, n: number): number;
function fn2<T>(strs: TemplateStringsArray, n: number, t: T): T;
function fn2() { return undefined; }

var d1: Date = fn2 \`\${ 0 }\${ undefined }\`; // contextually typed
var d2       = fn2 \`\${ 0 }\${ undefined }\`; // any

d1.foo(); // error
d2();     // no error (typed as any)

// Generic and non-generic overload where generic overload is the only candidate
fn2 \`\${ 0 }\${ '' }\`; // OK

// Generic and non-generic overload where non-generic overload is the only candidate
fn2 \`\${ '' }\${ 0 }\`; // OK

// Generic overloads with differing arity
function fn3<T>(strs: TemplateStringsArray, n: T): string;
function fn3<T, U>(strs: TemplateStringsArray, s: string, t: T, u: U): U;
function fn3<T, U, V>(strs: TemplateStringsArray, v: V, u: U, t: T): number;
function fn3() { return null; }

var s = fn3 \`\${ 3 }\`;
var s = fn3 \`\${'' }\${ 3 }\${ '' }\`;
var n = fn3 \`\${ 5 }\${ 5 }\${ 5 }\`;
var n: number;

// Generic overloads with differing arity tagging with arguments matching each overload type parameter count
var s = fn3 \`\${ 4 }\`
var s = fn3 \`\${ '' }\${ '' }\${ '' }\`;
var n = fn3 \`\${ '' }\${ '' }\${ 3 }\`;

// Generic overloads with differing arity tagging with argument count that doesn't match any overload
fn3 \`\`; // Error

// Generic overloads with constraints
function fn4<T extends string, U extends number>(strs: TemplateStringsArray, n: T, m: U);
function fn4<T extends number, U extends string>(strs: TemplateStringsArray, n: T, m: U);
function fn4(strs: TemplateStringsArray)
function fn4() { }

// Generic overloads with constraints tagged with types that satisfy the constraints
fn4 \`\${ '' }\${ 3  }\`;
fn4 \`\${ 3  }\${ '' }\`;
fn4 \`\${ 3  }\${ undefined }\`;
fn4 \`\${ '' }\${ null }\`;

// Generic overloads with constraints called with type arguments that do not satisfy the constraints
fn4 \`\${ null }\${ null }\`; // Error

// Generic overloads with constraints called without type arguments but with types that do not satisfy the constraints
fn4 \`\${ true }\${ null }\`;
fn4 \`\${ null }\${ true }\`;

// Non - generic overloads where contextual typing of function arguments has errors
function fn5(strs: TemplateStringsArray, f: (n: string) => void): string;
function fn5(strs: TemplateStringsArray, f: (n: number) => void): number;
function fn5() { return undefined; }
fn5 \`\${ (n) => n.toFixed() }\`; // will error; 'n' should have type 'string'.
fn5 \`\${ (n) => n.substr(0) }\`;

`,
      [],
    );
  });
  test("taggedTemplateStringsWithTagNamedDeclare", async () => {
    await expectPass(
      `// @target: es2015


function declare(x: any, ...ys: any[]) {
}

declare \`Hello \${0} world!\`;`,
      [],
    );
  });
  test("taggedTemplateStringsWithTagNamedDeclareES6", async () => {
    await expectPass(
      `//@target: es6

function declare(x: any, ...ys: any[]) {
}

declare \`Hello \${0} world!\`;`,
      [],
    );
  });
  test("taggedTemplateStringsWithTagsTypedAsAny", async () => {
    await expectPass(
      `// @target: es2015
var f: any;

f \`abc\`

f \`abc\${1}def\${2}ghi\`;

f.g.h \`abc\`

f.g.h \`abc\${1}def\${2}ghi\`;

f \`abc\`.member

f \`abc\${1}def\${2}ghi\`.member;

f \`abc\`["member"];

f \`abc\${1}def\${2}ghi\`["member"];

f \`abc\`["member"].someOtherTag \`abc\${1}def\${2}ghi\`;

f \`abc\${1}def\${2}ghi\`["member"].someOtherTag \`abc\${1}def\${2}ghi\`;

f.thisIsNotATag(\`abc\`);

f.thisIsNotATag(\`abc\${1}def\${2}ghi\`);`,
      [],
    );
  });
  test("taggedTemplateStringsWithTagsTypedAsAnyES6", async () => {
    await expectPass(
      `// @target: ES6
var f: any;
f \`abc\`

f \`abc\${1}def\${2}ghi\`;

f.g.h \`abc\`

f.g.h \`abc\${1}def\${2}ghi\`;

f \`abc\`.member

f \`abc\${1}def\${2}ghi\`.member;

f \`abc\`["member"];

f \`abc\${1}def\${2}ghi\`["member"];

f \`abc\`["member"].someOtherTag \`abc\${1}def\${2}ghi\`;

f \`abc\${1}def\${2}ghi\`["member"].someOtherTag \`abc\${1}def\${2}ghi\`;

f.thisIsNotATag(\`abc\`);

f.thisIsNotATag(\`abc\${1}def\${2}ghi\`);`,
      [],
    );
  });
  test("taggedTemplateStringsWithTypedTags", async () => {
    await expectPass(
      `// @target: es2015
interface I {
    (stringParts: TemplateStringsArray, ...rest: number[]): I;
    g: I;
    h: I;
    member: I;
    thisIsNotATag(x: string): void
    [x: number]: I;
}

var f: I;

f \`abc\`

f \`abc\${1}def\${2}ghi\`;

f \`abc\`.member

f \`abc\${1}def\${2}ghi\`.member;

f \`abc\`["member"];

f \`abc\${1}def\${2}ghi\`["member"];

f \`abc\`[0].member \`abc\${1}def\${2}ghi\`;

f \`abc\${1}def\${2}ghi\`["member"].member \`abc\${1}def\${2}ghi\`;

f.thisIsNotATag(\`abc\`);

f.thisIsNotATag(\`abc\${1}def\${2}ghi\`);
`,
      [],
    );
  });
  test("taggedTemplateStringsWithTypedTagsES6", async () => {
    await expectPass(
      `// @target: ES6
interface I {
    (stringParts: TemplateStringsArray, ...rest: number[]): I;
    g: I;
    h: I;
    member: I;
    thisIsNotATag(x: string): void
    [x: number]: I;
}

var f: I;

f \`abc\`

f \`abc\${1}def\${2}ghi\`;

f \`abc\`.member

f \`abc\${1}def\${2}ghi\`.member;

f \`abc\`["member"];

f \`abc\${1}def\${2}ghi\`["member"];

f \`abc\`[0].member \`abc\${1}def\${2}ghi\`;

f \`abc\${1}def\${2}ghi\`["member"].member \`abc\${1}def\${2}ghi\`;

f.thisIsNotATag(\`abc\`);

f.thisIsNotATag(\`abc\${1}def\${2}ghi\`);
`,
      [],
    );
  });
  test("taggedTemplateStringsWithTypeErrorInFunctionExpressionsInSubstitutionExpression", async () => {
    await expectPass(
      `// @target: es2015


function foo(...rest: any[]) {
}

foo \`\${function (x: number) { x = "bad"; } }\`;`,
      [],
    );
  });
  test("taggedTemplateStringsWithTypeErrorInFunctionExpressionsInSubstitutionExpressionES6", async () => {
    await expectPass(
      `//@target: es6

function foo(...rest: any[]) {
}

foo \`\${function (x: number) { x = "bad"; } }\`;`,
      [],
    );
  });
  test("taggedTemplatesWithTypeArguments1", async () => {
    await expectPass(
      `
declare function f<T>(strs: TemplateStringsArray, ...callbacks: Array<(x: T) => any>): void;

interface Stuff {
    x: number;
    y: string;
    z: boolean;
}

export const a = f<Stuff> \`
    hello
    \${stuff => stuff.x}
    brave
    \${stuff => stuff.y}
    world
    \${stuff => stuff.z}
\`;

declare function g<Input, T, U, V>(
    strs: TemplateStringsArray,
    t: (i: Input) => T, u: (i: Input) => U, v: (i: Input) => V): T | U | V;

export const b = g<Stuff, number, string, boolean> \`
    hello
    \${stuff => stuff.x}
    brave
    \${stuff => stuff.y}
    world
    \${stuff => stuff.z}
\`;

declare let obj: {
    prop: <T>(strs: TemplateStringsArray, x: (input: T) => T) => {
        returnedObjProp: T
    }
}

export let c = obj["prop"]<Stuff> \`\${(input) => ({ ...input })}\`
c.returnedObjProp.x;
c.returnedObjProp.y;
c.returnedObjProp.z;

c = obj.prop<Stuff> \`\${(input) => ({ ...input })}\`
c.returnedObjProp.x;
c.returnedObjProp.y;
c.returnedObjProp.z;`,
      [],
    );
  });
  test("taggedTemplatesWithTypeArguments2", async () => {
    await expectPass(
      `
export interface SomethingTaggable {
    <T>(t: TemplateStringsArray, ...args: T[]): SomethingNewable;
}

export interface SomethingNewable {
    new <T>(...args: T[]): any;
}

declare const tag: SomethingTaggable;

const a = new tag \`\${100} \${200}\`<string>("hello", "world");

const b = new tag<number> \`\${"hello"} \${"world"}\`(100, 200);

const c = new tag<number> \`\${100} \${200}\`<string>("hello", "world");

const d = new tag<number> \`\${"hello"} \${"world"}\`<string>(100, 200);

/**
 * Testing ASI. This should never parse as
 *
 * \`\`\`ts
 * new tag<number>;
 * \`hello\${369}\`();
 * \`\`\`
 */
const e = new tag<number>
\`hello\`();

class SomeBase<A, B, C> {
    a!: A; b!: B; c!: C;
}

class SomeDerived<T> extends SomeBase<number, string, T> {
    constructor() {
        super<number, string, T> \`hello world\`;
    }
}`,
      [],
    );
  });
  test("taggedTemplateUntypedTagCall01", async () => {
    await expectPass(
      `var tag: Function;
tag \`Hello world!\`;`,
      [],
    );
  });
  test("taggedTemplateWithConstructableTag01", async () => {
    await expectPass(
      `class CtorTag { }

CtorTag \`Hello world!\`;`,
      [],
    );
  });
  test("taggedTemplateWithConstructableTag02", async () => {
    await expectPass(
      `interface I {
    new (...args: any[]): string;
    new (): number;
}
declare var tag: I;
tag \`Hello world!\`;`,
      [],
    );
  });
  test("TemplateExpression1", async () => {
    await expectError(`var v = \`foo \${ a `, []);
  });
  test("templateStringBinaryOperations", async () => {
    await expectPass(
      `// @target: es2015
var a = 1 + \`\${ 3 }\`;
var b = 1 + \`2\${ 3 }\`;
var c = 1 + \`\${ 3 }4\`;
var d = 1 + \`2\${ 3 }4\`;
var e = \`\${ 3 }\` + 5;
var f = \`2\${ 3 }\` + 5;
var g = \`\${ 3 }4\` + 5;
var h = \`2\${ 3 }4\` + 5;
var i = 1 + \`\${ 3 }\` + 5;
var j = 1 + \`2\${ 3 }\` + 5;
var k = 1 + \`\${ 3 }4\` + 5;
var l = 1 + \`2\${ 3 }4\` + 5;

var a2 = 1 + \`\${ 3 - 4 }\`;
var b2 = 1 + \`2\${ 3 - 4 }\`;
var c2 = 1 + \`\${ 3 - 4 }5\`;
var d2 = 1 + \`2\${ 3 - 4 }5\`;
var e2 = \`\${ 3 - 4 }\` + 6;
var f2 = \`2\${ 3 - 4 }\` + 6;
var g2 = \`\${ 3 - 4 }5\` + 6;
var h2 = \`2\${ 3 - 4 }5\` + 6;
var i2 = 1 + \`\${ 3 - 4 }\` + 6;
var j2 = 1 + \`2\${ 3 - 4 }\` + 6;
var k2 = 1 + \`\${ 3 - 4 }5\` + 6;
var l2 = 1 + \`2\${ 3 - 4 }5\` + 6;

var a3 = 1 + \`\${ 3 * 4 }\`;
var b3 = 1 + \`2\${ 3 * 4 }\`;
var c3 = 1 + \`\${ 3 * 4 }5\`;
var d3 = 1 + \`2\${ 3 * 4 }5\`;
var e3 = \`\${ 3 * 4 }\` + 6;
var f3 = \`2\${ 3 * 4 }\` + 6;
var g3 = \`\${ 3 * 4 }5\` + 6;
var h3 = \`2\${ 3 * 4 }5\` + 6;
var i3 = 1 + \`\${ 3 * 4 }\` + 6;
var j3 = 1 + \`2\${ 3 * 4 }\` + 6;
var k3 = 1 + \`\${ 3 * 4 }5\` + 6;
var l3 = 1 + \`2\${ 3 * 4 }5\` + 6;

var a4 = 1 + \`\${ 3 & 4 }\`;
var b4 = 1 + \`2\${ 3 & 4 }\`;
var c4 = 1 + \`\${ 3 & 4 }5\`;
var d4 = 1 + \`2\${ 3 & 4 }5\`;
var e4 = \`\${ 3 & 4 }\` + 6;
var f4 = \`2\${ 3 & 4 }\` + 6;
var g4 = \`\${ 3 & 4 }5\` + 6;
var h4 = \`2\${ 3 & 4 }5\` + 6;
var i4 = 1 + \`\${ 3 & 4 }\` + 6;
var j4 = 1 + \`2\${ 3 & 4 }\` + 6;
var k4 = 1 + \`\${ 3 & 4 }5\` + 6;
var l4 = 1 + \`2\${ 3 & 4 }5\` + 6;
`,
      [],
    );
  });
  test("templateStringBinaryOperationsES6", async () => {
    await expectPass(
      `// @target: ES6
var a = 1 + \`\${ 3 }\`;
var b = 1 + \`2\${ 3 }\`;
var c = 1 + \`\${ 3 }4\`;
var d = 1 + \`2\${ 3 }4\`;
var e = \`\${ 3 }\` + 5;
var f = \`2\${ 3 }\` + 5;
var g = \`\${ 3 }4\` + 5;
var h = \`2\${ 3 }4\` + 5;
var i = 1 + \`\${ 3 }\` + 5;
var j = 1 + \`2\${ 3 }\` + 5;
var k = 1 + \`\${ 3 }4\` + 5;
var l = 1 + \`2\${ 3 }4\` + 5;

var a2 = 1 + \`\${ 3 - 4 }\`;
var b2 = 1 + \`2\${ 3 - 4 }\`;
var c2 = 1 + \`\${ 3 - 4 }5\`;
var d2 = 1 + \`2\${ 3 - 4 }5\`;
var e2 = \`\${ 3 - 4 }\` + 6;
var f2 = \`2\${ 3 - 4 }\` + 6;
var g2 = \`\${ 3 - 4 }5\` + 6;
var h2 = \`2\${ 3 - 4 }5\` + 6;
var i2 = 1 + \`\${ 3 - 4 }\` + 6;
var j2 = 1 + \`2\${ 3 - 4 }\` + 6;
var k2 = 1 + \`\${ 3 - 4 }5\` + 6;
var l2 = 1 + \`2\${ 3 - 4 }5\` + 6;

var a3 = 1 + \`\${ 3 * 4 }\`;
var b3 = 1 + \`2\${ 3 * 4 }\`;
var c3 = 1 + \`\${ 3 * 4 }5\`;
var d3 = 1 + \`2\${ 3 * 4 }5\`;
var e3 = \`\${ 3 * 4 }\` + 6;
var f3 = \`2\${ 3 * 4 }\` + 6;
var g3 = \`\${ 3 * 4 }5\` + 6;
var h3 = \`2\${ 3 * 4 }5\` + 6;
var i3 = 1 + \`\${ 3 * 4 }\` + 6;
var j3 = 1 + \`2\${ 3 * 4 }\` + 6;
var k3 = 1 + \`\${ 3 * 4 }5\` + 6;
var l3 = 1 + \`2\${ 3 * 4 }5\` + 6;

var a4 = 1 + \`\${ 3 & 4 }\`;
var b4 = 1 + \`2\${ 3 & 4 }\`;
var c4 = 1 + \`\${ 3 & 4 }5\`;
var d4 = 1 + \`2\${ 3 & 4 }5\`;
var e4 = \`\${ 3 & 4 }\` + 6;
var f4 = \`2\${ 3 & 4 }\` + 6;
var g4 = \`\${ 3 & 4 }5\` + 6;
var h4 = \`2\${ 3 & 4 }5\` + 6;
var i4 = 1 + \`\${ 3 & 4 }\` + 6;
var j4 = 1 + \`2\${ 3 & 4 }\` + 6;
var k4 = 1 + \`\${ 3 & 4 }5\` + 6;
var l4 = 1 + \`2\${ 3 & 4 }5\` + 6;
`,
      [],
    );
  });
  test("templateStringBinaryOperationsES6Invalid", async () => {
    await expectPass(
      `// @target: ES6
var a = 1 - \`\${ 3 }\`;
var b = 1 - \`2\${ 3 }\`;
var c = 1 - \`\${ 3 }4\`;
var d = 1 - \`2\${ 3 }4\`;
var e = \`\${ 3 }\` - 5;
var f = \`2\${ 3 }\` - 5;
var g = \`\${ 3 }4\` - 5;
var h = \`2\${ 3 }4\` - 5;

var a2 = 1 * \`\${ 3 }\`;
var b2 = 1 * \`2\${ 3 }\`;
var c2 = 1 * \`\${ 3 }4\`;
var d2 = 1 * \`2\${ 3 }4\`;
var e2 = \`\${ 3 }\` * 5;
var f2 = \`2\${ 3 }\` * 5;
var g2 = \`\${ 3 }4\` * 5;
var h2 = \`2\${ 3 }4\` * 5;

var a3 = 1 & \`\${ 3 }\`;
var b3 = 1 & \`2\${ 3 }\`;
var c3 = 1 & \`\${ 3 }4\`;
var d3 = 1 & \`2\${ 3 }4\`;
var e3 = \`\${ 3 }\` & 5;
var f3 = \`2\${ 3 }\` & 5;
var g3 = \`\${ 3 }4\` & 5;
var h3 = \`2\${ 3 }4\` & 5;

var a4 = 1 - \`\${ 3 - 4 }\`;
var b4 = 1 - \`2\${ 3 - 4 }\`;
var c4 = 1 - \`\${ 3 - 4 }5\`;
var d4 = 1 - \`2\${ 3 - 4 }5\`;
var e4 = \`\${ 3 - 4 }\` - 6;
var f4 = \`2\${ 3 - 4 }\` - 6;
var g4 = \`\${ 3 - 4 }5\` - 6;
var h4 = \`2\${ 3 - 4 }5\` - 6;

var a5 = 1 - \`\${ 3 * 4 }\`;
var b5 = 1 - \`2\${ 3 * 4 }\`;
var c5 = 1 - \`\${ 3 * 4 }5\`;
var d5 = 1 - \`2\${ 3 * 4 }5\`;
var e5 = \`\${ 3 * 4 }\` - 6;
var f5 = \`2\${ 3 * 4 }\` - 6;
var g5 = \`\${ 3 * 4 }5\` - 6;
var h5 = \`2\${ 3 * 4 }5\` - 6;

var a6 = 1 - \`\${ 3 & 4 }\`;
var b6 = 1 - \`2\${ 3 & 4 }\`;
var c6 = 1 - \`\${ 3 & 4 }5\`;
var d6 = 1 - \`2\${ 3 & 4 }5\`;
var e6 = \`\${ 3 & 4 }\` - 6;
var f6 = \`2\${ 3 & 4 }\` - 6;
var g6 = \`\${ 3 & 4 }5\` - 6;
var h6 = \`2\${ 3 & 4 }5\` - 6;

var a7 = 1 * \`\${ 3 - 4 }\`;
var b7 = 1 * \`2\${ 3 - 4 }\`;
var c7 = 1 * \`\${ 3 - 4 }5\`;
var d7 = 1 * \`2\${ 3 - 4 }5\`;
var e7 = \`\${ 3 - 4 }\` * 6;
var f7 = \`2\${ 3 - 4 }\` * 6;
var g7 = \`\${ 3 - 4 }5\` * 6;
var h7 = \`2\${ 3 - 4 }5\` * 6;

var a8 = 1 * \`\${ 3 * 4 }\`;
var b8 = 1 * \`2\${ 3 * 4 }\`;
var c8 = 1 * \`\${ 3 * 4 }5\`;
var d8 = 1 * \`2\${ 3 * 4 }5\`;
var e8 = \`\${ 3 * 4 }\` * 6;
var f8 = \`2\${ 3 * 4 }\` * 6;
var g8 = \`\${ 3 * 4 }5\` * 6;
var h8 = \`2\${ 3 * 4 }5\` * 6;

var a9 = 1 * \`\${ 3 & 4 }\`;
var b9 = 1 * \`2\${ 3 & 4 }\`;
var c9 = 1 * \`\${ 3 & 4 }5\`;
var d9 = 1 * \`2\${ 3 & 4 }5\`;
var e9 = \`\${ 3 & 4 }\` * 6;
var f9 = \`2\${ 3 & 4 }\` * 6;
var g9 = \`\${ 3 & 4 }5\` * 6;
var h9 = \`2\${ 3 & 4 }5\` * 6;

var aa = 1 & \`\${ 3 - 4 }\`;
var ba = 1 & \`2\${ 3 - 4 }\`;
var ca = 1 & \`\${ 3 - 4 }5\`;
var da = 1 & \`2\${ 3 - 4 }5\`;
var ea = \`\${ 3 - 4 }\` & 6;
var fa = \`2\${ 3 - 4 }\` & 6;
var ga = \`\${ 3 - 4 }5\` & 6;
var ha = \`2\${ 3 - 4 }5\` & 6;

var ab = 1 & \`\${ 3 * 4 }\`;
var bb = 1 & \`2\${ 3 * 4 }\`;
var cb = 1 & \`\${ 3 * 4 }5\`;
var db = 1 & \`2\${ 3 * 4 }5\`;
var eb = \`\${ 3 * 4 }\` & 6;
var fb = \`2\${ 3 * 4 }\` & 6;
var gb = \`\${ 3 * 4 }5\` & 6;
var hb = \`2\${ 3 * 4 }5\` & 6;

var ac = 1 & \`\${ 3 & 4 }\`;
var bc = 1 & \`2\${ 3 & 4 }\`;
var cc = 1 & \`\${ 3 & 4 }5\`;
var dc = 1 & \`2\${ 3 & 4 }5\`;
var ec = \`\${ 3 & 4 }\` & 6;
var fc = \`2\${ 3 & 4 }\` & 6;
var gc = \`\${ 3 & 4 }5\` & 6;
var hc = \`2\${ 3 & 4 }5\` & 6;
`,
      [],
    );
  });
  test("templateStringBinaryOperationsInvalid", async () => {
    await expectPass(
      `// @target: es2015
var a = 1 - \`\${ 3 }\`;
var b = 1 - \`2\${ 3 }\`;
var c = 1 - \`\${ 3 }4\`;
var d = 1 - \`2\${ 3 }4\`;
var e = \`\${ 3 }\` - 5;
var f = \`2\${ 3 }\` - 5;
var g = \`\${ 3 }4\` - 5;
var h = \`2\${ 3 }4\` - 5;

var a2 = 1 * \`\${ 3 }\`;
var b2 = 1 * \`2\${ 3 }\`;
var c2 = 1 * \`\${ 3 }4\`;
var d2 = 1 * \`2\${ 3 }4\`;
var e2 = \`\${ 3 }\` * 5;
var f2 = \`2\${ 3 }\` * 5;
var g2 = \`\${ 3 }4\` * 5;
var h2 = \`2\${ 3 }4\` * 5;

var a3 = 1 & \`\${ 3 }\`;
var b3 = 1 & \`2\${ 3 }\`;
var c3 = 1 & \`\${ 3 }4\`;
var d3 = 1 & \`2\${ 3 }4\`;
var e3 = \`\${ 3 }\` & 5;
var f3 = \`2\${ 3 }\` & 5;
var g3 = \`\${ 3 }4\` & 5;
var h3 = \`2\${ 3 }4\` & 5;

var a4 = 1 - \`\${ 3 - 4 }\`;
var b4 = 1 - \`2\${ 3 - 4 }\`;
var c4 = 1 - \`\${ 3 - 4 }5\`;
var d4 = 1 - \`2\${ 3 - 4 }5\`;
var e4 = \`\${ 3 - 4 }\` - 6;
var f4 = \`2\${ 3 - 4 }\` - 6;
var g4 = \`\${ 3 - 4 }5\` - 6;
var h4 = \`2\${ 3 - 4 }5\` - 6;

var a5 = 1 - \`\${ 3 * 4 }\`;
var b5 = 1 - \`2\${ 3 * 4 }\`;
var c5 = 1 - \`\${ 3 * 4 }5\`;
var d5 = 1 - \`2\${ 3 * 4 }5\`;
var e5 = \`\${ 3 * 4 }\` - 6;
var f5 = \`2\${ 3 * 4 }\` - 6;
var g5 = \`\${ 3 * 4 }5\` - 6;
var h5 = \`2\${ 3 * 4 }5\` - 6;

var a6 = 1 - \`\${ 3 & 4 }\`;
var b6 = 1 - \`2\${ 3 & 4 }\`;
var c6 = 1 - \`\${ 3 & 4 }5\`;
var d6 = 1 - \`2\${ 3 & 4 }5\`;
var e6 = \`\${ 3 & 4 }\` - 6;
var f6 = \`2\${ 3 & 4 }\` - 6;
var g6 = \`\${ 3 & 4 }5\` - 6;
var h6 = \`2\${ 3 & 4 }5\` - 6;

var a7 = 1 * \`\${ 3 - 4 }\`;
var b7 = 1 * \`2\${ 3 - 4 }\`;
var c7 = 1 * \`\${ 3 - 4 }5\`;
var d7 = 1 * \`2\${ 3 - 4 }5\`;
var e7 = \`\${ 3 - 4 }\` * 6;
var f7 = \`2\${ 3 - 4 }\` * 6;
var g7 = \`\${ 3 - 4 }5\` * 6;
var h7 = \`2\${ 3 - 4 }5\` * 6;

var a8 = 1 * \`\${ 3 * 4 }\`;
var b8 = 1 * \`2\${ 3 * 4 }\`;
var c8 = 1 * \`\${ 3 * 4 }5\`;
var d8 = 1 * \`2\${ 3 * 4 }5\`;
var e8 = \`\${ 3 * 4 }\` * 6;
var f8 = \`2\${ 3 * 4 }\` * 6;
var g8 = \`\${ 3 * 4 }5\` * 6;
var h8 = \`2\${ 3 * 4 }5\` * 6;

var a9 = 1 * \`\${ 3 & 4 }\`;
var b9 = 1 * \`2\${ 3 & 4 }\`;
var c9 = 1 * \`\${ 3 & 4 }5\`;
var d9 = 1 * \`2\${ 3 & 4 }5\`;
var e9 = \`\${ 3 & 4 }\` * 6;
var f9 = \`2\${ 3 & 4 }\` * 6;
var g9 = \`\${ 3 & 4 }5\` * 6;
var h9 = \`2\${ 3 & 4 }5\` * 6;

var aa = 1 & \`\${ 3 - 4 }\`;
var ba = 1 & \`2\${ 3 - 4 }\`;
var ca = 1 & \`\${ 3 - 4 }5\`;
var da = 1 & \`2\${ 3 - 4 }5\`;
var ea = \`\${ 3 - 4 }\` & 6;
var fa = \`2\${ 3 - 4 }\` & 6;
var ga = \`\${ 3 - 4 }5\` & 6;
var ha = \`2\${ 3 - 4 }5\` & 6;

var ab = 1 & \`\${ 3 * 4 }\`;
var bb = 1 & \`2\${ 3 * 4 }\`;
var cb = 1 & \`\${ 3 * 4 }5\`;
var db = 1 & \`2\${ 3 * 4 }5\`;
var eb = \`\${ 3 * 4 }\` & 6;
var fb = \`2\${ 3 * 4 }\` & 6;
var gb = \`\${ 3 * 4 }5\` & 6;
var hb = \`2\${ 3 * 4 }5\` & 6;

var ac = 1 & \`\${ 3 & 4 }\`;
var bc = 1 & \`2\${ 3 & 4 }\`;
var cc = 1 & \`\${ 3 & 4 }5\`;
var dc = 1 & \`2\${ 3 & 4 }5\`;
var ec = \`\${ 3 & 4 }\` & 6;
var fc = \`2\${ 3 & 4 }\` & 6;
var gc = \`\${ 3 & 4 }5\` & 6;
var hc = \`2\${ 3 & 4 }5\` & 6;
`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes01_ES6", async () => {
    await expectPass(
      `// @target: es6

var x = \`\\0\\x00\\u0000 0 00 0000\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes01", async () => {
    await expectPass(
      `// @target: es2015


var x = \`\\0\\x00\\u0000 0 00 0000\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes02_ES6", async () => {
    await expectPass(
      `// @target: es6

var x = \`\\x19\\u0019 19\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes02", async () => {
    await expectPass(
      `// @target: es2015


var x = \`\\x19\\u0019 19\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes03_ES6", async () => {
    await expectPass(
      `// @target: es6

var x = \`\\x1F\\u001f 1F 1f\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes03", async () => {
    await expectPass(
      `// @target: es2015


var x = \`\\x1F\\u001f 1F 1f\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes04_ES6", async () => {
    await expectPass(
      `// @target: es6

var x = \`\\x20\\u0020 20\`;`,
      [],
    );
  });
  test("templateStringControlCharacterEscapes04", async () => {
    await expectPass(
      `// @target: es2015


var x = \`\\x20\\u0020 20\`;`,
      [],
    );
  });
  test("templateStringInArray", async () => {
    await expectPass(
      `// @target: es2015
var x = [1, 2, \`abc\${ 123 }def\`];`,
      [],
    );
  });
  test("templateStringInArrowFunction", async () => {
    await expectPass(
      `// @target: es2015
var x = x => \`abc\${ x }def\`;`,
      [],
    );
  });
  test("templateStringInArrowFunctionES6", async () => {
    await expectPass(
      `// @strict: false
var x = x => \`abc\${ x }def\`;`,
      [],
    );
  });
  test("templateStringInCallExpression", async () => {
    await expectPass(
      `// @target: es2015
\`abc\${0}abc\`(\`hello \${0} world\`, \`   \`, \`1\${2}3\`);`,
      [],
    );
  });
  test("templateStringInCallExpressionES6", async () => {
    await expectPass(
      `// @target: ES6
\`abc\${0}abc\`(\`hello \${0} world\`, \`   \`, \`1\${2}3\`);`,
      [],
    );
  });
  test("templateStringInConditional", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ " " }def\` ? \`abc\${ " " }def\` : \`abc\${ " " }def\`;`,
      [],
    );
  });
  test("templateStringInConditionalES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ " " }def\` ? \`abc\${ " " }def\` : \`abc\${ " " }def\`;`,
      [],
    );
  });
  test("templateStringInDeleteExpression", async () => {
    await expectPass(
      `// @target: es2015
delete \`abc\${0}abc\`;`,
      [],
    );
  });
  test("templateStringInDeleteExpressionES6", async () => {
    await expectPass(
      `// @target: ES6
delete \`abc\${0}abc\`;`,
      [],
    );
  });
  test("templateStringInDivision", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ 1 }def\` / 1;`,
      [],
    );
  });
  test("templateStringInEqualityChecks", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${0}abc\` === \`abc\` ||
        \`abc\` !== \`abc\${0}abc\` &&
        \`abc\${0}abc\` == "abc0abc" &&
        "abc0abc" !== \`abc\${0}abc\`;`,
      [],
    );
  });
  test("templateStringInEqualityChecksES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${0}abc\` === \`abc\` ||
        \`abc\` !== \`abc\${0}abc\` &&
        \`abc\${0}abc\` == "abc0abc" &&
        "abc0abc" !== \`abc\${0}abc\`;`,
      [],
    );
  });
  test("templateStringInFunctionExpression", async () => {
    await expectPass(
      `var x = function y() {
    \`abc\${ 0 }def\`
    return \`abc\${ 0 }def\`;
};`,
      [],
    );
  });
  test("templateStringInFunctionExpressionES6", async () => {
    await expectPass(
      `var x = function y() {
    \`abc\${ 0 }def\`
    return \`abc\${ 0 }def\`;
};`,
      [],
    );
  });
  test("templateStringInFunctionParameterType", async () => {
    await expectError(
      `// @target: es2015
function f(\`hello\`);
function f(x: string);
function f(x: string) {
    return x;
}`,
      [],
    );
  });
  test("templateStringInFunctionParameterTypeES6", async () => {
    await expectError(
      `// @target: ES6
function f(\`hello\`);
function f(x: string);
function f(x: string) {
    return x;
}`,
      [],
    );
  });
  test("templateStringInIndexExpression", async () => {
    await expectPass(
      `// @target: es2015
\`abc\${0}abc\`[\`0\`];`,
      [],
    );
  });
  test("templateStringInIndexExpressionES6", async () => {
    await expectPass(
      `// @target: ES6
\`abc\${0}abc\`[\`0\`];`,
      [],
    );
  });
  test("templateStringInInOperator", async () => {
    await expectPass(
      `// @target: es2015
var x = \`\${ "hi" }\` in { hi: 10, hello: 20};`,
      [],
    );
  });
  test("templateStringInInOperatorES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`\${ "hi" }\` in { hi: 10, hello: 20};`,
      [],
    );
  });
  test("templateStringInInstanceOf", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ 0 }def\` instanceof String;`,
      [],
    );
  });
  test("templateStringInInstanceOfES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ 0 }def\` instanceof String;`,
      [],
    );
  });
  test("templateStringInModuleName", async () => {
    await expectError(
      `// @target: es2015
declare module \`M1\` {
}

declare module \`M\${2}\` {
}`,
      [],
    );
  });
  test("templateStringInModuleNameES6", async () => {
    await expectError(
      `// @target: ES6
declare module \`M1\` {
}

declare module \`M\${2}\` {
}`,
      [],
    );
  });
  test("templateStringInModulo", async () => {
    await expectPass(
      `// @target: es2015
var x = 1 % \`abc\${ 1 }def\`;`,
      [],
    );
  });
  test("templateStringInModuloES6", async () => {
    await expectPass(
      `// @target: ES6
var x = 1 % \`abc\${ 1 }def\`;`,
      [],
    );
  });
  test("templateStringInMultiplication", async () => {
    await expectPass(
      `// @target: es2015
var x = 1 * \`abc\${ 1 }def\`;`,
      [],
    );
  });
  test("templateStringInMultiplicationES6", async () => {
    await expectPass(
      `// @target: ES6
var x = 1 * \`abc\${ 1 }def\`;`,
      [],
    );
  });
  test("templateStringInNewExpression", async () => {
    await expectPass(
      `// @target: es2015
new \`abc\${0}abc\`(\`hello \${0} world\`, \`   \`, \`1\${2}3\`);`,
      [],
    );
  });
  test("templateStringInNewExpressionES6", async () => {
    await expectPass(
      `// @target: ES6
new \`abc\${0}abc\`(\`hello \${0} world\`, \`   \`, \`1\${2}3\`);`,
      [],
    );
  });
  test("templateStringInNewOperator", async () => {
    await expectPass(
      `// @target: es2015
var x = new \`abc\${ 1 }def\`;`,
      [],
    );
  });
  test("templateStringInNewOperatorES6", async () => {
    await expectPass(
      `// @target: ES6
var x = new \`abc\${ 1 }def\`;`,
      [],
    );
  });
  test("templateStringInObjectLiteral", async () => {
    await expectError(
      `// @target: es2015
var x = {
    a: \`abc\${ 123 }def\`,
    \`b\`: 321
}`,
      [],
    );
  });
  test("templateStringInObjectLiteralES6", async () => {
    await expectError(
      `// @target: ES6
var x = {
    a: \`abc\${ 123 }def\`,
    \`b\`: 321
}`,
      [],
    );
  });
  test("templateStringInParentheses", async () => {
    await expectPass(
      `// @target: es2015
var x = (\`abc\${0}abc\`);`,
      [],
    );
  });
  test("templateStringInParenthesesES6", async () => {
    await expectPass(
      `// @target: ES6
var x = (\`abc\${0}abc\`);`,
      [],
    );
  });
  test("templateStringInPropertyAssignment", async () => {
    await expectPass(
      `// @target: es2015
var x = {
    a: \`abc\${ 123 }def\${ 456 }ghi\`
}`,
      [],
    );
  });
  test("templateStringInPropertyAssignmentES6", async () => {
    await expectPass(
      `// @target: ES6
var x = {
    a: \`abc\${ 123 }def\${ 456 }ghi\`
}`,
      [],
    );
  });
  test("templateStringInPropertyName1", async () => {
    await expectError(
      `// @target: es2015
var x = {
    \`a\`: 321
}`,
      [],
    );
  });
  test("templateStringInPropertyName2", async () => {
    await expectError(
      `// @target: es2015
var x = {
    \`abc\${ 123 }def\${ 456 }ghi\`: 321
}`,
      [],
    );
  });
  test("templateStringInPropertyNameES6_1", async () => {
    await expectError(
      `// @target: ES6
var x = {
    \`a\`: 321
}`,
      [],
    );
  });
  test("templateStringInPropertyNameES6_2", async () => {
    await expectError(
      `// @target: ES6
var x = {
    \`abc\${ 123 }def\${ 456 }ghi\`: 321
}`,
      [],
    );
  });
  test("templateStringInSwitchAndCase", async () => {
    await expectPass(
      `// @target: es2015
switch (\`abc\${0}abc\`) {
    case \`abc\`:
    case \`123\`:
    case \`abc\${0}abc\`:
        \`def\${1}def\`;
}`,
      [],
    );
  });
  test("templateStringInSwitchAndCaseES6", async () => {
    await expectPass(
      `// @target: ES6
switch (\`abc\${0}abc\`) {
    case \`abc\`:
    case \`123\`:
    case \`abc\${0}abc\`:
        \`def\${1}def\`;
}`,
      [],
    );
  });
  test("templateStringInTaggedTemplate", async () => {
    await expectPass(
      `// @target: es2015
\`I AM THE \${ \`\${ \`TAG\` } \` } PORTION\`    \`I \${ "AM" } THE TEMPLATE PORTION\``,
      [],
    );
  });
  test("templateStringInTaggedTemplateES6", async () => {
    await expectPass(
      `// @target: ES6
\`I AM THE \${ \`\${ \`TAG\` } \` } PORTION\`    \`I \${ "AM" } THE TEMPLATE PORTION\``,
      [],
    );
  });
  test("templateStringInTypeAssertion", async () => {
    await expectPass(
      `// @target: es2015
var x = <any>\`abc\${ 123 }def\`;`,
      [],
    );
  });
  test("templateStringInTypeAssertionES6", async () => {
    await expectPass(
      `// @target: ES6
var x = <any>\`abc\${ 123 }def\`;`,
      [],
    );
  });
  test("templateStringInTypeOf", async () => {
    await expectPass(
      `// @target: es2015
var x = typeof \`abc\${ 123 }def\`;`,
      [],
    );
  });
  test("templateStringInTypeOfES6", async () => {
    await expectPass(
      `// @target: ES6
var x = typeof \`abc\${ 123 }def\`;`,
      [],
    );
  });
  test("templateStringInUnaryPlus", async () => {
    await expectPass(
      `// @target: es2015
var x = +\`abc\${ 123 }def\`;`,
      [],
    );
  });
  test("templateStringInUnaryPlusES6", async () => {
    await expectPass(
      `// @target: ES6
var x = +\`abc\${ 123 }def\`;`,
      [],
    );
  });
  test("templateStringInWhile", async () => {
    await expectPass(
      `// @target: es2015
while (\`abc\${0}abc\`) {
    \`def\${1}def\`;
}`,
      [],
    );
  });
  test("templateStringInWhileES6", async () => {
    await expectPass(
      `// @target: ES6
while (\`abc\${0}abc\`) {
    \`def\${1}def\`;
}`,
      [],
    );
  });
  test("templateStringInYieldKeyword", async () => {
    await expectPass(
      `// @strict: false
function* gen() {
    // Once this is supported, the inner expression does not need to be parenthesized.
    var x = yield \`abc\${ x }def\`;
}
`,
      [],
    );
  });
  test("templateStringMultiline1_ES6", async () => {
    await expectPass(
      `//@target: es6

// newlines are <CR><LF>
\`
\\
\``,
      [],
    );
  });
  test("templateStringMultiline1", async () => {
    await expectPass(
      `// @target: es2015


// newlines are <CR><LF>
\`
\\
\``,
      [],
    );
  });
  test("templateStringMultiline2_ES6", async () => {
    await expectPass(
      `//@target: es6

// newlines are <LF>
\`
\\
\``,
      [],
    );
  });
  test("templateStringMultiline2", async () => {
    await expectPass(
      `// @target: es2015


// newlines are <LF>
\`
\\
\``,
      [],
    );
  });
  test("templateStringMultiline3_ES6", async () => {
    await expectPass(
      `//@target: es6

// newlines are <CR>
\`
\\
\``,
      [],
    );
  });
  test("templateStringMultiline3", async () => {
    await expectPass(
      `// @target: es2015


// newlines are <CR>
\`
\\
\``,
      [],
    );
  });
  test("templateStringPlainCharactersThatArePartsOfEscapes01_ES6", async () => {
    await expectPass(
      `// @target: es6

\`0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 2028 2029 0085 t v f b r n\``,
      [],
    );
  });
  test("templateStringPlainCharactersThatArePartsOfEscapes01", async () => {
    await expectPass(
      `// @target: es2015

\`0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 2028 2029 0085 t v f b r n\``,
      [],
    );
  });
  test("templateStringPlainCharactersThatArePartsOfEscapes02_ES6", async () => {
    await expectPass(
      `// @target: es6

\`0\${ " " }1\${ " " }2\${ " " }3\${ " " }4\${ " " }5\${ " " }6\${ " " }7\${ " " }8\${ " " }9\${ " " }10\${ " " }11\${ " " }12\${ " " }13\${ " " }14\${ " " }15\${ " " }16\${ " " }17\${ " " }18\${ " " }19\${ " " }20\${ " " }2028\${ " " }2029\${ " " }0085\${ " " }t\${ " " }v\${ " " }f\${ " " }b\${ " " }r\${ " " }n\``,
      [],
    );
  });
  test("templateStringPlainCharactersThatArePartsOfEscapes02", async () => {
    await expectPass(
      `// @target: es2015


\`0\${ " " }1\${ " " }2\${ " " }3\${ " " }4\${ " " }5\${ " " }6\${ " " }7\${ " " }8\${ " " }9\${ " " }10\${ " " }11\${ " " }12\${ " " }13\${ " " }14\${ " " }15\${ " " }16\${ " " }17\${ " " }18\${ " " }19\${ " " }20\${ " " }2028\${ " " }2029\${ " " }0085\${ " " }t\${ " " }v\${ " " }f\${ " " }b\${ " " }r\${ " " }n\``,
      [],
    );
  });
  test("templateStringsWithTypeErrorInFunctionExpressionsInSubstitutionExpression", async () => {
    await expectPass(
      `// @target: es2015


\`\${function (x: number) { x = "bad"; } }\`;`,
      [],
    );
  });
  test("templateStringsWithTypeErrorInFunctionExpressionsInSubstitutionExpressionES6", async () => {
    await expectPass(
      `//@target: es6

\`\${function (x: number) { x = "bad"; } }\`;`,
      [],
    );
  });
  test("templateStringTermination1_ES6", async () => {
    await expectPass(
      `// @target: ES6
\`\``,
      [],
    );
  });
  test("templateStringTermination1", async () => {
    await expectPass(
      `// @target: es2015

\`\``,
      [],
    );
  });
  test("templateStringTermination2_ES6", async () => {
    await expectPass(
      `// @target: ES6
\`\\\\\``,
      [],
    );
  });
  test("templateStringTermination2", async () => {
    await expectPass(
      `// @target: es2015

\`\\\\\``,
      [],
    );
  });
  test("templateStringTermination3_ES6", async () => {
    await expectPass(
      `// @target: ES6
\`\\\`\``,
      [],
    );
  });
  test("templateStringTermination3", async () => {
    await expectPass(
      `// @target: es2015

\`\\\`\``,
      [],
    );
  });
  test("templateStringTermination4_ES6", async () => {
    await expectPass(
      `// @target: ES6
\`\\\\\\\\\``,
      [],
    );
  });
  test("templateStringTermination4", async () => {
    await expectPass(
      `// @target: es2015

\`\\\\\\\\\``,
      [],
    );
  });
  test("templateStringTermination5_ES6", async () => {
    await expectPass(
      `// @target: ES6
\`\\\\\\\\\\\\\``,
      [],
    );
  });
  test("templateStringTermination5", async () => {
    await expectPass(
      `// @target: es2015

\`\\\\\\\\\\\\\``,
      [],
    );
  });
  test("templateStringUnterminated1_ES6", async () => {
    await expectError(
      `// @target: ES6
\``,
      [],
    );
  });
  test("templateStringUnterminated1", async () => {
    await expectError(
      `// @target: es2015

\``,
      [],
    );
  });
  test("templateStringUnterminated2_ES6", async () => {
    await expectError(
      `// @target: ES6
\`\\\``,
      [],
    );
  });
  test("templateStringUnterminated2", async () => {
    await expectError(
      `// @target: es2015

\`\\\``,
      [],
    );
  });
  test("templateStringUnterminated3_ES6", async () => {
    await expectError(
      `// @target: ES6
\`\\\\`,
      [],
    );
  });
  test("templateStringUnterminated3", async () => {
    await expectError(
      `// @target: es2015

\`\\\\`,
      [],
    );
  });
  test("templateStringUnterminated4_ES6", async () => {
    await expectError(
      `// @target: ES6
\`\\\\\\\``,
      [],
    );
  });
  test("templateStringUnterminated4", async () => {
    await expectError(
      `// @target: es2015

\`\\\\\\\``,
      [],
    );
  });
  test("templateStringUnterminated5_ES6", async () => {
    await expectError(
      `// @target: ES6
\`\\\\\\\\\\\``,
      [],
    );
  });
  test("templateStringUnterminated5", async () => {
    await expectError(
      `// @target: es2015

\`\\\\\\\\\\\``,
      [],
    );
  });
  test("templateStringWhitespaceEscapes1_ES6", async () => {
    await expectPass(
      `//@target: es6

\`\\t\\n\\v\\f\\r\`;`,
      [],
    );
  });
  test("templateStringWhitespaceEscapes1", async () => {
    await expectPass(
      `// @target: es2015


\`\\t\\n\\v\\f\\r\`;`,
      [],
    );
  });
  test("templateStringWhitespaceEscapes2_ES6", async () => {
    await expectPass(
      `//@target: es6

// <TAB>, <VT>, <FF>, <SP>, <NBSP>, <BOM>
\`\\u0009\\u000B\\u000C\\u0020\\u00A0\\uFEFF\`;`,
      [],
    );
  });
  test("templateStringWhitespaceEscapes2", async () => {
    await expectPass(
      `// @target: es2015


// <TAB>, <VT>, <FF>, <SP>, <NBSP>, <BOM>
\`\\u0009\\u000B\\u000C\\u0020\\u00A0\\uFEFF\`;`,
      [],
    );
  });
  test("templateStringWithBackslashEscapes01_ES6", async () => {
    await expectPass(
      `// @target: es6

var a = \`hello\\world\`;
var b = \`hello\\\\world\`;
var c = \`hello\\\\\\world\`;
var d = \`hello\\\\\\\\world\`;`,
      [],
    );
  });
  test("templateStringWithBackslashEscapes01", async () => {
    await expectPass(
      `// @target: es2015


var a = \`hello\\world\`;
var b = \`hello\\\\world\`;
var c = \`hello\\\\\\world\`;
var d = \`hello\\\\\\\\world\`;`,
      [],
    );
  });
  test("templateStringWithCommentsInArrowFunction", async () => {
    await expectPass(
      `// @target: es2015

const a = 1;
const f1 = () =>
    \`\${
      // a
      a
    }a\`;

const f2 = () =>
    \`\${
      // a
      a
    }\`;
`,
      [],
    );
  });
  test("templateStringWithEmbeddedAddition", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ 10 + 10 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedAdditionES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ 10 + 10 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedArray", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ [1,2,3] }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedArrayES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ [1,2,3] }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedArrowFunction", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ x => x }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedArrowFunctionES6", async () => {
    await expectPass(
      `// @strict: false
var x = \`abc\${ x => x }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedComments", async () => {
    await expectPass(
      `// @target: es2015
\`head\${ // single line comment
10
}
middle\${
/* Multi-
 * line
 * comment
 */
 20
 // closing comment
}
tail\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedCommentsES6", async () => {
    await expectPass(
      `// @target: ES6
\`head\${ // single line comment
10
}
middle\${
/* Multi-
 * line
 * comment
 */
 20
 // closing comment
}
tail\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedConditional", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ true ? false : " " }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedConditionalES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ true ? false : " " }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedDivision", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ 1 / 1 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedDivisionES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ 1 / 1 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedFunctionExpression", async () => {
    await expectPass(`var x = \`abc\${ function y() { return y; } }def\`;`, []);
  });
  test("templateStringWithEmbeddedFunctionExpressionES6", async () => {
    await expectPass(`var x = \`abc\${ function y() { return y; } }def\`;`, []);
  });
  test("templateStringWithEmbeddedInOperator", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ "hi" in { hi: 10, hello: 20} }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedInOperatorES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ "hi" in { hi: 10, hello: 20} }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedInstanceOf", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ "hello" instanceof String }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedInstanceOfES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ "hello" instanceof String }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedModulo", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ 1 % 1 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedModuloES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ 1 % 1 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedMultiplication", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ 7 * 6 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedMultiplicationES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ 7 * 6 }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedNewOperator", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ new String("Hi") }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedNewOperatorES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ new String("Hi") }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedObjectLiteral", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ { x: 10, y: 20 } }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedObjectLiteralES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ { x: 10, y: 20 } }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedTemplateString", async () => {
    await expectPass(
      `// @target: es2015
var x = \`123\${ \`456 \${ " | " } 654\` }321 123\${ \`456 \${ " | " } 654\` }321\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedTemplateStringES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`123\${ \`456 \${ " | " } 654\` }321 123\${ \`456 \${ " | " } 654\` }321\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedTypeAssertionOnAddition", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ <any>(10 + 10) }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedTypeAssertionOnAdditionES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ <any>(10 + 10) }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedTypeOfOperator", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ typeof "hi" }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedTypeOfOperatorES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ typeof "hi" }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedUnaryPlus", async () => {
    await expectPass(
      `// @target: es2015
var x = \`abc\${ +Infinity }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedUnaryPlusES6", async () => {
    await expectPass(
      `// @target: ES6
var x = \`abc\${ +Infinity }def\`;`,
      [],
    );
  });
  test("templateStringWithEmbeddedYieldKeyword", async () => {
    await expectError(
      `// @target: es2015
function* gen {
    // Once this is supported, yield *must* be parenthesized.
    var x = \`abc\${ yield 10 }def\`;
}
`,
      [],
    );
  });
  test("templateStringWithEmbeddedYieldKeywordES6", async () => {
    await expectPass(
      `// @strict: false
function* gen() {
    // Once this is supported, yield *must* be parenthesized.
    var x = \`abc\${ yield 10 }def\`;
}
`,
      [],
    );
  });
  test("templateStringWithEmptyLiteralPortions", async () => {
    await expectPass(
      `// @target: es2015
var a = \`\`;

var b = \`\${ 0 }\`;

var c = \`1\${ 0 }\`;

var d = \`\${ 0 }2\`;

var e = \`1\${ 0 }2\`;

var f = \`\${ 0 }\${ 0 }\`;

var g = \`1\${ 0 }\${ 0 }\`;

var h = \`\${ 0 }2\${ 0 }\`;

var i = \`1\${ 0 }2\${ 0 }\`;

var j = \`\${ 0 }\${ 0 }3\`;

var k = \`1\${ 0 }\${ 0 }3\`;

var l = \`\${ 0 }2\${ 0 }3\`;

var m = \`1\${ 0 }2\${ 0 }3\`;
`,
      [],
    );
  });
  test("templateStringWithEmptyLiteralPortionsES6", async () => {
    await expectPass(
      `// @target: ES6
var a = \`\`;

var b = \`\${ 0 }\`;

var c = \`1\${ 0 }\`;

var d = \`\${ 0 }2\`;

var e = \`1\${ 0 }2\`;

var f = \`\${ 0 }\${ 0 }\`;

var g = \`1\${ 0 }\${ 0 }\`;

var h = \`\${ 0 }2\${ 0 }\`;

var i = \`1\${ 0 }2\${ 0 }\`;

var j = \`\${ 0 }\${ 0 }3\`;

var k = \`1\${ 0 }\${ 0 }3\`;

var l = \`\${ 0 }2\${ 0 }3\`;

var m = \`1\${ 0 }2\${ 0 }3\`;
`,
      [],
    );
  });
  test("templateStringWithOpenCommentInStringPortion", async () => {
    await expectPass(
      `// @target: es2015
\` /**head  \${ 10 } // still middle  \${ 20 } /* still tail \``,
      [],
    );
  });
  test("templateStringWithOpenCommentInStringPortionES6", async () => {
    await expectPass(
      `// @target: ES6
\` /**head  \${ 10 } // still middle  \${ 20 } /* still tail \``,
      [],
    );
  });
  test("templateStringWithPropertyAccess", async () => {
    await expectPass(
      `// @target: es2015
\`abc\${0}abc\`.indexOf(\`abc\`);`,
      [],
    );
  });
  test("templateStringWithPropertyAccessES6", async () => {
    await expectPass(
      `// @target: ES6
\`abc\${0}abc\`.indexOf(\`abc\`);`,
      [],
    );
  });
});
