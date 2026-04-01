import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: expressions", () => {
  test("arrayLiteralInference", async () => {
    await expectPass(
      `
// Repro from #31204

export enum AppType {
    HeaderDetail = 'HeaderDetail',
    HeaderMultiDetail = 'HeaderMultiDetail',
    AdvancedList = 'AdvancedList',
    Standard = 'Standard',
    Relationship = 'Relationship',
    Report = 'Report',
    Composite = 'Composite',
    ListOnly = 'ListOnly',
    ModuleSettings = 'ModuleSettings'
}

export enum AppStyle {
    Tree,
    TreeEntity,
    Standard,
    MiniApp,
    PivotTable
}

const appTypeStylesWithError: Map<AppType, Array<AppStyle>> = new Map([
    [AppType.Standard, [AppStyle.Standard, AppStyle.MiniApp]],
    [AppType.Relationship, [AppStyle.Standard, AppStyle.Tree, AppStyle.TreeEntity]],
    [AppType.AdvancedList, [AppStyle.Standard, AppStyle.MiniApp]]
]);

// Repro from #31204

declare function foo<T>(...args: T[]): T[];
let b1: { x: boolean }[] = foo({ x: true }, { x: false });
let b2: boolean[][] = foo([true], [false]);
`,
      [],
    );
  });
  test("arrayLiterals", async () => {
    await expectPass(
      `// Empty array literal with no contextual type has type Undefined[]

var arr1= [[], [1], ['']];

var arr2 = [[null], [1], ['']];


// Array literal with elements of only EveryType E has type E[]
var stringArrArr = [[''], [""]];

var stringArr = ['', ""];

var numberArr = [0, 0.0, 0x00, 1e1];

var boolArr = [false, true, false, true];

class C { private p; }
var classArr = [new C(), new C()];

var classTypeArray = [C, C, C];
var classTypeArray: Array<typeof C>; // Should OK, not be a parse error

// Contextual type C with numeric index signature makes array literal of EveryType E of type BCT(E,C)[]
var context1: { [n: number]: { a: string; b: number; }; } = [{ a: '', b: 0, c: '' }, { a: "", b: 3, c: 0 }];
var context2 = [{ a: '', b: 0, c: '' }, { a: "", b: 3, c: 0 }];

// Contextual type C with numeric index signature of type Base makes array literal of Derived have type Base[]
class Base { private p; }
class Derived1 extends Base { private m };
class Derived2 extends Base { private n };
var context3: Base[] = [new Derived1(), new Derived2()];

// Contextual type C with numeric index signature of type Base makes array literal of Derived1 and Derived2 have type Base[]
var context4: Base[] = [new Derived1(), new Derived1()];

`,
      [],
    );
  });
  test("arrayLiterals2ES5", async () => {
    await expectPass(
      `// @strict: false
// ElementList:  ( Modified )
//      Elisionopt   AssignmentExpression
//      Elisionopt   SpreadElement
//      ElementList, Elisionopt   AssignmentExpression
//      ElementList, Elisionopt   SpreadElement

// SpreadElement:
//      ...   AssignmentExpression

var a0 = [,, 2, 3, 4]
var a1 = ["hello", "world"]
var a2 = [, , , ...a0, "hello"];
var a3 = [,, ...a0]
var a4 = [() => 1, ];
var a5 = [...a0, , ]

// Each element expression in a non-empty array literal is processed as follows:
//    - If the array literal contains no spread elements, and if the array literal is contextually typed (section 4.19)
//      by a type T and T has a property with the numeric name N, where N is the index of the element expression in the array literal,
//      the element expression is contextually typed by the type of that property.

// The resulting type an array literal expression is determined as follows:
//     - If the array literal contains no spread elements and is contextually typed by a tuple-like type,
//       the resulting type is a tuple type constructed from the types of the element expressions.

var b0: [any, any, any] = [undefined, null, undefined];
var b1: [number[], string[]] = [[1, 2, 3], ["hello", "string"]];

// The resulting type an array literal expression is determined as follows:
//     - If the array literal contains no spread elements and is an array assignment pattern in a destructuring assignment (section 4.17.1),
//       the resulting type is a tuple type constructed from the types of the element expressions.

var [c0, c1] = [1, 2];        // tuple type [number, number]
var [c2, c3] = [1, 2, true];  // tuple type [number, number, boolean]

// The resulting type an array literal expression is determined as follows:
//      - the resulting type is an array type with an element type that is the union of the types of the
//        non - spread element expressions and the numeric index signature types of the spread element expressions
var temp = ["s", "t", "r"];
var temp1 = [1, 2, 3];
var temp2: [number[], string[]] = [[1, 2, 3], ["hello", "string"]];
var temp3 = [undefined, null, undefined];
var temp4 = [];

interface myArray extends Array<Number> { }
interface myArray2 extends Array<Number|String> { }
var d0 = [1, true, ...temp,];  // has type (string|number|boolean)[]
var d1 = [...temp];            // has type string[]
var d2: number[] = [...temp1];
var d3: myArray = [...temp1];
var d4: myArray2 = [...temp, ...temp1];
var d5 = [...temp3];
var d6 = [...temp4];
var d7 = [...[...temp1]];
var d8: number[][] = [[...temp1]]
var d9 = [[...temp1], ...["hello"]];`,
      [],
    );
  });
  test("arrayLiterals2ES6", async () => {
    await expectPass(
      `// @target:es6
// ElementList:  ( Modified )
//      Elisionopt   AssignmentExpression
//      Elisionopt   SpreadElement
//      ElementList, Elisionopt   AssignmentExpression
//      ElementList, Elisionopt   SpreadElement

// SpreadElement:
//      ...   AssignmentExpression

var a0 = [, , 2, 3, 4]
var a1 = ["hello", "world"]
var a2 = [, , , ...a0, "hello"];
var a3 = [, , ...a0]
var a4 = [() => 1, ];
var a5 = [...a0, , ]

// Each element expression in a non-empty array literal is processed as follows:
//    - If the array literal contains no spread elements, and if the array literal is contextually typed (section 4.19)
//      by a type T and T has a property with the numeric name N, where N is the index of the element expression in the array literal,
//      the element expression is contextually typed by the type of that property.

// The resulting type an array literal expression is determined as follows:
//     - If the array literal contains no spread elements and is contextually typed by a tuple-like type,
//       the resulting type is a tuple type constructed from the types of the element expressions.

var b0: [any, any, any] = [undefined, null, undefined];
var b1: [number[], string[]] = [[1, 2, 3], ["hello", "string"]];

// The resulting type an array literal expression is determined as follows:
//     - If the array literal contains no spread elements and is an array assignment pattern in a destructuring assignment (section 4.17.1),
//       the resulting type is a tuple type constructed from the types of the element expressions.

var [c0, c1] = [1, 2];        // tuple type [number, number]
var [c2, c3] = [1, 2, true];  // tuple type [number, number, boolean]

// The resulting type an array literal expression is determined as follows:
//      - the resulting type is an array type with an element type that is the union of the types of the
//        non - spread element expressions and the numeric index signature types of the spread element expressions
var temp = ["s", "t", "r"];
var temp1 = [1, 2, 3];
var temp2: [number[], string[]] = [[1, 2, 3], ["hello", "string"]];

interface myArray extends Array<Number> { }
interface myArray2 extends Array<Number|String> { }
var d0 = [1, true, ...temp, ];  // has type (string|number|boolean)[]
var d1 = [...temp];            // has type string[]
var d2: number[] = [...temp1];
var d3: myArray = [...temp1];
var d4: myArray2 = [...temp, ...temp1];
var d5 = [...a2];
var d6 = [...a3];
var d7 = [...a4];
var d8: number[][] = [[...temp1]]
var d9 = [[...temp1], ...["hello"]];`,
      [],
    );
  });
  test("arrayLiterals3", async () => {
    await expectPass(
      `// @target: es2015
// Each element expression in a non-empty array literal is processed as follows:
//    - If the array literal contains no spread elements, and if the array literal is contextually typed (section 4.19)
//      by a type T and T has a property with the numeric name N, where N is the index of the element expression in the array literal,
//      the element expression is contextually typed by the type of that property.

// The resulting type an array literal expression is determined as follows:
//     - If the array literal contains no spread elements and is contextually typed by a tuple-like type,
//       the resulting type is a tuple type constructed from the types of the element expressions.

var a0: [any, any, any] = [];                             // Error
var a1: [boolean, string, number] = ["string", 1, true];  // Error

// The resulting type an array literal expression is determined as follows:
//     - If the array literal contains no spread elements and is an array assignment pattern in a destructuring assignment (section 4.17.1),
//       the resulting type is a tuple type constructed from the types of the element expressions.

var [b1, b2]: [number, number] = [1, 2, "string", true];

// The resulting type an array literal expression is determined as follows:
//      - the resulting type is an array type with an element type that is the union of the types of the
//        non - spread element expressions and the numeric index signature types of the spread element expressions
var temp = ["s", "t", "r"];
var temp1 = [1, 2, 3];
var temp2: [number[], string[]] = [[1, 2, 3], ["hello", "string"]];

interface tup {
    0: number[]|string[];
    1: number[]|string[];
}
interface myArray extends Array<Number> { }
interface myArray2 extends Array<Number|String> { }
var c0: tup = [...temp2];                         // Error
var c1: [number, number, number] = [...temp1];    // Error cannot assign number[] to [number, number, number]
var c2: myArray = [...temp1, ...temp];            // Error cannot assign (number|string)[] to number[]
`,
      [],
    );
  });
  test("asOpEmitParens", async () => {
    await expectPass(
      `declare var x;
// Must emit as (x + 1) * 3
(x + 1 as number) * 3;

// Should still emit as x.y
(x as any).y;

// Emit as new (x())
new (x() as any);
`,
      [],
    );
  });
  test("asOperator1", async () => {
    await expectPass(
      `var as = 43;
var x = undefined as number;
var y = (null as string).length;
var z = Date as any as string;

// Should parse as a union type, not a bitwise 'or' of (32 as number) and 'string'
var j = 32 as number|string;
j = '';
`,
      [],
    );
  });
  test("asOperator2", async () => {
    await expectPass(
      `var x = 23 as string;
`,
      [],
    );
  });
  test("asOperator3", async () => {
    await expectPass(
      `declare function tag(...x: any[]): any;

var a = \`\${123 + 456 as number}\`;
var b = \`leading \${123 + 456 as number}\`;
var c = \`\${123 + 456 as number} trailing\`;
var d = \`Hello \${123} World\` as string;
var e = \`Hello\` as string;
var f = 1 + \`\${1} end of string\` as string;
var g = tag \`Hello \${123} World\` as string;
var h = tag \`Hello\` as string;`,
      [],
    );
  });
  test("asOperatorAmbiguity", async () => {
    await expectPass(
      `interface A<T> { x: T; }
interface B { m: string; }

// Make sure this is a type assertion to an array type, and not nested comparison operators.
var x: any;
var y = x as A<B>[];
var z = y[0].m; // z should be string

`,
      [],
    );
  });
  test("asOperatorASI", async () => {
    await expectPass(
      `class Foo { }
declare function as(...args: any[]);

// Example 1
var x = 10
as \`Hello world\`; // should not error

// Example 2
var y = 20
as(Foo); // should emit
`,
      [],
    );
  });
  test("asOperatorContextualType", async () => {
    await expectPass(
      `// should error
var x = (v => v) as (x: number) => string;`,
      [],
    );
  });
  test("asOperatorNames", async () => {
    await expectPass(
      `var a = 20;
var b = a as string;
var as = "hello";
var as1 = as as string;
`,
      [],
    );
  });
  test("assignmentGenericLookupTypeNarrowing", async () => {
    await expectPass(
      `// Repro from #26130

let mappedObject: {[K in "foo"]: null | {x: string}} = {foo: {x: "hello"}};
declare function foo<T>(x: T): null | T;

function bar<K extends "foo">(key: K) {
  const element = foo(mappedObject[key]);
  if (element == null)
    return;
  const x = element.x;
}`,
      [],
    );
  });
  test("assignmentLHSIsReference", async () => {
    await expectPass(
      `var value: any;

// identifiers: variable and parameter
var x1: number;
x1 = value;

function fn1(x2: number) {
    x2 = value;
}

// property accesses
var x3: { a: string  };
x3.a = value;
x3['a'] = value;

// parentheses, the contained expression is reference
(x1) = value;

function fn2(x4: number) {
    (x4) = value;
}

(x3.a) = value;
(x3['a']) = value;`,
      [],
    );
  });
  test("assignmentLHSIsValue", async () => {
    await expectError(
      `// expected error for all the LHS of assignments
var value: any;

// this
class C {
    constructor() { this = value; }
    foo() { this = value; }
    static sfoo() { this = value; }
}

function foo() { this = value; }

this = value;

// identifiers: module, class, enum, function
namespace M { export var a; }
M = value;

C = value;

enum E { }
E = value;

foo = value;

// literals
null = value;
true = value;
false = value;
0 = value;
'' = value;
/d+/ = value;

// object literals
{ a: 0} = value;

// array literals
['', ''] = value;

// super
class Derived extends C {
    constructor() { super(); super = value; }

    foo() { super = value }

    static sfoo() { super = value; }
}

// function expression
function bar() { } = value;
() => { } = value;

// function calls
foo() = value;

// parentheses, the containted expression is value
(this) = value;
(M) = value;
(C) = value;
(E) = value;
(foo) = value;
(null) = value;
(true) = value;
(0) = value;
('') = value;
(/d+/) = value;
({}) = value;
([]) = value;
(function baz() { }) = value;
(foo()) = value;`,
      [],
    );
  });
  test("assignmentTypeNarrowing", async () => {
    await expectPass(
      `let x: string | number | boolean | RegExp;

x = "";
x; // string

[x] = [true];
x; // boolean

[x = ""] = [1];
x; // string | number

({x} = {x: true});
x; // boolean

({y: x} = {y: 1});
x; // number

({x = ""} = {x: true});
x; // string | boolean

({y: x = /a/} = {y: 1});
x; // number | RegExp

let a: string[];

for (x of a) {
    x; // string
}

// Repro from #26405

type AOrArrA<T> = T | T[];
const arr: AOrArrA<{x?: "ok"}> = [{ x: "ok" }]; // weak type
arr.push({ x: "ok" });`,
      [],
    );
  });
  test("compoundAdditionAssignmentLHSCanBeAssigned", async () => {
    await expectPass(
      `enum E { a, b }

declare var a: any;
declare var b: void;

declare var x1: any;
x1 += a;
x1 += b;
x1 += true;
x1 += 0;
x1 += '';
x1 += E.a;
x1 += {};
x1 += null;
x1 += undefined;

declare var x2: string;
x2 += a;
x2 += b;
x2 += true;
x2 += 0;
x2 += '';
x2 += E.a;
x2 += {};
x2 += null;
x2 += undefined;

declare var x3: number;
x3 += a;
x3 += 0;
x3 += E.a;
x3 += null;
x3 += undefined;

declare var x4: E;
x4 += a;
x4 += 0;
x4 += E.a;
x4 += null;
x4 += undefined;

declare var x5: boolean;
x5 += a;

declare var x6: {};
x6 += a;
x6 += '';

declare var x7: void;
x7 += a;`,
      [],
    );
  });
  test("compoundAdditionAssignmentLHSCannotBeAssigned", async () => {
    await expectPass(
      `// string can add every type, and result string cannot be assigned to below types
enum E { a, b, c }

declare var x1: boolean;
x1 += '';

declare var x2: number;
x2 += '';

declare var x3: E;
x3 += '';

declare var x4: {a: string};
x4 += '';

declare var x5: void;
x5 += '';`,
      [],
    );
  });
  test("compoundAdditionAssignmentWithInvalidOperands", async () => {
    await expectPass(
      `enum E { a, b }

declare var a: void;

declare var x1: boolean;
x1 += a;
x1 += true;
x1 += 0;
x1 += E.a;
x1 += {};
x1 += null;
x1 += undefined;

declare var x2: {};
x2 += a;
x2 += true;
x2 += 0;
x2 += E.a;
x2 += {};
x2 += null;
x2 += undefined;

declare var x3: void;
x3 += a;
x3 += true;
x3 += 0;
x3 += E.a;
x3 += {};
x3 += null;
x3 += undefined;

declare var x4: number;
x4 += a;
x4 += true;
x4 += {};

declare var x5: E;
x5 += a;
x5 += true;
x5 += {};`,
      [],
    );
  });
  test("compoundArithmeticAssignmentLHSCanBeAssigned", async () => {
    await expectPass(
      `enum E { a, b, c }

declare var a: any;
declare var b: number;
declare var c: E;

declare var x1: any;
x1 *= a;
x1 *= b;
x1 *= c;
x1 *= null;
x1 *= undefined;

declare var x2: number;
x2 *= a;
x2 *= b;
x2 *= c;
x2 *= null;
x2 *= undefined;

declare var x3: E;
x3 *= a;
x3 *= b;
x3 *= c;
x3 *= null;
x3 *= undefined;`,
      [],
    );
  });
  test("compoundArithmeticAssignmentWithInvalidOperands", async () => {
    await expectPass(
      `enum E { a, b }

declare var a: any;
declare var b: void;

declare var x1: boolean;
x1 *= a;
x1 *= b;
x1 *= true;
x1 *= 0;
x1 *= ''
x1 *= E.a;
x1 *= {};
x1 *= null;
x1 *= undefined;

declare var x2: string;
x2 *= a;
x2 *= b;
x2 *= true;
x2 *= 0;
x2 *= ''
x2 *= E.a;
x2 *= {};
x2 *= null;
x2 *= undefined;

declare var x3: {};
x3 *= a;
x3 *= b;
x3 *= true;
x3 *= 0;
x3 *= ''
x3 *= E.a;
x3 *= {};
x3 *= null;
x3 *= undefined;

declare var x4: void;
x4 *= a;
x4 *= b;
x4 *= true;
x4 *= 0;
x4 *= ''
x4 *= E.a;
x4 *= {};
x4 *= null;
x4 *= undefined;

declare var x5: number;
x5 *= b;
x5 *= true;
x5 *= ''
x5 *= {};

declare var x6: E;
x6 *= b;
x6 *= true;
x6 *= ''
x6 *= {};`,
      [],
    );
  });
  test("compoundAssignmentLHSIsReference", async () => {
    await expectPass(
      `var value;

// identifiers: variable and parameter
var x1: number;
x1 *= value;
x1 += value;

function fn1(x2: number) {
    x2 *= value;
    x2 += value;
}

// property accesses
var x3: { a: number };
x3.a *= value;
x3.a += value;

x3['a'] *= value;
x3['a'] += value;

// parentheses, the contained expression is reference
(x1) *= value;
(x1) += value;

function fn2(x4: number) {
    (x4) *= value;
    (x4) += value;
}

(x3.a) *= value;
(x3.a) += value;

(x3['a']) *= value;
(x3['a']) += value;`,
      [],
    );
  });
  test("compoundAssignmentLHSIsValue", async () => {
    await expectError(
      `
// expected error for all the LHS of compound assignments (arithmetic and addition)
var value: any;

// this
class C {
    constructor() {
        this *= value;
        this += value;
    }
    foo() {
        this *= value;
        this += value;
    }
    static sfoo() {
        this *= value;
        this += value;
    }
}

function foo() {
    this *= value;
    this += value;
}

this *= value;
this += value;

// identifiers: module, class, enum, function
namespace M { export var a; }
M *= value;
M += value;

C *= value;
C += value;

enum E { }
E *= value;
E += value;

foo *= value;
foo += value;

// literals
null *= value;
null += value;
true *= value;
true += value;
false *= value;
false += value;
0 *= value;
0 += value;
'' *= value;
'' += value;
/d+/ *= value;
/d+/ += value;

// object literals
{ a: 0} *= value;
{ a: 0} += value;

// array literals
['', ''] *= value;
['', ''] += value;

// super
class Derived extends C {
    constructor() {
        super();
        super *= value;
        super += value;
    }

    foo() {
        super *= value;
        super += value;
    }

    static sfoo() {
        super *= value;
        super += value;
    }
}

// function expression
function bar1() { } *= value;
function bar2() { } += value;
() => { } *= value;
() => { } += value;

// function calls
foo() *= value;
foo() += value;

// parentheses, the containted expression is value
(this) *= value;
(this) += value;
(M) *= value;
(M) += value;
(C) *= value;
(C) += value;
(E) *= value;
(E) += value;
(foo) *= value;
(foo) += value;
(null) *= value;
(null) += value;
(true) *= value;
(true) += value;
(0) *= value;
(0) += value;
('') *= value;
('') += value;
(/d+/) *= value;
(/d+/) += value;
({}) *= value;
({}) += value;
([]) *= value;
([]) += value;
(function baz1() { }) *= value;
(function baz2() { }) += value;
(foo()) *= value;
(foo()) += value;`,
      [],
    );
  });
  test("additionOperatorWithAnyAndEveryType", async () => {
    await expectPass(
      `function foo() { }
class C {
    public a: string;
    static foo() { }
}
enum E { a, b, c }
namespace M { export var a }

var a: any;
var b: boolean;
var c: number;
var d: string;
var e: Object;

// any as left operand, result is type Any except plusing string
var r1 = a + a;
var r2 = a + b;
var r3 = a + c;
var r4 = a + d;
var r5 = a + e;

// any as right operand, result is type Any except plusing string
var r6 = b + a;
var r7 = c + a;
var r8 = d + a;
var r9 = e + a;

// other cases
var r10 = a + foo;
var r11 = a + foo();
var r12 = a + C;
var r13 = a + new C();
var r14 = a + E;
var r15 = a + E.a;
var r16 = a + M;
var r17 = a + '';
var r18 = a + 123;
var r19 = a + { a: '' };
var r20 = a + ((a: string) => { return a });`,
      [],
    );
  });
  test("additionOperatorWithConstrainedTypeParameter", async () => {
    await expectPass(
      `// test for #17069
function sum<T extends Record<K, number>, K extends string>(n: number, v: T, k: K) {
    n = n + v[k];
    n += v[k]; // += should work the same way
}
function realSum<T extends Record<K, number>, K extends string>(n: number, vs: T[], k: K) {
    for (const v of vs) {
        n = n + v[k];
        n += v[k];
    }
}`,
      [],
    );
  });
  test("additionOperatorWithInvalidOperands", async () => {
    await expectPass(
      `function foo() { }
class C {
    public a: string;
    static foo() { }
}
enum E { a, b, c }
namespace M { export var a }

declare var a: boolean;
declare var b: number;
declare var c: Object;
declare var d: Number;

// boolean + every type except any and string
var r1 = a + a;
var r2 = a + b;
var r3 = a + c;

// number + every type except any and string
var r4 = b + a;
var r5 = b + b; // number + number is valid
var r6 = b + c;

// object + every type except any and string
var r7 = c + a;
var r8 = c + b;
var r9 = c + c;

// other cases
var r10 = a + true;
var r11 = true + false;
var r12 = true + 123;
var r13 = {} + {};
var r14 = b + d;
var r15 = b + foo;
var r16 = b + foo();
var r17 = b + C;
var r18 = E.a + new C();
var r19 = E.a + C.foo();
var r20 = E.a + M;`,
      [],
    );
  });
  test("additionOperatorWithNullValueAndInvalidOperator", async () => {
    await expectPass(
      `// If one operand is the null or undefined value, it is treated as having the type of the other operand.

function foo(): void { return undefined }

declare var a: boolean;
declare var b: Object;
declare var c: void;
declare var d: Number;

// null + boolean/Object
var r1 = null + a;
var r2 = null + b;
var r3 = null + c;
var r4 = a + null;
var r5 = b + null;
var r6 = null + c;

// other cases
var r7 = null + d;
var r8 = null + true;
var r9 = null + { a: '' };
var r10 = null + foo();
var r11 = null + (() => { });`,
      [],
    );
  });
  test("additionOperatorWithNullValueAndValidOperator", async () => {
    await expectPass(
      `// If one operand is the null or undefined value, it is treated as having the type of the other operand.

enum E { a, b, c }

declare var a: any;
declare var b: number;
declare var c: E;
declare var d: string;

// null + any
var r1: any = null + a;
var r2: any = a + null;

// null + number/enum
var r3 = null + b;
var r4 = null + 1;
var r5 = null + c;
var r6 = null + E.a;
var r7 = null + E['a'];
var r8 = b + null;
var r9 = 1 + null;
var r10 = c + null
var r11 = E.a + null;
var r12 = E['a'] + null;

// null + string
var r13 = null + d;
var r14 = null + '';
var r15 = d + null;
var r16 = '' + null;`,
      [],
    );
  });
  test("additionOperatorWithNumberAndEnum", async () => {
    await expectPass(
      `enum E { a, b }
enum F { c, d }

var a: number;
var b: E;
var c: E | F;

var r1 = a + a;
var r2 = a + b;
var r3 = b + a;
var r4 = b + b;

var r5 = 0 + a;
var r6 = E.a + 0;
var r7 = E.a + E.b;
var r8 = E['a'] + E['b'];
var r9 = E['a'] + F['c'];

var r10 = a + c;
var r11 = c + a;
var r12 = b + c;
var r13 = c + b;
var r14 = c + c;`,
      [],
    );
  });
  test("additionOperatorWithOnlyNullValueOrUndefinedValue", async () => {
    await expectPass(
      `// bug 819721
var r1 = null + null;
var r2 = null + undefined;
var r3 = undefined + null;
var r4 = undefined + undefined;`,
      [],
    );
  });
  test("additionOperatorWithStringAndEveryType", async () => {
    await expectPass(
      `enum E { a, b, c }

var a: any;
var b: boolean;
var c: number;
var d: string;
var e: Object;
var f: void;
var g: E;

var x: string;

// string could plus every type, and the result is always string
// string as left operand
var r1 = x + a;
var r2 = x + b;
var r3 = x + c;
var r4 = x + d;
var r5 = x + e;
var r6 = x + f;
var r7 = x + g;

// string as right operand
var r8 = a + x;
var r9 = b + x;
var r10 = c + x;
var r11 = d + x;
var r12 = e + x;
var r13 = f + x;
var r14 = g + x;

// other cases
var r15 = x + E;
var r16 = x + E.a;
var r17 = x + '';
var r18 = x + 0;
var r19 = x + { a: '' };
var r20 = x + [];`,
      [],
    );
  });
  test("additionOperatorWithTypeParameter", async () => {
    await expectPass(
      `// type parameter type is not a valid operand of addition operator
enum E { a, b }

function foo<T, U>(t: T, u: U) {
    let a!: any;
    let b!: boolean;
    let c!: number;
    let d!: string;
    let e!: Object;
    let g!: E;
    let f!: void;

    // type parameter as left operand
    var r1: any = t + a; // ok, one operand is any
    var r2 = t + b;
    var r3 = t + c;
    var r4 = t + d; // ok, one operand is string
    var r5 = t + e;
    var r6 = t + g;
    var r7 = t + f;

    // type parameter as right operand
    var r8 = a + t; // ok, one operand is any
    var r9 = b + t;
    var r10 = c + t;
    var r11 = d + t; // ok, one operand is string
    var r12 = e + t;
    var r13 = g + t;
    var r14 = f + t;

    // other cases
    var r15 = t + null;
    var r16 = t + undefined;
    var r17 = t + t;
    var r18 = t + u;
    var r19 = t + (() => { });
    var r20 = t + [];
}`,
      [],
    );
  });
  test("additionOperatorWithUndefinedValueAndInvalidOperands", async () => {
    await expectPass(
      `// If one operand is the null or undefined value, it is treated as having the type of the other operand.

function foo(): void { return undefined }

declare var a: boolean;
declare var b: Object;
declare var c: void;
declare var d: Number;

// undefined + boolean/Object
var r1 = undefined + a;
var r2 = undefined + b;
var r3 = undefined + c;
var r4 = a + undefined;
var r5 = b + undefined;
var r6 = undefined + c;

// other cases
var r7 = undefined + d;
var r8 = undefined + true;
var r9 = undefined + { a: '' };
var r10 = undefined + foo();
var r11 = undefined + (() => { });`,
      [],
    );
  });
  test("additionOperatorWithUndefinedValueAndValidOperator", async () => {
    await expectPass(
      `// If one operand is the null or undefined value, it is treated as having the type of the other operand.

enum E { a, b, c }

declare var a: any;
declare var b: number;
declare var c: E;
declare var d: string;

// undefined + any
var r1: any = undefined + a;
var r2: any = a + undefined;

// undefined + number/enum
var r3 = undefined + b;
var r4 = undefined + 1;
var r5 = undefined + c;
var r6 = undefined + E.a;
var r7 = undefined + E['a'];
var r8 = b + undefined;
var r9 = 1 + undefined;
var r10 = c + undefined
var r11 = E.a + undefined;
var r12 = E['a'] + undefined;

// undefined + string
var r13 = undefined + d;
var r14 = undefined + '';
var r15 = d + undefined;
var r16 = '' + undefined;`,
      [],
    );
  });
  test("arithmeticOperatorWithAnyAndNumber", async () => {
    await expectPass(
      `var a: any;
var b: number;

// operator *
var ra1 = a * a;
var ra2 = a * b;
var ra3 = a * 0;
var ra4 = 0 * a;
var ra5 = 0 * 0;
var ra6 = b * 0;
var ra7 = 0 * b;
var ra8 = b * b;

// operator /
var rb1 = a / a;
var rb2 = a / b;
var rb3 = a / 0;
var rb4 = 0 / a;
var rb5 = 0 / 0;
var rb6 = b / 0;
var rb7 = 0 / b;
var rb8 = b / b;

// operator %
var rc1 = a % a;
var rc2 = a % b;
var rc3 = a % 0;
var rc4 = 0 % a;
var rc5 = 0 % 0;
var rc6 = b % 0;
var rc7 = 0 % b;
var rc8 = b % b;

// operator -
var rd1 = a - a;
var rd2 = a - b;
var rd3 = a - 0;
var rd4 = 0 - a;
var rd5 = 0 - 0;
var rd6 = b - 0;
var rd7 = 0 - b;
var rd8 = b - b;

// operator <<
var re1 = a << a;
var re2 = a << b;
var re3 = a << 0;
var re4 = 0 << a;
var re5 = 0 << 0;
var re6 = b << 0;
var re7 = 0 << b;
var re8 = b << b;

// operator >>
var rf1 = a >> a;
var rf2 = a >> b;
var rf3 = a >> 0;
var rf4 = 0 >> a;
var rf5 = 0 >> 0;
var rf6 = b >> 0;
var rf7 = 0 >> b;
var rf8 = b >> b;

// operator >>>
var rg1 = a >>> a;
var rg2 = a >>> b;
var rg3 = a >>> 0;
var rg4 = 0 >>> a;
var rg5 = 0 >>> 0;
var rg6 = b >>> 0;
var rg7 = 0 >>> b;
var rg8 = b >>> b;

// operator &
var rh1 = a & a;
var rh2 = a & b;
var rh3 = a & 0;
var rh4 = 0 & a;
var rh5 = 0 & 0;
var rh6 = b & 0;
var rh7 = 0 & b;
var rh8 = b & b;

// operator ^
var ri1 = a ^ a;
var ri2 = a ^ b;
var ri3 = a ^ 0;
var ri4 = 0 ^ a;
var ri5 = 0 ^ 0;
var ri6 = b ^ 0;
var ri7 = 0 ^ b;
var ri8 = b ^ b;

// operator |
var rj1 = a | a;
var rj2 = a | b;
var rj3 = a | 0;
var rj4 = 0 | a;
var rj5 = 0 | 0;
var rj6 = b | 0;
var rj7 = 0 | b;
var rj8 = b | b;`,
      [],
    );
  });
  test("arithmeticOperatorWithEnum", async () => {
    await expectPass(
      `// operands of an enum type are treated as having the primitive type Number.

enum E {
    a,
    b
}

var a: any;
var b: number;
var c: E;

// operator *
var ra1 = c * a;
var ra2 = c * b;
var ra3 = c * c;
var ra4 = a * c;
var ra5 = b * c;
var ra6 = E.a * a;
var ra7 = E.a * b;
var ra8 = E.a * E.b;
var ra9 = E.a * 1;
var ra10 = a * E.b;
var ra11 = b * E.b;
var ra12 = 1 * E.b;

// operator /
var rb1 = c / a;
var rb2 = c / b;
var rb3 = c / c;
var rb4 = a / c;
var rb5 = b / c;
var rb6 = E.a / a;
var rb7 = E.a / b;
var rb8 = E.a / E.b;
var rb9 = E.a / 1;
var rb10 = a / E.b;
var rb11 = b / E.b;
var rb12 = 1 / E.b;

// operator %
var rc1 = c % a;
var rc2 = c % b;
var rc3 = c % c;
var rc4 = a % c;
var rc5 = b % c;
var rc6 = E.a % a;
var rc7 = E.a % b;
var rc8 = E.a % E.b;
var rc9 = E.a % 1;
var rc10 = a % E.b;
var rc11 = b % E.b;
var rc12 = 1 % E.b;

// operator -
var rd1 = c - a;
var rd2 = c - b;
var rd3 = c - c;
var rd4 = a - c;
var rd5 = b - c;
var rd6 = E.a - a;
var rd7 = E.a - b;
var rd8 = E.a - E.b;
var rd9 = E.a - 1;
var rd10 = a - E.b;
var rd11 = b - E.b;
var rd12 = 1 - E.b;

// operator <<
var re1 = c << a;
var re2 = c << b;
var re3 = c << c;
var re4 = a << c;
var re5 = b << c;
var re6 = E.a << a;
var re7 = E.a << b;
var re8 = E.a << E.b;
var re9 = E.a << 1;
var re10 = a << E.b;
var re11 = b << E.b;
var re12 = 1 << E.b;

// operator >>
var rf1 = c >> a;
var rf2 = c >> b;
var rf3 = c >> c;
var rf4 = a >> c;
var rf5 = b >> c;
var rf6 = E.a >> a;
var rf7 = E.a >> b;
var rf8 = E.a >> E.b;
var rf9 = E.a >> 1;
var rf10 = a >> E.b;
var rf11 = b >> E.b;
var rf12 = 1 >> E.b;

// operator >>>
var rg1 = c >>> a;
var rg2 = c >>> b;
var rg3 = c >>> c;
var rg4 = a >>> c;
var rg5 = b >>> c;
var rg6 = E.a >>> a;
var rg7 = E.a >>> b;
var rg8 = E.a >>> E.b;
var rg9 = E.a >>> 1;
var rg10 = a >>> E.b;
var rg11 = b >>> E.b;
var rg12 = 1 >>> E.b;

// operator &
var rh1 = c & a;
var rh2 = c & b;
var rh3 = c & c;
var rh4 = a & c;
var rh5 = b & c;
var rh6 = E.a & a;
var rh7 = E.a & b;
var rh8 = E.a & E.b;
var rh9 = E.a & 1;
var rh10 = a & E.b;
var rh11 = b & E.b;
var rh12 = 1 & E.b;

// operator ^
var ri1 = c ^ a;
var ri2 = c ^ b;
var ri3 = c ^ c;
var ri4 = a ^ c;
var ri5 = b ^ c;
var ri6 = E.a ^ a;
var ri7 = E.a ^ b;
var ri8 = E.a ^ E.b;
var ri9 = E.a ^ 1;
var ri10 = a ^ E.b;
var ri11 = b ^ E.b;
var ri12 = 1 ^ E.b;

// operator |
var rj1 = c | a;
var rj2 = c | b;
var rj3 = c | c;
var rj4 = a | c;
var rj5 = b | c;
var rj6 = E.a | a;
var rj7 = E.a | b;
var rj8 = E.a | E.b;
var rj9 = E.a | 1;
var rj10 = a | E.b;
var rj11 = b | E.b;
var rj12 = 1 | E.b;`,
      [],
    );
  });
  test("arithmeticOperatorWithEnumUnion", async () => {
    await expectPass(
      `// operands of an enum type are treated as having the primitive type Number.

enum E {
    a,
    b
}
enum F {
    c,
    d
}

var a: any;
var b: number;
var c: E | F;

// operator *
var ra1 = c * a;
var ra2 = c * b;
var ra3 = c * c;
var ra4 = a * c;
var ra5 = b * c;
var ra6 = E.a * a;
var ra7 = E.a * b;
var ra8 = E.a * E.b;
var ra9 = E.a * 1;
var ra10 = a * E.b;
var ra11 = b * E.b;
var ra12 = 1 * E.b;

// operator /
var rb1 = c / a;
var rb2 = c / b;
var rb3 = c / c;
var rb4 = a / c;
var rb5 = b / c;
var rb6 = E.a / a;
var rb7 = E.a / b;
var rb8 = E.a / E.b;
var rb9 = E.a / 1;
var rb10 = a / E.b;
var rb11 = b / E.b;
var rb12 = 1 / E.b;

// operator %
var rc1 = c % a;
var rc2 = c % b;
var rc3 = c % c;
var rc4 = a % c;
var rc5 = b % c;
var rc6 = E.a % a;
var rc7 = E.a % b;
var rc8 = E.a % E.b;
var rc9 = E.a % 1;
var rc10 = a % E.b;
var rc11 = b % E.b;
var rc12 = 1 % E.b;

// operator -
var rd1 = c - a;
var rd2 = c - b;
var rd3 = c - c;
var rd4 = a - c;
var rd5 = b - c;
var rd6 = E.a - a;
var rd7 = E.a - b;
var rd8 = E.a - E.b;
var rd9 = E.a - 1;
var rd10 = a - E.b;
var rd11 = b - E.b;
var rd12 = 1 - E.b;

// operator <<
var re1 = c << a;
var re2 = c << b;
var re3 = c << c;
var re4 = a << c;
var re5 = b << c;
var re6 = E.a << a;
var re7 = E.a << b;
var re8 = E.a << E.b;
var re9 = E.a << 1;
var re10 = a << E.b;
var re11 = b << E.b;
var re12 = 1 << E.b;

// operator >>
var rf1 = c >> a;
var rf2 = c >> b;
var rf3 = c >> c;
var rf4 = a >> c;
var rf5 = b >> c;
var rf6 = E.a >> a;
var rf7 = E.a >> b;
var rf8 = E.a >> E.b;
var rf9 = E.a >> 1;
var rf10 = a >> E.b;
var rf11 = b >> E.b;
var rf12 = 1 >> E.b;

// operator >>>
var rg1 = c >>> a;
var rg2 = c >>> b;
var rg3 = c >>> c;
var rg4 = a >>> c;
var rg5 = b >>> c;
var rg6 = E.a >>> a;
var rg7 = E.a >>> b;
var rg8 = E.a >>> E.b;
var rg9 = E.a >>> 1;
var rg10 = a >>> E.b;
var rg11 = b >>> E.b;
var rg12 = 1 >>> E.b;

// operator &
var rh1 = c & a;
var rh2 = c & b;
var rh3 = c & c;
var rh4 = a & c;
var rh5 = b & c;
var rh6 = E.a & a;
var rh7 = E.a & b;
var rh8 = E.a & E.b;
var rh9 = E.a & 1;
var rh10 = a & E.b;
var rh11 = b & E.b;
var rh12 = 1 & E.b;

// operator ^
var ri1 = c ^ a;
var ri2 = c ^ b;
var ri3 = c ^ c;
var ri4 = a ^ c;
var ri5 = b ^ c;
var ri6 = E.a ^ a;
var ri7 = E.a ^ b;
var ri8 = E.a ^ E.b;
var ri9 = E.a ^ 1;
var ri10 = a ^ E.b;
var ri11 = b ^ E.b;
var ri12 = 1 ^ E.b;

// operator |
var rj1 = c | a;
var rj2 = c | b;
var rj3 = c | c;
var rj4 = a | c;
var rj5 = b | c;
var rj6 = E.a | a;
var rj7 = E.a | b;
var rj8 = E.a | E.b;
var rj9 = E.a | 1;
var rj10 = a | E.b;
var rj11 = b | E.b;
var rj12 = 1 | E.b;`,
      [],
    );
  });
  test("arithmeticOperatorWithInvalidOperands", async () => {
    await expectPass(
      `// these operators require their operands to be of type Any, the Number primitive type, or
// an enum type
enum E { a, b, c }

declare var a: any;
declare var b: boolean;
declare var c: number;
declare var d: string;
declare var e: { a: number };
declare var f: Number;

// All of the below should be an error unless otherwise noted
// operator *
var r1a1 = a * a; //ok
var r1a2 = a * b;
var r1a3 = a * c; //ok
var r1a4 = a * d;
var r1a5 = a * e;
var r1a6 = a * f;

var r1b1 = b * a;
var r1b2 = b * b;
var r1b3 = b * c;
var r1b4 = b * d;
var r1b5 = b * e;
var r1b6 = b * f;

var r1c1 = c * a; //ok
var r1c2 = c * b;
var r1c3 = c * c; //ok
var r1c4 = c * d;
var r1c5 = c * e;
var r1c6 = c * f;

var r1d1 = d * a;
var r1d2 = d * b;
var r1d3 = d * c;
var r1d4 = d * d;
var r1d5 = d * e;
var r1d6 = d * f;

var r1e1 = e * a;
var r1e2 = e * b;
var r1e3 = e * c;
var r1e4 = e * d;
var r1e5 = e * e;
var r1e6 = e * f;

var r1f1 = f * a;
var r1f2 = f * b;
var r1f3 = f * c;
var r1f4 = f * d;
var r1f5 = f * e;
var r1f6 = f * f;

var r1g1 = E.a * a; //ok
var r1g2 = E.a * b;
var r1g3 = E.a * c; //ok
var r1g4 = E.a * d;
var r1g5 = E.a * e;
var r1g6 = E.a * f;

var r1h1 = a * E.b; //ok
var r1h2 = b * E.b;
var r1h3 = c * E.b; //ok
var r1h4 = d * E.b;
var r1h5 = e * E.b;
var r1h6 = f * E.b;

// operator /
var r2a1 = a / a; //ok
var r2a2 = a / b;
var r2a3 = a / c; //ok
var r2a4 = a / d;
var r2a5 = a / e;
var r2a6 = a / f;

var r2b1 = b / a;
var r2b2 = b / b;
var r2b3 = b / c;
var r2b4 = b / d;
var r2b5 = b / e;
var r2b6 = b / f;

var r2c1 = c / a; //ok
var r2c2 = c / b;
var r2c3 = c / c; //ok
var r2c4 = c / d;
var r2c5 = c / e;
var r2c6 = c / f;

var r2d1 = d / a;
var r2d2 = d / b;
var r2d3 = d / c;
var r2d4 = d / d;
var r2d5 = d / e;
var r2d6 = d / f;

var r2e1 = e / a;
var r2e2 = e / b;
var r2e3 = e / c;
var r2e4 = e / d;
var r2e5 = e / e;
var r2e6 = e / f;

var r2f1 = f / a;
var r2f2 = f / b;
var r2f3 = f / c;
var r2f4 = f / d;
var r2f5 = f / e;
var r2f6 = f / f;

var r2g1 = E.a / a; //ok
var r2g2 = E.a / b;
var r2g3 = E.a / c; //ok
var r2g4 = E.a / d;
var r2g5 = E.a / e;
var r2g6 = E.a / f;

var r2h1 = a / E.b; //ok
var r2h2 = b / E.b;
var r2h3 = c / E.b; //ok
var r2h4 = d / E.b;
var r2h5 = e / E.b;
var r2h6 = f / E.b;

// operator %
var r3a1 = a % a; //ok
var r3a2 = a % b;
var r3a3 = a % c; //ok
var r3a4 = a % d;
var r3a5 = a % e;
var r3a6 = a % f;

var r3b1 = b % a;
var r3b2 = b % b;
var r3b3 = b % c;
var r3b4 = b % d;
var r3b5 = b % e;
var r3b6 = b % f;

var r3c1 = c % a; //ok
var r3c2 = c % b;
var r3c3 = c % c; //ok
var r3c4 = c % d;
var r3c5 = c % e;
var r3c6 = c % f;

var r3d1 = d % a;
var r3d2 = d % b;
var r3d3 = d % c;
var r3d4 = d % d;
var r3d5 = d % e;
var r3d6 = d % f;

var r3e1 = e % a;
var r3e2 = e % b;
var r3e3 = e % c;
var r3e4 = e % d;
var r3e5 = e % e;
var r3e6 = e % f;

var r3f1 = f % a;
var r3f2 = f % b;
var r3f3 = f % c;
var r3f4 = f % d;
var r3f5 = f % e;
var r3f6 = f % f;

var r3g1 = E.a % a; //ok
var r3g2 = E.a % b;
var r3g3 = E.a % c; //ok
var r3g4 = E.a % d;
var r3g5 = E.a % e;
var r3g6 = E.a % f;

var r3h1 = a % E.b; //ok
var r3h2 = b % E.b;
var r3h3 = c % E.b; //ok
var r3h4 = d % E.b;
var r3h5 = e % E.b;
var r3h6 = f % E.b;

// operator -
var r4a1 = a - a; //ok
var r4a2 = a - b;
var r4a3 = a - c; //ok
var r4a4 = a - d;
var r4a5 = a - e;
var r4a6 = a - f;

var r4b1 = b - a;
var r4b2 = b - b;
var r4b3 = b - c;
var r4b4 = b - d;
var r4b5 = b - e;
var r4b6 = b - f;

var r4c1 = c - a; //ok
var r4c2 = c - b;
var r4c3 = c - c; //ok
var r4c4 = c - d;
var r4c5 = c - e;
var r4c6 = c - f;

var r4d1 = d - a;
var r4d2 = d - b;
var r4d3 = d - c;
var r4d4 = d - d;
var r4d5 = d - e;
var r4d6 = d - f;

var r4e1 = e - a;
var r4e2 = e - b;
var r4e3 = e - c;
var r4e4 = e - d;
var r4e5 = e - e;
var r4e6 = e - f;

var r4f1 = f - a;
var r4f2 = f - b;
var r4f3 = f - c;
var r4f4 = f - d;
var r4f5 = f - e;
var r4f6 = f - f;

var r4g1 = E.a - a; //ok
var r4g2 = E.a - b;
var r4g3 = E.a - c; //ok
var r4g4 = E.a - d;
var r4g5 = E.a - e;
var r4g6 = E.a - f;

var r4h1 = a - E.b; //ok
var r4h2 = b - E.b;
var r4h3 = c - E.b; //ok
var r4h4 = d - E.b;
var r4h5 = e - E.b;
var r4h6 = f - E.b;

// operator <<
var r5a1 = a << a; //ok
var r5a2 = a << b;
var r5a3 = a << c; //ok
var r5a4 = a << d;
var r5a5 = a << e;
var r5a6 = a << f;

var r5b1 = b << a;
var r5b2 = b << b;
var r5b3 = b << c;
var r5b4 = b << d;
var r5b5 = b << e;
var r5b6 = b << f;

var r5c1 = c << a; //ok
var r5c2 = c << b;
var r5c3 = c << c; //ok
var r5c4 = c << d;
var r5c5 = c << e;
var r5c6 = c << f;

var r5d1 = d << a;
var r5d2 = d << b;
var r5d3 = d << c;
var r5d4 = d << d;
var r5d5 = d << e;
var r5d6 = d << f;

var r5e1 = e << a;
var r5e2 = e << b;
var r5e3 = e << c;
var r5e4 = e << d;
var r5e5 = e << e;
var r5e6 = e << f;

var r5f1 = f << a;
var r5f2 = f << b;
var r5f3 = f << c;
var r5f4 = f << d;
var r5f5 = f << e;
var r5f6 = f << f;

var r5g1 = E.a << a; //ok
var r5g2 = E.a << b;
var r5g3 = E.a << c; //ok
var r5g4 = E.a << d;
var r5g5 = E.a << e;
var r5g6 = E.a << f;

var r5h1 = a << E.b; //ok
var r5h2 = b << E.b;
var r5h3 = c << E.b; //ok
var r5h4 = d << E.b;
var r5h5 = e << E.b;
var r5h6 = f << E.b;

// operator >>
var r6a1 = a >> a; //ok
var r6a2 = a >> b;
var r6a3 = a >> c; //ok
var r6a4 = a >> d;
var r6a5 = a >> e;
var r6a6 = a >> f;

var r6b1 = b >> a;
var r6b2 = b >> b;
var r6b3 = b >> c;
var r6b4 = b >> d;
var r6b5 = b >> e;
var r6b6 = b >> f;

var r6c1 = c >> a; //ok
var r6c2 = c >> b;
var r6c3 = c >> c; //ok
var r6c4 = c >> d;
var r6c5 = c >> e;
var r6c6 = c >> f;

var r6d1 = d >> a;
var r6d2 = d >> b;
var r6d3 = d >> c;
var r6d4 = d >> d;
var r6d5 = d >> e;
var r6d6 = d >> f;

var r6e1 = e >> a;
var r6e2 = e >> b;
var r6e3 = e >> c;
var r6e4 = e >> d;
var r6e5 = e >> e;
var r6e6 = e >> f;

var r6f1 = f >> a;
var r6f2 = f >> b;
var r6f3 = f >> c;
var r6f4 = f >> d;
var r6f5 = f >> e;
var r6f6 = f >> f;

var r6g1 = E.a >> a; //ok
var r6g2 = E.a >> b;
var r6g3 = E.a >> c; //ok
var r6g4 = E.a >> d;
var r6g5 = E.a >> e;
var r6g6 = E.a >> f;

var r6h1 = a >> E.b; //ok
var r6h2 = b >> E.b;
var r6h3 = c >> E.b; //ok
var r6h4 = d >> E.b;
var r6h5 = e >> E.b;
var r6h6 = f >> E.b;

// operator >>>
var r7a1 = a >>> a; //ok
var r7a2 = a >>> b;
var r7a3 = a >>> c; //ok
var r7a4 = a >>> d;
var r7a5 = a >>> e;
var r7a6 = a >>> f;

var r7b1 = b >>> a;
var r7b2 = b >>> b;
var r7b3 = b >>> c;
var r7b4 = b >>> d;
var r7b5 = b >>> e;
var r7b6 = b >>> f;

var r7c1 = c >>> a; //ok
var r7c2 = c >>> b;
var r7c3 = c >>> c; //ok
var r7c4 = c >>> d;
var r7c5 = c >>> e;
var r7c6 = c >>> f;

var r7d1 = d >>> a;
var r7d2 = d >>> b;
var r7d3 = d >>> c;
var r7d4 = d >>> d;
var r7d5 = d >>> e;
var r7d6 = d >>> f;

var r7e1 = e >>> a;
var r7e2 = e >>> b;
var r7e3 = e >>> c;
var r7e4 = e >>> d;
var r7e5 = e >>> e;
var r7e6 = e >>> f;

var r7f1 = f >>> a;
var r7f2 = f >>> b;
var r7f3 = f >>> c;
var r7f4 = f >>> d;
var r7f5 = f >>> e;
var r7f6 = f >>> f;

var r7g1 = E.a >>> a; //ok
var r7g2 = E.a >>> b;
var r7g3 = E.a >>> c; //ok
var r7g4 = E.a >>> d;
var r7g5 = E.a >>> e;
var r7g6 = E.a >>> f;

var r7h1 = a >>> E.b; //ok
var r7h2 = b >>> E.b;
var r7h3 = c >>> E.b; //ok
var r7h4 = d >>> E.b;
var r7h5 = e >>> E.b;
var r7h6 = f >>> E.b;

// operator &
var r8a1 = a & a; //ok
var r8a2 = a & b;
var r8a3 = a & c; //ok
var r8a4 = a & d;
var r8a5 = a & e;
var r8a6 = a & f;

var r8b1 = b & a;
var r8b2 = b & b;
var r8b3 = b & c;
var r8b4 = b & d;
var r8b5 = b & e;
var r8b6 = b & f;

var r8c1 = c & a; //ok
var r8c2 = c & b;
var r8c3 = c & c; //ok
var r8c4 = c & d;
var r8c5 = c & e;
var r8c6 = c & f;

var r8d1 = d & a;
var r8d2 = d & b;
var r8d3 = d & c;
var r8d4 = d & d;
var r8d5 = d & e;
var r8d6 = d & f;

var r8e1 = e & a;
var r8e2 = e & b;
var r8e3 = e & c;
var r8e4 = e & d;
var r8e5 = e & e;
var r8e6 = e & f;

var r8f1 = f & a;
var r8f2 = f & b;
var r8f3 = f & c;
var r8f4 = f & d;
var r8f5 = f & e;
var r8f6 = f & f;

var r8g1 = E.a & a; //ok
var r8g2 = E.a & b;
var r8g3 = E.a & c; //ok
var r8g4 = E.a & d;
var r8g5 = E.a & e;
var r8g6 = E.a & f;

var r8h1 = a & E.b; //ok
var r8h2 = b & E.b;
var r8h3 = c & E.b; //ok
var r8h4 = d & E.b;
var r8h5 = e & E.b;
var r8h6 = f & E.b;

// operator ^
var r9a1 = a ^ a; //ok
var r9a2 = a ^ b;
var r9a3 = a ^ c; //ok
var r9a4 = a ^ d;
var r9a5 = a ^ e;
var r9a6 = a ^ f;

var r9b1 = b ^ a;
var r9b2 = b ^ b;
var r9b3 = b ^ c;
var r9b4 = b ^ d;
var r9b5 = b ^ e;
var r9b6 = b ^ f;

var r9c1 = c ^ a; //ok
var r9c2 = c ^ b;
var r9c3 = c ^ c; //ok
var r9c4 = c ^ d;
var r9c5 = c ^ e;
var r9c6 = c ^ f;

var r9d1 = d ^ a;
var r9d2 = d ^ b;
var r9d3 = d ^ c;
var r9d4 = d ^ d;
var r9d5 = d ^ e;
var r9d6 = d ^ f;

var r9e1 = e ^ a;
var r9e2 = e ^ b;
var r9e3 = e ^ c;
var r9e4 = e ^ d;
var r9e5 = e ^ e;
var r9e6 = e ^ f;

var r9f1 = f ^ a;
var r9f2 = f ^ b;
var r9f3 = f ^ c;
var r9f4 = f ^ d;
var r9f5 = f ^ e;
var r9f6 = f ^ f;

var r9g1 = E.a ^ a; //ok
var r9g2 = E.a ^ b;
var r9g3 = E.a ^ c; //ok
var r9g4 = E.a ^ d;
var r9g5 = E.a ^ e;
var r9g6 = E.a ^ f;

var r9h1 = a ^ E.b; //ok
var r9h2 = b ^ E.b;
var r9h3 = c ^ E.b; //ok
var r9h4 = d ^ E.b;
var r9h5 = e ^ E.b;
var r9h6 = f ^ E.b;

// operator |
var r10a1 = a | a; //ok
var r10a2 = a | b;
var r10a3 = a | c; //ok
var r10a4 = a | d;
var r10a5 = a | e;
var r10a6 = a | f;

var r10b1 = b | a;
var r10b2 = b | b;
var r10b3 = b | c;
var r10b4 = b | d;
var r10b5 = b | e;
var r10b6 = b | f;

var r10c1 = c | a; //ok
var r10c2 = c | b;
var r10c3 = c | c; //ok
var r10c4 = c | d;
var r10c5 = c | e;
var r10c6 = c | f;

var r10d1 = d | a;
var r10d2 = d | b;
var r10d3 = d | c;
var r10d4 = d | d;
var r10d5 = d | e;
var r10d6 = d | f;

var r10e1 = e | a;
var r10e2 = e | b;
var r10e3 = e | c;
var r10e4 = e | d;
var r10e5 = e | e;
var r10e6 = e | f;

var r10f1 = f | a;
var r10f2 = f | b;
var r10f3 = f | c;
var r10f4 = f | d;
var r10f5 = f | e;
var r10f6 = f | f;

var r10g1 = E.a | a; //ok
var r10g2 = E.a | b;
var r10g3 = E.a | c; //ok
var r10g4 = E.a | d;
var r10g5 = E.a | e;
var r10g6 = E.a | f;

var r10h1 = a | E.b; //ok
var r10h2 = b | E.b;
var r10h3 = c | E.b; //ok
var r10h4 = d | E.b;
var r10h5 = e | E.b;
var r10h6 = f | E.b;`,
      [],
    );
  });
  test("arithmeticOperatorWithNullValueAndInvalidOperands", async () => {
    await expectPass(
      `// If one operand is the null or undefined value, it is treated as having the type of the
// other operand.

declare var a: boolean;
declare var b: string;
declare var c: Object;

// operator *
var r1a1 = null * a;
var r1a2 = null * b;
var r1a3 = null * c;

var r1b1 = a * null;
var r1b2 = b * null;
var r1b3 = c * null;

var r1c1 = null * true;
var r1c2 = null * '';
var r1c3 = null * {};

var r1d1 = true * null;
var r1d2 = '' * null;
var r1d3 = {} * null;

// operator /
var r2a1 = null / a;
var r2a2 = null / b;
var r2a3 = null / c;

var r2b1 = a / null;
var r2b2 = b / null;
var r2b3 = c / null;

var r2c1 = null / true;
var r2c2 = null / '';
var r2c3 = null / {};

var r2d1 = true / null;
var r2d2 = '' / null;
var r2d3 = {} / null;

// operator %
var r3a1 = null % a;
var r3a2 = null % b;
var r3a3 = null % c;

var r3b1 = a % null;
var r3b2 = b % null;
var r3b3 = c % null;

var r3c1 = null % true;
var r3c2 = null % '';
var r3c3 = null % {};

var r3d1 = true % null;
var r3d2 = '' % null;
var r3d3 = {} % null;

// operator -
var r4a1 = null - a;
var r4a2 = null - b;
var r4a3 = null - c;

var r4b1 = a - null;
var r4b2 = b - null;
var r4b3 = c - null;

var r4c1 = null - true;
var r4c2 = null - '';
var r4c3 = null - {};

var r4d1 = true - null;
var r4d2 = '' - null;
var r4d3 = {} - null;

// operator <<
var r5a1 = null << a;
var r5a2 = null << b;
var r5a3 = null << c;

var r5b1 = a << null;
var r5b2 = b << null;
var r5b3 = c << null;

var r5c1 = null << true;
var r5c2 = null << '';
var r5c3 = null << {};

var r5d1 = true << null;
var r5d2 = '' << null;
var r5d3 = {} << null;

// operator >>
var r6a1 = null >> a;
var r6a2 = null >> b;
var r6a3 = null >> c;

var r6b1 = a >> null;
var r6b2 = b >> null;
var r6b3 = c >> null;

var r6c1 = null >> true;
var r6c2 = null >> '';
var r6c3 = null >> {};

var r6d1 = true >> null;
var r6d2 = '' >> null;
var r6d3 = {} >> null;

// operator >>>
var r7a1 = null >>> a;
var r7a2 = null >>> b;
var r7a3 = null >>> c;

var r7b1 = a >>> null;
var r7b2 = b >>> null;
var r7b3 = c >>> null;

var r7c1 = null >>> true;
var r7c2 = null >>> '';
var r7c3 = null >>> {};

var r7d1 = true >>> null;
var r7d2 = '' >>> null;
var r7d3 = {} >>> null;

// operator &
var r8a1 = null & a;
var r8a2 = null & b;
var r8a3 = null & c;

var r8b1 = a & null;
var r8b2 = b & null;
var r8b3 = c & null;

var r8c1 = null & true;
var r8c2 = null & '';
var r8c3 = null & {};

var r8d1 = true & null;
var r8d2 = '' & null;
var r8d3 = {} & null;

// operator ^
var r9a1 = null ^ a;
var r9a2 = null ^ b;
var r9a3 = null ^ c;

var r9b1 = a ^ null;
var r9b2 = b ^ null;
var r9b3 = c ^ null;

var r9c1 = null ^ true;
var r9c2 = null ^ '';
var r9c3 = null ^ {};

var r9d1 = true ^ null;
var r9d2 = '' ^ null;
var r9d3 = {} ^ null;

// operator |
var r10a1 = null | a;
var r10a2 = null | b;
var r10a3 = null | c;

var r10b1 = a | null;
var r10b2 = b | null;
var r10b3 = c | null;

var r10c1 = null | true;
var r10c2 = null | '';
var r10c3 = null | {};

var r10d1 = true | null;
var r10d2 = '' | null;
var r10d3 = {} | null;`,
      [],
    );
  });
  test("arithmeticOperatorWithNullValueAndValidOperands", async () => {
    await expectPass(
      `// If one operand is the null or undefined value, it is treated as having the type of the
// other operand.

enum E {
    a,
    b
}

declare var a: any;
declare var b: number;

// operator *
var ra1 = null * a;
var ra2 = null * b;
var ra3 = null * 1;
var ra4 = null * E.a;
var ra5 = a * null;
var ra6 = b * null;
var ra7 = 0 * null;
var ra8 = E.b * null;

// operator /
var rb1 = null / a;
var rb2 = null / b;
var rb3 = null / 1;
var rb4 = null / E.a;
var rb5 = a / null;
var rb6 = b / null;
var rb7 = 0 / null;
var rb8 = E.b / null;

// operator %
var rc1 = null % a;
var rc2 = null % b;
var rc3 = null % 1;
var rc4 = null % E.a;
var rc5 = a % null;
var rc6 = b % null;
var rc7 = 0 % null;
var rc8 = E.b % null;

// operator -
var rd1 = null - a;
var rd2 = null - b;
var rd3 = null - 1;
var rd4 = null - E.a;
var rd5 = a - null;
var rd6 = b - null;
var rd7 = 0 - null;
var rd8 = E.b - null;

// operator <<
var re1 = null << a;
var re2 = null << b;
var re3 = null << 1;
var re4 = null << E.a;
var re5 = a << null;
var re6 = b << null;
var re7 = 0 << null;
var re8 = E.b << null;

// operator >>
var rf1 = null >> a;
var rf2 = null >> b;
var rf3 = null >> 1;
var rf4 = null >> E.a;
var rf5 = a >> null;
var rf6 = b >> null;
var rf7 = 0 >> null;
var rf8 = E.b >> null;

// operator >>>
var rg1 = null >>> a;
var rg2 = null >>> b;
var rg3 = null >>> 1;
var rg4 = null >>> E.a;
var rg5 = a >>> null;
var rg6 = b >>> null;
var rg7 = 0 >>> null;
var rg8 = E.b >>> null;

// operator &
var rh1 = null & a;
var rh2 = null & b;
var rh3 = null & 1;
var rh4 = null & E.a;
var rh5 = a & null;
var rh6 = b & null;
var rh7 = 0 & null;
var rh8 = E.b & null;

// operator ^
var ri1 = null ^ a;
var ri2 = null ^ b;
var ri3 = null ^ 1;
var ri4 = null ^ E.a;
var ri5 = a ^ null;
var ri6 = b ^ null;
var ri7 = 0 ^ null;
var ri8 = E.b ^ null;

// operator |
var rj1 = null | a;
var rj2 = null | b;
var rj3 = null | 1;
var rj4 = null | E.a;
var rj5 = a | null;
var rj6 = b | null;
var rj7 = 0 | null;
var rj8 = E.b | null;`,
      [],
    );
  });
  test("arithmeticOperatorWithOnlyNullValueOrUndefinedValue", async () => {
    await expectPass(
      `// operator *
var ra1 = null * null;
var ra2 = null * undefined;
var ra3 = undefined * null;
var ra4 = undefined * undefined;

// operator /
var rb1 = null / null;
var rb2 = null / undefined;
var rb3 = undefined / null;
var rb4 = undefined / undefined;

// operator %
var rc1 = null % null;
var rc2 = null % undefined;
var rc3 = undefined % null;
var rc4 = undefined % undefined;

// operator -
var rd1 = null - null;
var rd2 = null - undefined;
var rd3 = undefined - null;
var rd4 = undefined - undefined;

// operator <<
var re1 = null << null;
var re2 = null << undefined;
var re3 = undefined << null;
var re4 = undefined << undefined;

// operator >>
var rf1 = null >> null;
var rf2 = null >> undefined;
var rf3 = undefined >> null;
var rf4 = undefined >> undefined;

// operator >>>
var rg1 = null >>> null;
var rg2 = null >>> undefined;
var rg3 = undefined >>> null;
var rg4 = undefined >>> undefined;

// operator &
var rh1 = null & null;
var rh2 = null & undefined;
var rh3 = undefined & null;
var rh4 = undefined & undefined;

// operator ^
var ri1 = null ^ null;
var ri2 = null ^ undefined;
var ri3 = undefined ^ null;
var ri4 = undefined ^ undefined;

// operator |
var rj1 = null | null;
var rj2 = null | undefined;
var rj3 = undefined | null;
var rj4 = undefined | undefined;`,
      [],
    );
  });
  test("arithmeticOperatorWithTypeParameter", async () => {
    await expectPass(
      `// type parameter type is not valid for arithmetic operand
function foo<T>(t: T) {
    let a!: any;
    let b!: boolean;
    let c!: number;
    let d!: string;
    let e!: {};

    var r1a1 = a * t;
    var r1a2 = a / t;
    var r1a3 = a % t;
    var r1a4 = a - t;
    var r1a5 = a << t;
    var r1a6 = a >> t;
    var r1a7 = a >>> t;
    var r1a8 = a & t;
    var r1a9 = a ^ t;
    var r1a10 = a | t;

    var r2a1 = t * a;
    var r2a2 = t / a;
    var r2a3 = t % a;
    var r2a4 = t - a;
    var r2a5 = t << a;
    var r2a6 = t >> a;
    var r2a7 = t >>> a;
    var r2a8 = t & a;
    var r2a9 = t ^ a;
    var r2a10 = t | a;

    var r1b1 = b * t;
    var r1b2 = b / t;
    var r1b3 = b % t;
    var r1b4 = b - t;
    var r1b5 = b << t;
    var r1b6 = b >> t;
    var r1b7 = b >>> t;
    var r1b8 = b & t;
    var r1b9 = b ^ t;
    var r1b10 = b | t;

    var r2b1 = t * b;
    var r2b2 = t / b;
    var r2b3 = t % b;
    var r2b4 = t - b;
    var r2b5 = t << b;
    var r2b6 = t >> b;
    var r2b7 = t >>> b;
    var r2b8 = t & b;
    var r2b9 = t ^ b;
    var r2b10 = t | b;

    var r1c1 = c * t;
    var r1c2 = c / t;
    var r1c3 = c % t;
    var r1c4 = c - t;
    var r1c5 = c << t;
    var r1c6 = c >> t;
    var r1c7 = c >>> t;
    var r1c8 = c & t;
    var r1c9 = c ^ t;
    var r1c10 = c | t;

    var r2c1 = t * c;
    var r2c2 = t / c;
    var r2c3 = t % c;
    var r2c4 = t - c;
    var r2c5 = t << c;
    var r2c6 = t >> c;
    var r2c7 = t >>> c;
    var r2c8 = t & c;
    var r2c9 = t ^ c;
    var r2c10 = t | c;

    var r1d1 = d * t;
    var r1d2 = d / t;
    var r1d3 = d % t;
    var r1d4 = d - t;
    var r1d5 = d << t;
    var r1d6 = d >> t;
    var r1d7 = d >>> t;
    var r1d8 = d & t;
    var r1d9 = d ^ t;
    var r1d10 = d | t;

    var r2d1 = t * d;
    var r2d2 = t / d;
    var r2d3 = t % d;
    var r2d4 = t - d;
    var r2d5 = t << d;
    var r2d6 = t >> d;
    var r2d7 = t >>> d;
    var r2d8 = t & d;
    var r2d9 = t ^ d;
    var r2d10 = t | d;

    var r1e1 = e * t;
    var r1e2 = e / t;
    var r1e3 = e % t;
    var r1e4 = e - t;
    var r1e5 = e << t;
    var r1e6 = e >> t;
    var r1e7 = e >>> t;
    var r1e8 = e & t;
    var r1e9 = e ^ t;
    var r1e10 = e | t;

    var r2e1 = t * e;
    var r2e2 = t / e;
    var r2e3 = t % e;
    var r2e4 = t - e;
    var r2e5 = t << e;
    var r2e6 = t >> e;
    var r2e7 = t >>> e;
    var r2e8 = t & e;
    var r2e9 = t ^ e;
    var r2e10 = t | e;

    var r1f1 = t * t;
    var r1f2 = t / t;
    var r1f3 = t % t;
    var r1f4 = t - t;
    var r1f5 = t << t;
    var r1f6 = t >> t;
    var r1f7 = t >>> t;
    var r1f8 = t & t;
    var r1f9 = t ^ t;
    var r1f10 = t | t;
}`,
      [],
    );
  });
  test("arithmeticOperatorWithUndefinedValueAndInvalidOperands", async () => {
    await expectPass(
      `// If one operand is the undefined or undefined value, it is treated as having the type of the
// other operand.

declare var a: boolean;
declare var b: string;
declare var c: Object;

// operator *
var r1a1 = undefined * a;
var r1a2 = undefined * b;
var r1a3 = undefined * c;

var r1b1 = a * undefined;
var r1b2 = b * undefined;
var r1b3 = c * undefined;

var r1c1 = undefined * true;
var r1c2 = undefined * '';
var r1c3 = undefined * {};

var r1d1 = true * undefined;
var r1d2 = '' * undefined;
var r1d3 = {} * undefined;

// operator /
var r2a1 = undefined / a;
var r2a2 = undefined / b;
var r2a3 = undefined / c;

var r2b1 = a / undefined;
var r2b2 = b / undefined;
var r2b3 = c / undefined;

var r2c1 = undefined / true;
var r2c2 = undefined / '';
var r2c3 = undefined / {};

var r2d1 = true / undefined;
var r2d2 = '' / undefined;
var r2d3 = {} / undefined;

// operator %
var r3a1 = undefined % a;
var r3a2 = undefined % b;
var r3a3 = undefined % c;

var r3b1 = a % undefined;
var r3b2 = b % undefined;
var r3b3 = c % undefined;

var r3c1 = undefined % true;
var r3c2 = undefined % '';
var r3c3 = undefined % {};

var r3d1 = true % undefined;
var r3d2 = '' % undefined;
var r3d3 = {} % undefined;

// operator -
var r4a1 = undefined - a;
var r4a2 = undefined - b;
var r4a3 = undefined - c;

var r4b1 = a - undefined;
var r4b2 = b - undefined;
var r4b3 = c - undefined;

var r4c1 = undefined - true;
var r4c2 = undefined - '';
var r4c3 = undefined - {};

var r4d1 = true - undefined;
var r4d2 = '' - undefined;
var r4d3 = {} - undefined;

// operator <<
var r5a1 = undefined << a;
var r5a2 = undefined << b;
var r5a3 = undefined << c;

var r5b1 = a << undefined;
var r5b2 = b << undefined;
var r5b3 = c << undefined;

var r5c1 = undefined << true;
var r5c2 = undefined << '';
var r5c3 = undefined << {};

var r5d1 = true << undefined;
var r5d2 = '' << undefined;
var r5d3 = {} << undefined;

// operator >>
var r6a1 = undefined >> a;
var r6a2 = undefined >> b;
var r6a3 = undefined >> c;

var r6b1 = a >> undefined;
var r6b2 = b >> undefined;
var r6b3 = c >> undefined;

var r6c1 = undefined >> true;
var r6c2 = undefined >> '';
var r6c3 = undefined >> {};

var r6d1 = true >> undefined;
var r6d2 = '' >> undefined;
var r6d3 = {} >> undefined;

// operator >>>
var r7a1 = undefined >>> a;
var r7a2 = undefined >>> b;
var r7a3 = undefined >>> c;

var r7b1 = a >>> undefined;
var r7b2 = b >>> undefined;
var r7b3 = c >>> undefined;

var r7c1 = undefined >>> true;
var r7c2 = undefined >>> '';
var r7c3 = undefined >>> {};

var r7d1 = true >>> undefined;
var r7d2 = '' >>> undefined;
var r7d3 = {} >>> undefined;

// operator &
var r8a1 = undefined & a;
var r8a2 = undefined & b;
var r8a3 = undefined & c;

var r8b1 = a & undefined;
var r8b2 = b & undefined;
var r8b3 = c & undefined;

var r8c1 = undefined & true;
var r8c2 = undefined & '';
var r8c3 = undefined & {};

var r8d1 = true & undefined;
var r8d2 = '' & undefined;
var r8d3 = {} & undefined;

// operator ^
var r9a1 = undefined ^ a;
var r9a2 = undefined ^ b;
var r9a3 = undefined ^ c;

var r9b1 = a ^ undefined;
var r9b2 = b ^ undefined;
var r9b3 = c ^ undefined;

var r9c1 = undefined ^ true;
var r9c2 = undefined ^ '';
var r9c3 = undefined ^ {};

var r9d1 = true ^ undefined;
var r9d2 = '' ^ undefined;
var r9d3 = {} ^ undefined;

// operator |
var r10a1 = undefined | a;
var r10a2 = undefined | b;
var r10a3 = undefined | c;

var r10b1 = a | undefined;
var r10b2 = b | undefined;
var r10b3 = c | undefined;

var r10c1 = undefined | true;
var r10c2 = undefined | '';
var r10c3 = undefined | {};

var r10d1 = true | undefined;
var r10d2 = '' | undefined;
var r10d3 = {} | undefined;`,
      [],
    );
  });
  test("arithmeticOperatorWithUndefinedValueAndValidOperands", async () => {
    await expectPass(
      `// If one operand is the undefined or undefined value, it is treated as having the type of the
// other operand.

enum E {
    a,
    b
}

declare var a: any;
declare var b: number;

// operator *
var ra1 = undefined * a;
var ra2 = undefined * b;
var ra3 = undefined * 1;
var ra4 = undefined * E.a;
var ra5 = a * undefined;
var ra6 = b * undefined;
var ra7 = 0 * undefined;
var ra8 = E.b * undefined;

// operator /
var rb1 = undefined / a;
var rb2 = undefined / b;
var rb3 = undefined / 1;
var rb4 = undefined / E.a;
var rb5 = a / undefined;
var rb6 = b / undefined;
var rb7 = 0 / undefined;
var rb8 = E.b / undefined;

// operator %
var rc1 = undefined % a;
var rc2 = undefined % b;
var rc3 = undefined % 1;
var rc4 = undefined % E.a;
var rc5 = a % undefined;
var rc6 = b % undefined;
var rc7 = 0 % undefined;
var rc8 = E.b % undefined;

// operator -
var rd1 = undefined - a;
var rd2 = undefined - b;
var rd3 = undefined - 1;
var rd4 = undefined - E.a;
var rd5 = a - undefined;
var rd6 = b - undefined;
var rd7 = 0 - undefined;
var rd8 = E.b - undefined;

// operator <<
var re1 = undefined << a;
var re2 = undefined << b;
var re3 = undefined << 1;
var re4 = undefined << E.a;
var re5 = a << undefined;
var re6 = b << undefined;
var re7 = 0 << undefined;
var re8 = E.b << undefined;

// operator >>
var rf1 = undefined >> a;
var rf2 = undefined >> b;
var rf3 = undefined >> 1;
var rf4 = undefined >> E.a;
var rf5 = a >> undefined;
var rf6 = b >> undefined;
var rf7 = 0 >> undefined;
var rf8 = E.b >> undefined;

// operator >>>
var rg1 = undefined >>> a;
var rg2 = undefined >>> b;
var rg3 = undefined >>> 1;
var rg4 = undefined >>> E.a;
var rg5 = a >>> undefined;
var rg6 = b >>> undefined;
var rg7 = 0 >>> undefined;
var rg8 = E.b >>> undefined;

// operator &
var rh1 = undefined & a;
var rh2 = undefined & b;
var rh3 = undefined & 1;
var rh4 = undefined & E.a;
var rh5 = a & undefined;
var rh6 = b & undefined;
var rh7 = 0 & undefined;
var rh8 = E.b & undefined;

// operator ^
var ri1 = undefined ^ a;
var ri2 = undefined ^ b;
var ri3 = undefined ^ 1;
var ri4 = undefined ^ E.a;
var ri5 = a ^ undefined;
var ri6 = b ^ undefined;
var ri7 = 0 ^ undefined;
var ri8 = E.b ^ undefined;

// operator |
var rj1 = undefined | a;
var rj2 = undefined | b;
var rj3 = undefined | 1;
var rj4 = undefined | E.a;
var rj5 = a | undefined;
var rj6 = b | undefined;
var rj7 = 0 | undefined;
var rj8 = E.b | undefined;`,
      [],
    );
  });
  test("comparisonOperatorWithIdenticalObjects", async () => {
    await expectPass(
      `class A1 {
    public a: string;
    public b: number;
    public c: boolean;
    public d: any;
    public e: Object;
    public fn(a: string): string {
        return null;
    }
}
class B1 {
    public a: string;
    public b: number;
    public c: boolean;
    public d: any;
    public e: Object;
    public fn(b: string): string {
        return null;
    }
}

class Base {
    private a: string;
    private fn(b: string): string {
        return null;
    }
}
class A2 extends Base { }
class B2 extends Base { }

interface A3 { f(a: number): string; }
interface B3 { f(a: number): string; }

interface A4 { new (a: string): A1; }
interface B4 { new (a: string): B1; }

interface A5 { [x: number]: number; }
interface B5 { [x: number]: number; }

interface A6 { [x: string]: string; }
interface B6 { [x: string]: string; }

var a1: A1;
var a2: A2;
var a3: A3;
var a4: A4;
var a5: A5;
var a6: A6;

var b1: B1;
var b2: B2;
var b3: B3;
var b4: B4;
var b5: B5;
var b6: B6;

var base1: Base;
var base2: Base;

// operator <
var r1a1 = a1 < b1;
var r1a2 = base1 < base2;
var r1a3 = a2 < b2;
var r1a4 = a3 < b3;
var r1a5 = a4 < b4;
var r1a6 = a5 < b5;
var r1a7 = a6 < b6;

var r1b1 = b1 < a1;
var r1b2 = base2 < base1;
var r1b3 = b2 < a2;
var r1b4 = b3 < a3;
var r1b5 = b4 < a4;
var r1b6 = b5 < a5;
var r1b7 = b6 < a6;

// operator >
var r2a1 = a1 > b1;
var r2a2 = base1 > base2;
var r2a3 = a2 > b2;
var r2a4 = a3 > b3;
var r2a5 = a4 > b4;
var r2a6 = a5 > b5;
var r2a7 = a6 > b6;

var r2b1 = b1 > a1;
var r2b2 = base2 > base1;
var r2b3 = b2 > a2;
var r2b4 = b3 > a3;
var r2b5 = b4 > a4;
var r2b6 = b5 > a5;
var r2b7 = b6 > a6;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = base1 <= base2;
var r3a3 = a2 <= b2;
var r3a4 = a3 <= b3;
var r3a5 = a4 <= b4;
var r3a6 = a5 <= b5;
var r3a7 = a6 <= b6;

var r3b1 = b1 <= a1;
var r3b2 = base2 <= base1;
var r3b3 = b2 <= a2;
var r3b4 = b3 <= a3;
var r3b5 = b4 <= a4;
var r3b6 = b5 <= a5;
var r3b7 = b6 <= a6;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = base1 >= base2;
var r4a3 = a2 >= b2;
var r4a4 = a3 >= b3;
var r4a5 = a4 >= b4;
var r4a6 = a5 >= b5;
var r4a7 = a6 >= b6;

var r4b1 = b1 >= a1;
var r4b2 = base2 >= base1;
var r4b3 = b2 >= a2;
var r4b4 = b3 >= a3;
var r4b5 = b4 >= a4;
var r4b6 = b5 >= a5;
var r4b7 = b6 >= a6;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = base1 == base2;
var r5a3 = a2 == b2;
var r5a4 = a3 == b3;
var r5a5 = a4 == b4;
var r5a6 = a5 == b5;
var r5a7 = a6 == b6;

var r5b1 = b1 == a1;
var r5b2 = base2 == base1;
var r5b3 = b2 == a2;
var r5b4 = b3 == a3;
var r5b5 = b4 == a4;
var r5b6 = b5 == a5;
var r5b7 = b6 == a6;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = base1 != base2;
var r6a3 = a2 != b2;
var r6a4 = a3 != b3;
var r6a5 = a4 != b4;
var r6a6 = a5 != b5;
var r6a7 = a6 != b6;

var r6b1 = b1 != a1;
var r6b2 = base2 != base1;
var r6b3 = b2 != a2;
var r6b4 = b3 != a3;
var r6b5 = b4 != a4;
var r6b6 = b5 != a5;
var r6b7 = b6 != a6;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = base1 === base2;
var r7a3 = a2 === b2;
var r7a4 = a3 === b3;
var r7a5 = a4 === b4;
var r7a6 = a5 === b5;
var r7a7 = a6 === b6;

var r7b1 = b1 === a1;
var r7b2 = base2 === base1;
var r7b3 = b2 === a2;
var r7b4 = b3 === a3;
var r7b5 = b4 === a4;
var r7b6 = b5 === a5;
var r7b7 = b6 === a6;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = base1 !== base2;
var r8a3 = a2 !== b2;
var r8a4 = a3 !== b3;
var r8a5 = a4 !== b4;
var r8a6 = a5 !== b5;
var r8a7 = a6 !== b6;

var r8b1 = b1 !== a1;
var r8b2 = base2 !== base1;
var r8b3 = b2 !== a2;
var r8b4 = b3 !== a3;
var r8b5 = b4 !== a4;
var r8b6 = b5 !== a5;
var r8b7 = b6 !== a6;`,
      [],
    );
  });
  test("comparisonOperatorWithIdenticalPrimitiveType", async () => {
    await expectPass(
      `enum E { a, b, c }

declare var a: number;
declare var b: boolean;
declare var c: string;
declare var d: void;
declare var e: E;

// operator <
var ra1 = a < a;
var ra2 = b < b;
var ra3 = c < c;
var ra4 = d < d;
var ra5 = e < e;
var ra6 = null < null;
var ra7 = undefined < undefined;

// operator >
var rb1 = a > a;
var rb2 = b > b;
var rb3 = c > c;
var rb4 = d > d;
var rb5 = e > e;
var rb6 = null > null;
var rb7 = undefined > undefined;

// operator <=
var rc1 = a <= a;
var rc2 = b <= b;
var rc3 = c <= c;
var rc4 = d <= d;
var rc5 = e <= e;
var rc6 = null <= null;
var rc7 = undefined <= undefined;

// operator >=
var rd1 = a >= a;
var rd2 = b >= b;
var rd3 = c >= c;
var rd4 = d >= d;
var rd5 = e >= e;
var rd6 = null >= null;
var rd7 = undefined >= undefined;

// operator ==
var re1 = a == a;
var re2 = b == b;
var re3 = c == c;
var re4 = d == d;
var re5 = e == e;
var re6 = null == null;
var re7 = undefined == undefined;

// operator !=
var rf1 = a != a;
var rf2 = b != b;
var rf3 = c != c;
var rf4 = d != d;
var rf5 = e != e;
var rf6 = null != null;
var rf7 = undefined != undefined;

// operator ===
var rg1 = a === a;
var rg2 = b === b;
var rg3 = c === c;
var rg4 = d === d;
var rg5 = e === e;
var rg6 = null === null;
var rg7 = undefined === undefined;

// operator !==
var rh1 = a !== a;
var rh2 = b !== b;
var rh3 = c !== c;
var rh4 = d !== d;
var rh5 = e !== e;
var rh6 = null !== null;
var rh7 = undefined !== undefined;`,
      [],
    );
  });
  test("comparisonOperatorWithIdenticalTypeParameter", async () => {
    await expectPass(
      `function foo<T>(t: T) {
    var r1 = t < t;
    var r2 = t > t;
    var r3 = t <= t;
    var r4 = t >= t;
    var r5 = t == t;
    var r6 = t != t;
    var r7 = t === t;
    var r8 = t !== t;
}`,
      [],
    );
  });
  test("comparisonOperatorWithIntersectionType", async () => {
    await expectPass(
      `declare let a: { a: 1 }
a > 1;

declare let b: { a: 1 } & { b: number }
b > 1;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnCallSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

class C {
    public c: string;
}

declare var a1: { fn(): Base };
declare var b1: { new (): Base };

declare var a2: { fn(a: number, b: string): void };
declare var b2: { fn(a: string): void };

declare var a3: { fn(a: Base, b: string): void };
declare var b3: { fn(a: Derived, b: Base): void };

declare var a4: { fn(): Base };
declare var b4: { fn(): C };

declare var a5: { fn(a?: Base): void };
declare var b5: { fn(a?: C): void };

declare var a6: { fn(...a: Base[]): void };
declare var b6: { fn(...a: C[]): void };

declare var a7: { fn<T>(t: T): T };
declare var b7: { fn<T>(t: T[]): T };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;
var r1a7 = a7 < b7;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;
var r1b7 = b7 < a7;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;
var r2a7 = a7 > b7;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;
var r2b7 = b7 > a7;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;
var r3a7 = a7 <= b7;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;
var r3b7 = b7 <= a7;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;
var r4a7 = a7 >= b7;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;
var r4b7 = b7 >= a7;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;
var r5a7 = a7 == b7;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;
var r5b7 = b7 == a7;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;
var r6a7 = a7 != b7;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;
var r6b7 = b7 != a7;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;
var r7a7 = a7 === b7;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;
var r7b7 = b7 === a7;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;
var r8a7 = a7 !== b7;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;
var r8b7 = b7 !== a7;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnConstructorSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

class C {
    public c: string;
}

declare var a1: { fn(): Base };
declare var b1: { new (): Base };

declare var a2: { new (a: number, b: string): Base };
declare var b2: { new (a: string): Base };

declare var a3: { new (a: Base, b: string): Base };
declare var b3: { new (a: Derived, b: Base): Base };

declare var a4: { new (): Base };
declare var b4: { new (): C };

declare var a5: { new (a?: Base): Base };
declare var b5: { new (a?: C): Base };

declare var a6: { new (...a: Base[]): Base };
declare var b6: { new (...a: C[]): Base };

declare var a7: { new <T>(t: T): T };
declare var b7: { new <T>(t: T[]): T };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;
var r1a7 = a7 < b7;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;
var r1b7 = b7 < a7;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;
var r2a7 = a7 > b7;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;
var r2b7 = b7 > a7;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;
var r3a7 = a7 <= b7;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;
var r3b7 = b7 <= a7;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;
var r4a7 = a7 >= b7;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;
var r4b7 = b7 >= a7;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;
var r5a7 = a7 == b7;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;
var r5b7 = b7 == a7;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;
var r6a7 = a7 != b7;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;
var r6b7 = b7 != a7;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;
var r7a7 = a7 === b7;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;
var r7b7 = b7 === a7;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;
var r8a7 = a7 !== b7;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;
var r8b7 = b7 !== a7;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnIndexSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

class C {
    public c: string;
}

declare var a1: { [a: string]: string };
declare var b1: { [b: string]: number };

declare var a2: { [index: string]: Base };
declare var b2: { [index: string]: C };

declare var a3: { [index: number]: Base };
declare var b3: { [index: number]: C };

declare var a4: { [index: number]: Derived };
declare var b4: { [index: string]: Base };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnInstantiatedCallSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

class C {
    public c: string;
}

var a1: { fn<T>(x: T): T };
var b1: { fn(): string };

var a2: { fn<T>(x: T): T };
var b2: { fn(x: string): number };

var a3: { fn<T>(x?: T): T };
var b3: { fn(x?: string): number };

var a4: { fn<T>(...x: T[]): T };
var b4: { fn(...x: string[]): number };

var a5: { fn<T>(x: T, y: T): T };
var b5: { fn(x: string, y: number): string };

var a6: { fn<T, U extends T>(x: T, y: U): T };
var b6: { fn(x: Base, y: C): Base };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnInstantiatedConstructorSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

class C {
    public c: string;
}

var a1: { new <T>(x: T): T };
var b1: { new (): string };

var a2: { new <T>(x: T): T };
var b2: { new (x: string): number };

var a3: { new <T>(x?: T): T };
var b3: { new (x?: string): number };

var a4: { new <T>(...x: T[]): T };
var b4: { new (...x: string[]): number };

var a5: { new <T>(x: T, y: T): T };
var b5: { new (x: string, y: number): string };

var a6: { new <T, U extends T>(x: T, y: U): T };
var b6: { new (x: Base, y: C): Base };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnOptionalProperty", async () => {
    await expectPass(
      `interface A1 {
    b?: number;
}

interface B1 {
    b?: string;
}

declare var a: A1;
declare var b: B1;

// operator <
var ra1 = a < b;
var ra2 = b < a;

// operator >
var rb1 = a > b;
var rb2 = b > a;

// operator <=
var rc1 = a <= b;
var rc2 = b <= a;

// operator >=
var rd1 = a >= b;
var rd2 = b >= a;

// operator ==
var re1 = a == b;
var re2 = b == a;

// operator !=
var rf1 = a != b;
var rf2 = b != a;

// operator ===
var rg1 = a === b;
var rg2 = b === a;

// operator !==
var rh1 = a !== b;
var rh2 = b !== a;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipObjectsOnProperty", async () => {
    await expectPass(
      `class A1 {
    public a: number;
}

class B1 {
    public a: string;
}

class A2 {
    private a: string;
}

class B2 {
    private a: string;
}

declare var a1: A1;
declare var b1: B1;
declare var a2: A2;
declare var b2: B2;

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipPrimitiveType", async () => {
    await expectPass(
      `enum E { a, b, c }

declare var a: number;
declare var b: boolean;
declare var c: string;
declare var d: void;
declare var e: E;

// operator <
var r1a1 = a < b;
var r1a1 = a < c;
var r1a1 = a < d;
var r1a1 = a < e; // no error, expected

var r1b1 = b < a;
var r1b1 = b < c;
var r1b1 = b < d;
var r1b1 = b < e;

var r1c1 = c < a;
var r1c1 = c < b;
var r1c1 = c < d;
var r1c1 = c < e;

var r1d1 = d < a;
var r1d1 = d < b;
var r1d1 = d < c;
var r1d1 = d < e;

var r1e1 = e < a; // no error, expected
var r1e1 = e < b;
var r1e1 = e < c;
var r1e1 = e < d;

// operator >
var r2a1 = a > b;
var r2a1 = a > c;
var r2a1 = a > d;
var r2a1 = a > e; // no error, expected

var r2b1 = b > a;
var r2b1 = b > c;
var r2b1 = b > d;
var r2b1 = b > e;

var r2c1 = c > a;
var r2c1 = c > b;
var r2c1 = c > d;
var r2c1 = c > e;

var r2d1 = d > a;
var r2d1 = d > b;
var r2d1 = d > c;
var r2d1 = d > e;

var r2e1 = e > a; // no error, expected
var r2e1 = e > b;
var r2e1 = e > c;
var r2e1 = e > d;

// operator <=
var r3a1 = a <= b;
var r3a1 = a <= c;
var r3a1 = a <= d;
var r3a1 = a <= e; // no error, expected

var r3b1 = b <= a;
var r3b1 = b <= c;
var r3b1 = b <= d;
var r3b1 = b <= e;

var r3c1 = c <= a;
var r3c1 = c <= b;
var r3c1 = c <= d;
var r3c1 = c <= e;

var r3d1 = d <= a;
var r3d1 = d <= b;
var r3d1 = d <= c;
var r3d1 = d <= e;

var r3e1 = e <= a; // no error, expected
var r3e1 = e <= b;
var r3e1 = e <= c;
var r3e1 = e <= d;

// operator >=
var r4a1 = a >= b;
var r4a1 = a >= c;
var r4a1 = a >= d;
var r4a1 = a >= e; // no error, expected

var r4b1 = b >= a;
var r4b1 = b >= c;
var r4b1 = b >= d;
var r4b1 = b >= e;

var r4c1 = c >= a;
var r4c1 = c >= b;
var r4c1 = c >= d;
var r4c1 = c >= e;

var r4d1 = d >= a;
var r4d1 = d >= b;
var r4d1 = d >= c;
var r4d1 = d >= e;

var r4e1 = e >= a; // no error, expected
var r4e1 = e >= b;
var r4e1 = e >= c;
var r4e1 = e >= d;

// operator ==
var r5a1 = a == b;
var r5a1 = a == c;
var r5a1 = a == d;
var r5a1 = a == e; // no error, expected

var r5b1 = b == a;
var r5b1 = b == c;
var r5b1 = b == d;
var r5b1 = b == e;

var r5c1 = c == a;
var r5c1 = c == b;
var r5c1 = c == d;
var r5c1 = c == e;

var r5d1 = d == a;
var r5d1 = d == b;
var r5d1 = d == c;
var r5d1 = d == e;

var r5e1 = e == a; // no error, expected
var r5e1 = e == b;
var r5e1 = e == c;
var r5e1 = e == d;

// operator !=
var r6a1 = a != b;
var r6a1 = a != c;
var r6a1 = a != d;
var r6a1 = a != e; // no error, expected

var r6b1 = b != a;
var r6b1 = b != c;
var r6b1 = b != d;
var r6b1 = b != e;

var r6c1 = c != a;
var r6c1 = c != b;
var r6c1 = c != d;
var r6c1 = c != e;

var r6d1 = d != a;
var r6d1 = d != b;
var r6d1 = d != c;
var r6d1 = d != e;

var r6e1 = e != a; // no error, expected
var r6e1 = e != b;
var r6e1 = e != c;
var r6e1 = e != d;

// operator ===
var r7a1 = a === b;
var r7a1 = a === c;
var r7a1 = a === d;
var r7a1 = a === e; // no error, expected

var r7b1 = b === a;
var r7b1 = b === c;
var r7b1 = b === d;
var r7b1 = b === e;

var r7c1 = c === a;
var r7c1 = c === b;
var r7c1 = c === d;
var r7c1 = c === e;

var r7d1 = d === a;
var r7d1 = d === b;
var r7d1 = d === c;
var r7d1 = d === e;

var r7e1 = e === a; // no error, expected
var r7e1 = e === b;
var r7e1 = e === c;
var r7e1 = e === d;

// operator !==
var r8a1 = a !== b;
var r8a1 = a !== c;
var r8a1 = a !== d;
var r8a1 = a !== e; // no error, expected

var r8b1 = b !== a;
var r8b1 = b !== c;
var r8b1 = b !== d;
var r8b1 = b !== e;

var r8c1 = c !== a;
var r8c1 = c !== b;
var r8c1 = c !== d;
var r8c1 = c !== e;

var r8d1 = d !== a;
var r8d1 = d !== b;
var r8d1 = d !== c;
var r8d1 = d !== e;

var r8e1 = e !== a; // no error, expected
var r8e1 = e !== b;
var r8e1 = e !== c;
var r8e1 = e !== d;`,
      [],
    );
  });
  test("comparisonOperatorWithNoRelationshipTypeParameter", async () => {
    await expectPass(
      `enum E { a, b, c }

var a: boolean;
var b: number;
var c: string;
var d: void;
var e: E;
var f: { a: string };
var g: any[];

function foo<T, U>(t: T, u: U) {
    var r1 = t < u;
    var r2 = t > u;
    var r3 = t <= u;
    var r4 = t >= u;
    var r5 = t == u;
    var r6 = t != u;
    var r7 = t === u;
    var r8 = t !== u;

    // operator <
    var r1a1 = t < a;
    var r1a2 = t < b;
    var r1a3 = t < c;
    var r1a4 = t < d;
    var r1a5 = t < e;
    var r1a6 = t < f;
    var r1a7 = t < g;

    var r1b1 = a < t;
    var r1b2 = b < t;
    var r1b3 = c < t;
    var r1b4 = d < t;
    var r1b5 = e < t;
    var r1b6 = f < t;
    var r1b7 = g < t;

    // operator >
    var r2a1 = t < a;
    var r2a2 = t < b;
    var r2a3 = t < c;
    var r2a4 = t < d;
    var r2a5 = t < e;
    var r2a6 = t < f;
    var r2a7 = t < g;

    var r2b1 = a < t;
    var r2b2 = b < t;
    var r2b3 = c < t;
    var r2b4 = d < t;
    var r2b5 = e < t;
    var r2b6 = f < t;
    var r2b7 = g < t;

    // operator <=
    var r3a1 = t < a;
    var r3a2 = t < b;
    var r3a3 = t < c;
    var r3a4 = t < d;
    var r3a5 = t < e;
    var r3a6 = t < f;
    var r3a7 = t < g;

    var r3b1 = a < t;
    var r3b2 = b < t;
    var r3b3 = c < t;
    var r3b4 = d < t;
    var r3b5 = e < t;
    var r3b6 = f < t;
    var r3b7 = g < t;

    // operator >=
    var r4a1 = t < a;
    var r4a2 = t < b;
    var r4a3 = t < c;
    var r4a4 = t < d;
    var r4a5 = t < e;
    var r4a6 = t < f;
    var r4a7 = t < g;

    var r4b1 = a < t;
    var r4b2 = b < t;
    var r4b3 = c < t;
    var r4b4 = d < t;
    var r4b5 = e < t;
    var r4b6 = f < t;
    var r4b7 = g < t;

    // operator ==
    var r5a1 = t < a;
    var r5a2 = t < b;
    var r5a3 = t < c;
    var r5a4 = t < d;
    var r5a5 = t < e;
    var r5a6 = t < f;
    var r5a7 = t < g;

    var r5b1 = a < t;
    var r5b2 = b < t;
    var r5b3 = c < t;
    var r5b4 = d < t;
    var r5b5 = e < t;
    var r5b6 = f < t;
    var r5b7 = g < t;

    // operator !=
    var r6a1 = t < a;
    var r6a2 = t < b;
    var r6a3 = t < c;
    var r6a4 = t < d;
    var r6a5 = t < e;
    var r6a6 = t < f;
    var r6a7 = t < g;

    var r6b1 = a < t;
    var r6b2 = b < t;
    var r6b3 = c < t;
    var r6b4 = d < t;
    var r6b5 = e < t;
    var r6b6 = f < t;
    var r6b7 = g < t;

    // operator ===
    var r7a1 = t < a;
    var r7a2 = t < b;
    var r7a3 = t < c;
    var r7a4 = t < d;
    var r7a5 = t < e;
    var r7a6 = t < f;
    var r7a7 = t < g;

    var r7b1 = a < t;
    var r7b2 = b < t;
    var r7b3 = c < t;
    var r7b4 = d < t;
    var r7b5 = e < t;
    var r7b6 = f < t;
    var r7b7 = g < t;

    // operator !==
    var r8a1 = t < a;
    var r8a2 = t < b;
    var r8a3 = t < c;
    var r8a4 = t < d;
    var r8a5 = t < e;
    var r8a6 = t < f;
    var r8a7 = t < g;

    var r8b1 = a < t;
    var r8b2 = b < t;
    var r8b3 = c < t;
    var r8b4 = d < t;
    var r8b5 = e < t;
    var r8b6 = f < t;
    var r8b7 = g < t;
}`,
      [],
    );
  });
  test("comparisonOperatorWithNumberOperand", async () => {
    await expectPass(
      `
// repro #52036
declare const t1: number | Promise<number>
t1 >= 0 // error`,
      [],
    );
  });
  test("comparisonOperatorWithNumericLiteral", async () => {
    await expectPass(
      `type BrandedNum = number & { __numberBrand: any };
var x : BrandedNum;

// operator >
x > 0;
x > <number>0;
x > <BrandedNum>0;

// operator <
x < 0;
x < <number>0;
x < <BrandedNum>0;

// operator >=
x >= 0;
x >= <number>0;
x >= <BrandedNum>0;

// operator <=
x <= 0;
x <= <number>0;
x <= <BrandedNum>0;

// operator ==
x == 0;
x == <number>0;
x == <BrandedNum>0;

// operator !=
x != 0;
x != <number>0;
x != <BrandedNum>0;

// operator ===
x === 0;
x === <number>0;
x === <BrandedNum>0;

// operator !==
x !== 0;
x !== <number>0;
x !== <BrandedNum>0;`,
      [],
    );
  });
  test("comparisonOperatorWithOneOperandIsAny", async () => {
    await expectPass(
      `var x: any;

enum E { a, b, c }

function foo<T>(t: T) {
    var foo_r1 = t < x;
    var foo_r2 = t > x;
    var foo_r3 = t <= x;
    var foo_r4 = t >= x;
    var foo_r5 = t == x;
    var foo_r6 = t != x;
    var foo_r7 = t === x;
    var foo_r8 = t !== x;

    var foo_r1 = x < t;
    var foo_r2 = x > t;
    var foo_r3 = x <= t;
    var foo_r4 = x >= t;
    var foo_r5 = x == t;
    var foo_r6 = x != t;
    var foo_r7 = x === t;
    var foo_r8 = x !== t;
}

var a: boolean;
var b: number;
var c: string;
var d: void;
var e: E;
var f: {};
var g: string[];

// operator <
var r1a1 = x < a;
var r1a2 = x < b;
var r1a3 = x < c;
var r1a4 = x < d;
var r1a5 = x < e;
var r1a6 = x < f;
var r1a7 = x < g;

var r1b1 = a < x;
var r1b2 = b < x;
var r1b3 = c < x;
var r1b4 = d < x;
var r1b5 = e < x;
var r1b6 = f < x;
var r1b7 = g < x;

// operator >
var r2a1 = x > a;
var r2a2 = x > b;
var r2a3 = x > c;
var r2a4 = x > d;
var r2a5 = x > e;
var r2a6 = x > f;
var r2a7 = x > g;

var r2b1 = a > x;
var r2b2 = b > x;
var r2b3 = c > x;
var r2b4 = d > x;
var r2b5 = e > x;
var r2b6 = f > x;
var r2b7 = g > x;

// operator <=
var r3a1 = x <= a;
var r3a2 = x <= b;
var r3a3 = x <= c;
var r3a4 = x <= d;
var r3a5 = x <= e;
var r3a6 = x <= f;
var r3a7 = x <= g;

var r3b1 = a <= x;
var r3b2 = b <= x;
var r3b3 = c <= x;
var r3b4 = d <= x;
var r3b5 = e <= x;
var r3b6 = f <= x;
var r3b7 = g <= x;

// operator >=
var r4a1 = x >= a;
var r4a2 = x >= b;
var r4a3 = x >= c;
var r4a4 = x >= d;
var r4a5 = x >= e;
var r4a6 = x >= f;
var r4a7 = x >= g;

var r4b1 = a >= x;
var r4b2 = b >= x;
var r4b3 = c >= x;
var r4b4 = d >= x;
var r4b5 = e >= x;
var r4b6 = f >= x;
var r4b7 = g >= x;

// operator ==
var r5a1 = x == a;
var r5a2 = x == b;
var r5a3 = x == c;
var r5a4 = x == d;
var r5a5 = x == e;
var r5a6 = x == f;
var r5a7 = x == g;

var r5b1 = a == x;
var r5b2 = b == x;
var r5b3 = c == x;
var r5b4 = d == x;
var r5b5 = e == x;
var r5b6 = f == x;
var r5b7 = g == x;

// operator !=
var r6a1 = x != a;
var r6a2 = x != b;
var r6a3 = x != c;
var r6a4 = x != d;
var r6a5 = x != e;
var r6a6 = x != f;
var r6a7 = x != g;

var r6b1 = a != x;
var r6b2 = b != x;
var r6b3 = c != x;
var r6b4 = d != x;
var r6b5 = e != x;
var r6b6 = f != x;
var r6b7 = g != x;

// operator ===
var r7a1 = x === a;
var r7a2 = x === b;
var r7a3 = x === c;
var r7a4 = x === d;
var r7a5 = x === e;
var r7a6 = x === f;
var r7a7 = x === g;

var r7b1 = a === x;
var r7b2 = b === x;
var r7b3 = c === x;
var r7b4 = d === x;
var r7b5 = e === x;
var r7b6 = f === x;
var r7b7 = g === x;

// operator !==
var r8a1 = x !== a;
var r8a2 = x !== b;
var r8a3 = x !== c;
var r8a4 = x !== d;
var r8a5 = x !== e;
var r8a6 = x !== f;
var r8a7 = x !== g;

var r8b1 = a !== x;
var r8b2 = b !== x;
var r8b3 = c !== x;
var r8b4 = d !== x;
var r8b5 = e !== x;
var r8b6 = f !== x;
var r8b7 = g !== x;`,
      [],
    );
  });
  test("comparisonOperatorWithOneOperandIsNull", async () => {
    await expectPass(
      `enum E { a, b, c }

function foo<T>(t: T) {
    var foo_r1 = t < null;
    var foo_r2 = t > null;
    var foo_r3 = t <= null;
    var foo_r4 = t >= null;
    var foo_r5 = t == null;
    var foo_r6 = t != null;
    var foo_r7 = t === null;
    var foo_r8 = t !== null;

    var foo_r1 = null < t;
    var foo_r2 = null > t;
    var foo_r3 = null <= t;
    var foo_r4 = null >= t;
    var foo_r5 = null == t;
    var foo_r6 = null != t;
    var foo_r7 = null === t;
    var foo_r8 = null !== t;
}

declare var a: boolean;
declare var b: number;
declare var c: string;
declare var d: void;
declare var e: E;
declare var f: {};
declare var g: string[];

// operator <
var r1a1 = null < a;
var r1a2 = null < b;
var r1a3 = null < c;
var r1a4 = null < d;
var r1a5 = null < e;
var r1a6 = null < f;
var r1a7 = null < g;

var r1b1 = a < null;
var r1b2 = b < null;
var r1b3 = c < null;
var r1b4 = d < null;
var r1b5 = e < null;
var r1b6 = f < null;
var r1b7 = g < null;

// operator >
var r2a1 = null > a;
var r2a2 = null > b;
var r2a3 = null > c;
var r2a4 = null > d;
var r2a5 = null > e;
var r2a6 = null > f;
var r2a7 = null > g;

var r2b1 = a > null;
var r2b2 = b > null;
var r2b3 = c > null;
var r2b4 = d > null;
var r2b5 = e > null;
var r2b6 = f > null;
var r2b7 = g > null;

// operator <=
var r3a1 = null <= a;
var r3a2 = null <= b;
var r3a3 = null <= c;
var r3a4 = null <= d;
var r3a5 = null <= e;
var r3a6 = null <= f;
var r3a7 = null <= g;

var r3b1 = a <= null;
var r3b2 = b <= null;
var r3b3 = c <= null;
var r3b4 = d <= null;
var r3b5 = e <= null;
var r3b6 = f <= null;
var r3b7 = g <= null;

// operator >=
var r4a1 = null >= a;
var r4a2 = null >= b;
var r4a3 = null >= c;
var r4a4 = null >= d;
var r4a5 = null >= e;
var r4a6 = null >= f;
var r4a7 = null >= g;

var r4b1 = a >= null;
var r4b2 = b >= null;
var r4b3 = c >= null;
var r4b4 = d >= null;
var r4b5 = e >= null;
var r4b6 = f >= null;
var r4b7 = g >= null;

// operator ==
var r5a1 = null == a;
var r5a2 = null == b;
var r5a3 = null == c;
var r5a4 = null == d;
var r5a5 = null == e;
var r5a6 = null == f;
var r5a7 = null == g;

var r5b1 = a == null;
var r5b2 = b == null;
var r5b3 = c == null;
var r5b4 = d == null;
var r5b5 = e == null;
var r5b6 = f == null;
var r5b7 = g == null;

// operator !=
var r6a1 = null != a;
var r6a2 = null != b;
var r6a3 = null != c;
var r6a4 = null != d;
var r6a5 = null != e;
var r6a6 = null != f;
var r6a7 = null != g;

var r6b1 = a != null;
var r6b2 = b != null;
var r6b3 = c != null;
var r6b4 = d != null;
var r6b5 = e != null;
var r6b6 = f != null;
var r6b7 = g != null;

// operator ===
var r7a1 = null === a;
var r7a2 = null === b;
var r7a3 = null === c;
var r7a4 = null === d;
var r7a5 = null === e;
var r7a6 = null === f;
var r7a7 = null === g;

var r7b1 = a === null;
var r7b2 = b === null;
var r7b3 = c === null;
var r7b4 = d === null;
var r7b5 = e === null;
var r7b6 = f === null;
var r7b7 = g === null;

// operator !==
var r8a1 = null !== a;
var r8a2 = null !== b;
var r8a3 = null !== c;
var r8a4 = null !== d;
var r8a5 = null !== e;
var r8a6 = null !== f;
var r8a7 = null !== g;

var r8b1 = a !== null;
var r8b2 = b !== null;
var r8b3 = c !== null;
var r8b4 = d !== null;
var r8b5 = e !== null;
var r8b6 = f !== null;
var r8b7 = g !== null;`,
      [],
    );
  });
  test("comparisonOperatorWithOneOperandIsUndefined", async () => {
    await expectPass(
      `var x: typeof undefined;

enum E { a, b, c }

function foo<T>(t: T) {
    var foo_r1 = t < x;
    var foo_r2 = t > x;
    var foo_r3 = t <= x;
    var foo_r4 = t >= x;
    var foo_r5 = t == x;
    var foo_r6 = t != x;
    var foo_r7 = t === x;
    var foo_r8 = t !== x;

    var foo_r1 = x < t;
    var foo_r2 = x > t;
    var foo_r3 = x <= t;
    var foo_r4 = x >= t;
    var foo_r5 = x == t;
    var foo_r6 = x != t;
    var foo_r7 = x === t;
    var foo_r8 = x !== t;
}

var a: boolean;
var b: number;
var c: string;
var d: void;
var e: E;
var f: {};
var g: string[];

// operator <
var r1a1 = x < a;
var r1a2 = x < b;
var r1a3 = x < c;
var r1a4 = x < d;
var r1a5 = x < e;
var r1a6 = x < f;
var r1a7 = x < g;

var r1b1 = a < x;
var r1b2 = b < x;
var r1b3 = c < x;
var r1b4 = d < x;
var r1b5 = e < x;
var r1b6 = f < x;
var r1b7 = g < x;

// operator >
var r2a1 = x > a;
var r2a2 = x > b;
var r2a3 = x > c;
var r2a4 = x > d;
var r2a5 = x > e;
var r2a6 = x > f;
var r2a7 = x > g;

var r2b1 = a > x;
var r2b2 = b > x;
var r2b3 = c > x;
var r2b4 = d > x;
var r2b5 = e > x;
var r2b6 = f > x;
var r2b7 = g > x;

// operator <=
var r3a1 = x <= a;
var r3a2 = x <= b;
var r3a3 = x <= c;
var r3a4 = x <= d;
var r3a5 = x <= e;
var r3a6 = x <= f;
var r3a7 = x <= g;

var r3b1 = a <= x;
var r3b2 = b <= x;
var r3b3 = c <= x;
var r3b4 = d <= x;
var r3b5 = e <= x;
var r3b6 = f <= x;
var r3b7 = g <= x;

// operator >=
var r4a1 = x >= a;
var r4a2 = x >= b;
var r4a3 = x >= c;
var r4a4 = x >= d;
var r4a5 = x >= e;
var r4a6 = x >= f;
var r4a7 = x >= g;

var r4b1 = a >= x;
var r4b2 = b >= x;
var r4b3 = c >= x;
var r4b4 = d >= x;
var r4b5 = e >= x;
var r4b6 = f >= x;
var r4b7 = g >= x;

// operator ==
var r5a1 = x == a;
var r5a2 = x == b;
var r5a3 = x == c;
var r5a4 = x == d;
var r5a5 = x == e;
var r5a6 = x == f;
var r5a7 = x == g;

var r5b1 = a == x;
var r5b2 = b == x;
var r5b3 = c == x;
var r5b4 = d == x;
var r5b5 = e == x;
var r5b6 = f == x;
var r5b7 = g == x;

// operator !=
var r6a1 = x != a;
var r6a2 = x != b;
var r6a3 = x != c;
var r6a4 = x != d;
var r6a5 = x != e;
var r6a6 = x != f;
var r6a7 = x != g;

var r6b1 = a != x;
var r6b2 = b != x;
var r6b3 = c != x;
var r6b4 = d != x;
var r6b5 = e != x;
var r6b6 = f != x;
var r6b7 = g != x;

// operator ===
var r7a1 = x === a;
var r7a2 = x === b;
var r7a3 = x === c;
var r7a4 = x === d;
var r7a5 = x === e;
var r7a6 = x === f;
var r7a7 = x === g;

var r7b1 = a === x;
var r7b2 = b === x;
var r7b3 = c === x;
var r7b4 = d === x;
var r7b5 = e === x;
var r7b6 = f === x;
var r7b7 = g === x;

// operator !==
var r8a1 = x !== a;
var r8a2 = x !== b;
var r8a3 = x !== c;
var r8a4 = x !== d;
var r8a5 = x !== e;
var r8a6 = x !== f;
var r8a7 = x !== g;

var r8b1 = a !== x;
var r8b2 = b !== x;
var r8b3 = c !== x;
var r8b4 = d !== x;
var r8b5 = e !== x;
var r8b6 = f !== x;
var r8b7 = g !== x;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeEnumAndNumber", async () => {
    await expectPass(
      `enum E { a, b, c }

var a: E;
var b: number;

// operator <
var ra1 = a < b;
var ra2 = b < a;
var ra3 = E.a < b;
var ra4 = b < E.a;
var ra5 = E.a < 0;
var ra6 = 0 < E.a;

// operator >
var rb1 = a > b;
var rb2 = b > a;
var rb3 = E.a > b;
var rb4 = b > E.a;
var rb5 = E.a > 0;
var rb6 = 0 > E.a;

// operator <=
var rc1 = a <= b;
var rc2 = b <= a;
var rc3 = E.a <= b;
var rc4 = b <= E.a;
var rc5 = E.a <= 0;
var rc6 = 0 <= E.a;

// operator >=
var rd1 = a >= b;
var rd2 = b >= a;
var rd3 = E.a >= b;
var rd4 = b >= E.a;
var rd5 = E.a >= 0;
var rd6 = 0 >= E.a;

// operator ==
var re1 = a == b;
var re2 = b == a;
var re3 = E.a == b;
var re4 = b == E.a;
var re5 = E.a == 0;
var re6 = 0 == E.a;

// operator !=
var rf1 = a != b;
var rf2 = b != a;
var rf3 = E.a != b;
var rf4 = b != E.a;
var rf5 = E.a != 0;
var rf6 = 0 != E.a;

// operator ===
var rg1 = a === b;
var rg2 = b === a;
var rg3 = E.a === b;
var rg4 = b === E.a;
var rg5 = E.a === 0;
var rg6 = 0 === E.a;

// operator !==
var rh1 = a !== b;
var rh2 = b !== a;
var rh3 = E.a !== b;
var rh4 = b !== E.a;
var rh5 = E.a !== 0;
var rh6 = 0 !== E.a;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnCallSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

var a1: { fn(): void };
var b1: { fn(): void };

var a2: { fn(a: number, b: string): void };
var b2: { fn(a: number, b: string): void };

var a3: { fn(a: number, b: string): void };
var b3: { fn(a: number): void };

var a4: { fn(a: number, b: string): void };
var b4: { fn(): void };

var a5: { fn(a: Base): void };
var b5: { fn(a: Derived): void };

var a6: { fn(a: Derived, b: Base): void };
var b6: { fn(a: Base, b: Derived): void };

var a7: { fn(): void };
var b7: { fn(): Base };

var a8: { fn(): Base };
var b8: { fn(): Base };

var a9: { fn(): Base };
var b9: { fn(): Derived };

var a10: { fn(a?: Base): void };
var b10: { fn(a?: Derived): void };

var a11: { fn(...a: Base[]): void };
var b11: { fn(...a: Derived[]): void };

//var a12: { fn<T, U extends T>(t: T, u: U): T[] };
//var b12: { fn<A, B extends A>(a: A, b: B): A[] };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;
var r1a7 = a7 < b7;
var r1a8 = a8 < b8;
var r1a9 = a9 < b9;
var r1a10 = a10 < b10;
var r1a11 = a11 < b11;
//var r1a12 = a12 < b12;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;
var r1b7 = b7 < a7;
var r1b8 = b8 < a8;
var r1b9 = b9 < a9;
var r1b10 = b10 < a10;
var r1b11 = b11 < a11;
//var r1b12 = b12 < a12;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;
var r2a7 = a7 > b7;
var r2a8 = a8 > b8;
var r2a9 = a9 > b9;
var r2a10 = a10 > b10;
var r2a11 = a11 > b11;
//var r2a12 = a12 > b12;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;
var r2b7 = b7 > a7;
var r2b8 = b8 > a8;
var r2b9 = b9 > a9;
var r2b10 = b10 > a10;
var r2b11 = b11 > a11;
//var r2b12 = b12 > a12;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;
var r3a7 = a7 <= b7;
var r3a8 = a8 <= b8;
var r3a9 = a9 <= b9;
var r3a10 = a10 <= b10;
var r3a11 = a11 <= b11;
//var r3a12 = a12 <= b12;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;
var r3b7 = b7 <= a7;
var r3b8 = b8 <= a8;
var r3b9 = b9 <= a9;
var r3b10 = b10 <= a10;
var r3b11 = b11 <= a11;
//var r3b12 = b12 <= a12;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;
var r4a7 = a7 >= b7;
var r4a8 = a8 >= b8;
var r4a9 = a9 >= b9;
var r4a10 = a10 >= b10;
var r4a11 = a11 >= b11;
//var r4a12 = a12 >= b12;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;
var r4b7 = b7 >= a7;
var r4b8 = b8 >= a8;
var r4b9 = b9 >= a9;
var r4b10 = b10 >= a10;
var r4b11 = b11 >= a11;
//var r4b12 = b12 >= a12;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;
var r5a7 = a7 == b7;
var r5a8 = a8 == b8;
var r5a9 = a9 == b9;
var r5a10 = a10 == b10;
var r5a11 = a11 == b11;
//var r5a12 = a12 == b12;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;
var r5b7 = b7 == a7;
var r5b8 = b8 == a8;
var r5b9 = b9 == a9;
var r5b10 = b10 == a10;
var r5b11 = b11 == a11;
//var r5b12 = b12 == a12;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;
var r6a7 = a7 != b7;
var r6a8 = a8 != b8;
var r6a9 = a9 != b9;
var r6a10 = a10 != b10;
var r6a11 = a11 != b11;
//var r6a12 = a12 != b12;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;
var r6b7 = b7 != a7;
var r6b8 = b8 != a8;
var r6b9 = b9 != a9;
var r6b10 = b10 != a10;
var r6b11 = b11 != a11;
//var r6b12 = b12 != a12;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;
var r7a7 = a7 === b7;
var r7a8 = a8 === b8;
var r7a9 = a9 === b9;
var r7a10 = a10 === b10;
var r7a11 = a11 === b11;
//var r7a12 = a12 === b12;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;
var r7b7 = b7 === a7;
var r7b8 = b8 === a8;
var r7b9 = b9 === a9;
var r7b10 = b10 === a10;
var r7b11 = b11 === a11;
//var r7b12 = b12 === a12;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;
var r8a7 = a7 !== b7;
var r8a8 = a8 !== b8;
var r8a9 = a9 !== b9;
var r8a10 = a10 !== b10;
var r8a11 = a11 !== b11;
//var r8a12 = a12 !== b12;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;
var r8b7 = b7 !== a7;
var r8b8 = b8 !== a8;
var r8b9 = b9 !== a9;
var r8b10 = b10 !== a10;
var r8b11 = b11 !== a11;
//var r8b12 = b12 !== a12;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnConstructorSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

var a1: { new (): Base };
var b1: { new (): Base };

var a2: { new (a: number, b: string): Base };
var b2: { new (a: number, b: string): Base };

var a3: { new (a: number, b: string): Base };
var b3: { new (a: number): Base };

var a4: { new (a: number, b: string): Base };
var b4: { new (): Base };

var a5: { new (a: Base): Base };
var b5: { new (a: Derived): Base };

var a6: { new (a: Derived, b: Base): Base };
var b6: { new (a: Base, b: Derived): Base };

var a7: { new (): Base };
var b7: { new (): Derived };

var a8: { new (a?: Base): Base };
var b8: { new (a?: Derived): Base };

var a9: { new (...a: Base[]): Base };
var b9: { new (...a: Derived[]): Base };

//var a10: { <T, U extends T>(t: T, u: U): T[] };
//var b10: { <A, B extends A>(a: A, b: B): A[] };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;
var r1a7 = a7 < b7;
var r1a8 = a8 < b8;
var r1a9 = a9 < b9;
//var r1a10 = a10 < b10;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;
var r1b7 = b7 < a7;
var r1b8 = b8 < a8;
var r1b9 = b9 < a9;
//var r1b10 = b10 < a10;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;
var r2a7 = a7 > b7;
var r2a8 = a8 > b8;
var r2a9 = a9 > b9;
//var r2a10 = a10 > b10;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;
var r2b7 = b7 > a7;
var r2b8 = b8 > a8;
var r2b9 = b9 > a9;
//var r2b10 = b10 > a10;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;
var r3a7 = a7 <= b7;
var r3a8 = a8 <= b8;
var r3a9 = a9 <= b9;
//var r3a10 = a10 <= b10;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;
var r3b7 = b7 <= a7;
var r3b8 = b8 <= a8;
var r3b9 = b9 <= a9;
//var r3b10 = b10 <= a10;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;
var r4a7 = a7 >= b7;
var r4a8 = a8 >= b8;
var r4a9 = a9 >= b9;
//var r4a10 = a10 >= b10;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;
var r4b7 = b7 >= a7;
var r4b8 = b8 >= a8;
var r4b9 = b9 >= a9;
//var r4b10 = b10 >= a10;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;
var r5a7 = a7 == b7;
var r5a8 = a8 == b8;
var r5a9 = a9 == b9;
//var r5a10 = a10 == b10;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;
var r5b7 = b7 == a7;
var r5b8 = b8 == a8;
var r5b9 = b9 == a9;
//var r5b10 = b10 == a10;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;
var r6a7 = a7 != b7;
var r6a8 = a8 != b8;
var r6a9 = a9 != b9;
//var r6a10 = a10 != b10;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;
var r6b7 = b7 != a7;
var r6b8 = b8 != a8;
var r6b9 = b9 != a9;
//var r6b10 = b10 != a10;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;
var r7a7 = a7 === b7;
var r7a8 = a8 === b8;
var r7a9 = a9 === b9;
//var r7a10 = a10 === b10;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;
var r7b7 = b7 === a7;
var r7b8 = b8 === a8;
var r7b9 = b9 === a9;
//var r7b10 = b10 === a10;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;
var r8a7 = a7 !== b7;
var r8a8 = a8 !== b8;
var r8a9 = a9 !== b9;
//var r8a10 = a10 !== b10;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;
var r8b7 = b7 !== a7;
var r8b8 = b8 !== a8;
var r8b9 = b9 !== a9;
//var r8b10 = b10 !== a10;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnIndexSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

var a1: { [a: string]: string };
var b1: { [b: string]: string };

var a2: { [index: string]: Base };
var b2: { [index: string]: Derived };

var a3: { [index: number]: string };
var b3: { [index: number]: string };

var a4: { [index: number]: Base };
var b4: { [index: string]: Derived };

// operator <
var r1a1 = a1 < b1;
var r1a1 = a2 < b2;
var r1a1 = a3 < b3;
var r1a1 = a4 < b4;

var r1b1 = b1 < a1;
var r1b1 = b2 < a2;
var r1b1 = b3 < a3;
var r1b1 = b4 < a4;

// operator >
var r2a1 = a1 > b1;
var r2a1 = a2 > b2;
var r2a1 = a3 > b3;
var r2a1 = a4 > b4;

var r2b1 = b1 > a1;
var r2b1 = b2 > a2;
var r2b1 = b3 > a3;
var r2b1 = b4 > a4;

// operator <=
var r3a1 = a1 <= b1;
var r3a1 = a2 <= b2;
var r3a1 = a3 <= b3;
var r3a1 = a4 <= b4;

var r3b1 = b1 <= a1;
var r3b1 = b2 <= a2;
var r3b1 = b3 <= a3;
var r3b1 = b4 <= a4;

// operator >=
var r4a1 = a1 >= b1;
var r4a1 = a2 >= b2;
var r4a1 = a3 >= b3;
var r4a1 = a4 >= b4;

var r4b1 = b1 >= a1;
var r4b1 = b2 >= a2;
var r4b1 = b3 >= a3;
var r4b1 = b4 >= a4;

// operator ==
var r5a1 = a1 == b1;
var r5a1 = a2 == b2;
var r5a1 = a3 == b3;
var r5a1 = a4 == b4;

var r5b1 = b1 == a1;
var r5b1 = b2 == a2;
var r5b1 = b3 == a3;
var r5b1 = b4 == a4;

// operator !=
var r6a1 = a1 != b1;
var r6a1 = a2 != b2;
var r6a1 = a3 != b3;
var r6a1 = a4 != b4;

var r6b1 = b1 != a1;
var r6b1 = b2 != a2;
var r6b1 = b3 != a3;
var r6b1 = b4 != a4;

// operator ===
var r7a1 = a1 === b1;
var r7a1 = a2 === b2;
var r7a1 = a3 === b3;
var r7a1 = a4 === b4;

var r7b1 = b1 === a1;
var r7b1 = b2 === a2;
var r7b1 = b3 === a3;
var r7b1 = b4 === a4;

// operator !==
var r8a1 = a1 !== b1;
var r8a1 = a2 !== b2;
var r8a1 = a3 !== b3;
var r8a1 = a4 !== b4;

var r8b1 = b1 !== a1;
var r8b1 = b2 !== a2;
var r8b1 = b3 !== a3;
var r8b1 = b4 !== a4;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnInstantiatedCallSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

var a1: { fn<T>(x: T): T };
var b1: { fn(x: string): string };

var a2: { fn<T>(x: T): T };
var b2: { fn(x: string, y: number): string };

var a3: { fn<T, U>(x: T, y: U): T };
var b3: { fn(x: string, y: number): string };

var a4: { fn<T>(x?: T): T };
var b4: { fn(x?: string): string };

var a5: { fn<T>(...x: T[]): T };
var b5: { fn(...x: string[]): string };

var a6: { fn<T>(x: T, y: T): T };
var b6: { fn(x: string, y: number): {} };

//var a7: { fn<T, U extends T>(x: T, y: U): T };
var b7: { fn(x: Base, y: Derived): Base };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;
//var r1a7 = a7 < b7;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;
//var r1b7 = b7 < a7;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;
//var r2a7 = a7 > b7;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;
//var r2b7 = b7 > a7;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;
//var r3a7 = a7 <= b7;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;
//var r3b7 = b7 <= a7;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;
//var r4a7 = a7 >= b7;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;
//var r4b7 = b7 >= a7;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;
//var r5a7 = a7 == b7;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;
//var r5b7 = b7 == a7;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;
//var r6a7 = a7 != b7;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;
//var r6b7 = b7 != a7;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;
//var r7a7 = a7 === b7;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;
//var r7b7 = b7 === a7;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;
//var r8a7 = a7 !== b7;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;
//var r8b7 = b7 !== a7;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnInstantiatedConstructorSignature", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

var a1: { new <T>(x: T): T };
var b1: { new (x: string): string };

var a2: { new <T>(x: T): T };
var b2: { new (x: string, y: number): string };

var a3: { new <T, U>(x: T, y: U): T };
var b3: { new (x: string, y: number): string };

var a4: { new <T>(x?: T): T };
var b4: { new (x?: string): string };

var a5: { new <T>(...x: T[]): T };
var b5: { new (...x: string[]): string };

var a6: { new <T>(x: T, y: T): T };
var b6: { new (x: string, y: number): {} };

//var a7: { new <T, U extends T>(x: T, y: U): T };
var b7: { new (x: Base, y: Derived): Base };

// operator <
var r1a1 = a1 < b1;
var r1a2 = a2 < b2;
var r1a3 = a3 < b3;
var r1a4 = a4 < b4;
var r1a5 = a5 < b5;
var r1a6 = a6 < b6;
//var r1a7 = a7 < b7;

var r1b1 = b1 < a1;
var r1b2 = b2 < a2;
var r1b3 = b3 < a3;
var r1b4 = b4 < a4;
var r1b5 = b5 < a5;
var r1b6 = b6 < a6;
//var r1b7 = b7 < a7;

// operator >
var r2a1 = a1 > b1;
var r2a2 = a2 > b2;
var r2a3 = a3 > b3;
var r2a4 = a4 > b4;
var r2a5 = a5 > b5;
var r2a6 = a6 > b6;
//var r2a7 = a7 > b7;

var r2b1 = b1 > a1;
var r2b2 = b2 > a2;
var r2b3 = b3 > a3;
var r2b4 = b4 > a4;
var r2b5 = b5 > a5;
var r2b6 = b6 > a6;
//var r2b7 = b7 > a7;

// operator <=
var r3a1 = a1 <= b1;
var r3a2 = a2 <= b2;
var r3a3 = a3 <= b3;
var r3a4 = a4 <= b4;
var r3a5 = a5 <= b5;
var r3a6 = a6 <= b6;
//var r3a7 = a7 <= b7;

var r3b1 = b1 <= a1;
var r3b2 = b2 <= a2;
var r3b3 = b3 <= a3;
var r3b4 = b4 <= a4;
var r3b5 = b5 <= a5;
var r3b6 = b6 <= a6;
//var r3b7 = b7 <= a7;

// operator >=
var r4a1 = a1 >= b1;
var r4a2 = a2 >= b2;
var r4a3 = a3 >= b3;
var r4a4 = a4 >= b4;
var r4a5 = a5 >= b5;
var r4a6 = a6 >= b6;
//var r4a7 = a7 >= b7;

var r4b1 = b1 >= a1;
var r4b2 = b2 >= a2;
var r4b3 = b3 >= a3;
var r4b4 = b4 >= a4;
var r4b5 = b5 >= a5;
var r4b6 = b6 >= a6;
//var r4b7 = b7 >= a7;

// operator ==
var r5a1 = a1 == b1;
var r5a2 = a2 == b2;
var r5a3 = a3 == b3;
var r5a4 = a4 == b4;
var r5a5 = a5 == b5;
var r5a6 = a6 == b6;
//var r5a7 = a7 == b7;

var r5b1 = b1 == a1;
var r5b2 = b2 == a2;
var r5b3 = b3 == a3;
var r5b4 = b4 == a4;
var r5b5 = b5 == a5;
var r5b6 = b6 == a6;
//var r5b7 = b7 == a7;

// operator !=
var r6a1 = a1 != b1;
var r6a2 = a2 != b2;
var r6a3 = a3 != b3;
var r6a4 = a4 != b4;
var r6a5 = a5 != b5;
var r6a6 = a6 != b6;
//var r6a7 = a7 != b7;

var r6b1 = b1 != a1;
var r6b2 = b2 != a2;
var r6b3 = b3 != a3;
var r6b4 = b4 != a4;
var r6b5 = b5 != a5;
var r6b6 = b6 != a6;
//var r6b7 = b7 != a7;

// operator ===
var r7a1 = a1 === b1;
var r7a2 = a2 === b2;
var r7a3 = a3 === b3;
var r7a4 = a4 === b4;
var r7a5 = a5 === b5;
var r7a6 = a6 === b6;
//var r7a7 = a7 === b7;

var r7b1 = b1 === a1;
var r7b2 = b2 === a2;
var r7b3 = b3 === a3;
var r7b4 = b4 === a4;
var r7b5 = b5 === a5;
var r7b6 = b6 === a6;
//var r7b7 = b7 === a7;

// operator !==
var r8a1 = a1 !== b1;
var r8a2 = a2 !== b2;
var r8a3 = a3 !== b3;
var r8a4 = a4 !== b4;
var r8a5 = a5 !== b5;
var r8a6 = a6 !== b6;
//var r8a7 = a7 !== b7;

var r8b1 = b1 !== a1;
var r8b2 = b2 !== a2;
var r8b3 = b3 !== a3;
var r8b4 = b4 !== a4;
var r8b5 = b5 !== a5;
var r8b6 = b6 !== a6;
//var r8b7 = b7 !== a7;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnOptionalProperty", async () => {
    await expectPass(
      `interface I {
    a: string;
    b?: number;
}

interface J {
    a: string;
}

var a: I;
var b: J;

// operator <
var ra1 = a < b;
var ra2 = b < a;

// operator >
var rb1 = a > b;
var rb2 = b > a;

// operator <=
var rc1 = a <= b;
var rc2 = b <= a;

// operator >=
var rd1 = a >= b;
var rd2 = b >= a;

// operator ==
var re1 = a == b;
var re2 = b == a;

// operator !=
var rf1 = a != b;
var rf2 = b != a;

// operator ===
var rg1 = a === b;
var rg2 = b === a;

// operator !==
var rh1 = a !== b;
var rh2 = b !== a;`,
      [],
    );
  });
  test("comparisonOperatorWithSubtypeObjectOnProperty", async () => {
    await expectPass(
      `class Base {
    public a: string;
}

class Derived extends Base {
    public b: string;
}

class A1 {
    public a: Base;
    public b: Base;
}

class B1 {
    public a: Base;
    public b: Derived;
}

class A2 {
    private a;
}

class B2 extends A2 {
    private b;
}

var a1: A1;
var a2: A2;
var b1: B1;
var b2: B2;

// operator <
var ra1 = a1 < b1;
var ra2 = a2 < b2;
var ra3 = b1 < a1;
var ra4 = b2 < a2;

// operator >
var rb1 = a1 > b1;
var rb2 = a2 > b2;
var rb3 = b1 > a1;
var rb4 = b2 > a2;

// operator <=
var rc1 = a1 <= b1;
var rc2 = a2 <= b2;
var rc3 = b1 <= a1;
var rc4 = b2 <= a2;

// operator >=
var rd1 = a1 >= b1;
var rd2 = a2 >= b2;
var rd3 = b1 >= a1;
var rd4 = b2 >= a2;

// operator ==
var re1 = a1 == b1;
var re2 = a2 == b2;
var re3 = b1 == a1;
var re4 = b2 == a2;

// operator !=
var rf1 = a1 != b1;
var rf2 = a2 != b2;
var rf3 = b1 != a1;
var rf4 = b2 != a2;

// operator ===
var rg1 = a1 === b1;
var rg2 = a2 === b2;
var rg3 = b1 === a1;
var rg4 = b2 === a2;

// operator !==
var rh1 = a1 !== b1;
var rh2 = a2 !== b2;
var rh3 = b1 !== a1;
var rh4 = b2 !== a2;`,
      [],
    );
  });
  test("comparisonOperatorWithTwoOperandsAreAny", async () => {
    await expectPass(
      `var a: any;

var r1 = a < a;
var r2 = a > a;
var r3 = a <= a;
var r4 = a >= a;
var r5 = a == a;
var r6 = a != a;
var r7 = a === a;
var r8 = a !== a;`,
      [],
    );
  });
  test("comparisonOperatorWithTypeParameter", async () => {
    await expectPass(
      `var a: {};
var b: Object;

function foo<T, U/* extends T*/, V/* extends U*/>(t: T, u: U, v: V) {
    // errors
    var ra1 = t < u;
    var ra2 = t > u;
    var ra3 = t <= u;
    var ra4 = t >= u;
    var ra5 = t == u;
    var ra6 = t != u;
    var ra7 = t === u;
    var ra8 = t !== u;

    var rb1 = u < t;
    var rb2 = u > t;
    var rb3 = u <= t;
    var rb4 = u >= t;
    var rb5 = u == t;
    var rb6 = u != t;
    var rb7 = u === t;
    var rb8 = u !== t;

    var rc1 = t < v;
    var rc2 = t > v;
    var rc3 = t <= v;
    var rc4 = t >= v;
    var rc5 = t == v;
    var rc6 = t != v;
    var rc7 = t === v;
    var rc8 = t !== v;

    var rd1 = v < t;
    var rd2 = v > t;
    var rd3 = v <= t;
    var rd4 = v >= t;
    var rd5 = v == t;
    var rd6 = v != t;
    var rd7 = v === t;
    var rd8 = v !== t;

    // ok
    var re1 = t < a;
    var re2 = t > a;
    var re3 = t <= a;
    var re4 = t >= a;
    var re5 = t == a;
    var re6 = t != a;
    var re7 = t === a;
    var re8 = t !== a;

    var rf1 = a < t;
    var rf2 = a > t;
    var rf3 = a <= t;
    var rf4 = a >= t;
    var rf5 = a == t;
    var rf6 = a != t;
    var rf7 = a === t;
    var rf8 = a !== t;

    var rg1 = t < b;
    var rg2 = t > b;
    var rg3 = t <= b;
    var rg4 = t >= b;
    var rg5 = t == b;
    var rg6 = t != b;
    var rg7 = t === b;
    var rg8 = t !== b;

    var rh1 = b < t;
    var rh2 = b > t;
    var rh3 = b <= t;
    var rh4 = b >= t;
    var rh5 = b == t;
    var rh6 = b != t;
    var rh7 = b === t;
    var rh8 = b !== t;
}`,
      [],
    );
  });
  test("inOperatorWithInvalidOperands", async () => {
    await expectPass(
      `class Foo {}
enum E { a }

var x: any;

// invalid left operands
// the left operand is required to be of type Any, the String primitive type, or the Number primitive type
declare var a1: boolean;
declare var a2: void;
declare var a3: {};
declare var a4: E;
declare var a5: Foo | string;
declare var a6: Foo;

var ra1 = a1 in x;
var ra2 = a2 in x;
var ra3 = a3 in x;
var ra4 = a4 in x;
var ra5 = null in x;
var ra6 = undefined in x;
var ra7 = E.a in x;
var ra8 = false in x;
var ra9 = {} in x;
var ra10 = a5 in x;
var ra11 = a6 in x;

// invalid right operands
// the right operand is required to be of type Any, an object type, or a type parameter type
declare var b1: number;
declare var b2: boolean;
declare var b3: string;
declare var b4: void;
declare var b5: string | number;

var rb1 = x in b1;
var rb2 = x in b2;
var rb3 = x in b3;
var rb4 = x in b4;
var rb5 = x in b5;
var rb6 = x in 0;
var rb7 = x in false;
var rb8 = x in '';
var rb9 = x in null;
var rb10 = x in undefined;

// both operands are invalid
var rc1 = {} in '';`,
      [],
    );
  });
  test("inOperatorWithValidOperands", async () => {
    await expectPass(
      `var x: any;

// valid left operands
// the left operand is required to be of type Any, the String primitive type, or the Number primitive type
declare var a1: string;
declare var a2: number;
declare var a3: string | number | symbol;
declare var a4: any;

var ra1 = x in x;
var ra2 = a1 in x;
var ra3 = a2 in x;
var ra4 = '' in x;
var ra5 = 0 in x;
var ra6 = a3 in x;
var ra7 = a4 in x;

// valid right operands
// the right operand is required to be of type Any, an object type, or a type parameter type
declare var b1: {};

var rb1 = x in b1;
var rb2 = x in {};

function foo<T>(t: T) {
    var rb3 = x in t;
}

function unionCase<T, U>(t: T | U) {
    var rb4 = x in t;
}

function unionCase2<T>(t: T | object) {
    var rb5 = x in t;
}

interface X { x: number }
interface Y { y: number }

declare var c1: X | Y;
declare var c2: X;
declare var c3: Y;

var rc1 = x in c1;
var rc2 = x in (c2 || c3);`,
      [],
    );
  });
  test("instanceofOperatorWithAny", async () => {
    await expectPass(
      `var a: any;

var r: boolean = a instanceof a;`,
      [],
    );
  });
  test("instanceofOperatorWithInvalidOperands.es2015", async () => {
    await expectError(
      `class C {
    foo() { }
}

var x: any;

// invalid left operand
// the left operand is required to be of type Any, an object type, or a type parameter type
declare var a1: number;
declare var a2: boolean;
declare var a3: string;
var a4: void;

var ra1 = a1 instanceof x;
var ra2 = a2 instanceof x;
var ra3 = a3 instanceof x;
var ra4 = a4 instanceof x;
var ra5 = 0 instanceof x;
var ra6 = true instanceof x;
var ra7 = '' instanceof x;
var ra8 = null instanceof x;
var ra9 = undefined instanceof x;

// invalid right operand
// the right operand to be of type Any or a subtype of the 'Function' interface type
declare var b1: number;
declare var b2: boolean;
declare var b3: string;
var b4: void;
declare var o1: {};
declare var o2: Object;
declare var o3: C;

var rb1 = x instanceof b1;
var rb2 = x instanceof b2;
var rb3 = x instanceof b3;
var rb4 = x instanceof b4;
var rb5 = x instanceof 0;
var rb6 = x instanceof true;
var rb7 = x instanceof '';
var rb8 = x instanceof o1;
var rb9 = x instanceof o2;
var rb10 = x instanceof o3;

// both operands are invalid
var rc1 = '' instanceof {};

declare var o4: {[Symbol.hasInstance](value: { x: number }): boolean;};
declare var o5: { y: string };
var ra10 = o5 instanceof o4;

// invalid @@hasInstance method return type on RHS
declare var o6: {[Symbol.hasInstance](value: unknown): number;};
var rb11 = x instanceof o6;`,
      [],
    );
  });
  test("instanceofOperatorWithInvalidOperands", async () => {
    await expectPass(
      `class C {
    foo() { }
}

var x: any;

// invalid left operand
// the left operand is required to be of type Any, an object type, or a type parameter type
declare var a1: number;
declare var a2: boolean;
declare var a3: string;
var a4: void;

var ra1 = a1 instanceof x;
var ra2 = a2 instanceof x;
var ra3 = a3 instanceof x;
var ra4 = a4 instanceof x;
var ra5 = 0 instanceof x;
var ra6 = true instanceof x;
var ra7 = '' instanceof x;
var ra8 = null instanceof x;
var ra9 = undefined instanceof x;

// invalid right operand
// the right operand to be of type Any or a subtype of the 'Function' interface type
declare var b1: number;
declare var b2: boolean;
declare var b3: string;
declare var b4: void;
declare var o1: {};
declare var o2: Object;
declare var o3: C;

var rb1 = x instanceof b1;
var rb2 = x instanceof b2;
var rb3 = x instanceof b3;
var rb4 = x instanceof b4;
var rb5 = x instanceof 0;
var rb6 = x instanceof true;
var rb7 = x instanceof '';
var rb8 = x instanceof o1;
var rb9 = x instanceof o2;
var rb10 = x instanceof o3;

// both operands are invalid
var rc1 = '' instanceof {};`,
      [],
    );
  });
  test("instanceofOperatorWithInvalidStaticToString", async () => {
    await expectPass(
      `declare class StaticToString {
    static toString(): void;
}

function foo(staticToString: StaticToString) {
    return staticToString instanceof StaticToString;
}

declare class StaticToNumber {
    static toNumber(): void;
}
function bar(staticToNumber: StaticToNumber) {
    return staticToNumber instanceof StaticToNumber;
}

declare class NormalToString {
    toString(): void;
}
function baz(normal: NormalToString) {
    return normal instanceof NormalToString;
}`,
      [],
    );
  });
  test("instanceofOperatorWithLHSIsObject", async () => {
    await expectPass(
      `class C { }

var x1: any;
var x2: Function;

var a: {};
var b: Object;
var c: C;
var d: string | C;

var r1 = a instanceof x1;
var r2 = b instanceof x2;
var r3 = c instanceof x1;
var r4 = d instanceof x1;`,
      [],
    );
  });
  test("instanceofOperatorWithLHSIsTypeParameter", async () => {
    await expectPass(
      `function foo<T>(t: T) {
    var x: any;
    var r = t instanceof x;
}`,
      [],
    );
  });
  test("instanceofOperatorWithRHSHasSymbolHasInstance", async () => {
    await expectError(
      `
interface Point { x: number, y: number }
interface Point3D { x: number, y: number, z: number }
interface Point3D2 extends Point { z: number }
interface Line { start: Point, end: Point }

declare var rhs0: { [Symbol.hasInstance](value: unknown): boolean; };
declare var rhs1: { [Symbol.hasInstance](value: any): boolean; };
declare var rhs2: { [Symbol.hasInstance](value: any): value is Point; };
declare var rhs3: { [Symbol.hasInstance](value: Point | Line): value is Point; };
declare var rhs4: { [Symbol.hasInstance](value: Point | Line): value is Line; };
declare var rhs5: { [Symbol.hasInstance](value: Point | Point3D | Line): value is Point3D; };
declare var rhs6: { [Symbol.hasInstance](value: Point3D | Line): value is Point3D; };

declare class Rhs7 { static [Symbol.hasInstance](value: unknown): boolean; }
declare class Rhs8 { static [Symbol.hasInstance](value: any): boolean; }
declare class Rhs9 { static [Symbol.hasInstance](value: any): value is Point; }
declare class Rhs10 { static [Symbol.hasInstance](value: Point | Line): value is Point; }
declare class Rhs11 { static [Symbol.hasInstance](value: Point | Line): value is Line; }
declare class Rhs12 { static [Symbol.hasInstance](value: Point | Point3D | Line): value is Point3D; }
declare class Rhs13 { static [Symbol.hasInstance](value: Point3D | Line): value is Point3D; }

declare var lhs0: any;
declare var lhs1: object;
declare var lhs2: Point | Point3D | Line;
declare var lhs3: Point3D | Line;
declare var lhs4: Point | Point3D2 | Line;

lhs0 instanceof rhs0 && lhs0;
lhs0 instanceof rhs1 && lhs0;
lhs0 instanceof rhs2 && lhs0;
lhs0 instanceof rhs3 && lhs0;
lhs0 instanceof rhs4 && lhs0;
lhs0 instanceof rhs5 && lhs0;
lhs0 instanceof rhs6 && lhs0;
lhs0 instanceof Rhs7 && lhs0;
lhs0 instanceof Rhs8 && lhs0;
lhs0 instanceof Rhs9 && lhs0;
lhs0 instanceof Rhs10 && lhs0;
lhs0 instanceof Rhs11 && lhs0;
lhs0 instanceof Rhs12 && lhs0;
lhs0 instanceof Rhs13 && lhs0;

lhs1 instanceof rhs0 && lhs1;
lhs1 instanceof rhs1 && lhs1;
lhs1 instanceof rhs2 && lhs1;
lhs1 instanceof Rhs7 && lhs1;
lhs1 instanceof Rhs8 && lhs1;
lhs1 instanceof Rhs9 && lhs1;

lhs2 instanceof rhs0 && lhs2;
lhs2 instanceof rhs1 && lhs2;
lhs2 instanceof rhs2 && lhs2;
lhs2 instanceof rhs3 && lhs2;
lhs2 instanceof rhs4 && lhs2;
lhs2 instanceof rhs5 && lhs2;
lhs2 instanceof Rhs7 && lhs2;
lhs2 instanceof Rhs8 && lhs2;
lhs2 instanceof Rhs9 && lhs2;
lhs2 instanceof Rhs10 && lhs2;
lhs2 instanceof Rhs11 && lhs2;
lhs2 instanceof Rhs12 && lhs2;

lhs3 instanceof rhs0 && lhs3;
lhs3 instanceof rhs1 && lhs3;
lhs3 instanceof rhs2 && lhs3;
lhs3 instanceof rhs3 && lhs3;
lhs3 instanceof rhs4 && lhs3;
lhs3 instanceof rhs5 && lhs3;
lhs3 instanceof rhs6 && lhs3;
lhs3 instanceof Rhs7 && lhs3;
lhs3 instanceof Rhs8 && lhs3;
lhs3 instanceof Rhs9 && lhs3;
lhs3 instanceof Rhs10 && lhs3;
lhs3 instanceof Rhs11 && lhs3;
lhs3 instanceof Rhs12 && lhs3;
lhs3 instanceof Rhs13 && lhs3;

lhs4 instanceof rhs0 && lhs4;
lhs4 instanceof rhs1 && lhs4;
lhs4 instanceof rhs2 && lhs4;
lhs4 instanceof rhs3 && lhs4;
lhs4 instanceof rhs4 && lhs4;
lhs4 instanceof rhs5 && lhs4;
lhs4 instanceof Rhs7 && lhs4;
lhs4 instanceof Rhs8 && lhs4;
lhs4 instanceof Rhs9 && lhs4;
lhs4 instanceof Rhs10 && lhs4;
lhs4 instanceof Rhs11 && lhs4;
lhs4 instanceof Rhs12 && lhs4;

declare class A {
    #x: number;

    // approximation of \`getInstanceType\` behavior, with one caveat: the checker versions unions the return types of
    // all construct signatures, but we have no way of extracting individual construct signatures from a type.
    static [Symbol.hasInstance]<T>(this: T, value: unknown): value is (
        T extends globalThis.Function ?
            T extends { readonly prototype: infer U } ?
                boolean extends (U extends never ? true : false) ? // <- tests whether 'U' is 'any'
                    T extends (abstract new (...args: any) => infer V) ? V : {} :
                U :
            never :
        never
    );
}

declare class B extends A { #y: number; }

declare const obj: unknown;
if (obj instanceof A) {
    obj; // A
}
if (obj instanceof B) {
    obj; // B
}

// intersections
// https://github.com/microsoft/TypeScript/issues/56536

interface HasInstanceOf { [Symbol.hasInstance](x: unknown): boolean }
type Rhs14 = HasInstanceOf & object;
declare const rhs14: Rhs14;
lhs0 instanceof rhs14 && lhs0;

// unions

interface HasInstanceOf1 { [Symbol.hasInstance](x: unknown): x is Point }
interface HasInstanceOf2 { [Symbol.hasInstance](x: unknown): x is Line }
type Rhs15 = HasInstanceOf1 | HasInstanceOf2;
declare const rhs15: Rhs15;
lhs0 instanceof rhs15 && lhs0;
`,
      [],
    );
  });
  test("instanceofOperatorWithRHSIsSubtypeOfFunction", async () => {
    await expectPass(
      `interface I extends Function { }

var x: any;
var f1: Function;
var f2: I;
var f3: { (): void };
var f4: { new (): number };

var r1 = x instanceof f1;
var r2 = x instanceof f2;
var r3 = x instanceof f3;
var r4 = x instanceof f4;
var r5 = x instanceof null;
var r6 = x instanceof undefined;`,
      [],
    );
  });
  test("logicalAndOperatorStrictMode", async () => {
    await expectPass(
      `
const a = [0];
const s = "";
const x = 0;
const b = false;
const v: void = undefined;
const u = undefined;
const n = null;
const z = s || x || u;

const a1 = a && a;
const a2 = a && s;
const a3 = a && x;
const a4 = a && b;
const a5 = a && v;
const a6 = a && u;
const a7 = a && n;
const a8 = a && z;

const s1 = s && a;
const s2 = s && s;
const s3 = s && x;
const s4 = s && b;
const s5 = s && v;
const s6 = s && u;
const s7 = s && n;
const s8 = s && z;

const x1 = x && a;
const x2 = x && s;
const x3 = x && x;
const x4 = x && b;
const x5 = x && v;
const x6 = x && u;
const x7 = x && n;
const x8 = x && z;

const b1 = b && a;
const b2 = b && s;
const b3 = b && x;
const b4 = b && b;
const b5 = b && v;
const b6 = b && u;
const b7 = b && n;
const b8 = b && z;

const v1 = v && a;
const v2 = v && s;
const v3 = v && x;
const v4 = v && b;
const v5 = v && v;
const v6 = v && u;
const v7 = v && n;
const v8 = v && z;

const u1 = u && a;
const u2 = u && s;
const u3 = u && x;
const u4 = u && b;
const u5 = u && v;
const u6 = u && u;
const u7 = u && n;
const u8 = u && z;

const n1 = n && a;
const n2 = n && s;
const n3 = n && x;
const n4 = n && b;
const n5 = n && v;
const n6 = n && u;
const n7 = n && n;
const n8 = n && z;

const z1 = z && a;
const z2 = z && s;
const z3 = z && x;
const z4 = z && b;
const z5 = z && v;
const z6 = z && u;
const z7 = z && n;
const z8 = z && z;`,
      [],
    );
  });
  test("logicalAndOperatorWithEveryType", async () => {
    await expectPass(
      `// The && operator permits the operands to be of any type and produces a result of the same
// type as the second operand.

enum E { a, b, c }

var a1: any;
declare var a2: boolean;
declare var a3: number;
declare var a4: string;
declare var a5: void;
declare var a6: E;
declare var a7: {};
declare var a8: string[];

var ra1 = a1 && a1;
var ra2 = a2 && a1;
var ra3 = a3 && a1;
var ra4 = a4 && a1;
var ra5 = a5 && a1;
var ra6 = a6 && a1;
var ra7 = a7 && a1;
var ra8 = a8 && a1;
var ra9 = null && a1;
var ra10 = undefined && a1;

var rb1 = a1 && a2;
var rb2 = a2 && a2;
var rb3 = a3 && a2;
var rb4 = a4 && a2;
var rb5 = a5 && a2;
var rb6 = a6 && a2;
var rb7 = a7 && a2;
var rb8 = a8 && a2;
var rb9 = null && a2;
var rb10 = undefined && a2;

var rc1 = a1 && a3;
var rc2 = a2 && a3;
var rc3 = a3 && a3;
var rc4 = a4 && a3;
var rc5 = a5 && a3;
var rc6 = a6 && a3;
var rc7 = a7 && a3;
var rc8 = a8 && a3;
var rc9 = null && a3;
var rc10 = undefined && a3;

var rd1 = a1 && a4;
var rd2 = a2 && a4;
var rd3 = a3 && a4;
var rd4 = a4 && a4;
var rd5 = a5 && a4;
var rd6 = a6 && a4;
var rd7 = a7 && a4;
var rd8 = a8 && a4;
var rd9 = null && a4;
var rd10 = undefined && a4;

var re1 = a1 && a5;
var re2 = a2 && a5;
var re3 = a3 && a5;
var re4 = a4 && a5;
var re5 = a5 && a5;
var re6 = a6 && a5;
var re7 = a7 && a5;
var re8 = a8 && a5;
var re9 = null && a5;
var re10 = undefined && a5;

var rf1 = a1 && a6;
var rf2 = a2 && a6;
var rf3 = a3 && a6;
var rf4 = a4 && a6;
var rf5 = a5 && a6;
var rf6 = a6 && a6;
var rf7 = a7 && a6;
var rf8 = a8 && a6;
var rf9 = null && a6;
var rf10 = undefined && a6;

var rg1 = a1 && a7;
var rg2 = a2 && a7;
var rg3 = a3 && a7;
var rg4 = a4 && a7;
var rg5 = a5 && a7;
var rg6 = a6 && a7;
var rg7 = a7 && a7;
var rg8 = a8 && a7;
var rg9 = null && a7;
var rg10 = undefined && a7;

var rh1 = a1 && a8;
var rh2 = a2 && a8;
var rh3 = a3 && a8;
var rh4 = a4 && a8;
var rh5 = a5 && a8;
var rh6 = a6 && a8;
var rh7 = a7 && a8;
var rh8 = a8 && a8;
var rh9 = null && a8;
var rh10 = undefined && a8;

var ri1 = a1 && null;
var ri2 = a2 && null;
var ri3 = a3 && null;
var ri4 = a4 && null;
var ri5 = a5 && null;
var ri6 = a6 && null;
var ri7 = a7 && null;
var ri8 = a8 && null;
var ri9 = null && null;
var ri10 = undefined && null;

var rj1 = a1 && undefined;
var rj2 = a2 && undefined;
var rj3 = a3 && undefined;
var rj4 = a4 && undefined;
var rj5 = a5 && undefined;
var rj6 = a6 && undefined;
var rj7 = a7 && undefined;
var rj8 = a8 && undefined;
var rj9 = null && undefined;
var rj10 = undefined && undefined;`,
      [],
    );
  });
  test("logicalAndOperatorWithTypeParameters", async () => {
    await expectPass(
      `// The && operator permits the operands to be of any type and produces a result of the same
// type as the second operand.

function foo<T, U, V/* extends T*/>(t: T, u: U, v: V) {
    var r1 = t && t;
    var r2 = u && t;
    var r3 = v && t;

    var r4 = t && u;
    var r5 = u && u;
    var r6 = v && u;

    var r7 = t && v;
    var r8 = u && v;
    var r9 = v && v;

    var a: number;
    var r10 = t && a;
}`,
      [],
    );
  });
  test("logicalOrExpressionIsContextuallyTyped", async () => {
    await expectPass(
      `// The || operator permits the operands to be of any type.
// If the || expression is contextually typed, the operands are contextually typed by the
// same type and the result is of the best common type of the contextual type and the two
// operand types.

var r: { a: string } = { a: '', b: 123 } || { a: '', b: true };`,
      [],
    );
  });
  test("logicalOrExpressionIsNotContextuallyTyped", async () => {
    await expectPass(
      `// The || operator permits the operands to be of any type.
// If the || expression is not contextually typed, the right operand is contextually typed
// by the type of the left operand and the result is of the best common type of the two
// operand types.


var a: (a: string) => string;

// bug 786110
var r = a || ((a) => a.toLowerCase());`,
      [],
    );
  });
  test("logicalOrOperatorWithEveryType", async () => {
    await expectPass(
      `// The || operator permits the operands to be of any type.
// If the || expression is not contextually typed, the right operand is contextually typed
// by the type of the left operand and the result is of the best common type of the two
// operand types.

enum E { a, b, c }

var a1: any;
declare var a2: boolean;
declare var a3: number;
declare var a4: string;
declare var a5: void;
declare var a6: E;
declare var a7: {a: string};
declare var a8: string[];

var ra1 = a1 || a1;         // any       || any is any
var ra2 = a2 || a1;         // boolean   || any is any
var ra3 = a3 || a1;         // number    || any is any
var ra4 = a4 || a1;         // string    || any is any
var ra5 = a5 || a1;         // void      || any is any
var ra6 = a6 || a1;         // enum      || any is any
var ra7 = a7 || a1;         // object    || any is any
var ra8 = a8 || a1;         // array     || any is any
var ra9 = null || a1;       // null      || any is any
var ra10 = undefined || a1; // undefined || any is any

var rb1 = a1 || a2;         // any       || boolean is any
var rb2 = a2 || a2;         // boolean   || boolean is boolean
var rb3 = a3 || a2;         // number    || boolean is number | boolean
var rb4 = a4 || a2;         // string    || boolean is string | boolean
var rb5 = a5 || a2;         // void      || boolean is void | boolean
var rb6 = a6 || a2;         // enum      || boolean is E | boolean
var rb7 = a7 || a2;         // object    || boolean is object | boolean
var rb8 = a8 || a2;         // array     || boolean is array | boolean
var rb9 = null || a2;       // null      || boolean is boolean
var rb10= undefined || a2;  // undefined || boolean is boolean

var rc1 = a1 || a3;         // any       || number is any
var rc2 = a2 || a3;         // boolean   || number is boolean | number
var rc3 = a3 || a3;         // number    || number is number
var rc4 = a4 || a3;         // string    || number is string | number
var rc5 = a5 || a3;         // void      || number is void | number
var rc6 = a6 || a3;         // enum      || number is number
var rc7 = a7 || a3;         // object    || number is object | number
var rc8 = a8 || a3;         // array     || number is array | number
var rc9 = null || a3;       // null      || number is number
var rc10 = undefined || a3; // undefined || number is number

var rd1 = a1 || a4;         // any       || string is any
var rd2 = a2 || a4;         // boolean   || string is boolean | string
var rd3 = a3 || a4;         // number    || string is number | string
var rd4 = a4 || a4;         // string    || string is string
var rd5 = a5 || a4;         // void      || string is void | string
var rd6 = a6 || a4;         // enum      || string is enum | string
var rd7 = a7 || a4;         // object    || string is object | string
var rd8 = a8 || a4;         // array     || string is array | string
var rd9 = null || a4;       // null      || string is string
var rd10 = undefined || a4; // undefined || string is string

var re1 = a1 || a5;         // any       || void is any
var re2 = a2 || a5;         // boolean   || void is boolean | void
var re3 = a3 || a5;         // number    || void is number | void
var re4 = a4 || a5;         // string    || void is string | void
var re5 = a5 || a5;         // void      || void is void
var re6 = a6 || a5;         // enum      || void is enum | void
var re7 = a7 || a5;         // object    || void is object | void
var re8 = a8 || a5;         // array     || void is array | void
var re9 = null || a5;       // null      || void is void
var re10 = undefined || a5; // undefined || void is void

var rg1 = a1 || a6;         // any       || enum is any
var rg2 = a2 || a6;         // boolean   || enum is boolean | enum
var rg3 = a3 || a6;         // number    || enum is number
var rg4 = a4 || a6;         // string    || enum is string | enum
var rg5 = a5 || a6;         // void      || enum is void | enum
var rg6 = a6 || a6;         // enum      || enum is E
var rg7 = a7 || a6;         // object    || enum is object | enum
var rg8 = a8 || a6;         // array     || enum is array | enum
var rg9 = null || a6;       // null      || enum is E
var rg10 = undefined || a6; // undefined || enum is E

var rh1 = a1 || a7;         // any       || object is any
var rh2 = a2 || a7;         // boolean   || object is boolean | object
var rh3 = a3 || a7;         // number    || object is number | object
var rh4 = a4 || a7;         // string    || object is string | object
var rh5 = a5 || a7;         // void      || object is void | object
var rh6 = a6 || a7;         // enum      || object is enum | object
var rh7 = a7 || a7;         // object    || object is object
var rh8 = a8 || a7;         // array     || object is array | object
var rh9 = null || a7;       // null      || object is object
var rh10 = undefined || a7; // undefined || object is object

var ri1 = a1 || a8;         // any       || array is any
var ri2 = a2 || a8;         // boolean   || array is boolean | array
var ri3 = a3 || a8;         // number    || array is number | array
var ri4 = a4 || a8;         // string    || array is string | array
var ri5 = a5 || a8;         // void      || array is void | array
var ri6 = a6 || a8;         // enum      || array is enum | array
var ri7 = a7 || a8;         // object    || array is object | array
var ri8 = a8 || a8;         // array     || array is array
var ri9 = null || a8;       // null      || array is array
var ri10 = undefined || a8; // undefined || array is array

var rj1 = a1 || null;         // any       || null is any
var rj2 = a2 || null;         // boolean   || null is boolean
var rj3 = a3 || null;         // number    || null is number
var rj4 = a4 || null;         // string    || null is string
var rj5 = a5 || null;         // void      || null is void
var rj6 = a6 || null;         // enum      || null is E
var rj7 = a7 || null;         // object    || null is object
var rj8 = a8 || null;         // array     || null is array
var rj9 = null || null;       // null      || null is any
var rj10 = undefined || null; // undefined || null is any

var rf1 = a1 || undefined;         // any       || undefined is any
var rf2 = a2 || undefined;         // boolean   || undefined is boolean
var rf3 = a3 || undefined;         // number    || undefined is number
var rf4 = a4 || undefined;         // string    || undefined is string
var rf5 = a5 || undefined;         // void      || undefined is void
var rf6 = a6 || undefined;         // enum      || undefined is E
var rf7 = a7 || undefined;         // object    || undefined is object
var rf8 = a8 || undefined;         // array     || undefined is array
var rf9 = null || undefined;       // null      || undefined is any
var rf10 = undefined || undefined; // undefined || undefined is any`,
      [],
    );
  });
  test("logicalOrOperatorWithTypeParameters", async () => {
    await expectPass(
      `function fn1<T, U>(t: T, u: U) {
    var r1 = t || t;
    var r2: T = t || t;
    var r3 = t || u;
    var r4: {} = t || u;
}

function fn2<T, U/* extends T*/, V/* extends T*/>(t: T, u: U, v: V) {
    var r1 = t || u;
    //var r2: T = t || u;
    var r3 = u || u;
    var r4: U = u || u;
    var r5 = u || v;
    var r6: {} = u || v;
    //var r7: T = u || v;
}

function fn3<T extends { a: string; b: string }, U extends { a: string; b: number }>(t: T, u: U) {
    var r1 = t || u;
    var r2: {} = t || u;
    var r3 = t || { a: '' };
    var r4: { a: string } = t || u;
}`,
      [],
    );
  });
  test("commaOperatorInvalidAssignmentType", async () => {
    await expectPass(
      `
declare var BOOLEAN: boolean;
declare var NUMBER: number;
declare var STRING: string;

declare var resultIsBoolean: boolean
declare var resultIsNumber: number
declare var resultIsString: string

//Expect errors when the results type is different form the second operand
resultIsBoolean = (BOOLEAN, STRING);
resultIsBoolean = (BOOLEAN, NUMBER);

resultIsNumber = (NUMBER, BOOLEAN);
resultIsNumber = (NUMBER, STRING);

resultIsString = (STRING, BOOLEAN);
resultIsString = (STRING, NUMBER);`,
      [],
    );
  });
  test("commaOperatorOtherInvalidOperation", async () => {
    await expectPass(
      `
//Expect to have compiler errors
//Comma operator in function arguments and return
function foo(x: number, y: string) {
    return x, y;
}
var resultIsString: number = foo(1, "123"); //error here

//TypeParameters
function foo1<T1, T2>() {
    var x: T1;
    var y: T2;
    var result: T1 = (x, y); //error here
}`,
      [],
    );
  });
  test("commaOperatorOtherValidOperation", async () => {
    await expectPass(
      `
//Comma operator in for loop
for (var i = 0, j = 10; i < j; i++, j--)
{
}

//Comma operator in function arguments and return
function foo(x: number, y: string)
{
    return x, y;
}
var resultIsString = foo(1, "123");

//TypeParameters
function foo1<T1, T2>()
{
    var x: T1;
    var y: T2;
    x, y;
    var resultIsT1 = (y, x);
}`,
      [],
    );
  });
  test("commaOperatorsMultipleOperators", async () => {
    await expectPass(
      `
var ANY: any;
var BOOLEAN: boolean;
var NUMBER: number;
var STRING: string;
var OBJECT: Object;

//Expected: work well
ANY, BOOLEAN, NUMBER;
BOOLEAN, NUMBER, STRING;
NUMBER, STRING, OBJECT;
STRING, OBJECT, ANY;
OBJECT, ANY, BOOLEAN;

//Results should have the same type as the third operand
var resultIsAny1 = (STRING, OBJECT, ANY);
var resultIsBoolean1 = (OBJECT, ANY, BOOLEAN);
var resultIsNumber1 = (ANY, BOOLEAN, NUMBER);
var resultIsString1 = (BOOLEAN, NUMBER, STRING);
var resultIsObject1 = (NUMBER, STRING, OBJECT);

//Literal and expression
null, true, 1;
++NUMBER, STRING.charAt(0), new Object();

var resultIsNumber2 = (null, true, 1);
var resultIsObject2 = (++NUMBER, STRING.charAt(0), new Object());`,
      [],
    );
  });
  test("commaOperatorWithoutOperand", async () => {
    await expectError(
      `declare var ANY: any;
declare var BOOLEAN: boolean;
declare var NUMBER: number;
declare var STRING: string;
declare var OBJECT: Object;

// Expect to have compiler errors
// Missing the second operand
(ANY, );
(BOOLEAN, );
(NUMBER, );
(STRING, );
(OBJECT, );

// Missing the first operand
(, ANY);
(, BOOLEAN);
(, NUMBER);
(, STRING);
(, OBJECT);

// Missing all operands
( , );`,
      [],
    );
  });
  test("commaOperatorWithSecondOperandAnyType", async () => {
    await expectPass(
      `
var ANY: any;
var BOOLEAN: boolean;
var NUMBER: number;
var STRING: string;
var OBJECT: Object;

//The second operand type is any
ANY, ANY;
BOOLEAN, ANY;
NUMBER, ANY;
STRING, ANY;
OBJECT, ANY;

//Return type is any
var resultIsAny1 = (ANY, ANY);
var resultIsAny2 = (BOOLEAN, ANY);
var resultIsAny3 = (NUMBER, ANY);
var resultIsAny4 = (STRING, ANY);
var resultIsAny5 = (OBJECT, ANY);

//Literal and expression
var x: any;

1, ANY;
++NUMBER, ANY;
"string", [null, 1];
"string".charAt(0), [null, 1];
true, x("any");
!BOOLEAN, x.doSomeThing();

var resultIsAny6 = (1, ANY);
var resultIsAny7 = (++NUMBER, ANY);
var resultIsAny8 = ("string", null);
var resultIsAny9 = ("string".charAt(0), undefined);
var resultIsAny10 = (true, x("any"));
var resultIsAny11 = (!BOOLEAN, x.doSomeThing());`,
      [],
    );
  });
  test("commaOperatorWithSecondOperandBooleanType", async () => {
    await expectPass(
      `
var ANY: any;
var BOOLEAN: boolean;
var NUMBER: number;
var STRING: string;
var OBJECT: Object;

//The second operand type is boolean
ANY, BOOLEAN;
BOOLEAN, BOOLEAN;
NUMBER, BOOLEAN;
STRING, BOOLEAN;
OBJECT, BOOLEAN;

//Return type is boolean
var resultIsBoolean1 = (ANY, BOOLEAN);
var resultIsBoolean2 = (BOOLEAN, BOOLEAN);
var resultIsBoolean3 = (NUMBER, BOOLEAN);
var resultIsBoolean4 = (STRING, BOOLEAN);
var resultIsBoolean5 = (OBJECT, BOOLEAN);

//Literal and expression
null, BOOLEAN;
ANY = undefined, BOOLEAN;
1, true;
++NUMBER, true;
[1, 2, 3], !BOOLEAN;
OBJECT = [1, 2, 3], BOOLEAN = false;

var resultIsBoolean6 = (null, BOOLEAN);
var resultIsBoolean7 = (ANY = undefined, BOOLEAN);
var resultIsBoolean8 = (1, true);
var resultIsBoolean9 = (++NUMBER, true);
var resultIsBoolean10 = ([1, 2, 3], !BOOLEAN);
var resultIsBoolean11 = (OBJECT = [1, 2, 3], BOOLEAN = false);`,
      [],
    );
  });
  test("commaOperatorWithSecondOperandNumberType", async () => {
    await expectPass(
      `
var ANY: any;
var BOOLEAN: boolean;
var NUMBER: number;
var STRING: string;
var OBJECT: Object;

//The second operand type is number
ANY, NUMBER;
BOOLEAN, NUMBER;
NUMBER, NUMBER;
STRING, NUMBER;
OBJECT, NUMBER;

//Return type is number
var resultIsNumber1 = (ANY, NUMBER);
var resultIsNumber2 = (BOOLEAN, NUMBER);
var resultIsNumber3 = (NUMBER, NUMBER);
var resultIsNumber4 = (STRING, NUMBER);
var resultIsNumber5 = (OBJECT, NUMBER);

//Literal and expression
null, NUMBER;
ANY = undefined, NUMBER;
true, 1;
BOOLEAN = false, 1;
"", NUMBER = 1;
STRING.trim(), NUMBER = 1;

var resultIsNumber6 = (null, NUMBER);
var resultIsNumber7 = (ANY = undefined, NUMBER);
var resultIsNumber8 = (true, 1);
var resultIsNumber9 = (BOOLEAN = false, 1);
var resultIsNumber10 = ("", NUMBER = 1);
var resultIsNumber11 = (STRING.trim(), NUMBER = 1);`,
      [],
    );
  });
  test("commaOperatorWithSecondOperandObjectType", async () => {
    await expectPass(
      `
var ANY: any;
var BOOLEAN: boolean;
var NUMBER: number;
var STRING: string;
var OBJECT: Object;

class CLASS {
    num: number;
}

//The second operand type is Object
ANY, OBJECT;
BOOLEAN, OBJECT;
NUMBER, OBJECT;
STRING, OBJECT;
OBJECT, OBJECT;

//Return type is Object
var resultIsObject1 = (ANY, OBJECT);
var resultIsObject2 = (BOOLEAN, OBJECT);
var resultIsObject3 = (NUMBER, OBJECT);
var resultIsObject4 = (STRING, OBJECT);
var resultIsObject5 = (OBJECT, OBJECT);

//Literal and expression
null, OBJECT
ANY = null, OBJECT
true, {}
!BOOLEAN, []
"string", new Date()
STRING.toLowerCase(), new CLASS()

var resultIsObject6 = (null, OBJECT);
var resultIsObject7 = (ANY = null, OBJECT);
var resultIsObject8 = (true, {});
var resultIsObject9 = (!BOOLEAN, { a: 1, b: "s" });
var resultIsObject10 = ("string", new Date());
var resultIsObject11 = (STRING.toLowerCase(), new CLASS());`,
      [],
    );
  });
  test("commaOperatorWithSecondOperandStringType", async () => {
    await expectPass(
      `
var ANY: any;
var BOOLEAN: boolean;
var NUMBER: number;
var STRING: string;
var OBJECT: Object;

var resultIsString: string;

//The second operand is string
ANY, STRING;
BOOLEAN, STRING;
NUMBER, STRING;
STRING, STRING;
OBJECT, STRING;

//Return type is string
var resultIsString1 = (ANY, STRING);
var resultIsString2 = (BOOLEAN, STRING);
var resultIsString3 = (NUMBER, STRING);
var resultIsString4 = (STRING, STRING);
var resultIsString5 = (OBJECT, STRING);

//Literal and expression
null, STRING;
ANY = new Date(), STRING;
true, "";
BOOLEAN == undefined, "";
["a", "b"], NUMBER.toString();
OBJECT = new Object, STRING + "string";

var resultIsString6 = (null, STRING);
var resultIsString7 = (ANY = new Date(), STRING);
var resultIsString8 = (true, "");
var resultIsString9 = (BOOLEAN == undefined, "");
var resultIsString10 = (["a", "b"], NUMBER.toString());
var resultIsString11 = (new Object, STRING + "string");`,
      [],
    );
  });
  test("conditionalOperatorConditionIsBooleanType", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Cond is of boolean type, Expr1 and Expr2 have the same type
var condBoolean: boolean;

var exprAny1: any;
var exprBoolean1: boolean;
var exprNumber1: number;
var exprString1: string;
var exprIsObject1: Object;

var exprAny2: any;
var exprBoolean2: boolean;
var exprNumber2: number;
var exprString2: string;
var exprIsObject2: Object;

//Cond is a boolean type variable
condBoolean ? exprAny1 : exprAny2;
condBoolean ? exprBoolean1 : exprBoolean2;
condBoolean ? exprNumber1 : exprNumber2;
condBoolean ? exprString1 : exprString2;
condBoolean ? exprIsObject1 : exprIsObject2;
condBoolean ? exprString1 : exprBoolean1; // union

//Cond is a boolean type literal
true ? exprAny1 : exprAny2;
false ? exprBoolean1 : exprBoolean2;
true ? exprNumber1 : exprNumber2;
false ? exprString1 : exprString2;
true ? exprIsObject1 : exprIsObject2;
true ? exprString1 : exprBoolean1; // union

//Cond is a boolean type expression
!true ? exprAny1 : exprAny2;
typeof "123" == "string" ? exprBoolean1 : exprBoolean2;
2 > 1 ? exprNumber1 : exprNumber2;
null === undefined ? exprString1 : exprString2;
true || false ? exprIsObject1 : exprIsObject2;
null === undefined ? exprString1 : exprBoolean1; // union

//Results shoud be same as Expr1 and Expr2
var resultIsAny1 = condBoolean ? exprAny1 : exprAny2;
var resultIsBoolean1 = condBoolean ? exprBoolean1 : exprBoolean2;
var resultIsNumber1 = condBoolean ? exprNumber1 : exprNumber2;
var resultIsString1 = condBoolean ? exprString1 : exprString2;
var resultIsObject1 = condBoolean ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean1 = condBoolean ? exprString1 : exprBoolean1; // union

var resultIsAny2 = true ? exprAny1 : exprAny2;
var resultIsBoolean2 = false ? exprBoolean1 : exprBoolean2;
var resultIsNumber2 = true ? exprNumber1 : exprNumber2;
var resultIsString2 = false ? exprString1 : exprString2;
var resultIsObject2 = true ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean2 = true ? exprString1 : exprBoolean1; // union
var resultIsStringOrBoolean3 = false ? exprString1 : exprBoolean1; // union

var resultIsAny3 = !true ? exprAny1 : exprAny2;
var resultIsBoolean3 = typeof "123" == "string" ? exprBoolean1 : exprBoolean2;
var resultIsNumber3 = 2 > 1 ? exprNumber1 : exprNumber2;
var resultIsString3 = null === undefined ? exprString1 : exprString2;
var resultIsObject3 = true || false ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean4 = typeof "123" === "string" ? exprString1 : exprBoolean1; // union`,
      [],
    );
  });
  test("conditionalOperatorConditionIsNumberType", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Cond is of number type, Expr1 and Expr2 have the same type
declare var condNumber: number;

declare var exprAny1: any;
declare var exprBoolean1: boolean;
declare var exprNumber1: number;
declare var exprString1: string;
declare var exprIsObject1: Object;

declare var exprAny2: any;
declare var exprBoolean2: boolean;
declare var exprNumber2: number;
declare var exprString2: string;
declare var exprIsObject2: Object;

//Cond is a number type variable
condNumber ? exprAny1 : exprAny2;
condNumber ? exprBoolean1 : exprBoolean2;
condNumber ? exprNumber1 : exprNumber2;
condNumber ? exprString1 : exprString2;
condNumber ? exprIsObject1 : exprIsObject2;
condNumber ? exprString1 : exprBoolean1; // Union

//Cond is a number type literal
1 ? exprAny1 : exprAny2;
0 ? exprBoolean1 : exprBoolean2;
0.123456789 ? exprNumber1 : exprNumber2;
- 10000000000000 ? exprString1 : exprString2;
1000000000000 ? exprIsObject1 : exprIsObject2;
10000 ? exprString1 : exprBoolean1; // Union

//Cond is a number type expression
function foo() { return 1 };
var array = [1, 2, 3];

1 * 0 ? exprAny1 : exprAny2;
1 + 1 ? exprBoolean1 : exprBoolean2;
"string".length ? exprNumber1 : exprNumber2;
foo() ? exprString1 : exprString2;
foo() / array[1] ? exprIsObject1 : exprIsObject2;
foo() ? exprString1 : exprBoolean1; // Union

//Results shoud be same as Expr1 and Expr2
var resultIsAny1 = condNumber ? exprAny1 : exprAny2;
var resultIsBoolean1 = condNumber ? exprBoolean1 : exprBoolean2;
var resultIsNumber1 = condNumber ? exprNumber1 : exprNumber2;
var resultIsString1 = condNumber ? exprString1 : exprString2;
var resultIsObject1 = condNumber ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean1 = condNumber ? exprString1 : exprBoolean1; // Union

var resultIsAny2 = 1 ? exprAny1 : exprAny2;
var resultIsBoolean2 = 0 ? exprBoolean1 : exprBoolean2;
var resultIsNumber2 = 0.123456789 ? exprNumber1 : exprNumber2;
var resultIsString2 = - 10000000000000 ? exprString1 : exprString2;
var resultIsObject2 = 1000000000000 ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean2 = 10000 ? exprString1 : exprBoolean1; // Union

var resultIsAny3 = 1 * 0 ? exprAny1 : exprAny2;
var resultIsBoolean3 = 1 + 1 ? exprBoolean1 : exprBoolean2;
var resultIsNumber3 = "string".length ? exprNumber1 : exprNumber2;
var resultIsString3 = foo() ? exprString1 : exprString2;
var resultIsObject3 = foo() / array[1] ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean3 = foo() / array[1] ? exprString1 : exprBoolean1; // Union`,
      [],
    );
  });
  test("conditionalOperatorConditionIsObjectType", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Cond is of object type, Expr1 and Expr2 have the same type
declare var condObject: Object;

declare var exprAny1: any;
declare var exprBoolean1: boolean;
declare var exprNumber1: number;
declare var exprString1: string;
declare var exprIsObject1: Object;

declare var exprAny2: any;
declare var exprBoolean2: boolean;
declare var exprNumber2: number;
declare var exprString2: string;
declare var exprIsObject2: Object;

function foo() { };
class C { static doIt: () => void };

//Cond is an object type variable
condObject ? exprAny1 : exprAny2;
condObject ? exprBoolean1 : exprBoolean2;
condObject ? exprNumber1 : exprNumber2;
condObject ? exprString1 : exprString2;
condObject ? exprIsObject1 : exprIsObject2;
condObject ? exprString1 : exprBoolean1; // union

//Cond is an object type literal
((a: string) => a.length) ? exprAny1 : exprAny2;
((a: string) => a.length) ? exprBoolean1 : exprBoolean2;
({}) ? exprNumber1 : exprNumber2;
({ a: 1, b: "s" }) ? exprString1 : exprString2;
({ a: 1, b: "s" }) ? exprIsObject1 : exprIsObject2;
({ a: 1, b: "s" }) ? exprString1: exprBoolean1; // union

//Cond is an object type expression
foo() ? exprAny1 : exprAny2;
new Date() ? exprBoolean1 : exprBoolean2;
new C() ? exprNumber1 : exprNumber2;
C.doIt() ? exprString1 : exprString2;
condObject.valueOf() ? exprIsObject1 : exprIsObject2;
new Date() ? exprString1 : exprBoolean1; // union

//Results shoud be same as Expr1 and Expr2
var resultIsAny1 = condObject ? exprAny1 : exprAny2;
var resultIsBoolean1 = condObject ? exprBoolean1 : exprBoolean2;
var resultIsNumber1 = condObject ? exprNumber1 : exprNumber2;
var resultIsString1 = condObject ? exprString1 : exprString2;
var resultIsObject1 = condObject ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean1 = condObject ? exprString1 : exprBoolean1; // union

var resultIsAny2 = ((a: string) => a.length) ? exprAny1 : exprAny2;
var resultIsBoolean2 = ((a: string) => a.length) ? exprBoolean1 : exprBoolean2;
var resultIsNumber2 = ({}) ? exprNumber1 : exprNumber2;
var resultIsString2 = ({ a: 1, b: "s" }) ? exprString1 : exprString2;
var resultIsObject2 = ({ a: 1, b: "s" }) ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean2 = ({ a: 1, b: "s" }) ? exprString1 : exprBoolean1; // union

var resultIsAny3 = foo() ? exprAny1 : exprAny2;
var resultIsBoolean3 = new Date() ? exprBoolean1 : exprBoolean2;
var resultIsNumber3 = new C() ? exprNumber1 : exprNumber2;
var resultIsString3 = C.doIt() ? exprString1 : exprString2;
var resultIsObject3 = condObject.valueOf() ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean3 = C.doIt() ? exprString1 : exprBoolean1; // union`,
      [],
    );
  });
  test("conditionalOperatorConditoinIsAnyType", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Cond is of any type, Expr1 and Expr2 have the same type
declare var condAny: any;
declare var x: any;

declare var exprAny1: any;
declare var exprBoolean1: boolean;
declare var exprNumber1: number;
declare var exprString1: string;
declare var exprIsObject1: Object;

declare var exprAny2: any;
declare var exprBoolean2: boolean;
declare var exprNumber2: number;
declare var exprString2: string;
declare var exprIsObject2: Object;

//Cond is an any type variable
condAny ? exprAny1 : exprAny2;
condAny ? exprBoolean1 : exprBoolean2;
condAny ? exprNumber1 : exprNumber2;
condAny ? exprString1 : exprString2;
condAny ? exprIsObject1 : exprIsObject2;
condAny ? exprString1 : exprBoolean1; // union

//Cond is an any type literal
null ? exprAny1 : exprAny2;
null ? exprBoolean1 : exprBoolean2;
undefined ? exprNumber1 : exprNumber2;
[null, undefined] ? exprString1 : exprString2;
[null, undefined] ? exprIsObject1 : exprIsObject2;
undefined ? exprString1 : exprBoolean1; // union

//Cond is an any type expression
x.doSomeThing() ? exprAny1 : exprAny2;
x("x") ? exprBoolean1 : exprBoolean2;
x(x) ? exprNumber1 : exprNumber2;
x("x") ? exprString1 : exprString2;
x.doSomeThing() ? exprIsObject1 : exprIsObject2;
x.doSomeThing() ? exprString1 : exprBoolean1; // union

//Results shoud be same as Expr1 and Expr2
var resultIsAny1 = condAny ? exprAny1 : exprAny2;
var resultIsBoolean1 = condAny ? exprBoolean1 : exprBoolean2;
var resultIsNumber1 = condAny ? exprNumber1 : exprNumber2;
var resultIsString1 = condAny ? exprString1 : exprString2;
var resultIsObject1 = condAny ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean1 = condAny ? exprString1 : exprBoolean1; // union

var resultIsAny2 = null ? exprAny1 : exprAny2;
var resultIsBoolean2 = null ? exprBoolean1 : exprBoolean2;
var resultIsNumber2 = undefined ? exprNumber1 : exprNumber2;
var resultIsString2 = [null, undefined] ? exprString1 : exprString2;
var resultIsObject2 = [null, undefined] ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean2 = null ? exprString1 : exprBoolean1; // union
var resultIsStringOrBoolean3 = undefined ? exprString1 : exprBoolean1; // union
var resultIsStringOrBoolean4 = [null, undefined] ? exprString1 : exprBoolean1; // union

var resultIsAny3 = x.doSomeThing() ? exprAny1 : exprAny2;
var resultIsBoolean3 = x("x") ? exprBoolean1 : exprBoolean2;
var resultIsNumber3 = x(x) ? exprNumber1 : exprNumber2;
var resultIsString3 = x("x") ? exprString1 : exprString2;
var resultIsObject3 = x.doSomeThing() ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean5 = x.doSomeThing() ? exprString1 : exprBoolean1; // union`,
      [],
    );
  });
  test("conditionalOperatorConditoinIsStringType", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Cond is of string type, Expr1 and Expr2 have the same type
declare var condString: string;

declare var exprAny1: any;
declare var exprBoolean1: boolean;
declare var exprNumber1: number;
declare var exprString1: string;
declare var exprIsObject1: Object;

declare var exprAny2: any;
declare var exprBoolean2: boolean;
declare var exprNumber2: number;
declare var exprString2: string;
declare var exprIsObject2: Object;

//Cond is a string type variable
condString ? exprAny1 : exprAny2;
condString ? exprBoolean1 : exprBoolean2;
condString ? exprNumber1 : exprNumber2;
condString ? exprString1 : exprString2;
condString ? exprIsObject1 : exprIsObject2;
condString ? exprString1 : exprBoolean1; // union

//Cond is a string type literal
"" ? exprAny1 : exprAny2;
"string" ? exprBoolean1 : exprBoolean2;
'c' ? exprNumber1 : exprNumber2;
'string' ? exprString1 : exprString2;
"  " ? exprIsObject1 : exprIsObject2;
"hello " ? exprString1 : exprBoolean1; // union

//Cond is a string type expression
function foo() { return "string" };
var array = ["1", "2", "3"];

typeof condString ? exprAny1 : exprAny2;
condString.toUpperCase ? exprBoolean1 : exprBoolean2;
condString + "string" ? exprNumber1 : exprNumber2;
foo() ? exprString1 : exprString2;
array[1] ? exprIsObject1 : exprIsObject2;
foo() ? exprString1 : exprBoolean1; // union

//Results shoud be same as Expr1 and Expr2
var resultIsAny1 = condString ? exprAny1 : exprAny2;
var resultIsBoolean1 = condString ? exprBoolean1 : exprBoolean2;
var resultIsNumber1 = condString ? exprNumber1 : exprNumber2;
var resultIsString1 = condString ? exprString1 : exprString2;
var resultIsObject1 = condString ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean1 = condString ? exprString1 : exprBoolean1; // union

var resultIsAny2 = "" ? exprAny1 : exprAny2;
var resultIsBoolean2 = "string" ? exprBoolean1 : exprBoolean2;
var resultIsNumber2 = 'c' ? exprNumber1 : exprNumber2;
var resultIsString2 = 'string' ? exprString1 : exprString2;
var resultIsObject2 = "  " ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean2 = "hello" ? exprString1 : exprBoolean1; // union

var resultIsAny3 = typeof condString ? exprAny1 : exprAny2;
var resultIsBoolean3 = condString.toUpperCase ? exprBoolean1 : exprBoolean2;
var resultIsNumber3 = condString + "string" ? exprNumber1 : exprNumber2;
var resultIsString3 = foo() ? exprString1 : exprString2;
var resultIsObject3 = array[1] ? exprIsObject1 : exprIsObject2;
var resultIsStringOrBoolean3 = typeof condString ? exprString1 : exprBoolean1; // union
var resultIsStringOrBoolean4 = condString.toUpperCase ? exprString1 : exprBoolean1; // union`,
      [],
    );
  });
  test("conditionalOperatorWithIdenticalBCT", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Expr1 and Expr2 have identical best common type
class X { propertyX: any; propertyX1: number; propertyX2: string };
class A extends X { propertyA: number };
class B extends X { propertyB: string };

var x: X;
var a: A;
var b: B;

//Cond ? Expr1 : Expr2,  Expr1 is supertype
//Be Not contextually typed
true ? x : a;
var result1 = true ? x : a;

//Expr1 and Expr2 are literals
true ? {} : 1;
true ? { a: 1 } : { a: 2, b: 'string' };
var result2 = true ? {} : 1;
var result3 = true ? { a: 1 } : { a: 2, b: 'string' };

//Contextually typed
var resultIsX1: X = true ? x : a;
var result4: (t: A) => any = true ? (m) => m.propertyX : (n) => n.propertyA;

//Cond ? Expr1 : Expr2,  Expr2 is supertype
//Be Not contextually typed
true ? a : x;
var result5 = true ? a : x;

//Expr1 and Expr2 are literals
true ? 1 : {};
true ? { a: 2, b: 'string' } : { a: 1 };
var result6 = true ? 1 : {};
var result7 = true ? { a: 2, b: 'string' } : { a: 1 };

//Contextually typed
var resultIsX2: X = true ? x : a;
var result8: (t: A) => any = true ? (m) => m.propertyA : (n) => n.propertyX;

//Result = Cond ? Expr1 : Expr2,  Result is supertype
//Contextually typed
var resultIsX3: X = true ? a : b;
var result10: (t: X) => any = true ? (m) => m.propertyX1 : (n) => n.propertyX2;

//Expr1 and Expr2 are literals
var result11: any = true ? 1 : 'string';`,
      [],
    );
  });
  test("conditionalOperatorWithoutIdenticalBCT", async () => {
    await expectPass(
      `//Cond ? Expr1 : Expr2,  Expr1 and Expr2 have no identical best common type
class X { propertyX: any; propertyX1: number; propertyX2: string };
class A extends X { propertyA: number };
class B extends X { propertyB: string };

declare var x: X;
declare var a: A;
declare var b: B;

// No errors anymore, uses union types
true ? a : b;
var result1 = true ? a : b;

//Be contextually typed and and bct is not identical, results in errors that union type is not assignable to target
var result2: A = true ? a : b;
var result3: B = true ? a : b;
var result31: A | B = true ? a : b;

var result4: (t: X) => number = true ? (m) => m.propertyX1 : (n) => n.propertyX2;
var result5: (t: X) => string = true ? (m) => m.propertyX1 : (n) => n.propertyX2;
var result6: (t: X) => boolean = true ? (m) => m.propertyX1 : (n) => n.propertyX2;
var result61: (t: X) => number| string = true ? (m) => m.propertyX1 : (n) => n.propertyX2;
`,
      [],
    );
  });
  test("argumentExpressionContextualTyping", async () => {
    await expectPass(
      `// @target: es2015
// In a typed function call, argument expressions are contextually typed by their corresponding parameter types.
function foo({x: [a, b], y: {c, d, e}}) { }
function bar({x: [a, b = 10], y: {c, d, e = { f:1 }}}) { }
function baz(x: [string, number, boolean]) { }

var o = { x: ["string", 1], y: { c: true, d: "world", e: 3 } };
var o1: { x: [string, number], y: { c: boolean, d: string, e: number } } = { x: ["string", 1], y: { c: true, d: "world", e: 3 } };
foo(o1); // Not error since x has contextual type of tuple namely [string, number]
foo({ x: ["string", 1], y: { c: true, d: "world", e: 3 } }); // Not error

var array = ["string", 1, true];
var tuple: [string, number, boolean] = ["string", 1, true];
baz(tuple);
baz(["string", 1, true]);

baz(array);                          // Error
baz(["string", 1, true, ...array]);  // Error
foo(o);                              // Error because x has an array type namely (string|number)[]`,
      [],
    );
  });
  test("arrayLiteralExpressionContextualTyping", async () => {
    await expectPass(
      `// @target: es2015
// In a contextually typed array literal expression containing no spread elements, an element expression at index N is contextually typed by
//      the type of the property with the numeric name N in the contextual type, if any, or otherwise
//      the numeric index type of the contextual type, if any.
var array = [1, 2, 3];
var array1 = [true, 2, 3];  // Contextual type by the numeric index type of the contextual type
var tup: [number, number, number] = [1, 2, 3, 4];
var tup1: [number|string, number|string, number|string] = [1, 2, 3, "string"];
var tup2: [number, number, number] = [1, 2, 3, "string"];  // Error

// In a contextually typed array literal expression containing one or more spread elements,
// an element expression at index N is contextually typed by the numeric index type of the contextual type, if any.
var spr = [1, 2, 3, ...array];
var spr1 = [1, 2, 3, ...tup];
var spr2:[number, number, number] = [1, 2, 3, ...tup];  // Error
`,
      [],
    );
  });
  test("functionExpressionContextualTyping1", async () => {
    await expectPass(
      `// @strict: false
// When a function expression with no type parameters and no parameter type annotations 
// is contextually typed (section 4.19) by a type T and a contextual signature S can be extracted from T

enum E { red, blue }

// A contextual signature S is extracted from a function type T as follows:
//      If T is a function type with exactly one call signature, and if that call signature is non- generic, S is that signature.

var a0: (n: number, s: string) => number = (num, str) => {
    num.toExponential();
    return 0;
}

class Class<T> {
    foo() { }
}

var a1: (c: Class<Number>) => number = (a1) => {
    a1.foo();
    return 1;
}

// A contextual signature S is extracted from a function type T as follows:
//      If T is a union type, let U be the set of element types in T that have call signatures.
//        If each type in U has exactly one call signature and that call signature is non- generic,
//        and if all of the signatures are identical ignoring return types,
//        then S is a signature with the same parameters and a union of the return types.
var b1: ((s: string, w: boolean) => void) | ((s: string, w: boolean) => string);
b1 = (k, h) => { };
var b2: typeof a0 | ((n: number, s: string) => string);
b2 = (foo, bar) => { return foo + 1; }
b2 = (foo, bar) => { return "hello"; }
var b3: (name: string, num: number, boo: boolean) => void;
b3 = (name, number) => { };

var b4: (n: E) => string = (number = 1) => { return "hello"; };
var b5: (n: {}) => string = (number = "string") => { return "hello"; };

// A contextual signature S is extracted from a function type T as follows:
//      Otherwise, no contextual signature can be extracted from T and S is undefined.
var b6: ((s: string, w: boolean) => void) | ((n: number) => number);
var b7: ((s: string, w: boolean) => void) | ((s: string, w: number) => string);
b6 = (k) => { k.toLowerCase() };
b6 = (i) => {
    i.toExponential();
    return i;
};                   // Per spec, no contextual signature can be extracted in this case. (Otherwise clause)
b7 = (j, m) => { };  // Per spec, no contextual signature can be extracted in this case. (Otherwise clause)

class C<T, U> {
    constructor() {
        var k: ((j: T, k: U) => (T|U)[]) | ((j: number,k :U) => number[]) = (j, k) => {
            return [j, k];
        }   // Per spec, no contextual signature can be extracted in this case.
    }
}`,
      [],
    );
  });
  test("functionExpressionContextualTyping2", async () => {
    await expectPass(
      `// @target: es2015
// A contextual signature S is extracted from a function type T as follows:
//      If T is a function type with exactly one call signature, and if that call signature is non- generic, S is that signature.
//      If T is a union type, let U be the set of element types in T that have call signatures.
//          If each type in U has exactly one call signature and that call signature is non- generic,
//          and if all of the signatures are identical ignoring return types, then S is a signature
//          with the same parameters and a union of the return types.
//      Otherwise, no contextual signature can be extracted from T and S is undefined.

var a0: (n: number, s: string) => number
var a1: typeof a0 | ((n: number, s: string) => string);
a1 = (foo, bar) => { return true; }  // Error`,
      [],
    );
  });
  test("functionExpressionContextualTyping3", async () => {
    await expectPass(
      `
// #31114
declare function f<T>(value: T | number): void;
f((a: any) => "")`,
      [],
    );
  });
  test("generatedContextualTyping", async () => {
    await expectError(
      `
class Base { private p; }
class Derived1 extends Base { private m; }
class Derived2 extends Base { private n; }
interface Genric<T> { func(n: T[]); }
var b = new Base(), d1 = new Derived1(), d2 = new Derived2();
var x1: () => Base[] = () => [d1, d2];
var x2: () => Base[] = function() { return [d1, d2] };
var x3: () => Base[] = function named() { return [d1, d2] };
var x4: { (): Base[]; } = () => [d1, d2];
var x5: { (): Base[]; } = function() { return [d1, d2] };
var x6: { (): Base[]; } = function named() { return [d1, d2] };
var x7: Base[] = [d1, d2];
var x8: Array<Base> = [d1, d2];
var x9: { [n: number]: Base; } = [d1, d2];
var x10: {n: Base[]; }  = { n: [d1, d2] };
var x11: (s: Base[]) => any = n => { var n: Base[]; return null; };
var x12: Genric<Base> = { func: n => { return [d1, d2]; } };
class x13 { member: () => Base[] = () => [d1, d2] }
class x14 { member: () => Base[] = function() { return [d1, d2] } }
class x15 { member: () => Base[] = function named() { return [d1, d2] } }
class x16 { member: { (): Base[]; } = () => [d1, d2] }
class x17 { member: { (): Base[]; } = function() { return [d1, d2] } }
class x18 { member: { (): Base[]; } = function named() { return [d1, d2] } }
class x19 { member: Base[] = [d1, d2] }
class x20 { member: Array<Base> = [d1, d2] }
class x21 { member: { [n: number]: Base; } = [d1, d2] }
class x22 { member: {n: Base[]; }  = { n: [d1, d2] } }
class x23 { member: (s: Base[]) => any = n => { var n: Base[]; return null; } }
class x24 { member: Genric<Base> = { func: n => { return [d1, d2]; } } }
class x25 { private member: () => Base[] = () => [d1, d2] }
class x26 { private member: () => Base[] = function() { return [d1, d2] } }
class x27 { private member: () => Base[] = function named() { return [d1, d2] } }
class x28 { private member: { (): Base[]; } = () => [d1, d2] }
class x29 { private member: { (): Base[]; } = function() { return [d1, d2] } }
class x30 { private member: { (): Base[]; } = function named() { return [d1, d2] } }
class x31 { private member: Base[] = [d1, d2] }
class x32 { private member: Array<Base> = [d1, d2] }
class x33 { private member: { [n: number]: Base; } = [d1, d2] }
class x34 { private member: {n: Base[]; }  = { n: [d1, d2] } }
class x35 { private member: (s: Base[]) => any = n => { var n: Base[]; return null; } }
class x36 { private member: Genric<Base> = { func: n => { return [d1, d2]; } } }
class x37 { public member: () => Base[] = () => [d1, d2] }
class x38 { public member: () => Base[] = function() { return [d1, d2] } }
class x39 { public member: () => Base[] = function named() { return [d1, d2] } }
class x40 { public member: { (): Base[]; } = () => [d1, d2] }
class x41 { public member: { (): Base[]; } = function() { return [d1, d2] } }
class x42 { public member: { (): Base[]; } = function named() { return [d1, d2] } }
class x43 { public member: Base[] = [d1, d2] }
class x44 { public member: Array<Base> = [d1, d2] }
class x45 { public member: { [n: number]: Base; } = [d1, d2] }
class x46 { public member: {n: Base[]; }  = { n: [d1, d2] } }
class x47 { public member: (s: Base[]) => any = n => { var n: Base[]; return null; } }
class x48 { public member: Genric<Base> = { func: n => { return [d1, d2]; } } }
class x49 { static member: () => Base[] = () => [d1, d2] }
class x50 { static member: () => Base[] = function() { return [d1, d2] } }
class x51 { static member: () => Base[] = function named() { return [d1, d2] } }
class x52 { static member: { (): Base[]; } = () => [d1, d2] }
class x53 { static member: { (): Base[]; } = function() { return [d1, d2] } }
class x54 { static member: { (): Base[]; } = function named() { return [d1, d2] } }
class x55 { static member: Base[] = [d1, d2] }
class x56 { static member: Array<Base> = [d1, d2] }
class x57 { static member: { [n: number]: Base; } = [d1, d2] }
class x58 { static member: {n: Base[]; }  = { n: [d1, d2] } }
class x59 { static member: (s: Base[]) => any = n => { var n: Base[]; return null; } }
class x60 { static member: Genric<Base> = { func: n => { return [d1, d2]; } } }
class x61 { private static member: () => Base[] = () => [d1, d2] }
class x62 { private static member: () => Base[] = function() { return [d1, d2] } }
class x63 { private static member: () => Base[] = function named() { return [d1, d2] } }
class x64 { private static member: { (): Base[]; } = () => [d1, d2] }
class x65 { private static member: { (): Base[]; } = function() { return [d1, d2] } }
class x66 { private static member: { (): Base[]; } = function named() { return [d1, d2] } }
class x67 { private static member: Base[] = [d1, d2] }
class x68 { private static member: Array<Base> = [d1, d2] }
class x69 { private static member: { [n: number]: Base; } = [d1, d2] }
class x70 { private static member: {n: Base[]; }  = { n: [d1, d2] } }
class x71 { private static member: (s: Base[]) => any = n => { var n: Base[]; return null; } }
class x72 { private static member: Genric<Base> = { func: n => { return [d1, d2]; } } }
class x73 { public static member: () => Base[] = () => [d1, d2] }
class x74 { public static member: () => Base[] = function() { return [d1, d2] } }
class x75 { public static member: () => Base[] = function named() { return [d1, d2] } }
class x76 { public static member: { (): Base[]; } = () => [d1, d2] }
class x77 { public static member: { (): Base[]; } = function() { return [d1, d2] } }
class x78 { public static member: { (): Base[]; } = function named() { return [d1, d2] } }
class x79 { public static member: Base[] = [d1, d2] }
class x80 { public static member: Array<Base> = [d1, d2] }
class x81 { public static member: { [n: number]: Base; } = [d1, d2] }
class x82 { public static member: {n: Base[]; }  = { n: [d1, d2] } }
class x83 { public static member: (s: Base[]) => any = n => { var n: Base[]; return null; } }
class x84 { public static member: Genric<Base> = { func: n => { return [d1, d2]; } } }
class x85 { constructor(parm: () => Base[] = () => [d1, d2]) { } }
class x86 { constructor(parm: () => Base[] = function() { return [d1, d2] }) { } }
class x87 { constructor(parm: () => Base[] = function named() { return [d1, d2] }) { } }
class x88 { constructor(parm: { (): Base[]; } = () => [d1, d2]) { } }
class x89 { constructor(parm: { (): Base[]; } = function() { return [d1, d2] }) { } }
class x90 { constructor(parm: { (): Base[]; } = function named() { return [d1, d2] }) { } }
class x91 { constructor(parm: Base[] = [d1, d2]) { } }
class x92 { constructor(parm: Array<Base> = [d1, d2]) { } }
class x93 { constructor(parm: { [n: number]: Base; } = [d1, d2]) { } }
class x94 { constructor(parm: {n: Base[]; }  = { n: [d1, d2] }) { } }
class x95 { constructor(parm: (s: Base[]) => any = n => { var n: Base[]; return null; }) { } }
class x96 { constructor(parm: Genric<Base> = { func: n => { return [d1, d2]; } }) { } }
class x97 { constructor(public parm: () => Base[] = () => [d1, d2]) { } }
class x98 { constructor(public parm: () => Base[] = function() { return [d1, d2] }) { } }
class x99 { constructor(public parm: () => Base[] = function named() { return [d1, d2] }) { } }
class x100 { constructor(public parm: { (): Base[]; } = () => [d1, d2]) { } }
class x101 { constructor(public parm: { (): Base[]; } = function() { return [d1, d2] }) { } }
class x102 { constructor(public parm: { (): Base[]; } = function named() { return [d1, d2] }) { } }
class x103 { constructor(public parm: Base[] = [d1, d2]) { } }
class x104 { constructor(public parm: Array<Base> = [d1, d2]) { } }
class x105 { constructor(public parm: { [n: number]: Base; } = [d1, d2]) { } }
class x106 { constructor(public parm: {n: Base[]; }  = { n: [d1, d2] }) { } }
class x107 { constructor(public parm: (s: Base[]) => any = n => { var n: Base[]; return null; }) { } }
class x108 { constructor(public parm: Genric<Base> = { func: n => { return [d1, d2]; } }) { } }
class x109 { constructor(private parm: () => Base[] = () => [d1, d2]) { } }
class x110 { constructor(private parm: () => Base[] = function() { return [d1, d2] }) { } }
class x111 { constructor(private parm: () => Base[] = function named() { return [d1, d2] }) { } }
class x112 { constructor(private parm: { (): Base[]; } = () => [d1, d2]) { } }
class x113 { constructor(private parm: { (): Base[]; } = function() { return [d1, d2] }) { } }
class x114 { constructor(private parm: { (): Base[]; } = function named() { return [d1, d2] }) { } }
class x115 { constructor(private parm: Base[] = [d1, d2]) { } }
class x116 { constructor(private parm: Array<Base> = [d1, d2]) { } }
class x117 { constructor(private parm: { [n: number]: Base; } = [d1, d2]) { } }
class x118 { constructor(private parm: {n: Base[]; }  = { n: [d1, d2] }) { } }
class x119 { constructor(private parm: (s: Base[]) => any = n => { var n: Base[]; return null; }) { } }
class x120 { constructor(private parm: Genric<Base> = { func: n => { return [d1, d2]; } }) { } }
function x121(parm: () => Base[] = () => [d1, d2]) { }
function x122(parm: () => Base[] = function() { return [d1, d2] }) { }
function x123(parm: () => Base[] = function named() { return [d1, d2] }) { }
function x124(parm: { (): Base[]; } = () => [d1, d2]) { }
function x125(parm: { (): Base[]; } = function() { return [d1, d2] }) { }
function x126(parm: { (): Base[]; } = function named() { return [d1, d2] }) { }
function x127(parm: Base[] = [d1, d2]) { }
function x128(parm: Array<Base> = [d1, d2]) { }
function x129(parm: { [n: number]: Base; } = [d1, d2]) { }
function x130(parm: {n: Base[]; }  = { n: [d1, d2] }) { }
function x131(parm: (s: Base[]) => any = n => { var n: Base[]; return null; }) { }
function x132(parm: Genric<Base> = { func: n => { return [d1, d2]; } }) { }
function x133(): () => Base[] { return () => [d1, d2]; }
function x134(): () => Base[] { return function() { return [d1, d2] }; }
function x135(): () => Base[] { return function named() { return [d1, d2] }; }
function x136(): { (): Base[]; } { return () => [d1, d2]; }
function x137(): { (): Base[]; } { return function() { return [d1, d2] }; }
function x138(): { (): Base[]; } { return function named() { return [d1, d2] }; }
function x139(): Base[] { return [d1, d2]; }
function x140(): Array<Base> { return [d1, d2]; }
function x141(): { [n: number]: Base; } { return [d1, d2]; }
function x142(): {n: Base[]; }  { return { n: [d1, d2] }; }
function x143(): (s: Base[]) => any { return n => { var n: Base[]; return null; }; }
function x144(): Genric<Base> { return { func: n => { return [d1, d2]; } }; }
function x145(): () => Base[] { return () => [d1, d2]; return () => [d1, d2]; }
function x146(): () => Base[] { return function() { return [d1, d2] }; return function() { return [d1, d2] }; }
function x147(): () => Base[] { return function named() { return [d1, d2] }; return function named() { return [d1, d2] }; }
function x148(): { (): Base[]; } { return () => [d1, d2]; return () => [d1, d2]; }
function x149(): { (): Base[]; } { return function() { return [d1, d2] }; return function() { return [d1, d2] }; }
function x150(): { (): Base[]; } { return function named() { return [d1, d2] }; return function named() { return [d1, d2] }; }
function x151(): Base[] { return [d1, d2]; return [d1, d2]; }
function x152(): Array<Base> { return [d1, d2]; return [d1, d2]; }
function x153(): { [n: number]: Base; } { return [d1, d2]; return [d1, d2]; }
function x154(): {n: Base[]; }  { return { n: [d1, d2] }; return { n: [d1, d2] }; }
function x155(): (s: Base[]) => any { return n => { var n: Base[]; return null; }; return n => { var n: Base[]; return null; }; }
function x156(): Genric<Base> { return { func: n => { return [d1, d2]; } }; return { func: n => { return [d1, d2]; } }; }
var x157: () => () => Base[] = () => { return () => [d1, d2]; };
var x158: () => () => Base[] = () => { return function() { return [d1, d2] }; };
var x159: () => () => Base[] = () => { return function named() { return [d1, d2] }; };
var x160: () => { (): Base[]; } = () => { return () => [d1, d2]; };
var x161: () => { (): Base[]; } = () => { return function() { return [d1, d2] }; };
var x162: () => { (): Base[]; } = () => { return function named() { return [d1, d2] }; };
var x163: () => Base[] = () => { return [d1, d2]; };
var x164: () => Array<Base> = () => { return [d1, d2]; };
var x165: () => { [n: number]: Base; } = () => { return [d1, d2]; };
var x166: () => {n: Base[]; }  = () => { return { n: [d1, d2] }; };
var x167: () => (s: Base[]) => any = () => { return n => { var n: Base[]; return null; }; };
var x168: () => Genric<Base> = () => { return { func: n => { return [d1, d2]; } }; };
var x169: () => () => Base[] = function() { return () => [d1, d2]; };
var x170: () => () => Base[] = function() { return function() { return [d1, d2] }; };
var x171: () => () => Base[] = function() { return function named() { return [d1, d2] }; };
var x172: () => { (): Base[]; } = function() { return () => [d1, d2]; };
var x173: () => { (): Base[]; } = function() { return function() { return [d1, d2] }; };
var x174: () => { (): Base[]; } = function() { return function named() { return [d1, d2] }; };
var x175: () => Base[] = function() { return [d1, d2]; };
var x176: () => Array<Base> = function() { return [d1, d2]; };
var x177: () => { [n: number]: Base; } = function() { return [d1, d2]; };
var x178: () => {n: Base[]; }  = function() { return { n: [d1, d2] }; };
var x179: () => (s: Base[]) => any = function() { return n => { var n: Base[]; return null; }; };
var x180: () => Genric<Base> = function() { return { func: n => { return [d1, d2]; } }; };
namespace x181 { var t: () => Base[] = () => [d1, d2]; }
namespace x182 { var t: () => Base[] = function() { return [d1, d2] }; }
namespace x183 { var t: () => Base[] = function named() { return [d1, d2] }; }
namespace x184 { var t: { (): Base[]; } = () => [d1, d2]; }
namespace x185 { var t: { (): Base[]; } = function() { return [d1, d2] }; }
namespace x186 { var t: { (): Base[]; } = function named() { return [d1, d2] }; }
namespace x187 { var t: Base[] = [d1, d2]; }
namespace x188 { var t: Array<Base> = [d1, d2]; }
namespace x189 { var t: { [n: number]: Base; } = [d1, d2]; }
namespace x190 { var t: {n: Base[]; }  = { n: [d1, d2] }; }
namespace x191 { var t: (s: Base[]) => any = n => { var n: Base[]; return null; }; }
namespace x192 { var t: Genric<Base> = { func: n => { return [d1, d2]; } }; }
namespace x193 { export var t: () => Base[] = () => [d1, d2]; }
namespace x194 { export var t: () => Base[] = function() { return [d1, d2] }; }
namespace x195 { export var t: () => Base[] = function named() { return [d1, d2] }; }
namespace x196 { export var t: { (): Base[]; } = () => [d1, d2]; }
namespace x197 { export var t: { (): Base[]; } = function() { return [d1, d2] }; }
namespace x198 { export var t: { (): Base[]; } = function named() { return [d1, d2] }; }
namespace x199 { export var t: Base[] = [d1, d2]; }
namespace x200 { export var t: Array<Base> = [d1, d2]; }
namespace x201 { export var t: { [n: number]: Base; } = [d1, d2]; }
namespace x202 { export var t: {n: Base[]; }  = { n: [d1, d2] }; }
namespace x203 { export var t: (s: Base[]) => any = n => { var n: Base[]; return null; }; }
namespace x204 { export var t: Genric<Base> = { func: n => { return [d1, d2]; } }; }
var x206 = <() => Base[]>function() { return [d1, d2] };
var x207 = <() => Base[]>function named() { return [d1, d2] };
var x209 = <{ (): Base[]; }>function() { return [d1, d2] };
var x210 = <{ (): Base[]; }>function named() { return [d1, d2] };
var x211 = <Base[]>[d1, d2];
var x212 = <Array<Base>>[d1, d2];
var x213 = <{ [n: number]: Base; }>[d1, d2];
var x214 = <{n: Base[]; } >{ n: [d1, d2] };
var x216 = <Genric<Base>>{ func: n => { return [d1, d2]; } };
var x217 = (<() => Base[]>undefined) || function() { return [d1, d2] };
var x218 = (<() => Base[]>undefined) || function named() { return [d1, d2] };
var x219 = (<{ (): Base[]; }>undefined) || function() { return [d1, d2] };
var x220 = (<{ (): Base[]; }>undefined) || function named() { return [d1, d2] };
var x221 = (<Base[]>undefined) || [d1, d2];
var x222 = (<Array<Base>>undefined) || [d1, d2];
var x223 = (<{ [n: number]: Base; }>undefined) || [d1, d2];
var x224 = (<{n: Base[]; } >undefined) || { n: [d1, d2] };
var x225: () => Base[]; x225 = () => [d1, d2];
var x226: () => Base[]; x226 = function() { return [d1, d2] };
var x227: () => Base[]; x227 = function named() { return [d1, d2] };
var x228: { (): Base[]; }; x228 = () => [d1, d2];
var x229: { (): Base[]; }; x229 = function() { return [d1, d2] };
var x230: { (): Base[]; }; x230 = function named() { return [d1, d2] };
var x231: Base[]; x231 = [d1, d2];
var x232: Array<Base>; x232 = [d1, d2];
var x233: { [n: number]: Base; }; x233 = [d1, d2];
var x234: {n: Base[]; } ; x234 = { n: [d1, d2] };
var x235: (s: Base[]) => any; x235 = n => { var n: Base[]; return null; };
var x236: Genric<Base>; x236 = { func: n => { return [d1, d2]; } };
var x237: { n: () => Base[]; } = { n: () => [d1, d2] };
var x238: { n: () => Base[]; } = { n: function() { return [d1, d2] } };
var x239: { n: () => Base[]; } = { n: function named() { return [d1, d2] } };
var x240: { n: { (): Base[]; }; } = { n: () => [d1, d2] };
var x241: { n: { (): Base[]; }; } = { n: function() { return [d1, d2] } };
var x242: { n: { (): Base[]; }; } = { n: function named() { return [d1, d2] } };
var x243: { n: Base[]; } = { n: [d1, d2] };
var x244: { n: Array<Base>; } = { n: [d1, d2] };
var x245: { n: { [n: number]: Base; }; } = { n: [d1, d2] };
var x246: { n: {n: Base[]; } ; } = { n: { n: [d1, d2] } };
var x247: { n: (s: Base[]) => any; } = { n: n => { var n: Base[]; return null; } };
var x248: { n: Genric<Base>; } = { n: { func: n => { return [d1, d2]; } } };
var x252: { (): Base[]; }[] = [() => [d1, d2]];
var x253: { (): Base[]; }[] = [function() { return [d1, d2] }];
var x254: { (): Base[]; }[] = [function named() { return [d1, d2] }];
var x255: Base[][] = [[d1, d2]];
var x256: Array<Base>[] = [[d1, d2]];
var x257: { [n: number]: Base; }[] = [[d1, d2]];
var x258: {n: Base[]; } [] = [{ n: [d1, d2] }];
var x260: Genric<Base>[] = [{ func: n => { return [d1, d2]; } }];
var x261: () => Base[] = function() { return [d1, d2] } || undefined;
var x262: () => Base[] = function named() { return [d1, d2] } || undefined;
var x263: { (): Base[]; } = function() { return [d1, d2] } || undefined;
var x264: { (): Base[]; } = function named() { return [d1, d2] } || undefined;
var x265: Base[] = [d1, d2] || undefined;
var x266: Array<Base> = [d1, d2] || undefined;
var x267: { [n: number]: Base; } = [d1, d2] || undefined;
var x268: {n: Base[]; }  = { n: [d1, d2] } || undefined;
var x269: () => Base[] = undefined || function() { return [d1, d2] };
var x270: () => Base[] = undefined || function named() { return [d1, d2] };
var x271: { (): Base[]; } = undefined || function() { return [d1, d2] };
var x272: { (): Base[]; } = undefined || function named() { return [d1, d2] };
var x273: Base[] = undefined || [d1, d2];
var x274: Array<Base> = undefined || [d1, d2];
var x275: { [n: number]: Base; } = undefined || [d1, d2];
var x276: {n: Base[]; }  = undefined || { n: [d1, d2] };
var x277: () => Base[] = function() { return [d1, d2] } || function() { return [d1, d2] };
var x278: () => Base[] = function named() { return [d1, d2] } || function named() { return [d1, d2] };
var x279: { (): Base[]; } = function() { return [d1, d2] } || function() { return [d1, d2] };
var x280: { (): Base[]; } = function named() { return [d1, d2] } || function named() { return [d1, d2] };
var x281: Base[] = [d1, d2] || [d1, d2];
var x282: Array<Base> = [d1, d2] || [d1, d2];
var x283: { [n: number]: Base; } = [d1, d2] || [d1, d2];
var x284: {n: Base[]; }  = { n: [d1, d2] } || { n: [d1, d2] };
var x285: () => Base[] = true ? () => [d1, d2] : () => [d1, d2];
var x286: () => Base[] = true ? function() { return [d1, d2] } : function() { return [d1, d2] };
var x287: () => Base[] = true ? function named() { return [d1, d2] } : function named() { return [d1, d2] };
var x288: { (): Base[]; } = true ? () => [d1, d2] : () => [d1, d2];
var x289: { (): Base[]; } = true ? function() { return [d1, d2] } : function() { return [d1, d2] };
var x290: { (): Base[]; } = true ? function named() { return [d1, d2] } : function named() { return [d1, d2] };
var x291: Base[] = true ? [d1, d2] : [d1, d2];
var x292: Array<Base> = true ? [d1, d2] : [d1, d2];
var x293: { [n: number]: Base; } = true ? [d1, d2] : [d1, d2];
var x294: {n: Base[]; }  = true ? { n: [d1, d2] } : { n: [d1, d2] };
var x295: (s: Base[]) => any = true ? n => { var n: Base[]; return null; } : n => { var n: Base[]; return null; };
var x296: Genric<Base> = true ? { func: n => { return [d1, d2]; } } : { func: n => { return [d1, d2]; } };
var x297: () => Base[] = true ? undefined : () => [d1, d2];
var x298: () => Base[] = true ? undefined : function() { return [d1, d2] };
var x299: () => Base[] = true ? undefined : function named() { return [d1, d2] };
var x300: { (): Base[]; } = true ? undefined : () => [d1, d2];
var x301: { (): Base[]; } = true ? undefined : function() { return [d1, d2] };
var x302: { (): Base[]; } = true ? undefined : function named() { return [d1, d2] };
var x303: Base[] = true ? undefined : [d1, d2];
var x304: Array<Base> = true ? undefined : [d1, d2];
var x305: { [n: number]: Base; } = true ? undefined : [d1, d2];
var x306: {n: Base[]; }  = true ? undefined : { n: [d1, d2] };
var x307: (s: Base[]) => any = true ? undefined : n => { var n: Base[]; return null; };
var x308: Genric<Base> = true ? undefined : { func: n => { return [d1, d2]; } };
var x309: () => Base[] = true ? () => [d1, d2] : undefined;
var x310: () => Base[] = true ? function() { return [d1, d2] } : undefined;
var x311: () => Base[] = true ? function named() { return [d1, d2] } : undefined;
var x312: { (): Base[]; } = true ? () => [d1, d2] : undefined;
var x313: { (): Base[]; } = true ? function() { return [d1, d2] } : undefined;
var x314: { (): Base[]; } = true ? function named() { return [d1, d2] } : undefined;
var x315: Base[] = true ? [d1, d2] : undefined;
var x316: Array<Base> = true ? [d1, d2] : undefined;
var x317: { [n: number]: Base; } = true ? [d1, d2] : undefined;
var x318: {n: Base[]; }  = true ? { n: [d1, d2] } : undefined;
var x319: (s: Base[]) => any = true ? n => { var n: Base[]; return null; } : undefined;
var x320: Genric<Base> = true ? { func: n => { return [d1, d2]; } } : undefined;
function x321(n: () => Base[]) { }; x321(() => [d1, d2]);
function x322(n: () => Base[]) { }; x322(function() { return [d1, d2] });
function x323(n: () => Base[]) { }; x323(function named() { return [d1, d2] });
function x324(n: { (): Base[]; }) { }; x324(() => [d1, d2]);
function x325(n: { (): Base[]; }) { }; x325(function() { return [d1, d2] });
function x326(n: { (): Base[]; }) { }; x326(function named() { return [d1, d2] });
function x327(n: Base[]) { }; x327([d1, d2]);
function x328(n: Array<Base>) { }; x328([d1, d2]);
function x329(n: { [n: number]: Base; }) { }; x329([d1, d2]);
function x330(n: {n: Base[]; } ) { }; x330({ n: [d1, d2] });
function x331(n: (s: Base[]) => any) { }; x331(n => { var n: Base[]; return null; });
function x332(n: Genric<Base>) { }; x332({ func: n => { return [d1, d2]; } });
var x333 = (n: () => Base[]) => n; x333(() => [d1, d2]);
var x334 = (n: () => Base[]) => n; x334(function() { return [d1, d2] });
var x335 = (n: () => Base[]) => n; x335(function named() { return [d1, d2] });
var x336 = (n: { (): Base[]; }) => n; x336(() => [d1, d2]);
var x337 = (n: { (): Base[]; }) => n; x337(function() { return [d1, d2] });
var x338 = (n: { (): Base[]; }) => n; x338(function named() { return [d1, d2] });
var x339 = (n: Base[]) => n; x339([d1, d2]);
var x340 = (n: Array<Base>) => n; x340([d1, d2]);
var x341 = (n: { [n: number]: Base; }) => n; x341([d1, d2]);
var x342 = (n: {n: Base[]; } ) => n; x342({ n: [d1, d2] });
var x343 = (n: (s: Base[]) => any) => n; x343(n => { var n: Base[]; return null; });
var x344 = (n: Genric<Base>) => n; x344({ func: n => { return [d1, d2]; } });
var x345 = function(n: () => Base[]) { }; x345(() => [d1, d2]);
var x346 = function(n: () => Base[]) { }; x346(function() { return [d1, d2] });
var x347 = function(n: () => Base[]) { }; x347(function named() { return [d1, d2] });
var x348 = function(n: { (): Base[]; }) { }; x348(() => [d1, d2]);
var x349 = function(n: { (): Base[]; }) { }; x349(function() { return [d1, d2] });
var x350 = function(n: { (): Base[]; }) { }; x350(function named() { return [d1, d2] });
var x351 = function(n: Base[]) { }; x351([d1, d2]);
var x352 = function(n: Array<Base>) { }; x352([d1, d2]);
var x353 = function(n: { [n: number]: Base; }) { }; x353([d1, d2]);
var x354 = function(n: {n: Base[]; } ) { }; x354({ n: [d1, d2] });
var x355 = function(n: (s: Base[]) => any) { }; x355(n => { var n: Base[]; return null; });
var x356 = function(n: Genric<Base>) { }; x356({ func: n => { return [d1, d2]; } });`,
      [],
    );
  });
  test("getSetAccessorContextualTyping", async () => {
    await expectPass(
      `// @target: es5, es2015
// In the body of a get accessor with no return type annotation,
// if a matching set accessor exists and that set accessor has a parameter type annotation,
// return expressions are contextually typed by the type given in the set accessor's parameter type annotation.

class C {
    set X(x: number) { }
    get X() {
        return "string";  // Error; get contextual type by set accessor parameter type annotation
    }

    set Y(y) { }
    get Y() {
        return true;
    }

    set W(w) { }
    get W(): boolean {
        return true;
    }

    set Z(z: number) { }
    get Z() {
        return 1;
    }
}`,
      [],
    );
  });
  test("iterableContextualTyping1", async () => {
    await expectPass(
      `//@target: ES6
var iter: Iterable<(x: string) => number> = [s => s.length];`,
      [],
    );
  });
  test("objectLiteralContextualTyping", async () => {
    await expectPass(
      `// In a contextually typed object literal, each property value expression is contextually typed by
//      the type of the property with a matching name in the contextual type, if any, or otherwise
//      for a numerically named property, the numeric index type of the contextual type, if any, or otherwise
//      the string index type of the contextual type, if any.

interface Item {
    name: string;
    description?: string;
}

declare function foo(item: Item): string;
declare function foo(item: any): number;

var x = foo({ name: "Sprocket" });
var x: string;

var y = foo({ name: "Sprocket", description: "Bumpy wheel" });
var y: string;

var z = foo({ name: "Sprocket", description: false });
var z: number;

var w = foo({ a: 10 });
var w: number;

declare function bar<T>(param: { x?: T }): T;

var b = bar({});
var b: {};
`,
      [],
    );
  });
  test("parenthesizedContexualTyping1", async () => {
    await expectError(
      `
function fun<T>(g: (x: T) => T, x: T): T;
function fun<T>(g: (x: T) => T, h: (y: T) => T, x: T): T;
function fun<T>(g: (x: T) => T, x: T): T {
    return g(x);
}

var a = fun(x => x, 10);
var b = fun((x => x), 10);
var c = fun(((x => x)), 10);
var d = fun((((x => x))), 10);

var e = fun(x => x, x => x, 10);
var f = fun((x => x), (x => x), 10);
var g = fun(((x => x)), ((x => x)), 10);
var h = fun((((x => x))), ((x => x)), 10);

// Ternaries in parens
var i = fun((Math.random() < 0.5 ? x => x : x => undefined), 10);
var j = fun((Math.random() < 0.5 ? (x => x) : (x => undefined)), 10);
var k = fun((Math.random() < 0.5 ? (x => x) : (x => undefined)), x => x, 10);
var l = fun(((Math.random() < 0.5 ? ((x => x)) : ((x => undefined)))), ((x => x)), 10);

var lambda1: (x: number) => number = x => x;
var lambda2: (x: number) => number = (x => x);

type ObjType = { x: (p: number) => string; y: (p: string) => number };
var obj1: ObjType = { x: x => (x, undefined), y: y => (y, undefined) };
var obj2: ObjType = ({ x: x => (x, undefined), y: y => (y, undefined) });`,
      [],
    );
  });
  test("parenthesizedContexualTyping2", async () => {
    await expectError(
      `// These tests ensure that in cases where it may *appear* that a value has a type,
// they actually are properly being contextually typed. The way we test this is
// that we invoke contextually typed arguments with type arguments.
// Since 'any' cannot be invoked with type arguments, we should get errors
// back if contextual typing is not taking effect.

type FuncType = (x: <T>(p: T) => T) => typeof x;

function fun<T>(f: FuncType, x: T): T;
function fun<T>(f: FuncType, g: FuncType, x: T): T;
function fun<T>(...rest: any[]): T {
    return undefined;
}

var a = fun(x => { x<number>(undefined); return x; }, 10);
var b = fun((x => { x<number>(undefined); return x; }), 10);
var c = fun(((x => { x<number>(undefined); return x; })), 10);
var d = fun((((x => { x<number>(undefined); return x; }))), 10);

var e = fun(x => { x<number>(undefined); return x; }, x => { x<number>(undefined); return x; }, 10);
var f = fun((x => { x<number>(undefined); return x; }),(x => { x<number>(undefined); return x; }), 10);
var g = fun(((x => { x<number>(undefined); return x; })),((x => { x<number>(undefined); return x; })), 10);
var h = fun((((x => { x<number>(undefined); return x; }))),((x => { x<number>(undefined); return x; })), 10);

// Ternaries in parens
var i = fun((Math.random() < 0.5 ? x => { x<number>(undefined); return x; } : x => undefined), 10);
var j = fun((Math.random() < 0.5 ? (x => { x<number>(undefined); return x; }) : (x => undefined)), 10);
var k = fun((Math.random() < 0.5 ? (x => { x<number>(undefined); return x; }) : (x => undefined)), x => { x<number>(undefined); return x; }, 10);
var l = fun(((Math.random() < 0.5 ? ((x => { x<number>(undefined); return x; })) : ((x => undefined)))),((x => { x<number>(undefined); return x; })), 10);

var lambda1: FuncType = x => { x<number>(undefined); return x; };
var lambda2: FuncType = (x => { x<number>(undefined); return x; });

type ObjType = { x: (p: number) => string; y: (p: string) => number };
var obj1: ObjType = { x: x => (x, undefined), y: y => (y, undefined) };
var obj2: ObjType = ({ x: x => (x, undefined), y: y => (y, undefined) });`,
      [],
    );
  });
  test("parenthesizedContexualTyping3", async () => {
    await expectPass(
      `
// Contextual typing for parenthesized substitution expressions in tagged templates.

/**
 * tempFun - Can't have fun for too long.
 */
function tempFun<T>(tempStrs: TemplateStringsArray, g: (x: T) => T, x: T): T;
function tempFun<T>(tempStrs: TemplateStringsArray, g: (x: T) => T, h: (y: T) => T, x: T): T;
function tempFun<T>(tempStrs: TemplateStringsArray, g: (x: T) => T, x: T): T {
    return g(x);
}

var a = tempFun \`\${ x => x }  \${ 10 }\`
var b = tempFun \`\${ (x => x) }  \${ 10 }\`
var c = tempFun \`\${ ((x => x)) } \${ 10 }\`
var d = tempFun \`\${ x => x } \${ x => x } \${ 10 }\`
var e = tempFun \`\${ x => x } \${ (x => x) } \${ 10 }\`
var f = tempFun \`\${ x => x } \${ ((x => x)) } \${ 10 }\`
var g = tempFun \`\${ (x => x) } \${ (((x => x))) } \${ 10 }\`
var h = tempFun \`\${ (x => x) } \${ (((x => x))) } \${ undefined }\``,
      [],
    );
  });
  test("superCallParameterContextualTyping1", async () => {
    await expectPass(
      `// @target: es2015

class A<T1, T2> {
    constructor(private map: (value: T1) => T2) {

    }
}

class B extends A<number, string> {
    // Ensure 'value' is of type 'number (and not '{}') by using its 'toExponential()' method.
    constructor() { super(value => String(value.toExponential())); }
}
`,
      [],
    );
  });
  test("superCallParameterContextualTyping2", async () => {
    await expectPass(
      `// @target: es2015

class A<T1, T2> {
    constructor(private map: (value: T1) => T2) {

    }
}

class C extends A<number, string> {
    // Ensure 'value' is not of type 'any' by invoking it with type arguments.
    constructor() { super(value => String(value<string>())); }
}`,
      [],
    );
  });
  test("superCallParameterContextualTyping3", async () => {
    await expectPass(
      `// @target: es2015
interface ContextualType<T> {
    method(parameter: T): void;
}

class CBase<T>  {
    constructor(param: ContextualType<T>) {
    }

    foo(param: ContextualType<T>) {
    }
}

class C extends CBase<string> {
    constructor() {
        // Should be okay.
        // 'p' should have type 'string'.
        super({
            method(p) {
                p.length;
            }
        });

        // Should be okay.
        // 'p' should have type 'string'.
        super.foo({
            method(p) {
                p.length;
            }
        });
    }
}`,
      [],
    );
  });
  test("taggedTemplateContextualTyping1", async () => {
    await expectPass(
      `
type FuncType = (x: <T>(p: T) => T) => typeof x;

function tempTag1<T>(templateStrs: TemplateStringsArray, f: FuncType, x: T): T;
function tempTag1<T>(templateStrs: TemplateStringsArray, f: FuncType, h: FuncType, x: T): T;
function tempTag1<T>(...rest: any[]): T {
    return undefined;
}

// If contextual typing takes place, these functions should work.
// Otherwise, the arrow functions' parameters will be typed as 'any',
// and it is an error to invoke an any-typed value with type arguments,
// so this test will error.
tempTag1 \`\${ x => { x<number>(undefined); return x; }                   }\${ 10 }\`;
tempTag1 \`\${ x => { x<number>(undefined); return x; }                   }\${ y => { y<number>(undefined); return y; }                  }\${ 10 }\`;
tempTag1 \`\${ x => { x<number>(undefined); return x; }                   }\${ (y: <T>(p: T) => T) => { y<number>(undefined); return y } }\${ undefined }\`;
tempTag1 \`\${ (x: <T>(p: T) => T) => { x<number>(undefined); return x; } }\${ y => { y<number>(undefined); return y; }                  }\${ undefined }\`;
`,
      [],
    );
  });
  test("taggedTemplateContextualTyping2", async () => {
    await expectPass(
      `
type FuncType1 = (x: <T>(p: T) => T) => typeof x;
type FuncType2 = (x: <S, T>(p: T) => T) => typeof x;

function tempTag2(templateStrs: TemplateStringsArray, f: FuncType1, x: number): number;
function tempTag2(templateStrs: TemplateStringsArray, f: FuncType2, h: FuncType2, x: string): string;
function tempTag2(...rest: any[]): any {
    return undefined;
}

// If contextual typing takes place, these functions should work.
// Otherwise, the arrow functions' parameters will be typed as 'any',
// and it is an error to invoke an any-typed value with type arguments,
// so this test will error.
tempTag2 \`\${ x => { x<number>(undefined); return x; }         }\${ 0 }\`;
tempTag2 \`\${ x => { x<number, string>(undefined); return x; } }\${ y => { y<string, number>(null); return y; } }\${ "hello" }\`;
tempTag2 \`\${ x => { x<number, string>(undefined); return x; } }\${ undefined }\${ "hello" }\`;`,
      [],
    );
  });
  test("letIdentifierInElementAccess01", async () => {
    await expectPass(
      `// @target: es2015
var let: any = {};
(let[0] = 100);`,
      [],
    );
  });
  test("stringEnumInElementAccess01", async () => {
    await expectPass(
      `enum E {
    A = "a",
    B = "b",
    C = "c",
}

interface Item {
    a: string;
    b: number;
    c: boolean;
}

declare const item: Item;
declare const e: E;
const snb: string | number | boolean = item[e];`,
      [],
    );
  });
  test("callOverload", async () => {
    await expectPass(
      `declare function fn(x: any): void;
declare function takeTwo(x: any, y: any): void;
declare function withRest(a: any, ...args: Array<any>): void;
declare var n: number[];

fn(1) // no error
fn(1, 2, 3, 4)
takeTwo(1, 2, 3, 4)
withRest('a', ...n); // no error
withRest();
withRest(...n); `,
      [],
    );
  });
  test("callWithMissingVoid", async () => {
    await expectPass(
      `
// From #4260
class X<T> {
    f(t: T) {
        return { a: t };
    }
}

declare const x: X<void>;
x.f() // no error because f expects void

declare const xUnion: X<void | number>;
xUnion.f(42) // no error because f accepts number
xUnion.f() // no error because f accepts void

declare const xAny: X<any>;
xAny.f() // error, any still expects an argument

declare const xUnknown: X<unknown>;
xUnknown.f() // error, unknown still expects an argument

declare const xNever: X<never>;
xNever.f() // error, never still expects an argument


// Promise has previously been updated to work without arguments, but to show this fixes the issue too.

class MyPromise<X> {
    constructor(executor: (resolve: (value: X) => void) => void) {

    }
}

new MyPromise<void>(resolve => resolve()); // no error
new MyPromise<void | number>(resolve => resolve()); // no error
new MyPromise<any>(resolve => resolve()); // error, \`any\` arguments cannot be omitted
new MyPromise<unknown>(resolve => resolve()); // error, \`unknown\` arguments cannot be omitted
new MyPromise<never>(resolve => resolve()); // error, \`never\` arguments cannot be omitted


// Multiple parameters

function a(x: number, y: string, z: void): void  {
    
}

a(4, "hello"); // ok
a(4, "hello", void 0); // ok
a(4); // not ok

function b(x: number, y: string, z: void, what: number): void  {
    
}

b(4, "hello", void 0, 2); // ok
b(4, "hello"); // not ok
b(4, "hello", void 0); // not ok
b(4); // not ok

function c(x: number | void, y: void, z: void | string | number): void  {
    
}

c(3, void 0, void 0); // ok
c(3, void 0); // ok
c(3); // ok
c(); // ok


// Spread Parameters

declare function call<TS extends unknown[]>(
    handler: (...args: TS) => unknown,
    ...args: TS): void;

call((x: number, y: number) => x + y) // error
call((x: number, y: number) => x + y, 4, 2) // ok

call((x: number, y: void) => x, 4, void 0) // ok
call((x: number, y: void) => x, 4) // ok
call((x: void, y: void) => 42) // ok
call((x: number | void, y: number | void) => 42) // ok
call((x: number | void, y: number | void) => 42, 4) // ok
call((x: number | void, y: number | void) => 42, 4, 2) // ok`,
      [],
    );
  });
  test("callWithMissingVoidUndefinedUnknownAnyInJs", async () => {
    await expectPass(
      `declare function f1(p: void): void;
declare function f2(p: undefined): void;
declare function f3(p: unknown): void;
declare function f4(p: any): void;

interface I<T> { m(p: T): void; }
declare const o1: I<void>;
declare const o2: I<undefined>;
declare const o3: I<unknown>;
declare const o4: I<any>;

// current behavior: treat trailing \`void\` as optional
f1();
o1.m();

// new behavior: treat 'undefined', 'unknown', and 'any' as optional in non-strict mode
f2();
f3();
f4();

o2.m();
o3.m();
o4.m();

// current behavior: treat trailing \`void\` as optional
f1();
o1.m();

// no change in behavior
f2();
f3();
f4();

o2.m();
o3.m();
o4.m();
`,
      [],
    );
  });
  test("callWithSpread", async () => {
    await expectPass(
      `interface X {
    foo(x: number, y: number, ...z: string[]): X;
}

function foo(x: number, y: number, ...z: string[]) {
}

var a: string[];
var z: number[];
var obj: X;
var xa: X[];

foo(1, 2, "abc");
foo(1, 2, ...a);
foo(1, 2, ...a, "abc");

obj.foo(1, 2, "abc");
obj.foo(1, 2, ...a);
obj.foo(1, 2, ...a, "abc");

obj.foo(1, 2, ...a).foo(1, 2, "abc");
obj.foo(1, 2, ...a).foo(1, 2, ...a);
obj.foo(1, 2, ...a).foo(1, 2, ...a, "abc");

(obj.foo)(1, 2, "abc");
(obj.foo)(1, 2, ...a);
(obj.foo)(1, 2, ...a, "abc");

((obj.foo)(1, 2, ...a).foo)(1, 2, "abc");
((obj.foo)(1, 2, ...a).foo)(1, 2, ...a);
((obj.foo)(1, 2, ...a).foo)(1, 2, ...a, "abc");

xa[1].foo(1, 2, "abc");
xa[1].foo(1, 2, ...a);
xa[1].foo(1, 2, ...a, "abc");

(<Function>xa[1].foo)(...[1, 2, "abc"]);

class C {
    constructor(x: number, y: number, ...z: string[]) {
        this.foo(x, y);
        this.foo(x, y, ...z);
    }
    foo(x: number, y: number, ...z: string[]) {
    }
}

class D extends C {
    constructor() {
        super(1, 2);
        super(1, 2, ...a);
    }
    foo() {
        super.foo(1, 2);
        super.foo(1, 2, ...a);
    }
}
`,
      [],
    );
  });
  test("callWithSpread2", async () => {
    await expectPass(
      `declare function all(a?: number, b?: number): void;
declare function weird(a?: number | string, b?: number | string): void;
declare function prefix(s: string, a?: number, b?: number): void;
declare function rest(s: string, a?: number, b?: number,  ...rest: number[]): void;
declare function normal(s: string): void;
declare function thunk(): string;
declare function prefix2(s: string, n: number, a?: number, b?: number): void;

declare var ns: number[];
declare var mixed: (number | string)[];
declare var tuple: [number, string];

// good
all(...ns)
weird(...ns)
weird(...mixed)
weird(...tuple)
prefix("a", ...ns)
rest("d", ...ns)


// extra arguments
normal("g", ...ns)
thunk(...ns)

// bad
all(...mixed)
all(...tuple)
prefix("b", ...mixed)
prefix("c", ...tuple)
rest("e", ...mixed)
rest("f", ...tuple)
prefix(...ns) // required parameters are required
prefix(...mixed)
prefix(...tuple)
prefix2("g", ...ns);`,
      [],
    );
  });
  test("callWithSpread3", async () => {
    await expectPass(
      `declare const s2: [string, string];
declare const s3: [string, string, string];
declare const s2_: [string, string, ...string[]];
declare const s_: string[];
declare const n_: number[];
declare const s2n_: [string, string, ...number[]];

declare function fs2(a: string, b: string): void;
declare function fs2_(a: string, b: string, ...c: string[]): void;
declare function fs2n_(a: string, b: string, ...c: number[]): void;
declare function fs5(a: string, b: string, c: string, d: string, e: string): void;

// error
fs2('a', ...s2); // error on ...s2
fs2('a', 'b', 'c', ...s2); // error on 'c' and ...s2
fs2('a', 'b', ...s2, 'c'); // error on ...s2 and 'c'
fs2('a', 'b', 'c', ...s2, 'd'); // error on 'c', ...s2 and 'd'
fs2(...s2, 'a'); // error on 'a'
fs2(...s3); // error on ...s3
fs2_(...s_); // error on ...s_
fs2_(...s2n_); // error on ...s2n_
fs2_(...s_, ...s_); // error on ...s_
fs2_(...s_, ...s_, ...s_); // error on ...s_
// fs2n_(...s2, ...s_); //           FIXME: should be a type error
fs2n_(...s2_); // error on ...s2_

// ok
fs2_(...s2_);
fs2_(...s2_, ...s_);
fs2_(...s2_, ...s2_);
fs2_(...s_, ...s2_);
fs2n_(...s2n_);
fs2n_(...s2);
// fs2n_(...s2, ...n_); // FIXME: should compile
fs5(...s2, "foo", ...s2);`,
      [],
    );
  });
  test("callWithSpread4", async () => {
    await expectPass(
      `type R = { a: number }
type W = { b: number }
type RW = { a: number, b: number }
declare const pli: {
    (s1: R, s2: RW, s3: RW, s4: RW, s5: W): Promise<void>;
    (streams: ReadonlyArray<R | W | RW>): Promise<void>;
    (s1: R, s2: RW | W, ...streams: Array<RW | W>): Promise<void>;
}

declare var writes: W
declare var reads: R
declare var tr: W
declare var gun: RW[]
declare var gz: RW[]
declare var fun: (inp: any) => AsyncGenerator<string, void, unknown>
pli(
    reads,
    ...gun,
    tr,
    fun,
    ...gz,
    writes
);

declare function test(x: any, y: () => string): string | undefined;
declare var anys: any[]
test(...anys)

pli(...[reads, writes, writes] as const)`,
      [],
    );
  });
  test("callWithSpread5", async () => {
    await expectPass(
      `declare const x: number
declare const nnnu: [number, number, number?]
declare const nntnnnt: [number, number] | [number, number, number]
declare function fn(a: number, b: number, bb: number, ...c: number[]): number

fn(...nnnu, x)
fn(...nntnnnt, x)`,
      [],
    );
  });
  test("callWithSpreadES6", async () => {
    await expectPass(
      `
interface X {
    foo(x: number, y: number, ...z: string[]);
}

function foo(x: number, y: number, ...z: string[]) {
}

var a: string[];
var z: number[];
var obj: X;
var xa: X[];

foo(1, 2, "abc");
foo(1, 2, ...a);
foo(1, 2, ...a, "abc");

obj.foo(1, 2, "abc");
obj.foo(1, 2, ...a);
obj.foo(1, 2, ...a, "abc");

(obj.foo)(1, 2, "abc");
(obj.foo)(1, 2, ...a);
(obj.foo)(1, 2, ...a, "abc");

xa[1].foo(1, 2, "abc");
xa[1].foo(1, 2, ...a);
xa[1].foo(1, 2, ...a, "abc");

(<Function>xa[1].foo)(...[1, 2, "abc"]);

class C {
    constructor(x: number, y: number, ...z: string[]) {
        this.foo(x, y);
        this.foo(x, y, ...z);
    }
    foo(x: number, y: number, ...z: string[]) {
    }
}

class D extends C {
    constructor() {
        super(1, 2);
        super(1, 2, ...a);
    }
    foo() {
        super.foo(1, 2);
        super.foo(1, 2, ...a);
    }
}
`,
      [],
    );
  });
  test("forgottenNew", async () => {
    await expectPass(
      `namespace Tools {
    export class NullLogger { }
}

var logger = Tools.NullLogger();`,
      [],
    );
  });
  test("functionCalls", async () => {
    await expectPass(
      `
// Invoke function call on value of type 'any' with no type arguments
declare var anyVar: any;
anyVar(0);
anyVar('');

// Invoke function call on value of type 'any' with type arguments
// These should be errors
anyVar<string>('hello');
anyVar<number>();
anyVar<Window>(undefined);


// Invoke function call on value of a subtype of Function with no call signatures with no type arguments
interface SubFunc extends Function {
    prop: number;
}
declare var subFunc: SubFunc;
subFunc(0);
subFunc('');
subFunc();


// Invoke function call on value of a subtype of Function with no call signatures with type arguments
// These should be errors
subFunc<number>(0);
subFunc<string>('');
subFunc<any>();

// Invoke function call on value of type Function with no call signatures with type arguments
// These should be errors
declare var func: Function;
func<number>(0);
func<string>('');
func<any>();
`,
      [],
    );
  });
  test("grammarAmbiguities", async () => {
    await expectPass(
      `function f(n: any) { return null; }
function g<A, B>(x: any) { return null; }
interface A { }
interface B { }
var A, B;

f(g<A, B>(7));
f(g < A, B > 7); // Should error
f(g < A, B > +(7)); // Should error

`,
      [],
    );
  });
  test("newWithSpread", async () => {
    await expectPass(
      `
function f(x: number, y: number, ...z: string[]) {
}

function f2(...x: string[]) {
}

interface A {
    f: {
        new (x: number, y: number, ...z: string[]);
    }
}

class B {
    constructor(x: number, y: number, ...z: string[]) {}
}

interface C {
    "a-b": typeof B;
}

interface D {
    1: typeof B;
}

var a: string[];
var b: A;
var c: C;
var d: A[];
var e: { [key: string]: A };
var g: C[];
var h: { [key: string]: C };
var i: C[][];

// Basic expression
new f(1, 2, "string");
new f(1, 2, ...a);
new f(1, 2, ...a, "string");

// Multiple spreads arguments
new f2(...a, ...a);
new f(1 ,2, ...a, ...a);

// Call expression
new f(1, 2, "string")();
new f(1, 2, ...a)();
new f(1, 2, ...a, "string")();

// Property access expression
new b.f(1, 2, "string");
new b.f(1, 2, ...a);
new b.f(1, 2, ...a, "string"); 

// Parenthesised expression
new (b.f)(1, 2, "string");
new (b.f)(1, 2, ...a);
new (b.f)(1, 2, ...a, "string"); 

// Element access expression
new d[1].f(1, 2, "string");
new d[1].f(1, 2, ...a);
new d[1].f(1, 2, ...a, "string");

// Element access expression with a punctuated key
new e["a-b"].f(1, 2, "string");
new e["a-b"].f(1, 2, ...a);
new e["a-b"].f(1, 2, ...a, "string");

// Basic expression
new B(1, 2, "string");
new B(1, 2, ...a);
new B(1, 2, ...a, "string");

// Property access expression
new c["a-b"](1, 2, "string");
new c["a-b"](1, 2, ...a);
new c["a-b"](1, 2, ...a, "string");

// Parenthesised expression
new (c["a-b"])(1, 2, "string");
new (c["a-b"])(1, 2, ...a);
new (c["a-b"])(1, 2, ...a, "string");

// Element access expression
new g[1]["a-b"](1, 2, "string");
new g[1]["a-b"](1, 2, ...a);
new g[1]["a-b"](1, 2, ...a, "string");

// Element access expression with a punctuated key
new h["a-b"]["a-b"](1, 2, "string");
new h["a-b"]["a-b"](1, 2, ...a);
new h["a-b"]["a-b"](1, 2, ...a, "string");

// Element access expression with a number
new i["a-b"][1](1, 2, "string");
new i["a-b"][1](1, 2, ...a);
new i["a-b"][1](1, 2, ...a, "string");`,
      [],
    );
  });
  test("newWithSpreadES5", async () => {
    await expectPass(
      `
function f(x: number, y: number, ...z: string[]) {
}

function f2(...x: string[]) {}

interface A {
    f: {
        new (x: number, y: number, ...z: string[]);
    }
}

class B {
    constructor(x: number, y: number, ...z: string[]) {}
}

interface C {
    "a-b": typeof B;
}

interface D {
    1: typeof B;
}

var a: string[];
var b: A;
var c: C;
var d: A[];
var e: { [key: string]: A };
var g: C[];
var h: { [key: string]: C };
var i: C[][];

// Basic expression
new f(1, 2, "string");
new f(1, 2, ...a);
new f(1, 2, ...a, "string");

// Multiple spreads arguments
new f2(...a, ...a);
new f(1 ,2, ...a, ...a);

// Call expression
new f(1, 2, "string")();
new f(1, 2, ...a)();
new f(1, 2, ...a, "string")();

// Property access expression
new b.f(1, 2, "string");
new b.f(1, 2, ...a);
new b.f(1, 2, ...a, "string"); 

// Parenthesised expression
new (b.f)(1, 2, "string");
new (b.f)(1, 2, ...a);
new (b.f)(1, 2, ...a, "string"); 

// Element access expression
new d[1].f(1, 2, "string");
new d[1].f(1, 2, ...a);
new d[1].f(1, 2, ...a, "string");

// Element access expression with a punctuated key
new e["a-b"].f(1, 2, "string");
new e["a-b"].f(1, 2, ...a);
new e["a-b"].f(1, 2, ...a, "string");

// Basic expression
new B(1, 2, "string");
new B(1, 2, ...a);
new B(1, 2, ...a, "string");

// Property access expression
new c["a-b"](1, 2, "string");
new c["a-b"](1, 2, ...a);
new c["a-b"](1, 2, ...a, "string");

// Parenthesised expression
new (c["a-b"])(1, 2, "string");
new (c["a-b"])(1, 2, ...a);
new (c["a-b"])(1, 2, ...a, "string");

// Element access expression
new g[1]["a-b"](1, 2, "string");
new g[1]["a-b"](1, 2, ...a);
new g[1]["a-b"](1, 2, ...a, "string");

// Element access expression with a punctuated key
new h["a-b"]["a-b"](1, 2, "string");
new h["a-b"]["a-b"](1, 2, ...a);
new h["a-b"]["a-b"](1, 2, ...a, "string");

// Element access expression with a number
new i["a-b"][1](1, 2, "string");
new i["a-b"][1](1, 2, ...a);
new i["a-b"][1](1, 2, ...a, "string");`,
      [],
    );
  });
  test("newWithSpreadES6", async () => {
    await expectPass(
      `
function f(x: number, y: number, ...z: string[]) {
}

function f2(...x: string[]) {
}

interface A {
    f: {
        new (x: number, y: number, ...z: string[]);
    }
}

class B {
    constructor(x: number, y: number, ...z: string[]) {}
}

interface C {
    "a-b": typeof B;
}

interface D {
    1: typeof B;
}

var a: string[];
var b: A;
var c: C;
var d: A[];
var e: { [key: string]: A };
var g: C[];
var h: { [key: string]: C };
var i: C[][];

// Basic expression
new f(1, 2, "string");
new f(1, 2, ...a);
new f(1, 2, ...a, "string");

// Multiple spreads arguments
new f2(...a, ...a);
new f(1 ,2, ...a, ...a);

// Call expression
new f(1, 2, "string")();
new f(1, 2, ...a)();
new f(1, 2, ...a, "string")();

// Property access expression
new b.f(1, 2, "string");
new b.f(1, 2, ...a);
new b.f(1, 2, ...a, "string"); 

// Parenthesised expression
new (b.f)(1, 2, "string");
new (b.f)(1, 2, ...a);
new (b.f)(1, 2, ...a, "string"); 

// Element access expression
new d[1].f(1, 2, "string");
new d[1].f(1, 2, ...a);
new d[1].f(1, 2, ...a, "string");

// Element access expression with a punctuated key
new e["a-b"].f(1, 2, "string");
new e["a-b"].f(1, 2, ...a);
new e["a-b"].f(1, 2, ...a, "string");

// Basic expression
new B(1, 2, "string");
new B(1, 2, ...a);
new B(1, 2, ...a, "string");

// Property access expression
new c["a-b"](1, 2, "string");
new c["a-b"](1, 2, ...a);
new c["a-b"](1, 2, ...a, "string");

// Parenthesised expression
new (c["a-b"])(1, 2, "string");
new (c["a-b"])(1, 2, ...a);
new (c["a-b"])(1, 2, ...a, "string");

// Element access expression
new g[1]["a-b"](1, 2, "string");
new g[1]["a-b"](1, 2, ...a);
new g[1]["a-b"](1, 2, ...a, "string");

// Element access expression with a punctuated key
new h["a-b"]["a-b"](1, 2, "string");
new h["a-b"]["a-b"](1, 2, ...a);
new h["a-b"]["a-b"](1, 2, ...a, "string");

// Element access expression with a number
new i["a-b"][1](1, 2, "string");
new i["a-b"][1](1, 2, ...a);
new i["a-b"][1](1, 2, ...a, "string");`,
      [],
    );
  });
  test("overloadResolution", async () => {
    await expectPass(
      `class SomeBase {
    private n;

    public s: string;
}
class SomeDerived1 extends SomeBase {
    private m;
}
class SomeDerived2 extends SomeBase {
    private m;
}
class SomeDerived3 extends SomeBase {
    private m;
}


// Ambiguous call picks the first overload in declaration order
function fn1(s: string): string;
function fn1(s: number): number;
function fn1() { return null; }

var s = fn1(undefined);
var s: string;


// No candidate overloads found
fn1({}); // Error

// Generic and non - generic overload where generic overload is the only candidate when called with type arguments
function fn2(s: string, n: number): number;
function fn2<T>(n: number, t: T): T;
function fn2() { return undefined; }

var d = fn2<Date>(0, undefined);
var d: Date;

// Generic and non - generic overload where generic overload is the only candidate when called without type arguments
var s = fn2(0, '');

// Generic and non - generic overload where non - generic overload is the only candidate when called with type arguments
fn2<Date>('', 0); // Error

// Generic and non - generic overload where non - generic overload is the only candidate when called without type arguments
fn2('', 0); // OK

// Generic overloads with differing arity called without type arguments
function fn3<T>(n: T): string;
function fn3<T, U>(s: string, t: T, u: U): U;
function fn3<T, U, V>(v: V, u: U, t: T): number;
function fn3() { return null; }

var s = fn3(3);
var s = fn3('', 3, '');
var n = fn3(5, 5, 5);
var n: number;

// Generic overloads with differing arity called with type arguments matching each overload type parameter count
var s = fn3<number>(4);
var s = fn3<string, string>('', '', '');
var n = fn3<number, string, string>('', '', 3);

// Generic overloads with differing arity called with type argument count that doesn't match any overload
fn3<number, number, number, number>(); // Error

// Generic overloads with constraints called with type arguments that satisfy the constraints
function fn4<T extends string, U extends number>(n: T, m: U);
function fn4<T extends number, U extends string>(n: T, m: U);
function fn4() { }
fn4<string, number>('', 3);
fn4<string, number>(3, ''); // Error
fn4<number, string>('', 3); // Error
fn4<number, string>(3, ''); 

// Generic overloads with constraints called without type arguments but with types that satisfy the constraints
fn4('', 3);
fn4(3, '');
fn4(3, undefined);
fn4('', null);

// Generic overloads with constraints called with type arguments that do not satisfy the constraints
fn4<boolean, Date>(null, null); // Error

// Generic overloads with constraints called without type arguments but with types that do not satisfy the constraints
fn4(true, null); // Error
fn4(null, true); // Error

// Non - generic overloads where contextual typing of function arguments has errors
function fn5(f: (n: string) => void): string;
function fn5(f: (n: number) => void): number;
function fn5() { return undefined; }
var n = fn5((n) => n.toFixed());
var s = fn5((n) => n.substr(0));

`,
      [],
    );
  });
  test("overloadResolutionClassConstructors", async () => {
    await expectPass(
      `class SomeBase {
    private n;

    public s: string;
}
class SomeDerived1 extends SomeBase {
    private m;
}
class SomeDerived2 extends SomeBase {
    private m;
}
class SomeDerived3 extends SomeBase {
    private m;
}


// Ambiguous call picks the first overload in declaration order
class fn1 {
    constructor(s: string);
    constructor(s: number);
    constructor() { }
}

new fn1(undefined);

// No candidate overloads found
new fn1({}); // Error

// Generic and non - generic overload where generic overload is the only candidate when called with type arguments
class fn2<T> {
    constructor(s: string, n: number);
    constructor(n: number, t: T);
    constructor() { }
}

var d = new fn2<Date>(0, undefined);

// Generic and non - generic overload where generic overload is the only candidate when called without type arguments
var s = new fn2(0, '');

// Generic and non - generic overload where non - generic overload is the only candidate when called with type arguments
new fn2<Date>('', 0); // OK

// Generic and non - generic overload where non - generic overload is the only candidate when called without type arguments
new fn2('', 0); // OK

// Generic overloads with differing arity called without type arguments
class fn3<T, U, V> {
    constructor(n: T);
    constructor(s: string, t: T, u: U);
    constructor(v: V, u: U, t: T);
    constructor() { }
}

new fn3(3);
new fn3('', 3, '');
new fn3(5, 5, 5);

// Generic overloads with differing arity called with type arguments matching each overload type parameter count
new fn3<number>(4); // Error
new fn3<string, string>('', '', '');  // Error
new fn3<number, string, string>('', '', 3);

// Generic overloads with differing arity called with type argument count that doesn't match any overload
new fn3<number, number, number, number>(); // Error

// Generic overloads with constraints called with type arguments that satisfy the constraints
class fn4<T extends string, U extends number> {
    constructor(n: T, m: U);
    constructor() { }
}
new fn4<string, number>('', 3);
new fn4<string, number>(3, ''); // Error
new fn4<number, string>('', 3); // Error
new fn4<number, string>(3, ''); // Error

// Generic overloads with constraints called without type arguments but with types that satisfy the constraints
new fn4('', 3);
new fn4(3, ''); // Error
new fn4(3, undefined); // Error
new fn4('', null);

// Generic overloads with constraints called with type arguments that do not satisfy the constraints
new fn4<boolean, Date>(null, null); // Error

// Generic overloads with constraints called without type arguments but with types that do not satisfy the constraints
new fn4(true, null); // Error
new fn4(null, true); // Error

// Non - generic overloads where contextual typing of function arguments has errors
class fn5 {
    constructor(f: (n: string) => void);
    constructor(f: (n: number) => void);
    constructor() { return undefined; }
}
new fn5((n) => n.toFixed());
new fn5((n) => n.substr(0));
new fn5((n) => n.blah); // Error


`,
      [],
    );
  });
  test("overloadResolutionConstructors", async () => {
    await expectPass(
      `class SomeBase {
    private n;

    public s: string;
}
class SomeDerived1 extends SomeBase {
    private m;
}
class SomeDerived2 extends SomeBase {
    private m;
}
class SomeDerived3 extends SomeBase {
    private m;
}

interface fn1 {
    new (s: string): string;
    new (s: number): number;
}
declare var fn1: fn1;

// Ambiguous call picks the first overload in declaration order
var s = new fn1(undefined);
var s: string;

// No candidate overloads found
new fn1({}); // Error

// Generic and non - generic overload where generic overload is the only candidate when called with type arguments
interface fn2 {
    new (s: string, n: number): number;
    new <T>(n: number, t: T): T;
}
declare var fn2: fn2;

var d = new fn2<Date>(0, undefined);
var d: Date;

// Generic and non - generic overload where generic overload is the only candidate when called without type arguments
var s = new fn2(0, '');

// Generic and non - generic overload where non - generic overload is the only candidate when called with type arguments
new fn2<Date>('', 0); // Error

// Generic and non - generic overload where non - generic overload is the only candidate when called without type arguments
new fn2('', 0); // OK

// Generic overloads with differing arity called without type arguments
interface fn3 {
    new<T>(n: T): string;
    new<T, U>(s: string, t: T, u: U): U;
    new<T, U, V>(v: V, u: U, t: T): number;
}
declare var fn3: fn3;

var s = new fn3(3);
var s = new fn3('', 3, '');
var n = new fn3(5, 5, 5);
var n: number;

// Generic overloads with differing arity called with type arguments matching each overload type parameter count
var s = new fn3<number>(4);
var s = new fn3<string, string>('', '', '');
var n = new fn3<number, string, string>('', '', 3);

// Generic overloads with differing arity called with type argument count that doesn't match any overload
new fn3<number, number, number, number>(); // Error

// Generic overloads with constraints called with type arguments that satisfy the constraints
interface fn4 {
    new<T extends string, U extends number>(n: T, m: U);
    new<T extends number, U extends string>(n: T, m: U);
}
declare var fn4: fn4;

new fn4<string, number>('', 3);
new fn4<string, number>(3, ''); // Error
new fn4<number, string>('', 3); // Error
new fn4<number, string>(3, ''); 

// Generic overloads with constraints called without type arguments but with types that satisfy the constraints
new fn4('', 3);
new fn4(3, '');
new fn4(3, undefined);
new fn4('', null);

// Generic overloads with constraints called with type arguments that do not satisfy the constraints
new fn4<boolean, Date>(null, null); // Error

// Generic overloads with constraints called without type arguments but with types that do not satisfy the constraints
new fn4(true, null); // Error
new fn4(null, true); // Error

// Non - generic overloads where contextual typing of function arguments has errors
interface fn5 {
    new(f: (n: string) => void): string;
    new(f: (n: number) => void): number;
}
declare var fn5: fn5;
var n = new fn5((n) => n.toFixed());
var s = new fn5((n) => n.substr(0));
`,
      [],
    );
  });
  test("typeArgumentInference", async () => {
    await expectPass(
      `// Generic call with no parameters
function noParams<T>() { }
noParams();
noParams<string>();
noParams<{}>();

// Generic call with parameters but none use type parameter type
function noGenericParams<T>(n: string) { }
noGenericParams('');
noGenericParams<number>('');
noGenericParams<{}>('');

// Generic call with multiple type parameters and only one used in parameter type annotation
function someGenerics1<T, U>(n: T, m: number) { }
someGenerics1(3, 4);
someGenerics1<number, {}>(3, 4);

// Generic call with argument of function type whose parameter is of type parameter type
function someGenerics2a<T>(n: (x: T) => void) { }
someGenerics2a((n: string) => n);
someGenerics2a<string>((n: string) => n);
someGenerics2a<string>((n) => n.substr(0));

function someGenerics2b<T, U>(n: (x: T, y: U) => void) { }
someGenerics2b((n: string, x: number) => n);
someGenerics2b<string, number>((n: string, t: number) => n);
someGenerics2b<string, number>((n, t) => n.substr(t * t));

// Generic call with argument of function type whose parameter is not of type parameter type but body/return type uses type parameter
function someGenerics3<T>(producer: () => T) { }
someGenerics3(() => '');
someGenerics3<Date>(() => undefined);
someGenerics3<number>(() => 3);

// 2 parameter generic call with argument 1 of type parameter type and argument 2 of function type whose parameter is of type parameter type
function someGenerics4<T, U>(n: T, f: (x: U) => void) { }
someGenerics4(4, () => null);
someGenerics4<string, number>('', () => 3);
someGenerics4<string, number>(null, null);

// 2 parameter generic call with argument 2 of type parameter type and argument 1 of function type whose parameter is of type parameter type
function someGenerics5<U, T>(n: T, f: (x: U) => void) { }
someGenerics5(4, () => null);
someGenerics5<number, string>('', () => 3);
someGenerics5<string, number>(null, null);

// Generic call with multiple arguments of function types that each have parameters of the same generic type
function someGenerics6<A>(a: (a: A) => A, b: (b: A) => A, c: (c: A) => A) { }
someGenerics6(n => n, n => n, n => n);
someGenerics6<number>(n => n, n => n, n => n);
someGenerics6<number>((n: number) => n, (n: number) => n, (n: number) => n);

// Generic call with multiple arguments of function types that each have parameters of different generic type
function someGenerics7<A, B, C>(a: (a: A) => A, b: (b: B) => B, c: (c: C) => C) { }
someGenerics7(n => n, n => n, n => n);
someGenerics7<number, string, number>(n => n, n => n, n => n);
someGenerics7<number, string, number>((n: number) => n, (n: string) => n, (n: number) => n);

// Generic call with argument of generic function type
function someGenerics8<T>(n: T): T { return n; }
var x = someGenerics8(someGenerics7);
x<string, string, string>(null, null, null);

// Generic call with multiple parameters of generic type passed arguments with no best common type
function someGenerics9<T>(a: T, b: T, c: T): T {
    return null;
}
var a9a = someGenerics9('', 0, []);
var a9a: {};
var a9b = someGenerics9<{ a?: number; b?: string; }>({ a: 0 }, { b: '' }, null);
var a9b: { a?: number; b?: string; };

// Generic call with multiple parameters of generic type passed arguments with multiple best common types
interface A91 {
    x: number;
    y?: string;
}
interface A92 {
    x: number;
    z?: Date;
}
var a9e = someGenerics9(undefined, { x: 6, z: new Date() }, { x: 6, y: '' });
var a9e: {};
var a9f = someGenerics9<A92>(undefined, { x: 6, z: new Date() }, { x: 6, y: '' });
var a9f: A92;

// Generic call with multiple parameters of generic type passed arguments with a single best common type
var a9d = someGenerics9({ x: 3 }, { x: 6 }, { x: 6 });
var a9d: { x: number; };

// Generic call with multiple parameters of generic type where one argument is of type 'any'
var anyVar: any;
var a = someGenerics9(7, anyVar, 4);
var a: any;

// Generic call with multiple parameters of generic type where one argument is [] and the other is not 'any'
var arr = someGenerics9([], null, undefined);
var arr: any[];

`,
      [],
    );
  });
  test("typeArgumentInferenceConstructSignatures", async () => {
    await expectPass(
      `// Generic call with no parameters
interface NoParams {
    new <T>();
}
declare var noParams: NoParams;
new noParams();
new noParams<string>();
new noParams<{}>();

// Generic call with parameters but none use type parameter type
interface noGenericParams {
    new <T>(n: string);
}
declare var noGenericParams: noGenericParams;
new noGenericParams('');
new noGenericParams<number>('');
new noGenericParams<{}>('');

// Generic call with multiple type parameters and only one used in parameter type annotation
interface someGenerics1 {
    new <T, U>(n: T, m: number);
}
declare var someGenerics1: someGenerics1;
new someGenerics1(3, 4);
new someGenerics1<string, number>(3, 4); // Error
new someGenerics1<number, {}>(3, 4);

// Generic call with argument of function type whose parameter is of type parameter type
interface someGenerics2a {
    new <T>(n: (x: T) => void);
}
declare var someGenerics2a: someGenerics2a;
new someGenerics2a((n: string) => n);
new someGenerics2a<string>((n: string) => n);
new someGenerics2a<string>((n) => n.substr(0));

interface someGenerics2b {
    new <T, U>(n: (x: T, y: U) => void);
}
declare var someGenerics2b: someGenerics2b;
new someGenerics2b((n: string, x: number) => n);
new someGenerics2b<string, number>((n: string, t: number) => n);
new someGenerics2b<string, number>((n, t) => n.substr(t * t));

// Generic call with argument of function type whose parameter is not of type parameter type but body/return type uses type parameter
interface someGenerics3 {
    new <T>(producer: () => T);
}
declare var someGenerics3: someGenerics3;
new someGenerics3(() => '');
new someGenerics3<Window>(() => undefined);
new someGenerics3<number>(() => 3);

// 2 parameter generic call with argument 1 of type parameter type and argument 2 of function type whose parameter is of type parameter type
interface someGenerics4 {
    new <T, U>(n: T, f: (x: U) => void);
}
declare var someGenerics4: someGenerics4;
new someGenerics4(4, () => null);
new someGenerics4<string, number>('', () => 3);
new someGenerics4<string, number>('', (x: string) => ''); // Error
new someGenerics4<string, number>(null, null);

// 2 parameter generic call with argument 2 of type parameter type and argument 1 of function type whose parameter is of type parameter type
interface someGenerics5 {
    new <U, T>(n: T, f: (x: U) => void);
}
declare var someGenerics5: someGenerics5;
new someGenerics5(4, () => null);
new someGenerics5<number, string>('', () => 3);
new someGenerics5<number, string>('', (x: string) => ''); // Error
new someGenerics5<string, number>(null, null);

// Generic call with multiple arguments of function types that each have parameters of the same generic type
interface someGenerics6 {
    new <A>(a: (a: A) => A, b: (b: A) => A, c: (c: A) => A);
}
declare var someGenerics6: someGenerics6;
new someGenerics6(n => n, n => n, n => n);
new someGenerics6<number>(n => n, n => n, n => n);
new someGenerics6<number>((n: number) => n, (n: string) => n, (n: number) => n); // Error
new someGenerics6<number>((n: number) => n, (n: number) => n, (n: number) => n);

// Generic call with multiple arguments of function types that each have parameters of different generic type
interface someGenerics7 {
    new <A, B, C>(a: (a: A) => A, b: (b: B) => B, c: (c: C) => C);
}
declare var someGenerics7: someGenerics7;
new someGenerics7(n => n, n => n, n => n);
new someGenerics7<number, string, number>(n => n, n => n, n => n);
new someGenerics7<number, string, number>((n: number) => n, (n: string) => n, (n: number) => n);

// Generic call with argument of generic function type
interface someGenerics8 {
    new <T>(n: T): T;
}
declare var someGenerics8: someGenerics8;
var x = new someGenerics8(someGenerics7);
new x<string, string, string>(null, null, null);

// Generic call with multiple parameters of generic type passed arguments with no best common type
interface someGenerics9 {
    new <T>(a: T, b: T, c: T): T;
}
declare var someGenerics9: someGenerics9;
var a9a = new someGenerics9('', 0, []);
declare var a9a: {};
var a9b = new someGenerics9<{ a?: number; b?: string; }>({ a: 0 }, { b: '' }, null);
declare var a9b: { a?: number; b?: string; };

// Generic call with multiple parameters of generic type passed arguments with multiple best common types
interface A91 {
    x: number;
    y?: string;
}
interface A92 {
    x: number;
    z?: Window;
}
var a9e = new someGenerics9(undefined, { x: 6, z: window }, { x: 6, y: '' });
declare var a9e: {};
var a9f = new someGenerics9<A92>(undefined, { x: 6, z: window }, { x: 6, y: '' });
declare var a9f: A92;

// Generic call with multiple parameters of generic type passed arguments with a single best common type
var a9d = new someGenerics9({ x: 3 }, { x: 6 }, { x: 6 });
declare var a9d: { x: number; };

// Generic call with multiple parameters of generic type where one argument is of type 'any'
declare var anyVar: any;
var a = new someGenerics9(7, anyVar, 4);
declare var a: any;

// Generic call with multiple parameters of generic type where one argument is [] and the other is not 'any'
var arr = new someGenerics9([], null, undefined);
declare var arr: any[];

`,
      [],
    );
  });
  test("typeArgumentInferenceErrors", async () => {
    await expectPass(
      `// Generic call with multiple type parameters and only one used in parameter type annotation
function someGenerics1<T, U>(n: T, m: number) { }
someGenerics1<string, number>(3, 4); // Error

// 2 parameter generic call with argument 1 of type parameter type and argument 2 of function type whose parameter is of type parameter type
function someGenerics4<T, U>(n: T, f: (x: U) => void) { }
someGenerics4<string, number>('', (x: string) => ''); // Error

// 2 parameter generic call with argument 2 of type parameter type and argument 1 of function type whose parameter is of type parameter type
function someGenerics5<U, T>(n: T, f: (x: U) => void) { }
someGenerics5<number, string>('', (x: string) => ''); // Error

// Generic call with multiple arguments of function types that each have parameters of the same generic type
function someGenerics6<A>(a: (a: A) => A, b: (b: A) => A, c: (c: A) => A) { }
someGenerics6<number>((n: number) => n, (n: string) => n, (n: number) => n); // Error
`,
      [],
    );
  });
  test("typeArgumentInferenceTransitiveConstraints", async () => {
    await expectPass(
      `
function fn<A extends Date, B extends A, C extends B>(a: A, b: B, c: C) {
    return [a, b, c];
}

var d = fn(new Date(), new Date(), new Date());
var d: Date[]; // Should be OK (d should be Date[])
`,
      [],
    );
  });
  test("typeArgumentInferenceWithConstraints", async () => {
    await expectPass(
      `// Generic call with no parameters
function noParams<T extends {}>() { }
noParams();
noParams<string>();
noParams<{}>();

// Generic call with parameters but none use type parameter type
function noGenericParams<T extends number>(n: string) { }
noGenericParams(''); // Valid
noGenericParams<number>('');
noGenericParams<{}>(''); // Error

// Generic call with multiple type parameters and only one used in parameter type annotation
function someGenerics1<T, U extends T>(n: T, m: number) { }
someGenerics1(3, 4); // Valid
someGenerics1<string, number>(3, 4); // Error
someGenerics1<number, {}>(3, 4); // Error
someGenerics1<number, number>(3, 4);

// Generic call with argument of function type whose parameter is of type parameter type
function someGenerics2a<T extends string>(n: (x: T) => void) { }
someGenerics2a((n: string) => n);
someGenerics2a<string>((n: string) => n);
someGenerics2a<string>((n) => n.substr(0));

function someGenerics2b<T extends string, U extends number>(n: (x: T, y: U) => void) { }
someGenerics2b((n: string, x: number) => n);
someGenerics2b<string, number>((n: string, t: number) => n);
someGenerics2b<string, number>((n, t) => n.substr(t * t));

// Generic call with argument of function type whose parameter is not of type parameter type but body/return type uses type parameter
function someGenerics3<T extends Window>(producer: () => T) { }
someGenerics3(() => ''); // Error
someGenerics3<Window>(() => undefined);
someGenerics3<number>(() => 3); // Error

// 2 parameter generic call with argument 1 of type parameter type and argument 2 of function type whose parameter is of type parameter type
function someGenerics4<T, U extends number>(n: T, f: (x: U) => void) { }
someGenerics4(4, () => null); // Valid
someGenerics4<string, number>('', () => 3);
someGenerics4<string, number>('', (x: string) => ''); // Error
someGenerics4<string, number>(null, null);

// 2 parameter generic call with argument 2 of type parameter type and argument 1 of function type whose parameter is of type parameter type
function someGenerics5<U extends number, T>(n: T, f: (x: U) => void) { }
someGenerics5(4, () => null); // Valid
someGenerics5<number, string>('', () => 3);
someGenerics5<number, string>('', (x: string) => ''); // Error
someGenerics5<string, number>(null, null); // Error

// Generic call with multiple arguments of function types that each have parameters of the same generic type
function someGenerics6<A extends number>(a: (a: A) => A, b: (b: A) => A, c: (c: A) => A) { }
someGenerics6(n => n, n => n, n => n); // Valid
someGenerics6<number>(n => n, n => n, n => n);
someGenerics6<number>((n: number) => n, (n: string) => n, (n: number) => n); // Error
someGenerics6<number>((n: number) => n, (n: number) => n, (n: number) => n);

// Generic call with multiple arguments of function types that each have parameters of different generic type
function someGenerics7<A, B extends string, C>(a: (a: A) => A, b: (b: B) => B, c: (c: C) => C) { }
someGenerics7(n => n, n => n, n => n); // Valid, types of n are <any, string, any> respectively
someGenerics7<number, string, number>(n => n, n => n, n => n);
someGenerics7<number, string, number>((n: number) => n, (n: string) => n, (n: number) => n);

// Generic call with argument of generic function type
function someGenerics8<T extends string>(n: T): T { return n; }
var x = someGenerics8<string>(someGenerics7); // Error
x<string, string, string>(null, null, null); // Error

// Generic call with multiple parameters of generic type passed arguments with no best common type
function someGenerics9<T extends any>(a: T, b: T, c: T): T {
    return null;
}
var a9a = someGenerics9('', 0, []);
var a9a: {};
var a9b = someGenerics9<{ a?: number; b?: string; }>({ a: 0 }, { b: '' }, null);
var a9b: { a?: number; b?: string; };

// Generic call with multiple parameters of generic type passed arguments with multiple best common types
interface A91 {
    x: number;
    y?: string;
}
interface A92 {
    x: number;
    z?: Window;
}
var a9e = someGenerics9(undefined, { x: 6, z: window }, { x: 6, y: '' });
var a9e: {};
var a9f = someGenerics9<A92>(undefined, { x: 6, z: window }, { x: 6, y: '' });
var a9f: A92;

// Generic call with multiple parameters of generic type passed arguments with a single best common type
var a9d = someGenerics9({ x: 3 }, { x: 6 }, { x: 6 });
var a9d: { x: number; };

// Generic call with multiple parameters of generic type where one argument is of type 'any'
var anyVar: any;
var a = someGenerics9(7, anyVar, 4);
var a: any;

// Generic call with multiple parameters of generic type where one argument is [] and the other is not 'any'
var arr = someGenerics9([], null, undefined);
var arr: any[];

`,
      [],
    );
  });
  test("typeArgumentInferenceWithObjectLiteral", async () => {
    await expectPass(
      `interface Computed<T> {
    read(): T;
    write(value: T);
}

function foo<T>(x: Computed<T>) { }

var s: string;

// Calls below should infer string for T and then assign that type to the value parameter
foo({
    read: () => s,
    write: value => s = value
});
foo({
    write: value => s = value,
    read: () => s
});

enum E1 { X }
enum E2 { X }

// Check that we infer from both a.r and b before fixing T in a.w

declare function f1<T, U>(a: { w: (x: T) => U; r: () => T; }, b: T): U;

var v1: number;
var v1 = f1({ w: x => x, r: () => 0 }, 0);
var v1 = f1({ w: x => x, r: () => 0 }, E1.X);
var v1 = f1({ w: x => x, r: () => E1.X }, 0);

var v2: E1;
var v2 = f1({ w: x => x, r: () => E1.X }, E1.X);

var v3 = f1({ w: x => x, r: () => E1.X }, E2.X);  // Error
`,
      [],
    );
  });
  test("arrowFunctionContexts", async () => {
    await expectPass(
      `
// Arrow function used in with statement
with (window) {
    var p = () => this;
}

// Arrow function as argument to super call
class Base {
    constructor(n: any) { }
}

class Derived extends Base {
    constructor() {
        super(() => this);
    }
}

// Arrow function as function argument
window.setTimeout(() => null, 100);

// Arrow function as value in array literal

var obj = (n: number) => '';
var obj: { (n: number): string; }; // OK

var arr = [(n: number) => ''];
var arr: { (n: number): string; }[]; // Incorrect error here (bug 829597)

// Arrow function as enum value
enum E {
    x = () => 4, // Error expected
    y = (() => this).length // error, can't use this in enum
}

// Arrow function as module variable initializer
namespace M {
    export var a = (s) => '';
    var b = (s) => s;
}

// Repeat above for module members that are functions? (necessary to redo all of them?)
namespace M2 {
    // Arrow function used in with statement
    with (window) {
        var p = () => this;
    }

    // Arrow function as argument to super call
    class Base {
        constructor(n: any) { }
    }

    class Derived extends Base {
        constructor() {
            super(() => this);
        }
    }

    // Arrow function as function argument
    window.setTimeout(() => null, 100);

    // Arrow function as value in array literal

    var obj = (n: number) => '';
    var obj: { (n: number): string; }; // OK

    var arr = [(n: number) => ''];
    var arr: { (n: number): string; }[]; // Incorrect error here (bug 829597)

    // Arrow function as enum value
    enum E {
        x = () => 4, // Error expected
        y = (() => this).length
    }

    // Arrow function as module variable initializer
    namespace M {
        export var a = (s) => '';
        var b = (s) => s;
    }

}

// <Identifier>(ParamList) => { ... } is a generic arrow function
var generic1 = <T>(n: T) => [n];
var generic1: { <T>(n: T): T[] }; // Incorrect error, Bug 829597
var generic2 = <T>(n: T) => { return [n]; };
var generic2: { <T>(n: T): T[] };

// <Identifier> ((ParamList) => { ... } ) is a type assertion to an arrow function
var asserted1 = <any>((n) => [n]);
var asserted1: any;
var asserted2 = <any>((n) => { return n; });
var asserted2: any;

`,
      [],
    );
  });
  test("arrowFunctionExpressions", async () => {
    await expectPass(
      `// ArrowFormalParameters => AssignmentExpression is equivalent to ArrowFormalParameters => { return AssignmentExpression; }
var a = (p: string) => p.length;
var a = (p: string) => { return p.length; }

// Identifier => Block is equivalent to(Identifier) => Block
var b = j => { return 0; }
var b = (j) => { return 0; }

// Identifier => AssignmentExpression is equivalent to(Identifier) => AssignmentExpression
var c: number;
var d = n => c = n;
var d = (n) => c = n;
var d: (n: any) => any;

// Binding patterns in arrow functions
var p1 = ([a]) => { };
var p2 = ([...a]) => { };
var p3 = ([, a]) => { };
var p4 = ([, ...a]) => { };
var p5 = ([a = 1]) => { };
var p6 = ({ a }) => { };
var p7 = ({ a: { b } }) => { };
var p8 = ({ a = 1 }) => { };
var p9 = ({ a: { b = 1 } = { b: 1 } }) => { };
var p10 = ([{ value, done }]) => { };

// Arrow function used in class member initializer
// Arrow function used in class member function
class MyClass {
    m = (n) => n + 1;
    p = (n) => n && this;

    fn() {
        var m = (n) => n + 1;
        var p = (n) => n && this;
    }
}

// Arrow function used in arrow function
var arrrr = () => (m: number) => () => (n: number) => m + n;
var e = arrrr()(3)()(4);
var e: number;

// Arrow function used in arrow function used in function
function someFn() {
    var arr = (n: number) => (p: number) => p * n;
    arr(3)(4).toExponential();
}

// Arrow function used in function
function someOtherFn() {
    var arr = (n: number) => '' + n;
    arr(4).charAt(0);
}

// Arrow function used in nested function in function
function outerFn() {
    function innerFn() {
        var arrowFn = () => { };
        var p = arrowFn();
        var p: void;
    }
}

// Arrow function used in nested function in arrow function
var f = (n: string) => {
    function fn(x: number) {
        return () => n + x;
    }
    return fn(4);
}
var g = f('')();
var g: string;


// Arrow function used in nested function in arrow function in nested function
function someOuterFn() {
    var arr = (n: string) => {
        function innerFn() {
            return () => n.length;
        }
        return innerFn;
    }
    return arr;
}
var h = someOuterFn()('')()();
h.toExponential();

// Arrow function used in try/catch/finally in function
function tryCatchFn() {
    try {
        var x = () => this;
    } catch (e) {
        var t = () => e + this;
    } finally {
        var m = () => this + '';
    }
}
`,
      [],
    );
  });
  test("contextuallyTypedFunctionExpressionsAndReturnAnnotations", async () => {
    await expectPass(
      `declare function foo(x: (y: string) => (y2: number) => void);

// Contextually type the parameter even if there is a return annotation
foo((y): (y2: number) => void => {
    var z = y.charAt(0); // Should be string
    return null;
});

foo((y: string) => {
    return y2 => {
        var z = y2.toFixed(); // Should be string
        return 0;
    };
});`,
      [],
    );
  });
  test("contextuallyTypedIife", async () => {
    await expectError(
      `// arrow
(jake => { })("build");
// function expression
(function (cats) { })("lol");
// Lots of Irritating Superfluous Parentheses
(function (x) { } ("!"));
((((function (y) { }))))("-");
// multiple arguments
((a, b, c) => { })("foo", 101, false);
// default parameters
((m = 10) => m + 1)(12);
((n = 10) => n + 1)();
// optional parameters
((j?) => j + 1)(12);
((k?) => k + 1)();
((l, o?) => l + o)(12); // o should be any
// rest parameters
((...numbers) => numbers.every(n => n > 0))(5,6,7);
((...mixed) => mixed.every(n => !!n))(5,'oops','oh no');
((...noNumbers) => noNumbers.some(n => n > 0))();
((first, ...rest) => first ? [] : rest.map(n => n > 0))(8,9,10);
// destructuring parameters (with defaults too!)
(({ q }) => q)({ q : 13 });
(({ p = 14 }) => p)({ p : 15 });
(({ r = 17 } = { r: 18 }) => r)({r : 19});
(({ u = 22 } = { u: 23 }) => u)();
// contextually typed parameters.
let twelve = (f => f(12))(i => i);
let eleven = (o => o.a(11))({ a: function(n) { return n; } });
// missing arguments
(function(x, undefined) { return x; })(42);
((x, y, z) => 42)();`,
      [],
    );
  });
  test("contextuallyTypedIifeStrict", async () => {
    await expectError(
      `// arrow
(jake => { })("build");
// function expression
(function (cats) { })("lol");
// Lots of Irritating Superfluous Parentheses
(function (x) { } ("!"));
((((function (y) { }))))("-");
// multiple arguments
((a, b, c) => { })("foo", 101, false);
// default parameters
((m = 10) => m + 1)(12);
((n = 10) => n + 1)();
// optional parameters
((j?) => j + 1)(12);
((k?) => k + 1)();
((l, o?) => l + o)(12);
// rest parameters
((...numbers) => numbers.every(n => n > 0))(5,6,7);
((...mixed) => mixed.every(n => !!n))(5,'oops','oh no');
((...noNumbers) => noNumbers.some(n => n > 0))();
((first, ...rest) => first ? [] : rest.map(n => n > 0))(8,9,10);
// destructuring parameters (with defaults too!)
(({ q }) => q)({ q : 13 });
(({ p = 14 }) => p)({ p : 15 });
(({ r = 17 } = { r: 18 }) => r)({r : 19});
(({ u = 22 } = { u: 23 }) => u)();
// contextually typed parameters.
let twelve = (f => f(12))(i => i);
let eleven = (o => o.a(11))({ a: function(n) { return n; } });
// missing arguments
(function(x, undefined) { return x; })(42);
((x, y, z) => 42)();`,
      [],
    );
  });
  test("typeOfThisInFunctionExpression", async () => {
    await expectPass(
      `// type of 'this' in FunctionExpression is Any

function fn() {
    var p = this;
    var p: any;
}

var t = function () {
    var p = this;
    var p: any;
}

var t2 = function f() {
    var x = this;
    var x: any;
}

class C {
    x = function () {
        var q: any;
        var q = this;
    }
    y = function ff() {
        var q: any;
        var q = this;
    }
}

namespace M {
    function fn() {
        var p = this;
        var p: any;
    }

    var t = function () {
        var p = this;
        var p: any;
    }

    var t2 = function f() {
        var x = this;
        var x: any;
    }

}`,
      [],
    );
  });
  test("voidParamAssignmentCompatibility", async () => {
    await expectPass(
      `declare function g(a: void): void;
let gg: () => void = g;

interface Obj<T> {
    method(value: T): void;
}

declare const o: Obj<void>;
gg = o.method;
`,
      [],
    );
  });
  test("scopeResolutionIdentifiers", async () => {
    await expectPass(
      `// EveryType used in a nested scope of a different EveryType with the same name, type of the identifier is the one defined in the inner scope

var s: string;
namespace M1 {
    export var s: number = 0;
    var n = s;
    var n: number;
}

namespace M2 {
    var s: number = 0;
    var n = s;
    var n: number;
}

function fn() {
    var s: boolean = false;
    var n = s;
    var n: boolean;
}

class C {
    s!: Date;
    n = this.s;
    x() {
        var p = this.n;
        var p: Date;
    }
}

namespace M3 {
    var s: any;
    namespace M4 {
        var n = s;
        var n: any;
    }
}
`,
      [],
    );
  });
  test("literals", async () => {
    await expectError(
      `
//typeof null is Null
//typeof true is Boolean
//typeof false is Boolean
//typeof numeric literal is Number
//typeof string literal is String
//typeof regex literal is Regex

var nu = null / null;
var u = undefined / undefined;

var b: boolean;
var b = true;
var b = false;

var n: number;
var n = 1;
var n = 1.0;
var n = 1e4;
var n = 001; // Error in ES5
var n = 0x1;
var n = -1;
var n = -1.0;
var n = -1e-4;
var n = -003; // Error in ES5
var n = -0x1;

var s: string;
var s = '';
var s = "";
var s = 'foo\\
    bar';
var s = "foo\\
    bar";

var r: RegExp;
var r = /what/;
var r = /\\\\\\\\/;
`,
      [],
    );
  });
  test("strictModeOctalLiterals", async () => {
    await expectError(
      `export enum E {
    A = 12 + 01
}
const orbitol: 01 = 01`,
      [],
    );
  });
  test("newOperatorConformance", async () => {
    await expectPass(
      `
class C0 {

}
class C1 {
    constructor(n: number, s: string) { }
}

class T<T> {
    constructor(n?: T) { }
}

var anyCtor: {
    new (): any;
};

var anyCtor1: {
    new (n): any;
};

interface nestedCtor {
    new (): nestedCtor;
}
var nestedCtor: nestedCtor;

// Construct expression with no parentheses for construct signature with 0 parameters
var a = new C0;
var a: C0;


// Generic construct expression with no parentheses
var c1 = new T;
var c1: T<{}>;

// Construct expression where constructor is of type 'any' with no parentheses
var d = new anyCtor;
var d: any;

// Construct expression where constructor is of type 'any' with > 1 arg
var d = new anyCtor1(undefined);

// Construct expression of type where apparent type has a construct signature with 0 arguments
function newFn1<T extends { new (): number }>(s: T) {
    var p = new s;
    var p: number;
}

// Construct expression of type where apparent type has a construct signature with 1 arguments
function newFn2<T extends { new (s: number): string}>(s: T) {
    var p = new s(32);
    var p: string;
}

// Construct expression of void returning function
function fnVoid(): void { }
var t = new fnVoid();
var t: any;

// Chained new expressions
var nested = new (new (new nestedCtor())())();
var n = new nested();
var n = new nested();
`,
      [],
    );
  });
  test("newOperatorErrorCases_noImplicitAny", async () => {
    await expectPass(
      `
function fnNumber(this: void): number { return 90; }
new fnNumber(); // Error

function fnVoid(this: void): void {}
new fnVoid(); // Error

function functionVoidNoThis(): void {}
new functionVoidNoThis(); // Error`,
      [],
    );
  });
  test("newOperatorErrorCases", async () => {
    await expectError(
      `
class C0 {

}
class C1 {
    constructor(n: number, s: string) { }
}

class T<T> {
    constructor(n?: T) { }
}

var anyCtor: {
    new (): any;
};

var anyCtor1: {
    new (n): any;
};

interface nestedCtor {
    new (): nestedCtor;
}
var nestedCtor: nestedCtor;

// Construct expression with no parentheses for construct signature with > 0 parameters
var b = new C0 32, ''; // Parse error

// Generic construct expression with no parentheses
var c1 = new T;
var c1: T<{}>;
var c2 = new T<string>;  // Ok


// Construct expression of non-void returning function
function fnNumber(): number { return 32; }
var s = new fnNumber(); // Error
`,
      [],
    );
  });
  test("nullishCoalescingAssignmentVsPrivateFieldsJsEmit1", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/61109

class Cls {
  #privateProp: number | undefined;

  problem() {
    this.#privateProp ??= false ? neverThis() : 20;
  }
}

function neverThis(): never {
  throw new Error("This should really really never happen!");
}`,
      [],
    );
  });
  test("nullishCoalescingOperator_es2020", async () => {
    await expectPass(
      `
declare const a1: 'literal' | undefined | null
declare const a2: '' | undefined | null
declare const a3: 1 | undefined | null
declare const a4: 0 | undefined | null
declare const a5: true | undefined | null
declare const a6: false | undefined | null
declare const a7: unknown | null
declare const a8: never | null
declare const a9: any | null


const aa1 = a1 ?? 'whatever'
const aa2 = a2 ?? 'whatever'
const aa3 = a3 ?? 'whatever'
const aa4 = a4 ?? 'whatever'
const aa5 = a5 ?? 'whatever'
const aa6 = a6 ?? 'whatever'
const aa7 = a7 ?? 'whatever'
const aa8 = a8 ?? 'whatever'
const aa9 = a9 ?? 'whatever'


declare let a: any, b: any, c: any;

let x1 = (a ?? b as any) || c;
let x2 = c || (a ?? b as any);
let x3 = ((a ?? b) as any) || c;
let x4 = c || ((a ?? b) as any);
let x5 = (a ?? b) as any || c;
let x6 = c || (a ?? b) as any;

let y1 = (a ?? b as any) && c;
let y2 = c && (a ?? b as any);
let y3 = ((a ?? b) as any) && c;
let y4 = c && ((a ?? b) as any);
let y5 = (a ?? b) as any && c;
let y6 = c && (a ?? b) as any;`,
      [],
    );
  });
  test("nullishCoalescingOperator_not_strict", async () => {
    await expectPass(
      `
declare const a1: 'literal' | undefined | null
declare const a2: '' | undefined | null
declare const a3: 1 | undefined | null
declare const a4: 0 | undefined | null
declare const a5: true | undefined | null
declare const a6: false | undefined | null
declare const a7: unknown | null
declare const a8: never | null
declare const a9: any | null


const aa1 = a1 ?? 'whatever'
const aa2 = a2 ?? 'whatever'
const aa3 = a3 ?? 'whatever'
const aa4 = a4 ?? 'whatever'
const aa5 = a5 ?? 'whatever'
const aa6 = a6 ?? 'whatever'
const aa7 = a7 ?? 'whatever'
const aa8 = a8 ?? 'whatever'
const aa9 = a9 ?? 'whatever'`,
      [],
    );
  });
  test("nullishCoalescingOperator1", async () => {
    await expectPass(
      `
declare const a1: string | undefined | null
declare const a2: string | undefined | null
declare const a3: string | undefined | null
declare const a4: string | undefined | null

declare const b1: number | undefined | null
declare const b2: number | undefined | null
declare const b3: number | undefined | null
declare const b4: number | undefined | null

declare const c1: boolean | undefined | null
declare const c2: boolean | undefined | null
declare const c3: boolean | undefined | null
declare const c4: boolean | undefined | null

interface I { a: string }
declare const d1: I | undefined | null
declare const d2: I | undefined | null
declare const d3: I | undefined | null
declare const d4: I | undefined | null

const aa1 = a1 ?? 'whatever';
const aa2 = a2 ?? 'whatever';
const aa3 = a3 ?? 'whatever';
const aa4 = a4 ?? 'whatever';

const bb1 = b1 ?? 1;
const bb2 = b2 ?? 1;
const bb3 = b3 ?? 1;
const bb4 = b4 ?? 1;

const cc1 = c1 ?? true;
const cc2 = c2 ?? true;
const cc3 = c3 ?? true;
const cc4 = c4 ?? true;

const dd1 = d1 ?? {b: 1};
const dd2 = d2 ?? {b: 1};
const dd3 = d3 ?? {b: 1};
const dd4 = d4 ?? {b: 1};

// Repro from #34635

declare function foo(): void;

const maybeBool = false;

if (!(maybeBool ?? true)) {
    foo();
}

if (maybeBool ?? true) {
    foo();
}
else {
    foo();
}

if (false ?? true) {
    foo();
}
else {
    foo();
}`,
      [],
    );
  });
  test("nullishCoalescingOperator10", async () => {
    await expectPass(
      `
declare function f(): string | undefined;

let gg = f() ?? 'foo'`,
      [],
    );
  });
  test("nullishCoalescingOperator11", async () => {
    await expectPass(
      `
declare const f11: 1 | 0 | '' | null | undefined;

let g11 = f11 ?? f11.toFixed()`,
      [],
    );
  });
  test("nullishCoalescingOperator12", async () => {
    await expectPass(
      `
const obj: { arr: any[] } = { arr: [] };
for (const i of obj?.arr ?? []) { }`,
      [],
    );
  });
  test("nullishCoalescingOperator2", async () => {
    await expectPass(
      `
declare const a1: 'literal' | undefined | null
declare const a2: '' | undefined | null
declare const a3: 1 | undefined | null
declare const a4: 0 | undefined | null
declare const a5: true | undefined | null
declare const a6: false | undefined | null
declare const a7: unknown | null
declare const a8: never | null
declare const a9: any | null


const aa1 = a1 ?? 'whatever'
const aa2 = a2 ?? 'whatever'
const aa3 = a3 ?? 'whatever'
const aa4 = a4 ?? 'whatever'
const aa5 = a5 ?? 'whatever'
const aa6 = a6 ?? 'whatever'
const aa7 = a7 ?? 'whatever'
const aa8 = a8 ?? 'whatever'
const aa9 = a9 ?? 'whatever'`,
      [],
    );
  });
  test("nullishCoalescingOperator3", async () => {
    await expectPass(
      `
declare const a1: 'literal' | undefined | null
declare const a2: '' | undefined | null
declare const a3: 1 | undefined | null
declare const a4: 0 | undefined | null
declare const a5: true | undefined | null
declare const a6: false | undefined | null


const aa1 = a1 ?? a2 ?? a3 ?? a4 ?? a5 ?? a6 ?? 'whatever'`,
      [],
    );
  });
  test("nullishCoalescingOperator4", async () => {
    await expectPass(
      `
declare const a1: 'literal' | undefined | null
const aa1 = a1 ?? a1.toLowerCase()
const aa2 = a1 || a1.toLocaleUpperCase()`,
      [],
    );
  });
  test("nullishCoalescingOperator5", async () => {
    await expectError(
      `
declare const a: string | undefined
declare const b: string | undefined
declare const c: string | undefined

// should be a syntax error
a ?? b || c;

// should be a syntax error
a || b ?? c;

// should be a syntax error
a ?? b && c;

// should be a syntax error
a && b ?? c;

// Valid according to spec
a ?? (b || c);

// Valid according to spec
(a ?? b) || c;

// Valid according to spec
(a || b) ?? c;

// Valid according to spec
a || (b ?? c);

// Valid according to spec
a ?? (b && c);

// Valid according to spec
(a ?? b) && c;

// Valid according to spec
(a && b) ?? c;

// Valid according to spec
a && (b ?? c);`,
      [],
    );
  });
  test("nullishCoalescingOperator6", async () => {
    await expectPass(
      `
function foo(foo: string, bar = foo ?? "bar") { }`,
      [],
    );
  });
  test("nullishCoalescingOperator7", async () => {
    await expectPass(
      `
declare const a: string | undefined;
declare const b: string | undefined;
declare const c: string | undefined;

const foo1 = a ? 1 : 2;
const foo2 = a ?? 'foo' ? 1 : 2;
const foo3 = a ?? 'foo' ? (b ?? 'bar') : (c ?? 'baz');

function f () {
    const foo4 = a ?? 'foo' ? b ?? 'bar' : c ?? 'baz';
}`,
      [],
    );
  });
  test("nullishCoalescingOperator8", async () => {
    await expectPass(
      `
declare const a: { p: string | undefined, m(): string | undefined };
declare const b: { p: string | undefined, m(): string | undefined };

const n1 = a.p ?? "default";
const n2 = a.m() ?? "default";
const n3 = a.m() ?? b.p ?? b.m() ?? "default";;`,
      [],
    );
  });
  test("nullishCoalescingOperator9", async () => {
    await expectPass(
      `
declare let f: null | ((x: string) => void);

let g = f || (abc => { void abc.toLowerCase() })
let gg = f ?? (abc => { void abc.toLowerCase() })`,
      [],
    );
  });
  test("nullishCoalescingOperatorInAsyncGenerator", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/37686
async function* f(a: { b?: number }) {
    let c = a.b ?? 10;
    while (c) {
        yield c--;
    }
}
`,
      [],
    );
  });
  test("nullishCoalescingOperatorInParameterBindingPattern.2", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): string | undefined => undefined;
(({ [a() ?? "d"]: c = "" }) => { var a; })();

const x = "";
(({ [a() ?? "d"]: c = "", d = x }) => { var x; })();`,
      [],
    );
  });
  test("nullishCoalescingOperatorInParameterBindingPattern", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): string | undefined => undefined;
(({ [a() ?? "d"]: c = "" }) => {})();`,
      [],
    );
  });
  test("nullishCoalescingOperatorInParameterInitializer.2", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): string | undefined => undefined;
((b = a() ?? "d") => { var a; })();

const x = "";
((b = a() ?? "d", d = x) => { var x; })();`,
      [],
    );
  });
  test("nullishCoalescingOperatorInParameterInitializer", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): string | undefined => undefined;
((b = a() ?? "d") => {})();`,
      [],
    );
  });
  test("objectLiteralErrors", async () => {
    await expectError(
      `
// Multiple properties with the same name
var e1 = { a: 0, a: 0 };
var e2 = { a: '', a: '' };
var e3 = { a: 0, a: '' };
var e4 = { a: true, a: false };
var e5 = { a: {}, a: {} };
var e6 = { a: 0, 'a': 0 };
var e7 = { 'a': 0, a: 0 };
var e8 = { 'a': 0, "a": 0 };
var e9 = { 'a': 0, 'a': 0 };
var e10 = { "a": 0, 'a': 0 };
var e11 = { 1.0: 0, '1': 0 };
var e12 = { 0: 0, 0: 0 };
var e13 = { 0: 0, 0: 0 };
var e14 = { 0: 0, 0x0: 0 };
var e14 = { 0: 0, 0o0: 0 };
var e15 = { "100": 0, 1e2: 0 };
var e16 = { 0x20: 0, 3.2e1: 0 };
var e17 = { a: 0, b: 1, a: 0 };

// Accessor and property with the same name
var f1 = { a: 0, get a() { return 0; } };
var f2 = { a: '', get a() { return ''; } };
var f3 = { a: 0, get a() { return ''; } };
var f4 = { a: true, get a() { return false; } };
var f5 = { a: {}, get a() { return {}; } };
var f6 = { a: 0, get 'a'() { return 0; } };
var f7 = { 'a': 0, get a() { return 0; } };
var f8 = { 'a': 0, get "a"() { return 0; } };
var f9 = { 'a': 0, get 'a'() { return 0; } };
var f10 = { "a": 0, get 'a'() { return 0; } };
var f11 = { 1.0: 0, get '1'() { return 0; } };
var f12 = { 0: 0, get 0() { return 0; } };
var f13 = { 0: 0, get 0() { return 0; } };
var f14 = { 0: 0, get 0x0() { return 0; } };
var f14 = { 0: 0, get 0o0() { return 0; } };
var f15 = { "100": 0, get 1e2() { return 0; } };
var f16 = { 0x20: 0, get 3.2e1() { return 0; } };
var f17 = { a: 0, get b() { return 1; }, get a() { return 0; } };

// Get and set accessor with mismatched type annotations (only g2 is an error after #43662 implemented)
var g1 = { get a(): number { return 4; }, set a(n: string) { } };
var g2 = { get a() { return 4; }, set a(n: string) { } };
var g3 = { get a(): number { return undefined; }, set a(n: string) { } };

// did you mean colon errors
var h1 = {
    x = 1,
    y = 2,
    #z: 3
}
`,
      [],
    );
  });
  test("objectLiteralGettersAndSetters", async () => {
    await expectPass(
      `// Get and set accessor with the same name
var sameName1a = { get 'a'() { return ''; }, set a(n) { var p = n; var p: string; } };
var sameName2a = { get 0.0() { return ''; }, set 0(n) { var p = n; var p: string; } };
var sameName3a = { get 0x20() { return ''; }, set 3.2e1(n) { var p = n; var p: string; } };
var sameName4a = { get ''() { return ''; }, set ""(n) { var p = n; var p: string; } };
var sameName5a = { get '\\t'() { return ''; }, set '\\t'(n) { var p = n; var p: string; } };
var sameName6a = { get 'a'() { return ''; }, set a(n) { var p = n; var p: string; } };

// PropertyName CallSignature{FunctionBody} is equivalent to PropertyName:function CallSignature{FunctionBody}
var callSig1 = { num(n: number) { return '' } };
var callSig1: { num: (n: number) => string; };
var callSig2 = { num: function (n: number) { return '' } };
var callSig2: { num: (n: number) => string; };
var callSig3 = { num: (n: number) => '' };
var callSig3: { num: (n: number) => string; };

// Get accessor only, type of the property is the annotated return type of the get accessor
var getter1 = { get x(): string { return undefined; } };
var getter1: { readonly x: string; }

// Get accessor only, type of the property is the inferred return type of the get accessor
var getter2 = { get x() { return ''; } };
var getter2: { readonly x: string; }

// Set accessor only, type of the property is the param type of the set accessor
var setter1 = { set x(n: number) { } };
var setter1: { x: number };

// Set accessor only, type of the property is Any for an unannotated set accessor
var setter2 = { set x(n) { } };
var setter2: { x: any };

var anyVar: any;
// Get and set accessor with matching type annotations
var sameType1 = { get x(): string { return undefined; }, set x(n: string) { } };
var sameType2 = { get x(): Array<number> { return undefined; }, set x(n: number[]) { } };
var sameType3 = { get x(): any { return undefined; }, set x(n: typeof anyVar) { } };
var sameType4 = { get x(): Date { return undefined; }, set x(n: Date) { } };

// Type of unannotated get accessor return type is the type annotation of the set accessor param
var setParamType1 = {
    set n(x: (t: string) => void) { },
    get n() { return (t) => {
            var p: string;
            var p = t;
        }
    }
};
var setParamType2 = {
    get n() { return (t) => {
            var p: string;
            var p = t;
        }
    },
    set n(x: (t: string) => void) { }
};

// Type of unannotated set accessor parameter is the return type annotation of the get accessor
var getParamType1 = {
    set n(x) {
        var y = x;
        var y: string;
    },
    get n() { return ''; }
};
var getParamType2 = {
    get n() { return ''; },
    set n(x) {
        var y = x;
        var y: string;
    }
};

// Type of unannotated accessors is the inferred return type of the get accessor
var getParamType3 = {
    get n() { return ''; },
    set n(x) {
        var y = x;
        var y: string;
    }
};

`,
      [],
    );
  });
  test("objectLiteralNormalization", async () => {
    await expectPass(
      `
// Object literals in unions are normalized upon widening
let a1 = [{ a: 0 }, { a: 1, b: "x" }, { a: 2, b: "y", c: true }][0];
a1.a;  // number
a1.b;  // string | undefined
a1.c;  // boolean | undefined
a1 = { a: 1 };
a1 = { a: 0, b: 0 };  // Error
a1 = { b: "y" };  // Error
a1 = { c: true };  // Error

let a2 = [{ a: 1, b: 2 }, { a: "abc" }, {}][0];
a2.a;  // string | number | undefined
a2.b;  // number | undefined
a2 = { a: 10, b: 20 };
a2 = { a: "def" };
a2 = {};
a2 = { a: "def", b: 20 };  // Error
a2 = { a: 1 };  // Error

// Object literals containing spreads are not normalized
declare let b1: { a: string, b: string } | { b: string, c: string };
let b2 = { ...b1, z: 55 };
let b3 = { ...b2 };

// Before widening {} acts like { [x: string]: undefined }, which is a
// subtype of types with all optional properties
declare let opts: { foo?: string, bar?: string, baz?: boolean };
let c1 = !true ? {} : opts;
let c2 = !true ? opts : {};
let c3 = !true ? { a: 0, b: 0 } : {};
let c4 = !true ? {} : { a: 0, b: 0 };

// Normalization applies to nested properties
let d1 = [{ kind: 'a', pos: { x: 0, y: 0 } }, { kind: 'b', pos: !true ? { a: "x" } : { b: 0 } }][0];
d1.kind;
d1.pos;
d1.pos.x;
d1.pos.y;
d1.pos.a;
d1.pos.b;

declare function f<T>(...items: T[]): T;
declare let data: { a: 1, b: "abc", c: true };

// Object literals are inferred as a single normalized union type
let e1 = f({ a: 1, b: 2 }, { a: "abc" }, {});
let e2 = f({}, { a: "abc" }, { a: 1, b: 2 });
let e3 = f(data, { a: 2 });
let e4 = f({ a: 2 }, data);
`,
      [],
    );
  });
  test("incrementAndDecrement", async () => {
    await expectError(
      `enum E { A, B, C };
var x = 4;
var e = E.B;
var a: any;
var w = window;

// Assign to expression++
x++ = 4; // Error

// Assign to expression--
x-- = 5; // Error

// Assign to++expression
++x = 4; // Error

// Assign to--expression
--x = 5; // Error

// Pre and postfix++ on number
x++;
x--;
++x;
--x;
++x++; // Error
--x--; // Error
++x--; // Error
--x++; // Error

// Pre and postfix++ on enum
e++;
e--;
++e;
--e;
++e++; // Error
--e--; // Error
++e--; // Error
--e++; // Error

// Pre and postfix++ on value of type 'any'
a++;
a--;
++a;
--a;
++a++; // Error
--a--; // Error
++a--; // Error
--a++; // Error


// Pre and postfix++ on other types
w++; // Error
w--; // Error
++w; // Error
--w; // Error
++w++; // Error
--w--; // Error
++w--; // Error
--w++; // Error


`,
      [],
    );
  });
  test("callChain.2", async () => {
    await expectPass(
      `
declare const o1: undefined | (() => number);
o1?.();

declare const o2: undefined | { b: () => number };
o2?.b();

declare const o3: { b: (() => { c: string }) | undefined };
o3.b?.().c;
`,
      [],
    );
  });
  test("callChain.3", async () => {
    await expectPass(
      `
declare function absorb<T>(): T;
declare const a: { m?<T>(obj: {x: T}): T } | undefined;
const n1: number = a?.m?.({x: 12 }); // should be an error (\`undefined\` is not assignable to \`number\`)
const n2: number = a?.m?.({x: absorb()}); // likewise
const n3: number | undefined = a?.m?.({x: 12}); // should be ok
const n4: number | undefined = a?.m?.({x: absorb()}); // likewise

// Also a test showing \`!\` vs \`?\` for good measure
let t1 = a?.m?.({x: 12});
t1 = a!.m!({x: 12});`,
      [],
    );
  });
  test("callChain", async () => {
    await expectPass(
      `
declare const o1: undefined | ((...args: any[]) => number);
o1?.();
o1?.(1);
o1?.(...[1, 2]);
o1?.(1, ...[2, 3], 4);

declare const o2: undefined | { b: (...args: any[]) => number };
o2?.b();
o2?.b(1);
o2?.b(...[1, 2]);
o2?.b(1, ...[2, 3], 4);
o2?.["b"]();
o2?.["b"](1);
o2?.["b"](...[1, 2]);
o2?.["b"](1, ...[2, 3], 4);

declare const o3: { b: ((...args: any[]) => { c: string }) | undefined };
o3.b?.().c;
o3.b?.(1).c;
o3.b?.(...[1, 2]).c;
o3.b?.(1, ...[2, 3], 4).c;
o3.b?.()["c"];
o3.b?.(1)["c"];
o3.b?.(...[1, 2])["c"];
o3.b?.(1, ...[2, 3], 4)["c"];
o3["b"]?.().c;
o3["b"]?.(1).c;
o3["b"]?.(...[1, 2]).c;
o3["b"]?.(1, ...[2, 3], 4).c;

declare const o4: undefined | (<T>(f: (a: T) => T) => T);
declare function incr(x: number): number;
const v: number | undefined = o4?.(incr);

// GH#33744
declare const o5: <T>() => undefined | (() => void);
o5<number>()?.();

// GH#36031
o2?.b()!.toString;
o2?.b()!.toString!;`,
      [],
    );
  });
  test("callChainInference", async () => {
    await expectPass(
      `
// Repro from #42404

interface Y {
    foo<T>(this: T, arg: keyof T): void;
    a: number;
    b: string;
}

declare const value: Y | undefined;

if (value) {
    value?.foo("a");
}

value?.foo("a");
`,
      [],
    );
  });
  test("callChainWithSuper", async () => {
    await expectPass(
      `
// GH#34952
class Base { method?() {} }
class Derived extends Base {
    method1() { return super.method?.(); }
    method2() { return super["method"]?.(); }
}`,
      [],
    );
  });
  test("parentheses", async () => {
    await expectPass(
      `
declare const o1: ((...args: any[]) => number);
declare const o2: { b: (...args: any[]) => number };
declare const o3: { b: ((...args: any[]) => (...args: any[]) => number) };
declare const o4: { b: ((...args: any[]) => { c: (...args: any[]) => number } ) };

(o1)(o1 ?? 1);
(o2?.b)(o1 ?? 1);
(o3?.b())(o1 ?? 1);
(o4?.b().c)(o1 ?? 1);`,
      [],
    );
  });
  test("superMethodCall", async () => {
    await expectPass(
      `class Base {
    method?() { }
}

class Derived extends Base {
    method() {
        return super.method?.();
    }

    async asyncMethod() {
        return super.method?.();
    }
}`,
      [],
    );
  });
  test("thisMethodCall", async () => {
    await expectPass(
      `class C {
    method?() {}
    other() {
        this.method?.();
    }
}`,
      [],
    );
  });
  test("deleteChain", async () => {
    await expectPass(
      `
declare const o1: undefined | { b: string };
delete o1?.b;
delete (o1?.b);

declare const o2: undefined | { b: { c: string } };
delete o2?.b.c;
delete (o2?.b.c);

declare const o3: { b: undefined | { c: string } };
delete o3.b?.c;
delete (o3.b?.c);

declare const o4: { b?: { c: { d?: { e: string } } } };
delete o4.b?.c.d?.e;
delete (o4.b?.c.d)?.e;
delete (o4.b?.c.d?.e);

declare const o5: { b?(): { c: { d?: { e: string } } } };
delete o5.b?.().c.d?.e;
delete (o5.b?.().c.d?.e);

declare const o6: { b?: { c: { d?: { e: string } } } };
delete o6.b?.['c'].d?.['e'];
delete (o6.b?.['c'].d?.['e']);`,
      [],
    );
  });
  test("elementAccessChain.2", async () => {
    await expectPass(
      `
declare const o1: undefined | { b: string };
o1?.["b"];

declare const o2: undefined | { b: { c: string } };
o2?.["b"].c;
o2?.b["c"];

declare const o3: { b: undefined | { c: string } };
o3["b"]?.c;
o3.b?.["c"];
`,
      [],
    );
  });
  test("elementAccessChain.3", async () => {
    await expectError(
      `
declare const obj: any;

obj?.["a"]++;
obj?.a["b"]++;
obj?.["a"]--;
obj?.a["b"]--;

++obj?.["a"];
++obj?.a["b"];
--obj?.["a"];
--obj?.a["b"];

obj?.["a"] = 1;
obj?.a["b"] = 1;
obj?.["a"] += 1;
obj?.a["b"] += 1;

for (obj?.["a"] in {});
for (obj?.a["b"] in {});
for (obj?.["a"] of []);
for (obj?.a["b"] of []);

({ a: obj?.["a"] } = { a: 1 });
({ a: obj?.a["b"] } = { a: 1 });
({ ...obj?.["a"] } = { a: 1 });
({ ...obj?.a["b"] } = { a: 1 });
[...obj?.["a"]] = [];
[...obj?.a["b"]] = [];
`,
      [],
    );
  });
  test("elementAccessChain", async () => {
    await expectPass(
      `
declare const o1: undefined | { b: string };
o1?.["b"];

declare const o2: undefined | { b: { c: string } };
o2?.["b"].c;
o2?.b["c"];

declare const o3: { b: undefined | { c: string } };
o3["b"]?.c;
o3.b?.["c"];

declare const o4: { b?: { c: { d?: { e: string } } } };
o4.b?.["c"].d?.e;
o4.b?.["c"].d?.["e"];

declare const o5: { b?(): { c: { d?: { e: string } } } };
o5.b?.()["c"].d?.e;
o5.b?.()["c"].d?.["e"];
o5["b"]?.()["c"].d?.e;
o5["b"]?.()["c"].d?.["e"];

// GH#33744
declare const o6: <T>() => undefined | ({ x: number });
o6<number>()?.["x"];

// GH#36031
o2?.["b"]!.c;
o2?.["b"]!["c"];
o2?.["b"]!.c!;
o2?.["b"]!["c"]!;`,
      [],
    );
  });
  test("optionalChainingInArrow", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/41814
const test = (names: string[]) =>
    // single-line comment
    names?.filter(x => x);
`,
      [],
    );
  });
  test("optionalChainingInference", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/34579
declare function unbox<T>(box: { value: T | undefined }): T;
declare const su: string | undefined;
declare const fnu: (() => number) | undefined;
declare const osu: { prop: string } | undefined;
declare const ofnu: { prop: () => number } | undefined;

const b1 = { value: su?.length };
const v1: number = unbox(b1);

const b2 = { value: su?.length as number | undefined };
const v2: number = unbox(b2);

const b3: { value: number | undefined } = { value: su?.length };
const v3: number = unbox(b3);

const b4 = { value: fnu?.() };
const v4: number = unbox(b4);

const b5 = { value: su?.["length"] };
const v5: number = unbox(b5);

const b6 = { value: osu?.prop.length };
const v6: number = unbox(b6);

const b7 = { value: osu?.prop["length"] };
const v7: number = unbox(b7);

const b8 = { value: ofnu?.prop() };
const v8: number = unbox(b8);

`,
      [],
    );
  });
  test("optionalChainingInLoop", async () => {
    await expectPass(
      `// https://github.com/microsoft/TypeScript/issues/40643
const list: any[] = []
for (const comp of list) {
    comp.sp.y = comp.sp.r.find((k: any) => k.c == (comp.xp ? '1' : '0'))
    for (const item of comp.c) {
        item.v = !!item.t?.length
    }
}`,
      [],
    );
  });
  test("optionalChainingInParameterBindingPattern.2", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): { d: string } | undefined => undefined;
(({ [a()?.d]: c = "" }) => { var a; })();

const x = "";
(({ [a()?.d]: c }, d = x) => { var x; })();`,
      [],
    );
  });
  test("optionalChainingInParameterBindingPattern", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): { d: string } | undefined => undefined;
(({ [a()?.d]: c = "" }) => {})();`,
      [],
    );
  });
  test("optionalChainingInParameterInitializer.2", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): { d: string } | undefined => undefined;
((b = a()?.d) => { var a; })();

const x = "";
((b = a()?.d, d = x) => { var x; })();`,
      [],
    );
  });
  test("optionalChainingInParameterInitializer", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/36295
const a = (): { d: string } | undefined => undefined;
((b = a()?.d) => {})();`,
      [],
    );
  });
  test("optionalChainingInTypeAssertions", async () => {
    await expectPass(
      `
class Foo {
    m() {}
}

const foo = new Foo();

(foo.m as any)?.();
(<any>foo.m)?.();

/*a1*/(/*a2*/foo.m as any/*a3*/)/*a4*/?.();
/*b1*/(/*b2*/<any>foo.m/*b3*/)/*b4*/?.();

// https://github.com/microsoft/TypeScript/issues/50148
(foo?.m as any).length;
(<any>foo?.m).length;
(foo?.["m"] as any).length;
(<any>foo?.["m"]).length;`,
      [],
    );
  });
  test("privateIdentifierChain.1", async () => {
    await expectPass(
      `
class A {
    a?: A
    #b?: A;
    getA(): A {
        return new A();
    }
    constructor() {
        this?.#b;           // Error
        this?.a.#b;         // Error
        this?.getA().#b;    // Error
    }
}`,
      [],
    );
  });
  test("propertyAccessChain.2", async () => {
    await expectPass(
      `
declare const o1: undefined | { b: string };
o1?.b;

declare const o2: undefined | { b: { c: string } };
o2?.b.c;

declare const o3: { b: undefined | { c: string } };
o3.b?.c;
`,
      [],
    );
  });
  test("propertyAccessChain.3", async () => {
    await expectError(
      `
declare const obj: any;

obj?.a++;
obj?.a.b++;
obj?.a--;
obj?.a.b--;

++obj?.a;
++obj?.a.b;
--obj?.a;
--obj?.a.b;

obj?.a = 1;
obj?.a.b = 1;
obj?.a += 1;
obj?.a.b += 1;

for (obj?.a in {});
for (obj?.a.b in {});
for (obj?.a of []);
for (obj?.a.b of []);

({ a: obj?.a } = { a: 1 });
({ a: obj?.a.b } = { a: 1 });
({ ...obj?.a } = { a: 1 });
({ ...obj?.a.b } = { a: 1 });
[...obj?.a] = [];
[...obj?.a.b] = [];
`,
      [],
    );
  });
  test("propertyAccessChain", async () => {
    await expectPass(
      `
declare const o1: undefined | { b: string };
o1?.b;

declare const o2: undefined | { b: { c: string } };
o2?.b.c;

declare const o3: { b: undefined | { c: string } };
o3.b?.c;

declare const o4: { b?: { c: { d?: { e: string } } } };
o4.b?.c.d?.e;

declare const o5: { b?(): { c: { d?: { e: string } } } };
o5.b?.().c.d?.e;

// GH#33744
declare const o6: <T>() => undefined | ({ x: number });
o6<number>()?.x;

// GH#34109
o1?.b ? 1 : 0;

// GH#36031
o2?.b!.c;
o2?.b!.c!;`,
      [],
    );
  });
  test("taggedTemplateChain", async () => {
    await expectError(
      `declare let a: any;
a?.\`b\`;

a?.\`b\${1}c\`;`,
      [],
    );
  });
  test("propertyAccess", async () => {
    await expectPass(
      `class A {
    a!: number;
}
class B extends A {
    b!: number;
}
enum Compass {
    North, South, East, West
}

var numIndex: { [n: number]: string } = { 3: 'three', 'three': 'three' };
var strIndex: { [n: string]: Compass } = { 'N': Compass.North, 'E': Compass.East };
declare var bothIndex:
    {
        [n: string]: A;
        [m: number]: B;
    };

function noIndex() { }

var obj = {
    10: 'ten',
    x: 'hello',
    y: 32,
    z: { n: 'world', m: 15, o: () => false },
    'literal property': 100
};
var anyVar: any = {};
declare var stringOrNumber: string | number;
declare var someObject: { name: string };

// Assign to a property access
obj.y = 4;

// Property access on value of type 'any'
anyVar.x = anyVar.y = obj.x = anyVar.z;

// Dotted property access of property that exists
var aa = obj.x;

// Dotted property access of property that exists on value's apparent type
var bb = obj.hasOwnProperty;

// Dotted property access of property that doesn't exist on value's apparent type
var cc = obj.qqq; // error

// Bracket notation property access using string literal value on type with property of that literal name
var dd = obj['literal property'];
var dd: number;

// Bracket notation property access using string literal value on type without property of that literal name
var ee = obj['wa wa wa wa wa'];
var ee: any;

// Bracket notation property access using numeric string literal value on type with property of that literal name
var ff = obj['10'];
var ff: string;

// Bracket notation property access using numeric string literal value on type without property of that literal name
var gg = obj['1'];
var gg: any;

// Bracket notation property access using numeric value on type with numeric index signature
var hh = numIndex[3.0];
var hh: string;

// Bracket notation property access using enum value on type with numeric index signature
var ii = numIndex[Compass.South];
var ii: string;

// Bracket notation property access using value of type 'any' on type with numeric index signature
var jj = numIndex[anyVar];
var jj: string;

// Bracket notation property access using string value on type with numeric index signature
var kk = numIndex['what'];
var kk: any;

// Bracket notation property access using value of other type on type with numeric index signature and no string index signature
var ll = numIndex[someObject]; // Error

// Bracket notation property access using string value on type with string index signature and no numeric index signature
var mm = strIndex['N'];
var mm: Compass;
var mm2 = strIndex['zzz'];
var mm2: Compass;

// Bracket notation property access using numeric value on type with string index signature and no numeric index signature
var nn = strIndex[10];
var nn: Compass;

// Bracket notation property access using enum value on type with string index signature and no numeric index signature
var oo = strIndex[Compass.East];
var oo: Compass;

// Bracket notation property access using value of type 'any' on type with string index signature and no numeric index signature
var pp = strIndex[<any>null];
var pp: Compass;

// Bracket notation property access using numeric value on type with no index signatures
var qq = noIndex[123];
var qq: any;

// Bracket notation property access using string value on type with no index signatures
var rr = noIndex['zzzz'];
var rr: any;

// Bracket notation property access using enum value on type with no index signatures
var ss = noIndex[Compass.South];
var ss: any;

// Bracket notation property access using value of type 'any' on type with no index signatures
var tt = noIndex[<any>null];
var tt: any;

// Bracket notation property access using values of other types on type with no index signatures
var uu = noIndex[someObject]; // Error

// Bracket notation property access using numeric value on type with numeric index signature and string index signature
var vv = noIndex[32];
var vv: any;

// Bracket notation property access using enum value on type with numeric index signature and string index signature
var ww = bothIndex[Compass.East];
var ww: B;

// Bracket notation property access using value of type 'any' on type with numeric index signature and string index signature
var xx = bothIndex[<any>null];
var xx: B;

// Bracket notation property access using string value on type with numeric index signature and string index signature
var yy = bothIndex['foo'];
var yy: A;

// Bracket notation property access using numeric string value on type with numeric index signature and string index signature
var zz = bothIndex['1.0'];
var zz: A;

// Bracket notation property access using value of other type on type with numeric index signature and no string index signature and string index signature
var zzzz = bothIndex[someObject]; // Error

var x1 = numIndex[stringOrNumber];
var x1: any;

var x2 = strIndex[stringOrNumber];
var x2: Compass;

var x3 = bothIndex[stringOrNumber];
var x3: A;
`,
      [],
    );
  });
  test("propertyAccessNumericLiterals", async () => {
    await expectError(
      `0xffffffff.toString();
0o01234.toString();
0b01101101.toString();
1234..toString();
1e0.toString();
000.toString();
08.8e5.toString();
0_8.8e5.toString();
8.8e5.toString();
088e4.toString();
88_e4.toString();
88e4.toString();
8_8e4.toString();`,
      [],
    );
  });
  test("propertyAccessStringIndexSignature", async () => {
    await expectPass(
      `interface Flags { [name: string]: boolean };
declare let flags: Flags;
flags.b;
flags.f;
flags.isNotNecessarilyNeverFalse;
flags['this is fine'];

interface Empty { }
declare let empty: Empty;
empty.nope;
empty["that's ok"];`,
      [],
    );
  });
  test("propertyAccessWidening", async () => {
    await expectPass(
      `
// Repro from #31762

function g1(headerNames: any) {
    let t = [{ hasLineBreak: false, cells: [] }];
    const table = [{cells: headerNames }].concat(t);
}

function g2(headerNames: any) {
    let t = [{ hasLineBreak: false, cells: [] }];
    const table = [{cells: headerNames }]["concat"](t);
}

// Object in property or element access is widened when target of assignment

function foo(options?: { a: string, b: number }) {
    let x1 = (options || {}).a;     // Object type not widened
    let x2 = (options || {})["a"];  // Object type not widened
    (options || {}).a = 1;          // Object type widened, error
    (options || {})["a"] = 1;       // Object type widened, error
}
`,
      [],
    );
  });
  test("errorSuperCalls", async () => {
    await expectError(
      `//super call in class constructor with no base type
class NoBase {
    constructor() {
        super();
    }

    //super call in class member function with no base type
    fn() {
        super();
    }

    //super call in class accessor (get and set) with no base type
    get foo() {
        super();
        return null;
    }
    set foo(v) {
        super();
    }

    //super call in class member initializer with no base type
    p = super();

    //super call in static class member function with no base type
    static fn() {
        super();
    }

    //super call in static class member initializer with no base type
    static k = super();

    //super call in static class accessor (get and set) with no base type
    static get q() {
        super();
        return null;
    }
    static set q(n) {
        super();
    }
}

class Base<T> { private n: T; }
class Derived<T> extends Base<T> {
    //super call with type arguments 
    constructor() {
        super<string>();
        super();
    }
}


class OtherBase {
    private n: string;
}

class OtherDerived extends OtherBase {
    //super call in class member initializer of derived type
    t = super();

    fn() {
        //super call in class member function of derived type
        super();
    }

    //super call in class accessor (get and set) of derived type
    get foo() {
        super();
        return null;
    }
    set foo(n) {
        super();
    }
}
`,
      [],
    );
  });
  test("superCalls", async () => {
    await expectPass(
      `class Base {
    x = 43;
    constructor(n: string) {

    }
}

function v(): void { }

class Derived extends Base {
    //super call in class constructor of derived type
    constructor(public q: number) {
        super('');
        //type of super call expression is void
        var p = super('');
        var p = v();
    }
}

class OtherBase {

}

class OtherDerived extends OtherBase {
    constructor() {
        var p = '';
        super();
    }
}
`,
      [],
    );
  });
  test("errorSuperPropertyAccess", async () => {
    await expectError(
      `//super property access in constructor of class with no base type
//super property access in instance member function of class with no base type
//super property access in instance member accessor(get and set) of class with no base type
class NoBase {
    constructor() {
        var a = super.prototype;
        var b = super.hasOwnProperty('');
    }

    fn() {
        var a = super.prototype;
        var b = super.hasOwnProperty('');
    }

    m = super.prototype;
    n = super.hasOwnProperty('');

    //super static property access in static member function of class with no base type
    //super static property access in static member accessor(get and set) of class with no base type
    public static static1() {
        super.hasOwnProperty('');
    }

    public static get static2() {
        super.hasOwnProperty('');
        return '';
    }

    public static set static2(n) {
        super.hasOwnProperty('');
    }
}

class SomeBase {
    private privateFunc() { }
    private privateMember = 0;

    public publicFunc() { }
    public publicMember = 0;

    private static privateStaticFunc() { }
    private static privateStaticMember = 0;

    public static publicStaticFunc() { }
    public static publicStaticMember = 0;

}


//super.publicInstanceMemberNotFunction in constructor of derived class
//super.publicInstanceMemberNotFunction in instance member function of derived class
//super.publicInstanceMemberNotFunction in instance member accessor(get and set) of derived class
//super property access only available with typed this
class SomeDerived1 extends SomeBase {
    constructor() {
        super();
        super.publicMember = 1;
    }

    fn() {
        var x = super.publicMember;
    }

    get a() {
        var x = super.publicMember;
        return undefined;
    }
    set a(n) {
        n = super.publicMember;
    }
    fn2() {
        function inner() {
            super.publicFunc();
        }
        var x = {
            test: function () { return super.publicFunc(); }
        }
    }
}

//super.privateProperty in constructor of derived class
//super.privateProperty in instance member function of derived class
//super.privateProperty in instance member accessor(get and set) of derived class
class SomeDerived2 extends SomeBase {
    constructor() {
        super();
        super.privateMember = 1;
    }

    fn() {
        var x = super.privateMember;
    }

    get a() {
        var x = super.privateMember;
        return undefined;
    }
    set a(n) {
        n = super.privateMember;
    }
}

//super.publicStaticMemberNotFunction in static member function of derived class
//super.publicStaticMemberNotFunction in static member accessor(get and set) of derived class
//super.privateStaticProperty in static member function of derived class
//super.privateStaticProperty in static member accessor(get and set) of derived class
class SomeDerived3 extends SomeBase {
    static fn() {
        super.publicStaticMember = 3;
        super.privateStaticMember = 3;
        super.privateStaticFunc();
    }
    static get a() {
        super.publicStaticMember = 3;
        super.privateStaticMember = 3;
        super.privateStaticFunc();
        return '';
    }
    static set a(n) {
        super.publicStaticMember = 3;
        super.privateStaticMember = 3;
        super.privateStaticFunc();
    }
}

// In object literal
var obj = { n: super.wat, p: super.foo() };
`,
      [],
    );
  });
  test("superPropertyAccessNoError", async () => {
    await expectPass(
      `//super.publicInstanceMemberFunction in constructor of derived class
//super.publicInstanceMemberFunction in instance member function of derived class
//super.publicInstanceMemberFunction in instance member accessor(get and set) of derived class
//super.publicInstanceMemberFunction in lambda in member function
//super.publicStaticMemberFunction in static member function of derived class
//super.publicStaticMemberFunction in static member accessor(get and set) of derived class


class SomeBaseClass {
    public func() {
        return '';
    }

    static func() {
        return 3;
    }

    returnThis() {
        return this;
    }
}

class SomeDerivedClass extends SomeBaseClass {
    constructor() {
        super();
        var x = super.func();
        var x: string;
    }

    fn() {
        var x = super.func();
        var x: string;
        var y = () => super.func();
    }

    get a() {
        var x = super.func();
        var x: string;
        return null;
    }

    set a(n) {
        var x = super.func();
        var x: string;
    }

    static fn() {
        var x = super.func();
        var x: number;
    }

    static get a() {
        var x = super.func();
        var x: number;
        return null;
    }

    static set a(n) {
        var x = super.func();
        var x: number;
    }

    returnThis() {
        return super.returnThis();
    }
}

let instance = new SomeDerivedClass();
instance.returnThis().fn();
`,
      [],
    );
  });
  test("superSymbolIndexedAccess1", async () => {
    await expectPass(
      `var symbol = Symbol.for('myThing');

class Foo {
    [symbol]() {
        return 0;
    }
}

class Bar extends Foo {
    [symbol]() {
        return super[symbol]();
    }
}`,
      [],
    );
  });
  test("superSymbolIndexedAccess2", async () => {
    await expectPass(
      `
class Foo {
    [Symbol.isConcatSpreadable]() {
        return 0;
    }
}

class Bar extends Foo {
    [Symbol.isConcatSpreadable]() {
        return super[Symbol.isConcatSpreadable]();
    }
}`,
      [],
    );
  });
  test("superSymbolIndexedAccess3", async () => {
    await expectPass(
      `var symbol = Symbol.for('myThing');

class Foo {
    [symbol]() {
        return 0;
    }
}

class Bar extends Foo {
    [symbol]() {
        return super[Bar]();
    }
}`,
      [],
    );
  });
  test("superSymbolIndexedAccess4", async () => {
    await expectPass(
      `var symbol = Symbol.for('myThing');

class Bar {
    [symbol]() {
        return super[symbol]();
    }
}`,
      [],
    );
  });
  test("superSymbolIndexedAccess5", async () => {
    await expectPass(
      `var symbol: any;

class Foo {
    [symbol]() {
        return 0;
    }
}

class Bar extends Foo {
    [symbol]() {
        return super[symbol]();
    }
}`,
      [],
    );
  });
  test("superSymbolIndexedAccess6", async () => {
    await expectPass(
      `var symbol: any;

class Foo {
    static [symbol]() {
        return 0;
    }
}

class Bar extends Foo {
    static [symbol]() {
        return super[symbol]();
    }
}`,
      [],
    );
  });
  test("thisInInvalidContexts", async () => {
    await expectPass(
      `class BaseErrClass {
    constructor(t: any) { }
}

class ClassWithNoInitializer extends BaseErrClass {
    t;
    //'this' in optional super call
    constructor() {
        super(this); // Error
    }
}

class ClassWithInitializer extends BaseErrClass {
    t = 4;
    //'this' in required super call
    constructor() {
        super(this); // Error
    }
}

namespace M {
    //'this' in module variable
    var x = this; // Error
}

//'this' as type parameter constraint
// function fn<T extends this >() { } // Error

//'this' as a type argument
function genericFunc<T>(x: T) { }
genericFunc<this>(undefined);  // Should be an error

class ErrClass3 extends this {

}

//'this' as a computed enum value
enum SomeEnum {
    A = this, // Should not be allowed
    B = this.spaaaace // Also should not be allowed
}

`,
      [],
    );
  });
  test("thisInInvalidContextsExternalModule", async () => {
    await expectPass(
      `class BaseErrClass {
    constructor(t: any) { }
}

class ClassWithNoInitializer extends BaseErrClass {
    t;
    //'this' in optional super call
    constructor() {
        super(this); // error: "super" has to be called before "this" accessing
    }
}

class ClassWithInitializer extends BaseErrClass {
    t = 4;
    //'this' in required super call
    constructor() {
        super(this); // Error
    }
}

namespace M {
    //'this' in module variable
    var x = this; // Error
}

//'this' as type parameter constraint
// function fn<T extends this >() { } // Error

//'this' as a type argument
function genericFunc<T>(x: T) { }
genericFunc<this>(undefined);  // Should be an error

class ErrClass3 extends this {

}

//'this' as a computed enum value
enum SomeEnum {
    A = this, // Should not be allowed
    B = this.spaaaace // Also should not be allowed
}

export = this; // Should be an error`,
      [],
    );
  });
  test("thisInObjectLiterals", async () => {
    await expectPass(
      `
class MyClass {
    t: number;

    fn() {
        type ContainingThis = this;
        //type of 'this' in an object literal is the containing scope's this
        var t = { x: this, y: this.t };
        var t: { x: ContainingThis; y: number };
    }
}

//type of 'this' in an object literal method is the type of the object literal
var obj = {
    f() {
        return this.spaaace;
    }
};
var obj: { f: () => any; };
`,
      [],
    );
  });
  test("typeOfThisGeneral", async () => {
    await expectPass(
      `class MyTestClass {
    private canary: number;
    static staticCanary: number;

    constructor() {
        //type of 'this' in constructor body is the class instance type
        var p = this.canary;
        var p!: number;
        this.canary = 3;
    }

    //type of 'this' in member function param list is the class instance type
    memberFunc(t = this) {
        var t!: MyTestClass;

        //type of 'this' in member function body is the class instance type
        var p = this;
        var p!: MyTestClass;
    }

    //type of 'this' in member accessor(get and set) body is the class instance type
    get prop() {
        var p = this;
        var p!: MyTestClass;
        return this;
    }
    set prop(v) {
        var p = this;
        var p!: MyTestClass;
        p = v;
        v = p;
    }

    someFunc = () => {
        //type of 'this' in member variable initializer is the class instance type
        var t = this;
        var t!: MyTestClass;
    };

    //type of 'this' in static function param list is constructor function type
    static staticFn(t = this) {
        var t!: typeof MyTestClass;
        var t = MyTestClass;
        t.staticCanary;

        //type of 'this' in static function body is constructor function type
        var p = this;
        var p!: typeof MyTestClass;
        var p = MyTestClass;
        p.staticCanary;
    }

    static get staticProp() {
        //type of 'this' in static accessor body is constructor function type
        var p = this;
        var p!: typeof MyTestClass;
        var p = MyTestClass;
        p.staticCanary;
        return this;
    }
    static set staticProp(v: typeof MyTestClass) {
        //type of 'this' in static accessor body is constructor function type
        var p = this;
        var p!: typeof MyTestClass;
        var p = MyTestClass;
        p.staticCanary;
    }
}

class MyGenericTestClass<T, U> {
    private canary: number;
    static staticCanary: number;

    constructor() {
        //type of 'this' in constructor body is the class instance type
        var p = this.canary;
        var p!: number;
        this.canary = 3;
    }

    //type of 'this' in member function param list is the class instance type
    memberFunc(t = this) {
        var t!: MyGenericTestClass<T, U>;

        //type of 'this' in member function body is the class instance type
        var p = this;
        var p!: MyGenericTestClass<T, U>;
    }

    //type of 'this' in member accessor(get and set) body is the class instance type
    get prop() {
        var p = this;
        var p!: MyGenericTestClass<T, U>;
        return this;
    }
    set prop(v) {
        var p = this;
        var p!: MyGenericTestClass<T, U>;
        p = v;
        v = p;
    }

    someFunc = () => {
        //type of 'this' in member variable initializer is the class instance type
        var t = this;
        var t!: MyGenericTestClass<T, U>;
    };

    //type of 'this' in static function param list is constructor function type
    static staticFn(t = this) {
        var t!: typeof MyGenericTestClass;
        var t = MyGenericTestClass;
        t.staticCanary;

        //type of 'this' in static function body is constructor function type
        var p = this;
        var p!: typeof MyGenericTestClass;
        var p = MyGenericTestClass;
        p.staticCanary;
    }

    static get staticProp() {
        //type of 'this' in static accessor body is constructor function type
        var p = this;
        var p!: typeof MyGenericTestClass;
        var p = MyGenericTestClass;
        p.staticCanary;
        return this;
    }
    static set staticProp(v: typeof MyGenericTestClass) {
        //type of 'this' in static accessor body is constructor function type
        var p = this;
        var p!: typeof MyGenericTestClass;
        var p = MyGenericTestClass;
        p.staticCanary;
    }
}

//type of 'this' in a function declaration param list is Any
function fn(s = this) {
    var s!: any;
    s.spaaaaaaace = 4;

    //type of 'this' in a function declaration body is Any
    var t!: any;
    var t = this;
    this.spaaaaace = 4;
}

//type of 'this' in a function expression param list list is Any
var q1 = function (s = this) {
    var s!: any;
    s.spaaaaaaace = 4;

    //type of 'this' in a function expression body is Any
    var t!: any;
    var t = this;
    this.spaaaaace = 4;
}

//type of 'this' in a fat arrow expression param list is typeof globalThis
var q2 = (s = this) => {
    var s!: typeof globalThis;
    s.spaaaaaaace = 4;

    //type of 'this' in a fat arrow expression body is typeof globalThis
    var t!: typeof globalThis;
    var t = this;
    this.spaaaaace = 4;
}

//type of 'this' in global namespace is GlobalThis
var t!: typeof globalThis;
var t = this;
this.spaaaaace = 4;

`,
      [],
    );
  });
  test("typeOfThisInConstructorParamList", async () => {
    await expectPass(
      `//type of 'this' in constructor param list is the class instance type (error)
class ErrClass {
    // Should be an error
    constructor(f = this) { }
}
`,
      [],
    );
  });
  test("constAssertions", async () => {
    await expectPass(
      `
let v1 = 'abc' as const;
let v2 = \`abc\` as const;
let v3 = 10 as const;
let v4 = -10 as const;
let v5 = +10 as const;
let v6 = 10n as const;
let v7 = -10n as const;
let v8 = true as const;
let v9 = false as const;

let c1 = 'abc' as const;
let c2 = \`abc\` as const;
let c3 = 10 as const;
let c4 = -10 as const;
let c5 = +10 as const;
let c6 = 10n as const;
let c7 = -10n as const;
let c8 = true as const;
let c9 = false as const;

let vv1 = v1;
let vc1 = c1;

let a1 = [] as const;
let a2 = [1, 2, 3] as const;
let a3 = [10, 'hello', true] as const;
let a4 = [...[1, 2, 3]] as const;
let a5 = [1, 2, 3];
let a6 = [...a5] as const;
let a7 = [...a6];
let a8 = ['abc', ...a7] as const;
let a9 = [...a8];

declare let d: { [x: string]: string };

let o1 = { x: 10, y: 20 } as const;
let o2 = { a: 1, 'b': 2, ['c']: 3, d() {}, ['e' + '']: 4 } as const;
let o3 = { ...o1, ...o2 } as const;
let o4 = { a: 1, b: 2 };
let o5 = { ...o4 } as const;
let o6 = { ...o5 };
let o7 = { ...d } as const;
let o8 = { ...o7 };
let o9 = { x: 10, foo() { this.x = 20 } } as const;  // Error

let p1 = (10) as const;
let p2 = ((-10)) as const;
let p3 = ([(10)]) as const;
let p4 = [[[[10]]]] as const;

let x1 = { x: 10, y: [20, 30], z: { a: { b: 42 } } } as const;

let q1 = <const> 10;
let q2 = <const> 'abc';
let q3 = <const> true;
let q4 = <const> [1, 2, 3];
let q5 = <const> { x: 10, y: 20 };

declare function id<T>(x: T): T;

let e1 = v1 as const;  // Error
let e2 = (true ? 1 : 0) as const;  // Error
let e3 = id(1) as const;  // Error

let t1 = 'foo' as const;
let t2 = 'bar' as const;
let t3 = \`\${t1}-\${t2}\` as const;
let t4 = \`\${\`(\${t1})\`}-\${\`(\${t2})\`}\` as const;

function ff1(x: 'foo' | 'bar', y: 1 | 2) {
    return \`\${x}-\${y}\` as const;
}

function ff2<T extends string, U extends string>(x: T, y: U) {
    return \`\${x}-\${y}\` as const;
}

const ts1 = ff2('foo', 'bar');
const ts2 = ff2('foo', !!true ? '0' : '1');
const ts3 = ff2(!!true ? 'top' : 'bottom', !!true ? 'left' : 'right');

function ff3(x: 'foo' | 'bar', y: object) {
    return \`\${x}\${y}\` as const;
}

type Action = "verify" | "write";
type ContentMatch = "match" | "nonMatch";
type Outcome = \`\${Action}_\${ContentMatch}\`;

function ff4(verify: boolean, contentMatches: boolean) {
    const action : Action = verify ? \`verify\` : \`write\`;
    const contentMatch: ContentMatch = contentMatches ? \`match\` : \`nonMatch\`;
    const outcome: Outcome = \`\${action}_\${contentMatch}\` as const;
    return outcome;
}

function ff5(verify: boolean, contentMatches: boolean) {
    const action = verify ? \`verify\` : \`write\`;
    const contentMatch = contentMatches ? \`match\` : \`nonMatch\`;
    const outcome = \`\${action}_\${contentMatch}\` as const;
    return outcome;
}

function accessorNames<S extends string>(propName: S) {
    return [\`get-\${propName}\`, \`set-\${propName}\`] as const;
}

const ns1 = accessorNames('foo');

// repro from https://github.com/microsoft/TypeScript/issues/54374
interface Foo54374 {
  a: 1;
  b: 2;
}

const fooConst54374: Foo54374 = {
  a: 1,
  b: 3
} as const
`,
      [],
    );
  });
  test("duplicatePropertiesInTypeAssertions01", async () => {
    await expectPass(
      `
let x = <{a: number; a: number}>{};`,
      [],
    );
  });
  test("duplicatePropertiesInTypeAssertions02", async () => {
    await expectPass(
      `
let x = {} as {a: number; a: number};`,
      [],
    );
  });
  test("typeAssertions", async () => {
    await expectError(
      `// Function call whose argument is a 1 arg generic function call with explicit type arguments
function fn1<T>(t: T) { }
function fn2(t: any) { }

fn1(fn2<string>(4)); // Error

declare var a: any;
declare var s: string;

// Type assertion of non - unary expression
var a = <any>"" + 4;
var s = "" + <any>4;

class SomeBase {
    private p;
}
class SomeDerived extends SomeBase {
    private x;
}
class SomeOther {
    private q;
}

// Type assertion should check for assignability in either direction
var someBase = new SomeBase();
var someDerived = new SomeDerived();
var someOther = new SomeOther();

someBase = <SomeBase>someDerived;
someBase = <SomeBase>someBase;
someBase = <SomeBase>someOther; // Error

someDerived = <SomeDerived>someDerived;
someDerived = <SomeDerived>someBase;
someDerived = <SomeDerived>someOther; // Error

someOther = <SomeOther>someDerived; // Error
someOther = <SomeOther>someBase; // Error
someOther = <SomeOther>someOther;

// Type assertion cannot be a type-predicate type
declare var numOrStr: number | string;
declare var str: string;
if(<numOrStr is string>(numOrStr === undefined)) { // Error
	str = numOrStr; // Error, no narrowing occurred
}

if((numOrStr === undefined) as numOrStr is string) { // Error
}

`,
      [],
    );
  });
  test("nullOrUndefinedTypeGuardIsOrderIndependent", async () => {
    await expectPass(
      `function test(strOrNull: string | null, strOrUndefined: string | undefined) {
    var str: string = "original";
    var nil: null;
    if (null === strOrNull) {
        nil = strOrNull;
    }
    else {
        str = strOrNull;
    }
    if (undefined !== strOrUndefined) {
        str = strOrUndefined;
    }
}`,
      [],
    );
  });
  test("typeGuardEnums", async () => {
    await expectPass(
      `enum E {}
enum V {}

let x: number|string|E|V;

if (typeof x === "number") {
    x; // number|E|V
}
else {
    x; // string
}

if (typeof x !== "number") {
    x; // string
}
else {
    x; // number|E|V
}
`,
      [],
    );
  });
  test("typeGuardFunction", async () => {
    await expectError(
      `
class A {
    propA: number;
}

class B {
    propB: number;
}

class C extends A {
    propC: number;
}

declare function isA(p1: any): p1 is A;
declare function isB(p1: any): p1 is B;
declare function isC(p1: any): p1 is C;

declare function retC(): C;

var a: A;
var b: B;

// Basic
if (isC(a)) {
    a.propC;
}

// Sub type
var subType: C;
if(isA(subType)) {
    subType.propC;
}

// Union type
var union: A | B;
if(isA(union)) {
    union.propA;
}

// Call signature
interface I1 {
    (p1: A): p1 is C;
}

// The parameter index and argument index for the type guard target is matching.
// The type predicate type is assignable to the parameter type.
declare function isC_multipleParams(p1, p2): p1 is C;
if (isC_multipleParams(a, 0)) {
    a.propC;
}

// Methods
var obj: {
    func1(p1: A): p1 is C;
}
class D {
    method1(p1: A): p1 is C {
        return true;
    }
}

// Arrow function
let f1 = (p1: A): p1 is C => false;

// Function type
declare function f2(p1: (p1: A) => p1 is C);

// Function expressions
f2(function(p1: A): p1 is C {
    return true;
});

// Evaluations are asssignable to boolean.
declare function acceptingBoolean(a: boolean);
acceptingBoolean(isA(a));

// Type predicates with different parameter name.
declare function acceptingTypeGuardFunction(p1: (item) => item is A);
acceptingTypeGuardFunction(isA);

// Binary expressions
let union2: C | B;
let union3: boolean | B = isA(union2) || union2;`,
      [],
    );
  });
  test("typeGuardFunctionErrors", async () => {
    await expectError(
      `
class A {
    propA: number;
}

class B {
    propB: number;
}

class C extends A {
    propC: number;
}

function hasANonBooleanReturnStatement(x): x is A {
    return '';
}

function hasTypeGuardTypeInsideTypeGuardType(x): x is x is A {
    return true;
}

function hasMissingIsKeyword(): x {
    return true;
}

function hasMissingParameter(): x is A {
    return true;
}

function hasMissingTypeInTypeGuardType(x): x is {
    return true;
}

function hasNonMatchingParameter(y): x is A {
    return true;
}

function hasNonMatchingParameterType1(x: A): x is B {
    return true;
}

function hasNonMatchingParameterType2(x: string): x is number {
    return true;
}

function hasNonMathcingGenericType<T>(a: string): a is T[] {
    return true;
}

let a: A;
let b: B;

declare function isB(p1): p1 is B;
declare function isC(p1): p1 is C;
declare function funA(p1: any, p2: any): p1 is B;
declare function hasNoTypeGuard(x);

// Passed argument is not the same as the one being guarded.
if (isB(b)) {
    a.propB;
}

// Parameter index and argument index for the type guard target is not matching.
if (funA(0, a)) {
    a.propB; // Error
}

// No type guard in if statement
if (hasNoTypeGuard(a)) {
    a.propB;
}

// Type predicate type is not assignable
declare function acceptingDifferentSignatureTypeGuardFunction(p1: (p1) => p1 is B);
acceptingDifferentSignatureTypeGuardFunction(isC);

// Boolean not assignable to type guard
var assign1: (p1, p2) => p1 is A;
assign1 = function(p1, p2): boolean {
    return true;
};

// Must have matching parameter index
var assign2: (p1, p2) => p1 is A;
assign2 = function(p1, p2): p2 is A {
    return true;
};

// No matching signature
var assign3: (p1, p2) => p1 is A;
assign3 = function(p1, p2, p3): p1 is A {
    return true;
};

// Type predicates in non-return type positions
var b1: b is A;
function b2(a: b is A) {};
function b3(): A | b is A {
    return true;
};

// Non-compatiable type predicate positions for signature declarations
class D {
    constructor(p1: A): p1 is C {
        return true;
    }
    get m1(p1: A): p1 is C {
        return true;
    }
    set m2(p1: A): p1 is C {
        return true;
    }
}

interface I1 {
    new (p1: A): p1 is C;
}

interface I2 {
    [index: number]: p1 is C;
}

// Reference to rest parameter
function b4(...a): a is A {
    return true;
}

// Reference to binding pattern
function b5({a, b, p1}, p2, p3): p1 is A {
    return true;
}

function b6([a, b, p1], p2, p3): p1 is A {
    return true;
}

function b7({a, b, c: {p1}}, p2, p3): p1 is A {
    return true;
}

// Should not crash the compiler
var x: A;
if (hasMissingParameter()) {
    x.propA;
}

// repro #17297

type Keys = 'a'|'b'|'c'
type KeySet<T extends Keys> = { [k in T]: true }

// expected an error, since Keys doesn't have a 'd'
declare function hasKey<T extends Keys>(x: KeySet<T>): x is KeySet<T|'d'>;

type Foo = { 'a': string; }
type Bar = { 'a': number; }

interface NeedsFoo<T extends Foo> {
    foo: T;
    isFoo(): this is NeedsFoo<Bar>; // should error
};

declare var anError: NeedsFoo<Bar>; // error, as expected
declare var alsoAnError: NeedsFoo<number>; // also error, as expected
declare function newError1(x: any): x is NeedsFoo<Bar>; // should error
declare function newError2(x: any): x is NeedsFoo<number>; // should error
declare function newError3(x: number): x is NeedsFoo<number>; // should error`,
      [],
    );
  });
  test("typeGuardFunctionGenerics", async () => {
    await expectError(
      `
class A {
    propA: number;
}

class B {
    propB: number;
}

class C extends A {
    propC: number;
}

declare function isB(p1): p1 is B;
declare function isC(p1): p1 is C;
declare function retC(x): C; 

declare function funA<T>(p1: (p1) => T): T;
declare function funB<T>(p1: (p1) => T, p2: any): p2 is T;
declare function funC<T>(p1: (p1) => p1 is T): T;
declare function funD<T>(p1: (p1) => p1 is T, p2: any): p2 is T;
declare function funE<T, U>(p1: (p1) => p1 is T, p2: U): T;

let a: A;
let test1: boolean = funA(isB);
if (funB(retC, a)) {
    a.propC;
}
let test2: B = funC(isB);
if (funD(isC, a)) {
    a.propC;
}
let test3: B = funE(isB, 1);`,
      [],
    );
  });
  test("typeGuardFunctionOfFormThis", async () => {
    await expectPass(
      `class RoyalGuard {
    isLeader(): this is LeadGuard {
        return this instanceof LeadGuard;
    }
    isFollower(): this is FollowerGuard {
        return this instanceof FollowerGuard;
    }
}

class LeadGuard extends RoyalGuard {
    lead(): void {};
}

class FollowerGuard extends RoyalGuard {
    follow(): void {};
}

let a: RoyalGuard = new FollowerGuard();
if (a.isLeader()) {
    a.lead();
}
else if (a.isFollower()) {
    a.follow();
}

interface GuardInterface extends RoyalGuard {}

let b: GuardInterface;
if (b.isLeader()) {
    b.lead();
}
else if (b.isFollower()) {
    b.follow();
}

// if (((a.isLeader)())) {
//     a.lead();
// }
// else if (((a).isFollower())) {
//     a.follow();
// }

// if (((a["isLeader"])())) {
//     a.lead();
// }
// else if (((a)["isFollower"]())) {
//     a.follow();
// }

var holder2 = {a};

if (holder2.a.isLeader()) {
    holder2.a;
}
else {
    holder2.a;
}

class ArrowGuard {
    isElite = (): this is ArrowElite => {
        return this instanceof ArrowElite;
    }
    isMedic = (): this is ArrowMedic => {
        return this instanceof ArrowMedic;
    }
}

class ArrowElite extends ArrowGuard {
    defend(): void {}
}

class ArrowMedic extends ArrowGuard {
    heal(): void {}
}

let guard = new ArrowGuard();
if (guard.isElite()) {
    guard.defend();
}
else if (guard.isMedic()) {
    guard.heal();
}

interface Supplies {
    spoiled: boolean;
}

interface Sundries {
    broken: boolean;
}

interface Crate<T> {
    contents: T;
    volume: number;
    isSupplies(): this is Crate<Supplies>;
    isSundries(): this is Crate<Sundries>;
}

let crate: Crate<{}>;

if (crate.isSundries()) {
    crate.contents.broken = true;
}
else if (crate.isSupplies()) {
    crate.contents.spoiled = true;
}

// Matching guards should be assignable

a.isFollower = b.isFollower;
a.isLeader = b.isLeader;

class MimicGuard {
    isLeader(): this is MimicLeader { return this instanceof MimicLeader; };
    isFollower(): this is MimicFollower { return this instanceof MimicFollower; };
}

class MimicLeader extends MimicGuard {
    lead(): void {}
}

class MimicFollower extends MimicGuard {
    follow(): void {}
}

let mimic = new MimicGuard();

a.isLeader = mimic.isLeader;
a.isFollower = mimic.isFollower;

if (mimic.isFollower()) {
    mimic.follow();
    mimic.isFollower = a.isFollower;
}


interface MimicGuardInterface {
    isLeader(): this is LeadGuard;
    isFollower(): this is FollowerGuard;
}
`,
      [],
    );
  });
  test("typeGuardFunctionOfFormThisErrors", async () => {
    await expectPass(
      `class RoyalGuard {
    isLeader(): this is LeadGuard {
        return this instanceof LeadGuard;
    }
    isFollower(): this is FollowerGuard {
        return this instanceof FollowerGuard;
    }
}

class LeadGuard extends RoyalGuard {
    lead(): void {};
}

class FollowerGuard extends RoyalGuard {
    follow(): void {};
}

interface GuardInterface extends RoyalGuard {}
let a: RoyalGuard = new FollowerGuard();
let b: GuardInterface = new LeadGuard();

// Mismatched guards shouldn't be assignable
b.isFollower = b.isLeader;
b.isLeader = b.isFollower;

a.isFollower = a.isLeader;
a.isLeader = a.isFollower;

function invalidGuard(c: any): this is number {
    return false;
}

declare var c: number | number[];
if (invalidGuard(c)) {
    c;
}
else {
    c;
}

let holder = {invalidGuard};

if (holder.invalidGuard(c)) {
    c;
    holder;
}
else {
    c;
    holder;
}

let detached = a.isFollower;

if (detached()) {
    a.follow();
}
else {
    a.lead();
}`,
      [],
    );
  });
  test("typeGuardInClass", async () => {
    await expectPass(
      `declare var x: string | number;

if (typeof x === "string") {
    let n = class {
        constructor() {
            let y: string = x;
        }
    }
}
else {
    let m = class {
        constructor() {
            let y: number = x;
        }
    }
}
`,
      [],
    );
  });
  test("typeGuardIntersectionTypes", async () => {
    await expectPass(
      `
interface X {
    x: string;
}

interface Y {
    y: string;
}

interface Z {
    z: string;
}

declare function isX(obj: any): obj is X;
declare function isY(obj: any): obj is Y;
declare function isZ(obj: any): obj is Z;

function f1(obj: Object) {
    if (isX(obj) || isY(obj) || isZ(obj)) {
        obj;
    }
    if (isX(obj) && isY(obj) && isZ(obj)) {
        obj;
    }
}

// Repro from #8911

// two interfaces
interface A {
  a: string;
}

interface B {
  b: string;
}

// a type guard for B
function isB(toTest: any): toTest is B {
  return toTest && toTest.b;
}

// a function that turns an A into an A & B
function union(a: A): A & B | null {
  if (isB(a)) {
    return a;
  } else {
    return null;
  }
}

// Repro from #9016

declare function log(s: string): void;

// Supported beast features
interface Beast     { wings?: boolean; legs?: number }
interface Legged    { legs: number; }
interface Winged    { wings: boolean; }

// Beast feature detection via user-defined type guards
function hasLegs(x: Beast): x is Legged { return x && typeof x.legs === 'number'; }
function hasWings(x: Beast): x is Winged { return x && !!x.wings; }

// Function to identify a given beast by detecting its features
function identifyBeast(beast: Beast) {

    // All beasts with legs
    if (hasLegs(beast)) {

        // All winged beasts with legs
        if (hasWings(beast)) {
            if (beast.legs === 4) {
                log(\`pegasus - 4 legs, wings\`);
            }
            else if (beast.legs === 2) {
                log(\`bird - 2 legs, wings\`);
            }
            else {
                log(\`unknown - \${beast.legs} legs, wings\`);
            }
        }

        // All non-winged beasts with legs
        else {
            log(\`manbearpig - \${beast.legs} legs, no wings\`);
        }
    }

    // All beasts without legs    
    else {
        if (hasWings(beast)) {
            log(\`quetzalcoatl - no legs, wings\`)
        }
        else {
            log(\`snake - no legs, no wings\`)
        }
    }
}

function beastFoo(beast: Object) {
    if (hasWings(beast) && hasLegs(beast)) {
        beast;  // Winged & Legged
    }
    else {
        beast;
    }

    if (hasLegs(beast) && hasWings(beast)) {
        beast;  // Legged & Winged
    }
}`,
      [],
    );
  });
  test("typeGuardNarrowsPrimitiveIntersection", async () => {
    await expectPass(
      `type Tag = {__tag: any};
declare function isNonBlank(value: string) : value is (string & Tag);
declare function doThis(value: string & Tag): void;
declare function doThat(value: string) : void;
let value: string;
if (isNonBlank(value)) {
    doThis(value);
} else {
    doThat(value);
}


const enum Tag2 {}
declare function isNonBlank2(value: string) : value is (string & Tag2);
declare function doThis2(value: string & Tag2): void;
declare function doThat2(value: string) : void;
if (isNonBlank2(value)) {
    doThis2(value);
} else {
    doThat2(value);
}
`,
      [],
    );
  });
  test("typeGuardNarrowsToLiteralType", async () => {
    await expectPass(
      `declare function isFoo(value: string) : value is "foo";
declare function doThis(value: "foo"): void;
declare function doThat(value: string) : void;
let value: string;
if (isFoo(value)) {
    doThis(value);
} else {
    doThat(value);
}

`,
      [],
    );
  });
  test("typeGuardNarrowsToLiteralTypeUnion", async () => {
    await expectPass(
      `declare function isFoo(value: string) : value is ("foo" | "bar");
declare function doThis(value: "foo" | "bar"): void;
declare function doThat(value: string) : void;
let value: string;
if (isFoo(value)) {
    doThis(value);
} else {
    doThat(value);
}

`,
      [],
    );
  });
  test("typeGuardNesting", async () => {
    await expectPass(
      `let strOrBool: string|boolean;
if ((typeof strOrBool === 'boolean' && !strOrBool) || typeof strOrBool === 'string') {
	let label: string = (typeof strOrBool === 'string') ? strOrBool : "string";
	let bool: boolean = (typeof strOrBool === 'boolean') ? strOrBool : false;
	let label2: string = (typeof strOrBool !== 'boolean') ? strOrBool : "string";
	let bool2: boolean = (typeof strOrBool !== 'string') ? strOrBool : false;
}

if ((typeof strOrBool !== 'string' && !strOrBool) || typeof strOrBool !== 'boolean') {
	let label: string = (typeof strOrBool === 'string') ? strOrBool : "string";
	let bool: boolean = (typeof strOrBool === 'boolean') ? strOrBool : false;
	let label2: string = (typeof strOrBool !== 'boolean') ? strOrBool : "string";
	let bool2: boolean = (typeof strOrBool !== 'string') ? strOrBool : false;
}
`,
      [],
    );
  });
  test("typeGuardOfFormExpr1AndExpr2", async () => {
    await expectPass(
      `var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrNumOrBool: string | number | boolean;
var numOrBool: number | boolean;
class C { private p; }
var c: C;
var cOrBool: C| boolean;
var strOrNumOrBoolOrC: string | number | boolean | C;

// A type guard of the form expr1 && expr2
//  - when true, narrows the type of x by expr1 when true and then by expr2 when true, or
//  - when false, narrows the type of x to T1 | T2, where T1 is the type of x narrowed by expr1 when 
//    false, and T2 is the type of x narrowed by expr1 when true and then by expr2 when false.

// (typeguard1 && typeguard2)
if (typeof strOrNumOrBool !== "string" && typeof strOrNumOrBool !== "number") {
    bool = strOrNumOrBool; // boolean
}
else {
    strOrNum = strOrNumOrBool; // string | number
}
// (typeguard1 && typeguard2 && typeguard3)
if (typeof strOrNumOrBoolOrC !== "string" && typeof strOrNumOrBoolOrC !== "number" && typeof strOrNumOrBoolOrC !== "boolean") {
    c = strOrNumOrBoolOrC; // C
}
else {
    strOrNumOrBool = strOrNumOrBoolOrC; // string | number | boolean
}
// (typeguard1 && typeguard2 && typeguard11(onAnotherType))
if (typeof strOrNumOrBoolOrC !== "string" && typeof strOrNumOrBoolOrC !== "number" && typeof strOrNumOrBool === "boolean") {
    cOrBool = strOrNumOrBoolOrC; // C | boolean
    bool = strOrNumOrBool; // boolean
}
else {
    var r1: string | number | boolean | C = strOrNumOrBoolOrC; // string | number | boolean | C
    var r2: string | number | boolean = strOrNumOrBool;
}
// (typeguard1) && simpleExpr
if (typeof strOrNumOrBool !== "string" && numOrBool !== strOrNumOrBool) {
    numOrBool = strOrNumOrBool; // number | boolean
}
else {
    var r3: string | number | boolean = strOrNumOrBool; // string | number | boolean
}`,
      [],
    );
  });
  test("typeGuardOfFormExpr1OrExpr2", async () => {
    await expectPass(
      `var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrNumOrBool: string | number | boolean;
var numOrBool: number | boolean;
class C { private p; }
var c: C;
var cOrBool: C| boolean;
var strOrNumOrBoolOrC: string | number | boolean | C;

// A type guard of the form expr1 || expr2
//  - when true, narrows the type of x to T1 | T2, where T1 is the type of x narrowed by expr1 when true, 
//    and T2 is the type of x narrowed by expr1 when false and then by expr2 when true, or
//  - when false, narrows the type of x by expr1 when false and then by expr2 when false.

// (typeguard1 || typeguard2)
if (typeof strOrNumOrBool === "string" || typeof strOrNumOrBool === "number") {
    strOrNum = strOrNumOrBool; // string | number
}
else {
    bool = strOrNumOrBool; // boolean
}
// (typeguard1 || typeguard2 || typeguard3)
if (typeof strOrNumOrBoolOrC === "string" || typeof strOrNumOrBoolOrC === "number" || typeof strOrNumOrBoolOrC === "boolean") {
    strOrNumOrBool = strOrNumOrBoolOrC; // string | number | boolean
}
else {
    c = strOrNumOrBoolOrC; // C
}
// (typeguard1 || typeguard2 || typeguard11(onAnotherType))
if (typeof strOrNumOrBoolOrC === "string" || typeof strOrNumOrBoolOrC === "number" || typeof strOrNumOrBool !== "boolean") {
    var r1: string | number | boolean | C = strOrNumOrBoolOrC; // string | number | boolean | C
    var r2: string | number | boolean = strOrNumOrBool;
}
else {
    cOrBool = strOrNumOrBoolOrC; // C | boolean
    bool = strOrNumOrBool; // boolean
}
// (typeguard1) || simpleExpr
if (typeof strOrNumOrBool === "string" || numOrBool !== strOrNumOrBool) {
    var r3: string | number | boolean = strOrNumOrBool; // string | number | boolean
}
else {
    numOrBool = strOrNumOrBool; // number | boolean
}`,
      [],
    );
  });
  test("typeGuardOfFormFunctionEquality", async () => {
    await expectPass(
      `declare function isString1(a: number, b: Object): b is string;

declare function isString2(a: Object): a is string;

switch (isString1(0, "")) {
    case isString2(""):
    default:
}

var x = isString1(0, "") === isString2("");

function isString3(a: number, b: number, c: Object): c is string {
    return isString1(0, c);
}
`,
      [],
    );
  });
  test("typeGuardOfFormInstanceOf", async () => {
    await expectPass(
      `// A type guard of the form x instanceof C, where C is of a subtype of the global type 'Function' 
// and C has a property named 'prototype'
//  - when true, narrows the type of x to the type of the 'prototype' property in C provided 
//    it is a subtype of the type of x, or
//  - when false, has no effect on the type of x.

class C1 {
    p1: string;
}
class C2 {
    p2: number;
}
class D1 extends C1 {
    p3: number;
}
class C3 {
    p4: number;
}
var str: string;
var num: number;
var strOrNum: string | number;

var ctor1: C1 | C2;
str = ctor1 instanceof C1 && ctor1.p1; // C1
num = ctor1 instanceof C2 && ctor1.p2; // C2
str = ctor1 instanceof D1 && ctor1.p1; // D1
num = ctor1 instanceof D1 && ctor1.p3; // D1

var ctor2: C2 | D1;
num = ctor2 instanceof C2 && ctor2.p2; // C2
num = ctor2 instanceof D1 && ctor2.p3; // D1
str = ctor2 instanceof D1 && ctor2.p1; // D1
var r2: D1 | C2 = ctor2 instanceof C1 && ctor2; // C2 | D1

var ctor3: C1 | C2;
if (ctor3 instanceof C1) {
    ctor3.p1; // C1
}
else {
    ctor3.p2; // C2
}

var ctor4: C1 | C2 | C3;
if (ctor4 instanceof C1) {
    ctor4.p1; // C1
}
else if (ctor4 instanceof C2) {
    ctor4.p2; // C2
}
else {
    ctor4.p4; // C3
}

var ctor5: C1 | D1 | C2;
if (ctor5 instanceof C1) {
    ctor5.p1; // C1
}
else {
    ctor5.p2; // C2
}

var ctor6: C1 | C2 | C3;
if (ctor6 instanceof C1 || ctor6 instanceof C2) {
}
else {
    ctor6.p4; // C3
}`,
      [],
    );
  });
  test("typeGuardOfFormInstanceOfOnInterface", async () => {
    await expectPass(
      `// A type guard of the form x instanceof C, where C is of a subtype of the global type 'Function' 
// and C has a property named 'prototype'
//  - when true, narrows the type of x to the type of the 'prototype' property in C provided 
//    it is a subtype of the type of x, or
//  - when false, has no effect on the type of x.

interface C1 {
    (): C1;
    prototype: C1;
    p1: string;
}
interface C2 {
    (): C2;
    prototype: C2;
    p2: number;
}
interface D1 extends C1 {
    prototype: D1;
    p3: number;
}
var str: string;
var num: number;
var strOrNum: string | number;

var c1: C1;
var c2: C2;
var d1: D1;
var c1Orc2: C1 | C2;
str = c1Orc2 instanceof c1 && c1Orc2.p1; // C1
num = c1Orc2 instanceof c2 && c1Orc2.p2; // C2
str = c1Orc2 instanceof d1 && c1Orc2.p1; // C1
num = c1Orc2 instanceof d1 && c1Orc2.p3; // D1

var c2Ord1: C2 | D1;
num = c2Ord1 instanceof c2 && c2Ord1.p2; // C2
num = c2Ord1 instanceof d1 && c2Ord1.p3; // D1
str = c2Ord1 instanceof d1 && c2Ord1.p1; // D1
var r2: D1 | C2 = c2Ord1 instanceof c1 && c2Ord1; // C2 | D1`,
      [],
    );
  });
  test("typeGuardOfFormIsType", async () => {
    await expectPass(
      `
class C1 {
    p1: string;
}
class C2 {
    p2: number;
}
class D1 extends C1 {
    p3: number;
}
var str: string;
var num: number;
var strOrNum: string | number;

function isC1(x: any): x is C1 {
    return true;
}

function isC2(x: any): x is C2 {
    return true;
}

function isD1(x: any): x is D1 {
    return true;
}

var c1Orc2: C1 | C2;
str = isC1(c1Orc2) && c1Orc2.p1; // C1
num = isC2(c1Orc2) && c1Orc2.p2; // C2
str = isD1(c1Orc2) && c1Orc2.p1; // D1
num = isD1(c1Orc2) && c1Orc2.p3; // D1

var c2Ord1: C2 | D1;
num = isC2(c2Ord1) && c2Ord1.p2; // C2
num = isD1(c2Ord1) && c2Ord1.p3; // D1
str = isD1(c2Ord1) && c2Ord1.p1; // D1
var r2: C2 | D1 = isC1(c2Ord1) && c2Ord1; // C2 | D1`,
      [],
    );
  });
  test("typeGuardOfFormIsTypeOnInterfaces", async () => {
    await expectPass(
      `
interface C1 {
    (): C1;
    prototype: C1;
    p1: string;
}
interface C2 {
    (): C2;
    prototype: C2;
    p2: number;
}
interface D1 extends C1 {
    prototype: D1;
    p3: number;
}
var str: string;
var num: number;
var strOrNum: string | number;


function isC1(x: any): x is C1 {
    return true;
}

function isC2(x: any): x is C2 {
    return true;
}

function isD1(x: any): x is D1 {
    return true;
}

var c1: C1;
var c2: C2;
var d1: D1;
var c1Orc2: C1 | C2;
str = isC1(c1Orc2) && c1Orc2.p1; // C1
num = isC2(c1Orc2) && c1Orc2.p2; // C2
str = isD1(c1Orc2) && c1Orc2.p1; // D1
num = isD1(c1Orc2) && c1Orc2.p3; // D1

var c2Ord1: C2 | D1;
num = isC2(c2Ord1) && c2Ord1.p2; // C2
num = isD1(c2Ord1) && c2Ord1.p3; // D1
str = isD1(c2Ord1) && c2Ord1.p1; // D1
var r2: C2 | D1 = isC1(c2Ord1) && c2Ord1; // C2 | D1`,
      [],
    );
  });
  test("typeGuardOfFormNotExpr", async () => {
    await expectPass(
      `var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrNumOrBool: string | number | boolean;
var numOrBool: number | boolean;

// A type guard of the form !expr
// - when true, narrows the type of x by expr when false, or
// - when false, narrows the type of x by expr when true.

// !typeguard1
if (!(typeof strOrNum === "string")) {
    num === strOrNum; // number
}
else {
    str = strOrNum; // string
}
// !(typeguard1 || typeguard2)
if (!(typeof strOrNumOrBool === "string" || typeof strOrNumOrBool === "number")) {
    bool = strOrNumOrBool; // boolean
}
else {
    strOrNum = strOrNumOrBool; // string | number
}
// !(typeguard1) || !(typeguard2)
if (!(typeof strOrNumOrBool !== "string") || !(typeof strOrNumOrBool !== "number")) {
    strOrNum = strOrNumOrBool; // string | number
}
else {
    bool = strOrNumOrBool; // boolean
}
// !(typeguard1 && typeguard2)
if (!(typeof strOrNumOrBool !== "string" && typeof strOrNumOrBool !== "number")) {
    strOrNum = strOrNumOrBool; // string | number
}
else {
    bool = strOrNumOrBool; // boolean
}
// !(typeguard1) && !(typeguard2)
if (!(typeof strOrNumOrBool === "string") && !(typeof strOrNumOrBool === "number")) {
    bool = strOrNumOrBool; // boolean
}
else {
    strOrNum = strOrNumOrBool; // string | number
}
// !(typeguard1) && simpleExpr
if (!(typeof strOrNumOrBool === "string") && numOrBool !== strOrNumOrBool) {
    numOrBool = strOrNumOrBool; // number | boolean
}
else {
    var r1: string | number | boolean = strOrNumOrBool; // string | number | boolean
}`,
      [],
    );
  });
  test("typeGuardOfFormThisMember", async () => {
    await expectError(
      `// There's a 'File' class in the stdlib, wrap with a namespace to avoid collision
namespace Test {
	export class FileSystemObject {
		isFSO: this is FileSystemObject;
		get isFile(): this is File {
			return this instanceof File;
		}
		set isFile(param) {
			// noop
		}
		get isDirectory(): this is Directory {
			return this instanceof Directory;
		}
		isNetworked: this is (Networked & this);
		constructor(public path: string) {}
	}

	export class File extends FileSystemObject {
		constructor(path: string, public content: string) { super(path); }
	}
	export class Directory extends FileSystemObject {
		children: FileSystemObject[];
	}
	export interface Networked {
		host: string;
	}

	let file: FileSystemObject = new File("foo/bar.txt", "foo");
	file.isNetworked = false;
	file.isFSO = file.isFile;
	file.isFile = true;
	let x = file.isFile;
	if (file.isFile) {
		file.content;
		if (file.isNetworked) {
			file.host;
			file.content;
		}
	}
	else if (file.isDirectory) {
		file.children;
	}
	else if (file.isNetworked) {
		file.host;
	}
	
	interface GenericLeadGuard<T> extends GenericGuard<T> {
		lead(): void;
	}
	
	interface GenericFollowerGuard<T> extends GenericGuard<T> {
		follow(): void;
	}
	
	interface GenericGuard<T> {
		target: T;
		isLeader: this is (GenericLeadGuard<T>);
		isFollower: this is GenericFollowerGuard<T>;
	}

	declare var guard: GenericGuard<File>;
	if (guard.isLeader) {
		guard.lead();
	}
	else if (guard.isFollower) {
		guard.follow();
	}

	interface SpecificGuard {
		isMoreSpecific: this is MoreSpecificGuard;
	}

	interface MoreSpecificGuard extends SpecificGuard {
		do(): void;
	}

	declare var general: SpecificGuard;
	if (general.isMoreSpecific) {
		general.do();
	}
}
`,
      [],
    );
  });
  test("typeGuardOfFormThisMemberErrors", async () => {
    await expectError(
      `// There's a 'File' class in the stdlib, wrap with a namespace to avoid collision
namespace Test {
	export class FileSystemObject {
		isFSO: this is FileSystemObject;
		get isFile(): this is File {
			return this instanceof File;
		}
		set isFile(param) {
			// noop
		}
		get isDirectory(): this is Directory {
			return this instanceof Directory;
		}
		isNetworked: this is (Networked & this);
		constructor(public path: string) {}
	}

	export class File extends FileSystemObject {
		constructor(path: string, public content: string) { super(path); }
	}
	export class Directory extends FileSystemObject {
		children: FileSystemObject[];
	}
	export interface Networked {
		host: string;
	}

	let file: FileSystemObject = new File("foo/bar.txt", "foo");
	file.isNetworked = file.isFile;
	file.isFSO = file.isNetworked;
	file.isFile = file.isFSO;
}`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfBoolean", async () => {
    await expectPass(
      `class C { private p: string };

var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrBool: string | boolean;
var numOrBool: number | boolean
var strOrNumOrBool: string | number | boolean;
var strOrC: string | C;
var numOrC: number | C;
var boolOrC: boolean | C;
var c: C;

//	A type guard of the form typeof x === s, 
//  where s is a string literal with the value 'string', 'number', or 'boolean',
//  - when true, narrows the type of x to the given primitive type, or
//  - when false, removes the primitive type from the type of x.
if (typeof strOrBool === "boolean") {
    bool = strOrBool; // boolean
}
else {
    str = strOrBool; // string
}
if (typeof numOrBool === "boolean") {
    bool = numOrBool; // boolean
}
else {
    num = numOrBool; // number
}
if (typeof strOrNumOrBool === "boolean") {
    bool = strOrNumOrBool; // boolean
}
else {
    strOrNum = strOrNumOrBool; // string | number
}
if (typeof boolOrC === "boolean") {
    bool = boolOrC; // boolean
}
else {
    c = boolOrC; // C
}

if (typeof strOrNum === "boolean") {
    let z1: {} = strOrNum; // {}
}
else {
    let z2: string | number = strOrNum; // string | number
}


// A type guard of the form typeof x !== s, where s is a string literal,
//  - when true, narrows the type of x by typeof x === s when false, or
//  - when false, narrows the type of x by typeof x === s when true.
if (typeof strOrBool !== "boolean") {
    str = strOrBool; // string
}
else {
    bool = strOrBool; // boolean
}
if (typeof numOrBool !== "boolean") {
    num = numOrBool; // number
}
else {
    bool = numOrBool; // boolean
}
if (typeof strOrNumOrBool !== "boolean") {
    strOrNum = strOrNumOrBool; // string | number
}
else {
    bool = strOrNumOrBool; // boolean
}
if (typeof boolOrC !== "boolean") {
    c = boolOrC; // C
}
else {
    bool = boolOrC; // boolean
}

if (typeof strOrNum !== "boolean") {
    let z1: string | number = strOrNum; // string | number
}
else {
    let z2: {} = strOrNum; // {}
}
`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfEqualEqualHasNoEffect", async () => {
    await expectPass(
      `class C { private p: string };

declare var strOrNum: string | number;
declare var strOrBool: string | boolean;
declare var numOrBool: number | boolean;
declare var strOrC: string | C;

// typeof x == s has not effect on typeguard
if (typeof strOrNum == "string") {
    var r1 = strOrNum; // string | number
}
else {
    var r1 = strOrNum; // string | number
}

if (typeof strOrBool == "boolean") {
    var r2 = strOrBool; // string | boolean
}
else {
    var r2 = strOrBool; // string | boolean
}

if (typeof numOrBool == "number") {
    var r3 = numOrBool; // number | boolean
}
else {
    var r3 =  numOrBool; // number | boolean
}

if (typeof strOrC == "Object") {
    var r4 = strOrC; // string | C
}
else {
    var r4 = strOrC; // string | C
}`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfFunction", async () => {
    await expectPass(
      `
function f1(x: any) {
    if (typeof x === "function") {
        x;  // any
    }
}

function f2(x: unknown) {
    if (typeof x === "function") {
        x;  // Function
    }
}

function f3(x: {}) {
    if (typeof x === "function") {
        x;  // Function
    }
}

function f4<T>(x: T) {
    if (typeof x === "function") {
        x;  // T & Function
    }
}

function f5(x: { s: string }) {
    if (typeof x === "function") {
        x;  // never
    }
}

function f6(x: () => string) {
    if (typeof x === "function") {
        x;  // () => string
    }
}

function f10(x: string | (() => string)) {
    if (typeof x === "function") {
        x;  // () => string
    }
    else {
        x;  // string
    }
}

function f11(x: { s: string } | (() => string)) {
    if (typeof x === "function") {
        x;  // () => string
    }
    else {
        x;  // { s: string }
    }
}

function f12(x: { s: string } | { n: number }) {
    if (typeof x === "function") {
        x;  // never
    }
    else {
        x;  // { s: string } | { n: number }
    }
}

// Repro from #18238

function f100<T, K extends keyof T>(obj: T, keys: K[]) : void {
    for (const k of keys) {
        const item = obj[k];
        if (typeof item == 'function')
            item.call(obj);
    }
}

// Repro from #49316

function configureStore<S extends object>(reducer: (() => void) | Record<keyof S, () => void>) {
    let rootReducer: () => void;
    if (typeof reducer === 'function') {
        rootReducer = reducer;
    }
}

function f101(x: string | Record<string, any>) {
    return typeof x === "object" && x.anything;
}
`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfIsOrderIndependent", async () => {
    await expectPass(
      `var strOrNum: string | number;
var strOrBool: string | boolean;
var strOrFunc: string | (() => void);
var numOrBool: number | boolean
var str: string;
var num: number;
var bool: boolean;
var func: () => void;

if ("string" === typeof strOrNum) {
    str = strOrNum;
}
else {
    num = strOrNum;
}
if ("function" === typeof strOrFunc) {
    func = strOrFunc;
}
else {
    str = strOrFunc;
}
if ("number" === typeof numOrBool) {
    num = numOrBool;
}
else {
    bool = numOrBool;
}
if ("boolean" === typeof strOrBool) {
    bool = strOrBool;
}
else {
    str = strOrBool;
}`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfNotEqualHasNoEffect", async () => {
    await expectPass(
      `class C { private p: string };

declare var strOrNum: string | number;
declare var strOrBool: string | boolean;
declare var numOrBool: number | boolean;
declare var strOrC: string | C;

// typeof x != s has not effect on typeguard
if (typeof strOrNum != "string") {
    var r1 = strOrNum; // string | number
}
else {
    var r1 = strOrNum; // string | number
}

if (typeof strOrBool != "boolean") {
    var r2 = strOrBool; // string | boolean
}
else {
    var r2 = strOrBool; // string | boolean
}

if (typeof numOrBool != "number") {
    var r3 = numOrBool; // number | boolean
}
else {
    var r3 = numOrBool; // number | boolean
}

if (typeof strOrC != "Object") {
    var r4 = strOrC; // string | C
}
else {
    var r4 = strOrC; // string | C
}`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfNumber", async () => {
    await expectPass(
      `class C { private p: string };

var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrBool: string | boolean;
var numOrBool: number | boolean
var strOrNumOrBool: string | number | boolean;
var strOrC: string | C;
var numOrC: number | C;
var boolOrC: boolean | C;
var c: C;

//	A type guard of the form typeof x === s, 
//  where s is a string literal with the value 'string', 'number', or 'boolean',
//  - when true, narrows the type of x to the given primitive type, or
//  - when false, removes the primitive type from the type of x.
if (typeof strOrNum === "number") {
    num = strOrNum; // number
}
else {
    str === strOrNum; // string
}
if (typeof numOrBool === "number") {
    num = numOrBool; // number
}
else {
    var x: number | boolean = numOrBool; // number | boolean
}
if (typeof strOrNumOrBool === "number") {
    num = strOrNumOrBool; // number
}
else {
    strOrBool = strOrNumOrBool; // string | boolean
}
if (typeof numOrC === "number") {
    num = numOrC; // number
}
else {
    c = numOrC; // C
}

if (typeof strOrBool === "number") {
    let y1: {} = strOrBool; // {}
}
else {
    let y2: string | boolean = strOrBool; // string | boolean
}

// A type guard of the form typeof x !== s, where s is a string literal,
//  - when true, narrows the type of x by typeof x === s when false, or
//  - when false, narrows the type of x by typeof x === s when true.
if (typeof strOrNum !== "number") {
    str === strOrNum; // string
}
else {
    num = strOrNum; // number
}
if (typeof numOrBool !== "number") {
    var x: number | boolean = numOrBool; // number | boolean
}
else {
    num = numOrBool; // number
}
if (typeof strOrNumOrBool !== "number") {
    strOrBool = strOrNumOrBool; // string | boolean
}
else {
    num = strOrNumOrBool; // number
}
if (typeof numOrC !== "number") {
    c = numOrC; // C
}
else {
    num = numOrC; // number
}

if (typeof strOrBool !== "number") {
    let y1: string | boolean = strOrBool; // string | boolean
}
else {
    let y2: {} = strOrBool; // {}
}
`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfOther", async () => {
    await expectPass(
      `class C { private p: string };

var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrBool: string | boolean;
var numOrBool: number | boolean
var strOrNumOrBool: string | number | boolean;
declare var strOrC: string | C;
declare var numOrC: number | C;
declare var boolOrC: boolean | C;
var emptyObj: {};
var c: C;

// A type guard of the form typeof x === s, 
// where s is a string literal with any value but 'string', 'number' or 'boolean',
//  - when true, removes the primitive types string, number, and boolean from the type of x, or
//  - when false, has no effect on the type of x.

if (typeof strOrC === "Object") {
    c = strOrC; // C
}
else {
    var r2: string = strOrC; // string
}
if (typeof numOrC === "Object") {
    c = numOrC; // C
}
else {
    var r3: number  = numOrC; // number
}
if (typeof boolOrC === "Object") {
    c = boolOrC; // C
}
else {
    var r4: boolean = boolOrC; // boolean
}
if (typeof strOrC === "Object" as string) { // comparison is OK with cast
    c = strOrC; // error: but no narrowing to C
}
else {
    var r5: string = strOrC; // error: no narrowing to string
}

if (typeof strOrNumOrBool === "Object") {
    let q1: {} = strOrNumOrBool; // {}
}
else {
    let q2: string | number | boolean = strOrNumOrBool; // string | number | boolean
}

// A type guard of the form typeof x !== s, where s is a string literal,
//  - when true, narrows the type of x by typeof x === s when false, or
//  - when false, narrows the type of x by typeof x === s when true.
if (typeof strOrC !== "Object") {
    var r2: string = strOrC; // string
}
else {
    c = strOrC; // C
}
if (typeof numOrC !== "Object") {
    var r3: number = numOrC; // number
}
else {
    c = numOrC; // C
}
if (typeof boolOrC !== "Object") {
    var r4: boolean = boolOrC; // boolean
}
else {
    c = boolOrC; // C
}

if (typeof strOrNumOrBool !== "Object") {
    let q1: string | number | boolean = strOrNumOrBool; // string | number | boolean
}
else {
    let q2: {} = strOrNumOrBool; // {}
}
`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfPrimitiveSubtype", async () => {
    await expectPass(
      `let a: {};
let b: {toString(): string};
if (typeof a === "number") {
    let c: number = a;
}
if (typeof a === "string") {
    let c: string = a;
}
if (typeof a === "boolean") {
    let c: boolean = a;
}

if (typeof b === "number") {
    let c: number = b;
}
if (typeof b === "string") {
    let c: string = b;
}
if (typeof b === "boolean") {
    let c: boolean = b;
}
`,
      [],
    );
  });
  test("typeGuardOfFormTypeOfString", async () => {
    await expectPass(
      `class C { private p: string };

var str: string;
var bool: boolean;
var num: number;
var strOrNum: string | number;
var strOrBool: string | boolean;
var numOrBool: number | boolean
var strOrNumOrBool: string | number | boolean;
var strOrC: string | C;
var numOrC: number | C;
var boolOrC: boolean | C;
var c: C;

//	A type guard of the form typeof x === s, 
//  where s is a string literal with the value 'string', 'number', or 'boolean',
//  - when true, narrows the type of x to the given primitive type, or
//  - when false, removes the primitive type from the type of x.
if (typeof strOrNum === "string") {
    str = strOrNum; // string
}
else {
    num === strOrNum; // number
}
if (typeof strOrBool === "string") {
    str = strOrBool; // string
}
else {
    bool = strOrBool; // boolean
}
if (typeof strOrNumOrBool === "string") {
    str = strOrNumOrBool; // string
}
else {
    numOrBool = strOrNumOrBool; // number | boolean
}
if (typeof strOrC === "string") {
    str = strOrC; // string
}
else {
    c = strOrC; // C
}

if (typeof numOrBool === "string") {
    let x1: {} = numOrBool; // {}
}
else {
    let x2: number | boolean = numOrBool; // number | boolean
}

// A type guard of the form typeof x !== s, where s is a string literal,
//  - when true, narrows the type of x by typeof x === s when false, or
//  - when false, narrows the type of x by typeof x === s when true.
if (typeof strOrNum !== "string") {
    num === strOrNum; // number
}
else {
    str = strOrNum; // string
}
if (typeof strOrBool !== "string") {
    bool = strOrBool; // boolean
}
else {
    str = strOrBool; // string
}
if (typeof strOrNumOrBool !== "string") {
    numOrBool = strOrNumOrBool; // number | boolean
}
else {
    str = strOrNumOrBool; // string
}
if (typeof strOrC !== "string") {
    c = strOrC; // C
}
else {
    str = strOrC; // string
}

if (typeof numOrBool !== "string") {
    let x1: number | boolean = numOrBool; // number | boolean
}
else {
    let x2: {} = numOrBool; // {}
}
`,
      [],
    );
  });
  test("typeGuardOfFromPropNameInUnionType", async () => {
    await expectPass(
      `class A { a: string; }
class B { b: number; }
class C { b: Object; }
class D { a: Date; }

function namedClasses(x: A | B) {
    if ("a" in x) {
        x.a = "1";
    } else {
        x.b = 1;
    }
}

function multipleClasses(x: A | B | C | D) {
    if ("a" in x) {
        let y: string | Date = x.a;
    } else {
        let z: number | Object = x.b;
    }
}

function anonymousClasses(x: { a: string; } | { b: number; }) {
    if ("a" in x) {
        let y: string = x.a;
    } else {
        let z: number = x.b;
    }
}

class AWithOptionalProp { a?: string; }
class BWithOptionalProp { b?: string; }

function positiveTestClassesWithOptionalProperties(x: AWithOptionalProp | BWithOptionalProp) {
    if ("a" in x) {
        x.a = "1";
    } else {
        const y: string = x instanceof AWithOptionalProp
            ? x.a
            : x.b
    }
}

function inParenthesizedExpression(x: A | B) {
    if ("a" in (x)) {
        let y: string = x.a;
    } else {
        let z: number = x.b;
    }
}

class ClassWithUnionProp { prop: A | B; }

function inProperty(x: ClassWithUnionProp) {
    if ("a" in x.prop) {
        let y: string = x.prop.a;
    } else {
        let z: number = x.prop.b;
    }
}

class NestedClassWithProp { outer: ClassWithUnionProp; }

function innestedProperty(x: NestedClassWithProp) {
    if ("a" in x.outer.prop) {
        let y: string = x.outer.prop.a;
    } else {
        let z: number = x.outer.prop.b;
    }
}

class InMemberOfClass {
    protected prop: A | B;
    inThis() {
        if ("a" in this.prop) {
            let y: string = this.prop.a;
        } else {
            let z: number = this.prop.b;
        }
    }
}

// added for completeness
class SelfAssert {
    a: string;
    inThis() {
        if ("a" in this) {
            let y: string = this.a;
        } else {
        }
    }
}

interface Indexed {
    [s: string]: any;
}

function f(i: Indexed) {
    if ("a" in i) {
        return i.a;
    }
    else if ("b" in i) {
        return i.b;
    }
    return "c" in i && i.c;
}
`,
      [],
    );
  });
  test("typeGuardRedundancy", async () => {
    await expectPass(
      `var x: string|number;

var r1 = typeof x === "string" && typeof x === "string" ? x.substr : x.toFixed;

var r2 = !(typeof x === "string" && typeof x === "string") ? x.toFixed : x.substr;

var r3 = typeof x === "string" || typeof x === "string" ? x.substr : x.toFixed;

var r4 = !(typeof x === "string" || typeof x === "string") ? x.toFixed : x.substr;`,
      [],
    );
  });
  test("typeGuardsDefeat", async () => {
    await expectPass(
      `// Also note that it is possible to defeat a type guard by calling a function that changes the 
// type of the guarded variable.
function foo(x: number | string) {
    function f() {
        x = 10;
    }
    if (typeof x === "string") {
        f();
        return x.length; // string
    }
    else {
        return x++; // number
    }
}
function foo2(x: number | string) {
    if (typeof x === "string") {
        return x.length; // string
    }
    else {
        var f = function () {
            return x * x;
        };
    }
    x = "hello";
    f();
}
function foo3(x: number | string) {
    if (typeof x === "string") {
        return x.length; // string
    }
    else {
        var f = () => x * x;
    }
    x = "hello";
    f();
}
`,
      [],
    );
  });
  test("typeGuardsInClassAccessors", async () => {
    await expectPass(
      `
// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// variables in global
var num: number;
var strOrNum: string | number;
var var1: string | number;
class ClassWithAccessors {
    // Inside public accessor getter
    get p1() {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        return strOrNum;
    }
    // Inside public accessor setter
    set p1(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // parameter of function declaration
        num = typeof param === "string" && param.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string
    }
    // Inside private accessor getter
    private get pp1() {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        return strOrNum;
    }
    // Inside private accessor setter
    private set pp1(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // parameter of function declaration
        num = typeof param === "string" && param.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string
    }
    // Inside static accessor getter
    static get s1() {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        return strOrNum;
    }
    // Inside static accessor setter
    static set s1(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // parameter of function declaration
        num = typeof param === "string" && param.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string
    }
    // Inside private static accessor getter
    private static get ss1() {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        return strOrNum;
    }
    // Inside private static accessor setter
    private static set ss1(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // parameter of function declaration
        num = typeof param === "string" && param.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string
    }
}
`,
      [],
    );
  });
  test("typeGuardsInClassMethods", async () => {
    await expectPass(
      `// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// variables in global
var num: number;
var var1: string | number;
class C1 {
    constructor(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string
    }
    // Inside function declaration
    private p1(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string
    }
    // Inside function declaration
    p2(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string
    }
    // Inside function declaration
    private static s1(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string
    }
    // Inside function declaration
    static s2(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string
    }
}
`,
      [],
    );
  });
  test("typeGuardsInConditionalExpression", async () => {
    await expectPass(
      `// In the true expression of a conditional expression, 
// the type of a variable or parameter is narrowed by any type guard in the condition when true, 
// provided the true expression contains no assignments to the variable or parameter.
// In the false expression of a conditional expression, 
// the type of a variable or parameter is narrowed by any type guard in the condition when false, 
// provided the false expression contains no assignments to the variable or parameter.

function foo(x: number | string) {
    return typeof x === "string"
        ? x.length // string
        : x++; // number
}
function foo2(x: number | string) {
    return typeof x === "string"
        ? ((x = "hello") && x) // string
        : x; // number
}
function foo3(x: number | string) {
    return typeof x === "string"
        ? ((x = 10) && x) // number
        : x; // number
}
function foo4(x: number | string) {
    return typeof x === "string"
        ? x // string
        : ((x = 10) && x); // number
}
function foo5(x: number | string) {
    return typeof x === "string"
        ? x // string
        : ((x = "hello") && x); // string
}
function foo6(x: number | string) {
    // Modify in both branches
    return typeof x === "string"
        ? ((x = 10) && x) // number
        : ((x = "hello") && x); // string
}
function foo7(x: number | string | boolean) {
    return typeof x === "string"
        ? x === "hello" // boolean
        : typeof x === "boolean"
        ? x // boolean
        : x == 10; // boolean
}
function foo8(x: number | string | boolean) {
    var b: number | boolean;
    return typeof x === "string"
        ? x === "hello"
        : ((b = x) && //  number | boolean
        (typeof x === "boolean"
        ? x // boolean
        : x == 10)); // boolean
}
function foo9(x: number | string) {
    var y = 10;
    // usage of x or assignment to separate variable shouldn't cause narrowing of type to stop
    return typeof x === "string"
        ? ((y = x.length) && x === "hello") // boolean
        : x === 10; // boolean
}
function foo10(x: number | string | boolean) {
    // Mixing typeguards
    var b: boolean | number;
    return typeof x === "string"
        ? x // string
        : ((b = x) // x is number | boolean
        && typeof x === "number"
        && x.toString()); // x is number
}
function foo11(x: number | string | boolean) {
    // Mixing typeguards
    var b: number | boolean | string;
    return typeof x === "string"
        ? x // string
        : ((b = x) // x is number | boolean
        && typeof x === "number"
        && (x = 10) // assignment to x
        && x); // x is number
}
function foo12(x: number | string | boolean) {
    // Mixing typeguards
    var b: number | boolean | string;
    return typeof x === "string"
        ? ((x = 10) && x.toString().length) // number
        : ((b = x) // x is number | boolean
        && typeof x === "number"
        && x); // x is number
}`,
      [],
    );
  });
  test("typeGuardsInDoStatement", async () => {
    await expectPass(
      `let cond: boolean;
function a(x: string | number | boolean) {
    x = true;
    do {
        x; // boolean | string
        x = undefined;
    } while (typeof x === "string")
    x; // number | boolean
}
function b(x: string | number | boolean) {
    x = true;
    do {
        x; // boolean | string
        if (cond) continue;
        x = undefined;
    } while (typeof x === "string")
    x; // number | boolean
}
function c(x: string | number) {
    x = "";
    do {
        x; // string
        if (cond) break;
        x = undefined;
    } while (typeof x === "string")
    x; // string | number
}`,
      [],
    );
  });
  test("typeGuardsInExternalModule", async () => {
    await expectPass(
      `// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// local variable in external module
var num: number;
var var1: string | number;
if (typeof var1 === "string") {
    num = var1.length; // string
}
else {
    num = var1; // number
}

// exported variable in external module
var strOrNum: string | number;
export var var2: string | number;
if (typeof var2 === "string") {
    // export makes the var property and not variable
    strOrNum = var2; // string | number
}
else {
    strOrNum = var2; // number | string
}`,
      [],
    );
  });
  test("typeGuardsInForStatement", async () => {
    await expectPass(
      `let cond: boolean;
function a(x: string | number) {
    for (x = undefined; typeof x !== "number"; x = undefined) {
        x; // string
    }
    x; // number
}
function b(x: string | number) {
    for (x = undefined; typeof x !== "number"; x = undefined) {
        x; // string
        if (cond) continue;
    }
    x; // number
}
function c(x: string | number) {
    for (x = undefined; typeof x !== "number"; x = undefined) {
        x; // string
        if (cond) break;
    }
    x; // string | number
}`,
      [],
    );
  });
  test("typeGuardsInFunction", async () => {
    await expectPass(
      `// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// variables in global
var num: number;
var var1: string | number;
// Inside function declaration
function f(param: string | number) {
    // global vars in function declaration
    num =  typeof var1 === "string" && var1.length; // string

    // variables in function declaration
    var var2: string | number;
    num = typeof var2 === "string" && var2.length; // string

    // parameters in function declaration
    num = typeof param === "string" && param.length; // string
}
// local function declaration
function f1(param: string | number) {
    var var2: string | number;
    function f2(param1: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables from outer function declaration
        num = typeof var2 === "string" && var2.length; // string

        // parameters in outer declaration
        num = typeof param === "string" && param.length; // string

        // local
        var var3: string | number;
        num = typeof var3 === "string" && var3.length; // string
        num = typeof param1 === "string" && param1.length; // string
    }
}
// Function expression
function f2(param: string | number) {
    // variables in function declaration
    var var2: string | number;
    // variables in function expressions
    var r = function (param1: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables from outer function declaration
        num = typeof var2 === "string" && var2.length; // string

        // parameters in outer declaration
        num = typeof param === "string" && param.length; // string

        // local
        var var3: string | number;
        num = typeof var3 === "string" && var3.length; // string
        num = typeof param1 === "string" && param1.length; // string
    } (param);
}
// Arrow expression
function f3(param: string | number) {
    // variables in function declaration
    var var2: string | number;
    // variables in function expressions
    var r = ((param1: string | number) => {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables from outer function declaration
        num = typeof var2 === "string" && var2.length; // string

        // parameters in outer declaration
        num = typeof param === "string" && param.length; // string

        // local
        var var3: string | number;
        num = typeof var3 === "string" && var3.length; // string
        num = typeof param1 === "string" && param1.length; // string
    })(param);
}
// Return type of function
// Inside function declaration
var strOrNum: string | number;
function f4() {
    var var2: string | number = strOrNum;
    return var2;
}
strOrNum = typeof f4() === "string" && f4(); // string | number `,
      [],
    );
  });
  test("typeGuardsInFunctionAndModuleBlock", async () => {
    await expectPass(
      `// typeguards are scoped in function/module block

function foo(x: number | string | boolean) {
    return typeof x === "string"
        ? x
        : function f() {
            var b = x; // number | boolean
            return typeof x === "boolean"
                ? x.toString() // boolean
                : x.toString(); // number
        } ();
}
function foo2(x: number | string | boolean) {
    return typeof x === "string"
        ? x
        : function f(a: number | boolean) {
            var b = x; // new scope - number | boolean
            return typeof x === "boolean"
                ? x.toString() // boolean
                : x.toString(); // number
        } (x); // x here is narrowed to number | boolean
}
function foo3(x: number | string | boolean) {
    return typeof x === "string"
        ? x
        : (() => {
            var b = x; // new scope - number | boolean
            return typeof x === "boolean"
                ? x.toString() // boolean
                : x.toString(); // number
        })();
}
function foo4(x: number | string | boolean) {
    return typeof x === "string"
        ? x
        : ((a: number | boolean) => {
            var b = x; // new scope - number | boolean
            return typeof x === "boolean"
                ? x.toString() // boolean
                : x.toString(); // number
        })(x); // x here is narrowed to number | boolean
}
// Type guards do not affect nested function declarations
function foo5(x: number | string | boolean) {
    if (typeof x === "string") {
        var y = x; // string;
        function foo() {
            var z = x; // string
        }
    }
}
namespace m {
    var x: number | string | boolean;
    namespace m2 {
        var b = x; // new scope - number | boolean | string
        var y: string;
        if (typeof x === "string") {
            y = x // string;
        } else {
            y = typeof x === "boolean"
            ? x.toString() // boolean
            : x.toString(); // number
        }
    }
}
namespace m1 {
    var x: number | string | boolean;
    namespace m2.m3 {
        var b = x; // new scope - number | boolean | string
        var y: string;
        if (typeof x === "string") {
            y = x // string;
        } else {
            y = typeof x === "boolean"
            ? x.toString() // boolean
            : x.toString(); // number
        }
    }
}`,
      [],
    );
  });
  test("typeGuardsInGlobal", async () => {
    await expectPass(
      `// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// variables in global
var num: number;
var var1: string | number;
if (typeof var1 === "string") {
    num = var1.length; // string
}
else {
    num = var1; // number
}
`,
      [],
    );
  });
  test("typeGuardsInIfStatement", async () => {
    await expectPass(
      `// In the true branch statement of an 'if' statement, 
// the type of a variable or parameter is narrowed by any type guard in the 'if' condition when true.
// In the false branch statement of an 'if' statement, 
// the type of a variable or parameter is narrowed by any type guard in the 'if' condition when false.
function foo(x: number | string) {
    if (typeof x === "string") {
        return x.length; // string
    }
    else {
        return x++; // number
    }
}
function foo2(x: number | string) {
    if (typeof x === "string") {
        x = 10;
        return x; // number
    }
    else {
        return x; // number
    }
}
function foo3(x: number | string) {
    if (typeof x === "string") {
        x = "Hello";
        return x; // string
    }
    else {
        return x; // number
    }
}
function foo4(x: number | string) {
    if (typeof x === "string") {
        return x; // string
    }
    else {
        x = 10;
        return x; // number
    }
}
function foo5(x: number | string) {
    if (typeof x === "string") {
        return x; // string
    }
    else {
        x = "hello";
        return x; // string
    }
}
function foo6(x: number | string) {
    if (typeof x === "string") {
        x = 10;
        return x; // number
    }
    else {
        x = "hello";
        return x; // string
    }
}
function foo7(x: number | string | boolean) {
    if (typeof x === "string") {
        return x === "hello"; // string
    }
    else if (typeof x === "boolean") {
        return x; // boolean
    }
    else {
        return x == 10; // number
    }
}
function foo8(x: number | string | boolean) {
    if (typeof x === "string") {
        return x === "hello"; // string
    }
    else {
        var b: number | boolean = x; //  number | boolean
        if (typeof x === "boolean") {
            return x; // boolean
        }
        else {
            return x == 10; // number
        }
    }
}
function foo9(x: number | string) {
    var y = 10;
    if (typeof x === "string") {
        // usage of x or assignment to separate variable shouldn't cause narrowing of type to stop
        y = x.length; 
        return x === "hello"; // string
    }
    else {
        return x == 10; // number
    }
}
function foo10(x: number | string | boolean) {
    // Mixing typeguard narrowing in if statement with conditional expression typeguard
    if (typeof x === "string") {
        return x === "hello"; // string
    }
    else {
        var y: boolean | string;
        var b = x; // number | boolean
        return typeof x === "number"
            ? x === 10 // number
            : x; // x should be boolean
    }
}
function foo11(x: number | string | boolean) {
    // Mixing typeguard narrowing in if statement with conditional expression typeguard
    // Assigning value to x deep inside another guard stops narrowing of type too
    if (typeof x === "string") {
        return x; // string | number | boolean - x changed in else branch
    }
    else {
        var y: number| boolean | string;
        var b = x; // number | boolean | string - because below we are changing value of x in if statement
        return typeof x === "number"
            ? (
            // change value of x
            x = 10 && x.toString() // number | boolean | string
            )
            : (
            // do not change value
            y = x && x.toString() // number | boolean | string
            );
    }
}
function foo12(x: number | string | boolean) {
    // Mixing typeguard narrowing in if statement with conditional expression typeguard
    // Assigning value to x in outer guard shouldn't stop narrowing in the inner expression
    if (typeof x === "string") {
        return x.toString(); // string | number | boolean - x changed in else branch
    }
    else {
        x = 10;
        var b = x; // number | boolean | string
        return typeof x === "number"
            ? x.toString() // number
            : x.toString(); // boolean | string
    }
}`,
      [],
    );
  });
  test("typeGuardsInModule", async () => {
    await expectPass(
      `// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// variables in global
var num: number;
var strOrNum: string | number;
var var1: string | number;
// Inside module
namespace m1 {
    // global vars in function declaration
    num = typeof var1 === "string" && var1.length; // string

    // variables in module declaration
    var var2: string | number;
    if (typeof var2 === "string") {
        num = var2.length; // string
    }
    else {
        num = var2; // number
    }

    // exported variable in the module
    export var var3: string | number;
    if (typeof var3 === "string") {
        strOrNum = var3; // string | number
    }
    else {
        strOrNum = var3; // string | number
    }
}
// local module
namespace m2 {
    var var2: string | number;
    export var var3: string | number;
    namespace m3 {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // local variables from outer module declaration
        num = typeof var2 === "string" && var2.length; // string

        // exported variable from outer the module
        strOrNum = typeof var3 === "string" && var3; // string | number

        // variables in module declaration
        var var4: string | number;
        if (typeof var4 === "string") {
            num = var4.length; // string
        }
        else {
            num = var4; // number
        }

        // exported variable in the module
        export var var5: string | number;
        if (typeof var5 === "string") {
            strOrNum = var5; // string | number
        }
        else {
            strOrNum = var5; // string | number
        }
    }
}
// Dotted module
namespace m3.m4 {
    // global vars in function declaration
    num = typeof var1 === "string" && var1.length; // string

    // variables in module declaration
    var var2: string | number;
    if (typeof var2 === "string") {
        num = var2.length; // string
    }
    else {
        num = var2; // number
    }

    // exported variable in the module
    export var var3: string | number;
    if (typeof var3 === "string") {
        strOrNum = var3; // string | number
    }
    else {
        strOrNum = var3; // string | number
    }
}
`,
      [],
    );
  });
  test("typeGuardsInProperties", async () => {
    await expectPass(
      `
// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

var num: number;
var strOrNum: string | number;
class C1 {
    private pp1: string | number;
    pp2: string | number;
    // Inside public accessor getter
    get pp3() {
        return strOrNum;
    }
    method() {
        strOrNum = typeof this.pp1 === "string" && this.pp1; // string | number
        strOrNum = typeof this.pp2 === "string" && this.pp2; // string | number
        strOrNum = typeof this.pp3 === "string" && this.pp3; // string | number
    }
}
var c1: C1;
strOrNum = typeof c1.pp2 === "string" && c1.pp2; // string | number
strOrNum = typeof c1.pp3 === "string" && c1.pp3; // string | number
var obj1: {
    x: string | number;
};
strOrNum = typeof obj1.x === "string" && obj1.x;  // string | number`,
      [],
    );
  });
  test("typeGuardsInRightOperandOfAndAndOperator", async () => {
    await expectPass(
      `// In the right operand of a && operation, 
// the type of a variable or parameter is narrowed by any type guard in the left operand when true.
function foo(x: number | string) {
    return typeof x === "string" && x.length === 10; // string
}
function foo2(x: number | string) {
    // modify x in right hand operand
    return typeof x === "string" && ((x = 10) && x); // string | number
}
function foo3(x: number | string) {
    // modify x in right hand operand with string type itself
    return typeof x === "string" && ((x = "hello") && x); // string | number
}
function foo4(x: number | string | boolean) {
    return typeof x !== "string" // string | number | boolean
        && typeof x !== "number"  // number | boolean
        && x;   // boolean
}
function foo5(x: number | string | boolean) {
    // usage of x or assignment to separate variable shouldn't cause narrowing of type to stop
    var b: number | boolean;
    return typeof x !== "string" // string | number | boolean
        && ((b = x) && (typeof x !== "number"  // number | boolean
        && x));   // boolean
}
function foo6(x: number | string | boolean) {
    // Mixing typeguard narrowing in if statement with conditional expression typeguard
    return typeof x !== "string" // string | number | boolean
        && (typeof x !== "number" // number | boolean
        ? x // boolean
        : x === 10) // number 
}
function foo7(x: number | string | boolean) {
    var y: number| boolean | string;
    var z: number| boolean | string;
    // Mixing typeguard narrowing
    return typeof x !== "string"
        && ((z = x) // number | boolean
        && (typeof x === "number"
        // change value of x
        ? ((x = 10) && x.toString()) // x is number
        // do not change value
        : ((y = x) && x.toString()))); // x is boolean
}
`,
      [],
    );
  });
  test("typeGuardsInRightOperandOfOrOrOperator", async () => {
    await expectPass(
      `// In the right operand of a || operation, 
// the type of a variable or parameter is narrowed by any type guard in the left operand when false, 
// provided the right operand contains no assignments to the variable or parameter.
function foo(x: number | string) {
    return typeof x !== "string" || x.length === 10; // string
}
function foo2(x: number | string) {
    // modify x in right hand operand
    return typeof x !== "string" || ((x = 10) || x); // string | number
}
function foo3(x: number | string) {
    // modify x in right hand operand with string type itself
    return typeof x !== "string" || ((x = "hello") || x); // string | number
}
function foo4(x: number | string | boolean) {
    return typeof x === "string" // string | number | boolean
        || typeof x === "number"  // number | boolean
        || x;   // boolean
}
function foo5(x: number | string | boolean) {
    // usage of x or assignment to separate variable shouldn't cause narrowing of type to stop
    var b: number | boolean;
    return typeof x === "string" // string | number | boolean
        || ((b = x) || (typeof x === "number"  // number | boolean
        || x));   // boolean
}
function foo6(x: number | string | boolean) {
    // Mixing typeguard
    return typeof x === "string" // string | number | boolean
        || (typeof x !== "number" // number | boolean
        ? x // boolean
        : x === 10) // number 
}
function foo7(x: number | string | boolean) {
    var y: number| boolean | string;
    var z: number| boolean | string;
    // Mixing typeguard narrowing
    return typeof x === "string"
        || ((z = x) // number | boolean
        || (typeof x === "number"
        // change value of x
        ? ((x = 10) && x.toString()) // number | boolean | string
        // do not change value
        : ((y = x) && x.toString()))); // number | boolean | string
}
`,
      [],
    );
  });
  test("typeGuardsInWhileStatement", async () => {
    await expectPass(
      `let cond: boolean;
function a(x: string | number) {
    while (typeof x === "string") {
        x; // string
        x = undefined;
    }
    x; // number
}
function b(x: string | number) {
    while (typeof x === "string") {
        if (cond) continue;
        x; // string
        x = undefined;
    }
    x; // number
}
function c(x: string | number) {
    while (typeof x === "string") {
        if (cond) break;
        x; // string
        x = undefined;
    }
    x; // string | number
}`,
      [],
    );
  });
  test("typeGuardsObjectMethods", async () => {
    await expectPass(
      `
// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// variables in global
var num: number;
var strOrNum: string | number;
var var1: string | number;
var obj1 = {
    // Inside method
    method(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string

        return strOrNum;
    },
    get prop() {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        return strOrNum;
    },
    set prop(param: string | number) {
        // global vars in function declaration
        num = typeof var1 === "string" && var1.length; // string

        // variables in function declaration
        var var2: string | number;
        num = typeof var2 === "string" && var2.length; // string

        // parameters in function declaration
        num = typeof param === "string" && param.length; // string
    }
};
// return expression of the method
strOrNum = typeof obj1.method(strOrNum) === "string" && obj1.method(strOrNum); 

// accessing getter property
strOrNum = typeof obj1.prop === "string" && obj1.prop; `,
      [],
    );
  });
  test("typeGuardsOnClassProperty", async () => {
    await expectPass(
      `// @target: es2015
// Note that type guards affect types of variables and parameters only and 
// have no effect on members of objects such as properties. 

// Note that the class's property must be copied to a local variable for
// the type guard to have an effect
class D {
    data: string | string[];
    getData() {
        var data = this.data;
        return typeof data === "string" ? data : data.join(" ");
    }

    getData1() {
        return typeof this.data === "string" ? this.data : this.data.join(" ");
    }
}

var o: {
    prop1: number|string;
    prop2: boolean|string;
} = {
        prop1: "string" ,
        prop2: true
    }

if (typeof o.prop1 === "string" && o.prop1.toLowerCase()) {}
var prop1 = o.prop1;
if (typeof prop1 === "string" && prop1.toLocaleLowerCase()) { }`,
      [],
    );
  });
  test("typeGuardsWithAny", async () => {
    await expectPass(
      `var x: any = { p: 0 };

if (x instanceof Object) {
    x.p; // No error, type any unaffected by instanceof type guard
}
else {
    x.p; // No error, type any unaffected by instanceof type guard
}

if (typeof x === "string") {
    x.p; // Error, type any narrowed by primitive type check
}
else {
    x.p; // No error, type unaffected in this branch
}

if (typeof x === "number") {
    x.p; // Error, type any narrowed by primitive type check
}
else {
    x.p; // No error, type unaffected in this branch
}

if (typeof x === "boolean") {
    x.p; // Error, type any narrowed by primitive type check
}
else {
    x.p; // No error, type unaffected in this branch
}

if (typeof x === "object") {
    x.p; // No error, type any only affected by primitive type check
}
else {
    x.p; // No error, type unaffected in this branch
}
`,
      [],
    );
  });
  test("typeGuardsWithInstanceOf", async () => {
    await expectPass(
      `// @target: es2015

interface I { global: string; }
var result!: I;
var result2!: I;

if (!(result instanceof RegExp)) {
    result = result2;
} else if (!result.global) {
}

// Repro from #31155

interface OnChanges {
    onChanges(changes: Record<string, unknown>): void
}
interface Validator {
    validate(): null | Record<string, unknown>;
}

class C {
    validate() {
        return {}
    }
}

function foo() {
    let v: Validator & Partial<OnChanges> = null as any;
    if (v instanceof C) {
        v // Validator & Partial<OnChanges> & C
    }
    v // Validator & Partial<OnChanges> via subtype reduction

    // In 4.1, we introduced a change which _fixed_ a bug with CFA
    // correctly setting this to be the right object. With 4.2,
    // we reverted that fix in #42231 which brought behavior back to
    // before 4.1.
    if (v.onChanges) {
        v.onChanges({});
    }
}

`,
      [],
    );
  });
  test("typeGuardsWithInstanceOfByConstructorSignature", async () => {
    await expectPass(
      `interface AConstructor {
    new (): A;
}
interface A {
    foo: string;
}
declare var A: AConstructor;

declare var obj1: A | string;
if (obj1 instanceof A) { // narrowed to A.
    obj1.foo;
    obj1.bar;
}

declare var obj2: any;
if (obj2 instanceof A) {
    obj2.foo;
    obj2.bar;
}

// a construct signature with generics
interface BConstructor {
    new <T>(): B<T>;
}
interface B<T> {
    foo: T;
}
declare var B: BConstructor;

declare var obj3: B<number> | string;
if (obj3 instanceof B) { // narrowed to B<number>.
    obj3.foo = 1;
    obj3.foo = "str";
    obj3.bar = "str";
}

declare var obj4: any;
if (obj4 instanceof B) {
    obj4.foo = "str";
    obj4.foo = 1;
    obj4.bar = "str";
}

// has multiple construct signature
interface CConstructor {
    new (value: string): C1;
    new (value: number): C2;
}
interface C1 {
    foo: string;
    c: string;
    bar1: number;
}
interface C2 {
    foo: string;
    c: string;
    bar2: number;
}
declare var C: CConstructor;

declare var obj5: C1 | A;
if (obj5 instanceof C) { // narrowed to C1.
    obj5.foo;
    obj5.c;
    obj5.bar1;
    obj5.bar2;
}

declare var obj6: any;
if (obj6 instanceof C) {
    obj6.foo;
    obj6.bar1;
    obj6.bar2;
}

// with object type literal
interface D {
    foo: string;
}
declare var D: { new (): D; };

declare var obj7: D | string;
if (obj7 instanceof D) { // narrowed to D.
    obj7.foo;
    obj7.bar;
}

declare var obj8: any;
if (obj8 instanceof D) {
    obj8.foo;
    obj8.bar;
}

// a construct signature that returns a union type
interface EConstructor {
    new (): E1 | E2;
}
interface E1 {
    foo: string;
    bar1: number;
}
interface E2 {
    foo: string;
    bar2: number;
}
declare var E: EConstructor;

declare var obj9: E1 | A;
if (obj9 instanceof E) { // narrowed to E1
    obj9.foo;
    obj9.bar1;
    obj9.bar2;
}

declare var obj10: any;
if (obj10 instanceof E) {
    obj10.foo;
    obj10.bar1;
    obj10.bar2;
}

// a construct signature that returns any
interface FConstructor {
    new (): any;
}
interface F {
    foo: string;
    bar: number;
}
declare var F: FConstructor;

declare var obj11: F | string;
if (obj11 instanceof F) { // can't type narrowing, construct signature returns any.
    obj11.foo;
    obj11.bar;
}

declare var obj12: any;
if (obj12 instanceof F) {
    obj12.foo;
    obj12.bar;
}

// a type with a prototype, it overrides the construct signature
interface GConstructor {
    prototype: G1; // high priority
    new (): G2;    // low priority
}
interface G1 {
    foo1: number;
}
interface G2 {
    foo2: boolean;
}
declare var G: GConstructor;

declare var obj13: G1 | G2;
if (obj13 instanceof G) { // narrowed to G1. G1 is return type of prototype property.
    obj13.foo1;
    obj13.foo2;
}

declare var obj14: any;
if (obj14 instanceof G) {
    obj14.foo1;
    obj14.foo2;
}

// a type with a prototype that has any type
interface HConstructor {
    prototype: any; // high priority, but any type is ignored. interface has implicit \`prototype: any\`.
    new (): H;      // low priority
}
interface H {
    foo: number;
}
declare var H: HConstructor;

declare var obj15: H | string;
if (obj15 instanceof H) { // narrowed to H.
    obj15.foo;
    obj15.bar;
}

declare var obj16: any;
if (obj16 instanceof H) {
    obj16.foo1;
    obj16.foo2;
}

declare var obj17: any;
if (obj17 instanceof Object) { // can't narrow type from 'any' to 'Object'
    obj17.foo1;
    obj17.foo2;
}

declare var obj18: any;
if (obj18 instanceof Function) { // can't narrow type from 'any' to 'Function'
    obj18.foo1;
    obj18.foo2;
}`,
      [],
    );
  });
  test("typeGuardsWithInstanceOfBySymbolHasInstance", async () => {
    await expectError(
      `
interface AConstructor {
    new (): A;
    [Symbol.hasInstance](value: unknown): value is A;
}
interface A {
    foo: string;
}
declare var A: AConstructor;

declare var obj1: A | string;
if (obj1 instanceof A) { // narrowed to A.
    obj1.foo;
    obj1.bar;
}

declare var obj2: any;
if (obj2 instanceof A) {
    obj2.foo;
    obj2.bar;
}

// a construct signature with generics
interface BConstructor {
    new <T>(): B<T>;
    [Symbol.hasInstance](value: unknown): value is B<any>;
}
interface B<T> {
    foo: T;
}
declare var B: BConstructor;

declare var obj3: B<number> | string;
if (obj3 instanceof B) { // narrowed to B<number>.
    obj3.foo = 1;
    obj3.foo = "str";
    obj3.bar = "str";
}

declare var obj4: any;
if (obj4 instanceof B) {
    obj4.foo = "str";
    obj4.foo = 1;
    obj4.bar = "str";
}

// has multiple construct signature
interface CConstructor {
    new (value: string): C1;
    new (value: number): C2;
    [Symbol.hasInstance](value: unknown): value is C1 | C2;
}
interface C1 {
    foo: string;
    c: string;
    bar1: number;
}
interface C2 {
    foo: string;
    c: string;
    bar2: number;
}
declare var C: CConstructor;

declare var obj5: C1 | A;
if (obj5 instanceof C) { // narrowed to C1.
    obj5.foo;
    obj5.c;
    obj5.bar1;
    obj5.bar2;
}

declare var obj6: any;
if (obj6 instanceof C) {
    obj6.foo;
    obj6.bar1;
    obj6.bar2;
}

// with object type literal
interface D {
    foo: string;
}
declare var D: {
    new (): D;
    [Symbol.hasInstance](value: unknown): value is D;
};

declare var obj7: D | string;
if (obj7 instanceof D) { // narrowed to D.
    obj7.foo;
    obj7.bar;
}

declare var obj8: any;
if (obj8 instanceof D) {
    obj8.foo;
    obj8.bar;
}

// a construct signature that returns a union type
interface EConstructor {
    new (): E1 | E2;
    [Symbol.hasInstance](value: unknown): value is E1 | E2;
}
interface E1 {
    foo: string;
    bar1: number;
}
interface E2 {
    foo: string;
    bar2: number;
}
declare var E: EConstructor;

declare var obj9: E1 | A;
if (obj9 instanceof E) { // narrowed to E1
    obj9.foo;
    obj9.bar1;
    obj9.bar2;
}

declare var obj10: any;
if (obj10 instanceof E) {
    obj10.foo;
    obj10.bar1;
    obj10.bar2;
}

// a construct signature that returns any
interface FConstructor {
    new (): any;
    [Symbol.hasInstance](value: unknown): value is any;
}
interface F {
    foo: string;
    bar: number;
}
declare var F: FConstructor;

declare var obj11: F | string;
if (obj11 instanceof F) { // can't type narrowing, construct signature returns any.
    obj11.foo;
    obj11.bar;
}

declare var obj12: any;
if (obj12 instanceof F) {
    obj12.foo;
    obj12.bar;
}

// a type with a prototype, it overrides the construct signature
interface GConstructor {
    prototype: G1; // high priority
    new (): G2;    // low priority
    [Symbol.hasInstance](value: unknown): value is G1; // overrides priority
}
interface G1 {
    foo1: number;
}
interface G2 {
    foo2: boolean;
}
declare var G: GConstructor;

declare var obj13: G1 | G2;
if (obj13 instanceof G) { // narrowed to G1. G1 is return type of prototype property.
    obj13.foo1;
    obj13.foo2;
}

declare var obj14: any;
if (obj14 instanceof G) {
    obj14.foo1;
    obj14.foo2;
}

// a type with a prototype that has any type
interface HConstructor {
    prototype: any; // high priority, but any type is ignored. interface has implicit \`prototype: any\`.
    new (): H;      // low priority
    [Symbol.hasInstance](value: unknown): value is H; // overrides priority
}
interface H {
    foo: number;
}
declare var H: HConstructor;

declare var obj15: H | string;
if (obj15 instanceof H) { // narrowed to H.
    obj15.foo;
    obj15.bar;
}

declare var obj16: any;
if (obj16 instanceof H) {
    obj16.foo1;
    obj16.foo2;
}

declare var obj17: any;
if (obj17 instanceof Object) { // can't narrow type from 'any' to 'Object'
    obj17.foo1;
    obj17.foo2;
}

declare var obj18: any;
if (obj18 instanceof Function) { // can't narrow type from 'any' to 'Function'
    obj18.foo1;
    obj18.foo2;
}`,
      [],
    );
  });
  test("typeGuardTautologicalConsistiency", async () => {
    await expectPass(
      `let stringOrNumber: string | number;

if (typeof stringOrNumber === "number") {
    if (typeof stringOrNumber !== "number") {
        stringOrNumber;
    }
}

if (typeof stringOrNumber === "number" && typeof stringOrNumber !== "number") {
    stringOrNumber;
}
`,
      [],
    );
  });
  test("typeGuardTypeOfUndefined", async () => {
    await expectPass(
      `// undefined type guard adds no new type information
function test1(a: any) {
    if (typeof a !== "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test2(a: any) {
    if (typeof a === "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test3(a: any) {
    if (typeof a === "undefined" || typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test4(a: any) {
    if (typeof a !== "undefined" && typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test5(a: boolean | void) {
    if (typeof a !== "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test6(a: boolean | void) {
    if (typeof a === "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test7(a: boolean | void) {
    if (typeof a === "undefined" || typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test8(a: boolean | void) {
    if (typeof a !== "undefined" && typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test9(a: boolean | number) {
    if (typeof a !== "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test10(a: boolean | number) {
    if (typeof a === "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test11(a: boolean | number) {
    if (typeof a === "undefined" || typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test12(a: boolean | number) {
    if (typeof a !== "undefined" && typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test13(a: boolean | number | void) {
    if (typeof a !== "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test14(a: boolean | number | void) {
    if (typeof a === "undefined") {
        if (typeof a === "boolean") {
            a;
        }
        else {
            a;
        }
    }
    else {
        a;
    }
}

function test15(a: boolean | number | void) {
    if (typeof a === "undefined" || typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}

function test16(a: boolean | number | void) {
    if (typeof a !== "undefined" && typeof a === "boolean") {
		a;
    }
    else {
        a;
    }
}
`,
      [],
    );
  });
  test("TypeGuardWithArrayUnion", async () => {
    await expectPass(
      `class Message {
    value: string;
}

function saySize(message: Message | Message[]) {
    if (message instanceof Array) {
        return message.length;  // Should have type Message[] here
    }
}
`,
      [],
    );
  });
  test("TypeGuardWithEnumUnion", async () => {
    await expectPass(
      `enum Color { R, G, B }

function f1(x: Color | string) {
    if (typeof x === "number") {
        var y = x;
        var y: Color;
    }
    else {
        var z = x;
        var z: string;
    }
}

function f2(x: Color | string | string[]) {
    if (typeof x === "object") {
        var y = x;
        var y: string[];
    }
    if (typeof x === "number") {
        var z = x;
        var z: Color;
    }
    else {
        var w = x;
        var w: string | string[];
    }
    if (typeof x === "string") {
        var a = x;
        var a: string;
    }
    else {
        var b = x;
        var b: Color | string[];
    }
}
`,
      [],
    );
  });
  test("typePredicateASI", async () => {
    await expectPass(
      `interface I {
    foo(callback: (a: any, b: any) => void): I
    is(): boolean;
}`,
      [],
    );
  });
  test("typePredicateOnVariableDeclaration01", async () => {
    await expectError(
      `
var x: this is string;`,
      [],
    );
  });
  test("typePredicateOnVariableDeclaration02", async () => {
    await expectError(
      `
var y: z is number;`,
      [],
    );
  });
  test("typeSatisfaction_asConstArrays", async () => {
    await expectPass(
      `
// with readonly array
const arr1 = [1, 2, 3] as const satisfies readonly unknown[]

// with mutable array
const arr2 = [1, 2, 3] as const satisfies unknown[]`,
      [],
    );
  });
  test("typeSatisfaction_contextualTyping1", async () => {
    await expectPass(
      `type Predicates = { [s: string]: (n: number) => boolean };

const p = {
    isEven: n => n % 2 === 0,
    isOdd: n => n % 2 === 1
} satisfies Predicates;`,
      [],
    );
  });
  test("typeSatisfaction_contextualTyping2", async () => {
    await expectPass(
      `
let obj: { f(s: string): void } & Record<string, unknown> = {
    f(s) { }, // "incorrect" implicit any on 's'
    g(s) { }
} satisfies { g(s: string): void } & Record<string, unknown>;

// This needs to not crash (outer node is not expression)
({ f(x) { } }) satisfies { f(s: string): void };`,
      [],
    );
  });
  test("typeSatisfaction_contextualTyping3", async () => {
    await expectPass(
      `
// see https://github.com/microsoft/TypeScript/issues/53920#issuecomment-1516616255

const obj = {
   foo: (param = "default") => param,
} satisfies {
   [key: string]: (...params: any) => any;
};

const obj2 = {
   foo: (param = "default") => param,
} satisfies {
   [key: string]: Function;
};

type StringOrNumberFunc = (x: string | number) => any;

const fn = ((x = "ok") => null) satisfies StringOrNumberFunc;
fn();
fn(32);`,
      [],
    );
  });
  test("typeSatisfaction_ensureInterfaceImpl", async () => {
    await expectPass(
      `type Movable = {
    move(distance: number): void;
};

const car = {
    start() { },
    move(d) {
        // d should be number
    },
    stop() { }
} satisfies Movable & Record<string, unknown>;`,
      [],
    );
  });
  test("typeSatisfaction_errorLocations1", async () => {
    await expectPass(
      `
const obj1 = { a: 1 };

const fn1 = (s: { a: true }) => {};
fn1({} satisfies unknown);
fn1({ a: 1 } satisfies unknown);
fn1(obj1 satisfies unknown);

class Cls1 {
  constructor(p: { a: true }) {}
}
new Cls1({} satisfies unknown);
new Cls1({ a: 1 } satisfies unknown);
new Cls1(obj1 satisfies unknown);

function fn2<T extends { a: true }[]>(f: (...args: T) => void) {
  f({ a: true } satisfies unknown);
  const o = { a: true as const };
  f(o satisfies unknown);
}

const tuple1: [boolean, boolean] = [true, 100 satisfies unknown];

const obj2 = { a: 10, b: true } satisfies Record<string, number>;

const literal1 = 1 satisfies boolean;
const literal2: true = 1 satisfies number;

declare function fn3(...args: unknown[]): void;
fn3(10, ...([10, "20"] satisfies number[]));
const tuple2 = [10, "20"] as const;
fn3(10, ...(tuple2 satisfies number[]));

declare function fn4(...args: number[]): void;
fn4(10, ...(["10", "20"] satisfies readonly string[]));
const tuple3 = ["10", "20"] as const;
fn4(10, ...(tuple3 satisfies readonly string[]));

function fn5(): number {
  return "foo" satisfies unknown;
}

function fn6(): number {
  return "foo" satisfies number;
}

((): { a: true } => ({}) satisfies unknown)();
((): { a: true } => ({ a: 1 }) satisfies unknown)();
((): { a: true } => obj1 satisfies unknown)();

((): { a: true } => (({}) satisfies unknown) satisfies unknown)();
((): { a: true } => ((({}) satisfies unknown)) satisfies unknown)();`,
      [],
    );
  });
  test("typeSatisfaction_js", async () => {
    await expectPass(
      `
var v = undefined satisfies 1;`,
      [],
    );
  });
  test("typeSatisfaction_optionalMemberConformance", async () => {
    await expectPass(
      `type Point2d = { x: number, y: number };
// Undesirable behavior today with type annotation
const a = { x: 10 } satisfies Partial<Point2d>;
// Should OK
console.log(a.x.toFixed());
// Should error
let p = a.y;`,
      [],
    );
  });
  test("typeSatisfaction_propertyNameFulfillment", async () => {
    await expectPass(
      `type Keys = 'a' | 'b' | 'c' | 'd';

const p = {
    a: 0,
    b: "hello",
    x: 8 // Should error, 'x' isn't in 'Keys'
} satisfies Record<Keys, unknown>;

// Should be OK -- retain info that a is number and b is string
let a = p.a.toFixed();
let b = p.b.substring(1);
// Should error even though 'd' is in 'Keys'
let d = p.d;`,
      [],
    );
  });
  test("typeSatisfaction_propertyValueConformance1", async () => {
    await expectPass(
      `
type Facts = { [key: string]: boolean };
declare function checkTruths(x: Facts): void;
declare function checkM(x: { m: boolean }): void;
const x = {
    m: true
};

// Should be OK
checkTruths(x);
// Should be OK
checkM(x);
// Should fail under --noPropertyAccessFromIndexSignature
console.log(x.z);
const m: boolean = x.m;

// Should be 'm'
type M = keyof typeof x;

// Should be able to detect a failure here
const x2 = {
    m: true,
    s: "false"
} satisfies Facts;`,
      [],
    );
  });
  test("typeSatisfaction_propertyValueConformance2", async () => {
    await expectPass(
      `
type Facts = { [key: string]: boolean };
declare function checkTruths(x: Facts): void;
declare function checkM(x: { m: boolean }): void;
const x = {
    m: true
};

// Should be OK
checkTruths(x);
// Should be OK
checkM(x);
console.log(x.z);
// Should be OK under --noUncheckedIndexedAccess
const m: boolean = x.m;

// Should be 'm'
type M = keyof typeof x;

// Should be able to detect a failure here
const x2 = {
    m: true,
    s: "false"
} satisfies Facts;`,
      [],
    );
  });
  test("typeSatisfaction_propertyValueConformance3", async () => {
    await expectPass(
      `export type Color = { r: number, g: number, b: number };

// All of these should be Colors, but I only use some of them here.
export const Palette = {
    white: { r: 255, g: 255, b: 255 },
    black: { r: 0, g: 0, d: 0 }, // <- oops! 'd' in place of 'b'
    blue: { r: 0, g: 0, b: 255 },
} satisfies Record<string, Color>;`,
      [],
    );
  });
  test("typeSatisfaction_propNameConstraining", async () => {
    await expectPass(
      `type Keys = 'a' | 'b' | 'c' | 'd';

const p = {
    a: 0,
    b: "hello",
    x: 8 // Should error, 'x' isn't in 'Keys'
} satisfies Partial<Record<Keys, unknown>>;

// Should be OK -- retain info that a is number and b is string
let a = p.a.toFixed();
let b = p.b.substring(1);
// Should error even though 'd' is in 'Keys'
let d = p.d;`,
      [],
    );
  });
  test("typeSatisfaction_vacuousIntersectionOfContextualTypes", async () => {
    await expectPass(
      `const a: "baz" = "foo" satisfies "foo" | "bar";
const b: { xyz: "baz" } = { xyz: "foo" } satisfies { xyz: "foo" | "bar" };`,
      [],
    );
  });
  test("typeSatisfaction", async () => {
    await expectPass(
      `interface I1 {
    a: number;
}

type T1 = {
    a: "a" | "b";
}

type T2 = (x: string) => void;

const t1 = { a: 1 } satisfies I1; // Ok
const t2 = { a: 1, b: 1 } satisfies I1; // Error
const t3 = { } satisfies I1; // Error

const t4: T1 = { a: "a" } satisfies T1; // Ok
const t5 = (m => m.substring(0)) satisfies T2; // Ok

const t6 = [1, 2] satisfies [number, number];

interface A {
    a: string
}
let t7 = { a: 'test' } satisfies A;
let t8 = { a: 'test', b: 'test' } satisfies A;`,
      [],
    );
  });
  test("typeSatisfactionWithDefaultExport", async () => {
    await expectPass(
      `
interface Foo {
    a: number;
}
export default {} satisfies Foo;

interface Foo {
    a: number;
}
export default { a: 1 } satisfies Foo;`,
      [],
    );
  });
  test("bitwiseNotOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator ~
var q;

// operand before ~
var a = q~;  //expect error

// multiple operands after ~
var mul = ~[1, 2, "abc"], "";  //expect error

// miss an operand
var b =~;`,
      [],
    );
  });
  test("bitwiseNotOperatorWithAnyOtherType", async () => {
    await expectPass(
      `
// ~ operator on any type

declare var ANY: any;
declare var ANY1;
declare var ANY2: any[];
declare var obj: () => {};
declare var obj1: { x:"", y: () => { }};

function foo(): any {
    var a;
    return a;
}
class A {
    public a: any;
    static foo() {
        var a;
        return a;
    }
}
namespace M {
    export declare var n: any;
}
declare var objA: A;

// any other type var
var ResultIsNumber = ~ANY1;
var ResultIsNumber1 = ~ANY2;
var ResultIsNumber2 = ~A;
var ResultIsNumber3 = ~M;
var ResultIsNumber4 = ~obj;
var ResultIsNumber5 = ~obj1;

// any type literal
var ResultIsNumber6 = ~undefined;
var ResultIsNumber7 = ~null;

// any type expressions
var ResultIsNumber8 = ~ANY2[0]
var ResultIsNumber9 = ~obj1.x;
var ResultIsNumber10 = ~obj1.y;
var ResultIsNumber11 = ~objA.a;
var ResultIsNumber12 = ~M.n;
var ResultIsNumber13 = ~foo();
var ResultIsNumber14 = ~A.foo();
var ResultIsNumber15 = ~(ANY + ANY1);
var ResultIsNumber16 = ~(null + undefined);
var ResultIsNumber17 = ~(null + null);
var ResultIsNumber18 = ~(undefined + undefined);

// multiple ~ operators
var ResultIsNumber19 = ~~ANY;
var ResultIsNumber20 = ~~~(ANY + ANY1);

//miss assignment operators
~ANY;
~ANY1;
~ANY2[0];
~ANY, ANY1;
~obj1.y;
~objA.a;
~M.n;
~~obj1.x;`,
      [],
    );
  });
  test("bitwiseNotOperatorWithBooleanType", async () => {
    await expectPass(
      `
// ~ operator on boolean type
var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a: boolean;
    static foo() { return false; }
}
namespace M {
    export var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsNumber1 = ~BOOLEAN;

// boolean type literal
var ResultIsNumber2 = ~true;
var ResultIsNumber3 = ~{ x: true, y: false };

// boolean type expressions
var ResultIsNumber4 = ~objA.a;
var ResultIsNumber5 = ~M.n;
var ResultIsNumber6 = ~foo();
var ResultIsNumber7 = ~A.foo();

// multiple ~ operators
var ResultIsNumber8 = ~~BOOLEAN;

// miss assignment operators
~true;
~BOOLEAN;
~foo();
~true, false;
~objA.a;
~M.n;`,
      [],
    );
  });
  test("bitwiseNotOperatorWithEnumType", async () => {
    await expectPass(
      `
// ~ operator on enum type

enum ENUM1 { A, B, "" };

// enum type var
var ResultIsNumber1 = ~ENUM1;

// enum type expressions
var ResultIsNumber2 = ~ENUM1["A"];
var ResultIsNumber3 = ~(ENUM1.A + ENUM1["B"]);

// multiple ~ operators
var ResultIsNumber4 = ~~~(ENUM1["A"] + ENUM1.B);

// miss assignment operators
~ENUM1;
~ENUM1["A"];
~ENUM1.A, ~ENUM1["B"];`,
      [],
    );
  });
  test("bitwiseNotOperatorWithNumberType", async () => {
    await expectPass(
      `
// ~ operator on number type
var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a: number;
    static foo() { return 1; }
}
namespace M {
    export var n: number;
}

var objA = new A();

// number type var
var ResultIsNumber1 = ~NUMBER;
var ResultIsNumber2 = ~NUMBER1;

// number type literal
var ResultIsNumber3 = ~1;
var ResultIsNumber4 = ~{ x: 1, y: 2};
var ResultIsNumber5 = ~{ x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsNumber6 = ~objA.a;
var ResultIsNumber7 = ~M.n;
var ResultIsNumber8 = ~NUMBER1[0];
var ResultIsNumber9 = ~foo();
var ResultIsNumber10 = ~A.foo();
var ResultIsNumber11 = ~(NUMBER + NUMBER);

// multiple ~ operators
var ResultIsNumber12 = ~~NUMBER;
var ResultIsNumber13 = ~~~(NUMBER + NUMBER);

// miss assignment operators
~NUMBER;
~NUMBER1;
~foo();
~objA.a;
~M.n;
~objA.a, M.n;`,
      [],
    );
  });
  test("bitwiseNotOperatorWithStringType", async () => {
    await expectPass(
      `
// ~ operator on string type
var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string;
}

var objA = new A();

// string type var
var ResultIsNumber1 = ~STRING;
var ResultIsNumber2 = ~STRING1;

// string type literal
var ResultIsNumber3 = ~"";
var ResultIsNumber4 = ~{ x: "", y: "" };
var ResultIsNumber5 = ~{ x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsNumber6 = ~objA.a;
var ResultIsNumber7 = ~M.n;
var ResultIsNumber8 = ~STRING1[0];
var ResultIsNumber9 = ~foo();
var ResultIsNumber10 = ~A.foo();
var ResultIsNumber11 = ~(STRING + STRING);
var ResultIsNumber12 = ~STRING.charAt(0);

// multiple ~ operators
var ResultIsNumber13 = ~~STRING;
var ResultIsNumber14 = ~~~(STRING + STRING);

//miss assignment operators
~STRING;
~STRING1;
~foo();
~objA.a,M.n;`,
      [],
    );
  });
  test("decrementOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// -- operator on any type

var ANY: any;
var ANY1: any;
var ANY2: any[] = ["", ""];
var obj = {x:1,y:null};
class A {
    public a: any;
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsNumber1 = --ANY;
var ResultIsNumber2 = --ANY1;

var ResultIsNumber3 = ANY1--;
var ResultIsNumber4 = ANY1--;

// expressions
var ResultIsNumber5 = --ANY2[0];
var ResultIsNumber6 = --obj.x;
var ResultIsNumber7 = --obj.y;
var ResultIsNumber8 = --objA.a;
var ResultIsNumber = --M.n;

var ResultIsNumber9 = ANY2[0]--;
var ResultIsNumber10 = obj.x--;
var ResultIsNumber11 = obj.y--;
var ResultIsNumber12 = objA.a--;
var ResultIsNumber13 = M.n--;

// miss assignment opertors
--ANY;
--ANY1;
--ANY2[0];
--ANY, --ANY1;
--objA.a;
--M.n;

ANY--;
ANY1--;
ANY2[0]--;
ANY--, ANY1--;
objA.a--;
M.n--;`,
      [],
    );
  });
  test("decrementOperatorWithAnyOtherTypeInvalidOperations", async () => {
    await expectError(
      `// -- operator on any type
declare var ANY1: any;
var ANY2: any[] = ["", ""];

declare var obj: () => {}
var obj1 = { x: "", y: () => { } };
function foo(): any {
    var a;
    return a;
}
class A {
    public a: any;
    static foo(): any {
        var a;
        return a;
    }
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsNumber1 = --ANY2;
var ResultIsNumber2 = --A;
var ResultIsNumber3 = --M;
var ResultIsNumber4 = --obj;
var ResultIsNumber5 = --obj1;

var ResultIsNumber6 = ANY2--;
var ResultIsNumber7 = A--;
var ResultIsNumber8 = M--;
var ResultIsNumber9 = obj--;
var ResultIsNumber10 = obj1--;

// any type literal
var ResultIsNumber11 = --{};
var ResultIsNumber12 = --null;
var ResultIsNumber13 = --undefined;

var ResultIsNumber14 = null--;
var ResultIsNumber15 = {}--;
var ResultIsNumber16 = undefined--;

// any type expressions
var ResultIsNumber17 = --foo();
var ResultIsNumber18 = --A.foo();
var ResultIsNumber19 = --(null + undefined);
var ResultIsNumber20 = --(null + null);
var ResultIsNumber21 = --(undefined + undefined);
var ResultIsNumber22 = --obj1.x;
var ResultIsNumber23 = --obj1.y;

var ResultIsNumber24 = foo()--;
var ResultIsNumber25 = A.foo()--;
var ResultIsNumber26 = (null + undefined)--;
var ResultIsNumber27 = (null + null)--;
var ResultIsNumber28 = (undefined + undefined)--;
var ResultIsNumber29 = obj1.x--;
var ResultIsNumber30 = obj1.y--;

// miss assignment operators
--ANY2;

ANY2--;

--ANY1--;
--ANY1++;
++ANY1--;
--ANY2[0]--;
--ANY2[0]++;
++ANY2[0]--;`,
      [],
    );
  });
  test("decrementOperatorWithEnumType", async () => {
    await expectPass(
      `// -- operator on enum type

enum ENUM1 { A, B, "" };

// expression
var ResultIsNumber1 = --ENUM1["A"];
var ResultIsNumber2 = ENUM1.A--;

// miss assignment operator
--ENUM1["A"];

ENUM1[A]--;`,
      [],
    );
  });
  test("decrementOperatorWithEnumTypeInvalidOperations", async () => {
    await expectError(
      `// -- operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsNumber1 = --ENUM;
var ResultIsNumber2 = --ENUM1;

var ResultIsNumber3 = ENUM--;
var ResultIsNumber4 = ENUM1--;

// enum type expressions
var ResultIsNumber5 = --(ENUM["A"] + ENUM.B);
var ResultIsNumber6 = (ENUM.A + ENUM["B"])--;

// miss assignment operator
--ENUM;
--ENUM1;

ENUM--;
ENUM1--;`,
      [],
    );
  });
  test("decrementOperatorWithNumberType", async () => {
    await expectPass(
      `// -- operator on number type
var NUMBER: number;
var NUMBER1: number[] = [1, 2];

class A {
    public a: number;
}
namespace M {
    export var n: number;
}

var objA = new A();

// number type var
var ResultIsNumber1 = --NUMBER;

var ResultIsNumber2 = NUMBER--;

// expressions
var ResultIsNumber3 = --objA.a;
var ResultIsNumber4 = --M.n;

var ResultIsNumber5 = objA.a--;
var ResultIsNumber6 = M.n--;
var ResultIsNumber7 = NUMBER1[0]--;

// miss assignment operators
--NUMBER;

--NUMBER1[0];
--objA.a;
--M.n;
--objA.a, M.n;

NUMBER--;
NUMBER1[0]--;
objA.a--;
M.n--;
objA.a--, M.n--;`,
      [],
    );
  });
  test("decrementOperatorWithNumberTypeInvalidOperations", async () => {
    await expectError(
      `// -- operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a: number;
    static foo() { return 1; }
}
namespace M {
    export var n: number;
}

var objA = new A();

//number type var
var ResultIsNumber1 = --NUMBER1;
var ResultIsNumber2 = NUMBER1--;

// number type literal
var ResultIsNumber3 = --1;
var ResultIsNumber4 = --{ x: 1, y: 2};
var ResultIsNumber5 = --{ x: 1, y: (n: number) => { return n; } };

var ResultIsNumber6 = 1--;
var ResultIsNumber7 = { x: 1, y: 2 }--;
var ResultIsNumber8 = { x: 1, y: (n: number) => { return n; } }--;

// number type expressions
var ResultIsNumber9 = --foo();
var ResultIsNumber10 = --A.foo();
var ResultIsNumber11 = --(NUMBER + NUMBER);

var ResultIsNumber12 = foo()--;
var ResultIsNumber13 = A.foo()--;
var ResultIsNumber14 = (NUMBER + NUMBER)--;

// miss assignment operator
--1;
--NUMBER1;
--foo();

1--;
NUMBER1--;
foo()--;`,
      [],
    );
  });
  test("decrementOperatorWithUnsupportedBooleanType", async () => {
    await expectError(
      `// -- operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a: boolean;
    static foo() { return true; }
}
namespace M {
    export var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsNumber1 = --BOOLEAN;

var ResultIsNumber2 = BOOLEAN--;

// boolean type literal
var ResultIsNumber3 = --true;
var ResultIsNumber4 = --{ x: true, y: false };
var ResultIsNumber5 = --{ x: true, y: (n: boolean) => { return n; } };

var ResultIsNumber6 = true--;
var ResultIsNumber7 = { x: true, y: false }--;
var ResultIsNumber8 = { x: true, y: (n: boolean) => { return n; } }--;

// boolean type expressions
var ResultIsNumber9 = --objA.a;
var ResultIsNumber10 = --M.n;
var ResultIsNumber11 = --foo();
var ResultIsNumber12 = --A.foo();

var ResultIsNumber13 = foo()--;
var ResultIsNumber14 = A.foo()--;
var ResultIsNumber15 = objA.a--;
var ResultIsNumber16 = M.n--;

// miss assignment operators
--true;
--BOOLEAN;
--foo();
--objA.a;
--M.n;
--objA.a, M.n;

true--;
BOOLEAN--;
foo()--;
objA.a--;
M.n--;
objA.a--, M.n--;`,
      [],
    );
  });
  test("decrementOperatorWithUnsupportedStringType", async () => {
    await expectError(
      `// -- operator on string type
declare var STRING: string;
var STRING1: string[] = ["", ""];

function foo(): string { return ""; }

class A {
    public a: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string;
}

var objA = new A();

// string type var
var ResultIsNumber1 = --STRING;
var ResultIsNumber2 = --STRING1;

var ResultIsNumber3 = STRING--;
var ResultIsNumber4 = STRING1--;

// string type literal
var ResultIsNumber5 = --"";
var ResultIsNumber6 = --{ x: "", y: "" };
var ResultIsNumber7 = --{ x: "", y: (s: string) => { return s; } };

var ResultIsNumber8 = ""--;
var ResultIsNumber9 = { x: "", y: "" }--;
var ResultIsNumber10 = { x: "", y: (s: string) => { return s; } }--;

// string type expressions
var ResultIsNumber11 = --objA.a;
var ResultIsNumber12 = --M.n;
var ResultIsNumber13 = --STRING1[0];
var ResultIsNumber14 = --foo();
var ResultIsNumber15 = --A.foo();
var ResultIsNumber16 = --(STRING + STRING);

var ResultIsNumber17 = objA.a--;
var ResultIsNumber18 = M.n--;
var ResultIsNumber19 = STRING1[0]--;
var ResultIsNumber20 = foo()--;
var ResultIsNumber21 = A.foo()--;
var ResultIsNumber22 = (STRING + STRING)--;

// miss assignment operators
--"";
--STRING;
--STRING1;
--STRING1[0];
--foo();
--objA.a;
--M.n;
--objA.a, M.n;

""--;
STRING--;
STRING1--;
STRING1[0]--;
foo()--;
objA.a--;
M.n--;
objA.a--, M.n--;`,
      [],
    );
  });
  test("deleteOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator delete
var ANY;

// operand before delete operator
var BOOLEAN1 = ANY delete ;     //expect error

// miss an operand
var BOOLEAN2 = delete ;

// delete global variable s
class testADelx {
    constructor(public s: () => {}) {
        delete s;      //expect error
    }
}`,
      [],
    );
  });
  test("deleteOperatorWithAnyOtherType", async () => {
    await expectError(
      `// delete  operator on any type

declare var ANY: any;
declare var ANY1;
var ANY2: any[] = ["", ""];
declare var obj: () => {};
var obj1 = { x: "", y: () => { }};
function foo(): any {
    var a;
    return a;
}
class A {
    public a: any;
    static foo() {
        var a;
        return a;
    }
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsBoolean1 = delete ANY1;
var ResultIsBoolean2 = delete ANY2;
var ResultIsBoolean3 = delete A;
var ResultIsBoolean4 = delete M;
var ResultIsBoolean5 = delete obj;
var ResultIsBoolean6 = delete obj1;

// any type literal
var ResultIsBoolean7 = delete undefined;
var ResultIsBoolean8 = delete null;

// any type expressions
var ResultIsBoolean9 = delete ANY2[0];
var ResultIsBoolean10 = delete obj1.x;
var ResultIsBoolean11 = delete obj1.y;
var ResultIsBoolean12 = delete objA.a;
var ResultIsBoolean13 = delete M.n;
var ResultIsBoolean14 = delete foo();
var ResultIsBoolean15 = delete A.foo();
var ResultIsBoolean16 = delete (ANY + ANY1);
var ResultIsBoolean17 = delete (null + undefined);
var ResultIsBoolean18 = delete (null + null);
var ResultIsBoolean19 = delete (undefined + undefined);

// multiple delete  operators
var ResultIsBoolean20 = delete delete ANY;
var ResultIsBoolean21 = delete delete delete (ANY + ANY1);

// miss assignment operators
delete ANY;
delete ANY1;
delete ANY2[0];
delete ANY, ANY1;
delete obj1.x;
delete obj1.y;
delete objA.a;
delete M.n;`,
      [],
    );
  });
  test("deleteOperatorWithBooleanType", async () => {
    await expectError(
      `// delete  operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a: boolean;
    static foo() { return false; }
}
namespace M {
    export var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsBoolean1 = delete BOOLEAN;

// boolean type literal
var ResultIsBoolean2 = delete true;
var ResultIsBoolean3 = delete { x: true, y: false };

// boolean type expressions
var ResultIsBoolean4 = delete objA.a;
var ResultIsBoolean5 = delete M.n;
var ResultIsBoolean6 = delete foo();
var ResultIsBoolean7 = delete A.foo();

// multiple delete  operator
var ResultIsBoolean8 = delete delete BOOLEAN;

// miss assignment operators
delete true;
delete BOOLEAN;
delete foo();
delete true, false;
delete objA.a;
delete M.n;`,
      [],
    );
  });
  test("deleteOperatorWithEnumType", async () => {
    await expectError(
      `// delete  operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsBoolean1 = delete ENUM;
var ResultIsBoolean2 = delete ENUM1;

// enum type expressions
var ResultIsBoolean3 = delete ENUM1["A"];
var ResultIsBoolean4 = delete (ENUM[0] + ENUM1["B"]);

// multiple delete  operators
var ResultIsBoolean5 = delete delete ENUM;
var ResultIsBoolean6 = delete delete delete (ENUM[0] + ENUM1["B"]);

// miss assignment operators
delete ENUM;
delete ENUM1;
delete ENUM1.B;
delete ENUM, ENUM1;`,
      [],
    );
  });
  test("deleteOperatorWithNumberType", async () => {
    await expectError(
      `// delete  operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a: number;
    static foo() { return 1; }
}
namespace M {
    export var n: number;
}

var objA = new A();

// number type var
var ResultIsBoolean1 = delete NUMBER;
var ResultIsBoolean2 = delete NUMBER1;

// number type literal
var ResultIsBoolean3 = delete 1;
var ResultIsBoolean4 = delete { x: 1, y: 2};
var ResultIsBoolean5 = delete { x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsBoolean6 = delete objA.a;
var ResultIsBoolean7 = delete M.n;
var ResultIsBoolean8 = delete NUMBER1[0];
var ResultIsBoolean9 = delete foo();
var ResultIsBoolean10 = delete A.foo();
var ResultIsBoolean11 = delete (NUMBER + NUMBER);

// multiple delete  operator
var ResultIsBoolean12 = delete delete NUMBER;
var ResultIsBoolean13 = delete delete delete (NUMBER + NUMBER);

// miss assignment operators
delete 1;
delete NUMBER;
delete NUMBER1;
delete foo();
delete objA.a;
delete M.n;
delete objA.a, M.n;`,
      [],
    );
  });
  test("deleteOperatorWithStringType", async () => {
    await expectError(
      `// delete  operator on string type
declare var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string;
}

var objA = new A();

// string type var
var ResultIsBoolean1 = delete STRING;
var ResultIsBoolean2 = delete STRING1;

// string type literal
var ResultIsBoolean3 = delete "";
var ResultIsBoolean4 = delete { x: "", y: "" };
var ResultIsBoolean5 = delete { x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsBoolean6 = delete objA.a;
var ResultIsBoolean7 = delete M.n;
var ResultIsBoolean8 = delete STRING1[0];
var ResultIsBoolean9 = delete foo();
var ResultIsBoolean10 = delete A.foo();
var ResultIsBoolean11 = delete (STRING + STRING);
var ResultIsBoolean12 = delete STRING.charAt(0);

// multiple delete  operator
var ResultIsBoolean13 = delete delete STRING;
var ResultIsBoolean14 = delete delete delete (STRING + STRING);

// miss assignment operators
delete "";
delete STRING;
delete STRING1;
delete foo();
delete objA.a,M.n;`,
      [],
    );
  });
  test("incrementOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// ++ operator on any type

var ANY: any;
var ANY1: any;
var ANY2: any[] = ["", ""];
var obj = {x:1,y:null};
class A {
    public a: any;
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsNumber1 = ++ANY;
var ResultIsNumber2 = ++ANY1;

var ResultIsNumber3 = ANY1++;
var ResultIsNumber4 = ANY1++;

// expressions
var ResultIsNumber5 = ++ANY2[0];
var ResultIsNumber6 = ++obj.x;
var ResultIsNumber7 = ++obj.y;
var ResultIsNumber8 = ++objA.a;
var ResultIsNumber = ++M.n;

var ResultIsNumber9 = ANY2[0]++;
var ResultIsNumber10 = obj.x++;
var ResultIsNumber11 = obj.y++;
var ResultIsNumber12 = objA.a++;
var ResultIsNumber13 = M.n++;

// miss assignment opertors
++ANY;
++ANY1;
++ANY2[0];
++ANY, ++ANY1;
++objA.a;
++M.n;

ANY++;
ANY1++;
ANY2[0]++;
ANY++, ANY1++;
objA.a++;
M.n++;`,
      [],
    );
  });
  test("incrementOperatorWithAnyOtherTypeInvalidOperations", async () => {
    await expectError(
      `// ++ operator on any type
var ANY1: any;
var ANY2: any[] = [1, 2];

declare var obj: () => {}
var obj1 = { x: "", y: () => { } };
function foo(): any {
    var a;
    return a;
}
class A {
    public a: any;
    static foo(): any {
        var a;
        return a;
    }
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsNumber1 = ++ANY2;
var ResultIsNumber2 = ++A;
var ResultIsNumber3 = ++M;
var ResultIsNumber4 = ++obj;
var ResultIsNumber5 = ++obj1;

var ResultIsNumber6 = ANY2++;
var ResultIsNumber7 = A++;
var ResultIsNumber8 = M++;
var ResultIsNumber9 = obj++;
var ResultIsNumber10 = obj1++;

// any type literal
var ResultIsNumber11 = ++{};
var ResultIsNumber12 = ++null;
var ResultIsNumber13 = ++undefined;

var ResultIsNumber14 = null++;
var ResultIsNumber15 = {}++;
var ResultIsNumber16 = undefined++;

// any type expressions
var ResultIsNumber17 = ++foo();
var ResultIsNumber18 = ++A.foo();
var ResultIsNumber19 = ++(null + undefined);
var ResultIsNumber20 = ++(null + null);
var ResultIsNumber21 = ++(undefined + undefined);
var ResultIsNumber22 = ++obj1.x;
var ResultIsNumber23 = ++obj1.y;

var ResultIsNumber24 = foo()++;
var ResultIsNumber25 = A.foo()++;
var ResultIsNumber26 = (null + undefined)++;
var ResultIsNumber27 = (null + null)++;
var ResultIsNumber28 = (undefined + undefined)++;
var ResultIsNumber29 = obj1.x++;
var ResultIsNumber30 = obj1.y++;

// miss assignment operators
++ANY2;

ANY2++;

++ANY1++;
++ANY2++;
++ANY2[0]++;`,
      [],
    );
  });
  test("incrementOperatorWithEnumType", async () => {
    await expectPass(
      `// ++ operator on enum type

enum ENUM1 { A, B, "" };

// expression
var ResultIsNumber1 = ++ENUM1["B"];
var ResultIsNumber2 = ENUM1.B++;

// miss assignment operator
++ENUM1["B"];

ENUM1.B++;`,
      [],
    );
  });
  test("incrementOperatorWithEnumTypeInvalidOperations", async () => {
    await expectError(
      `// ++ operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsNumber1 = ++ENUM;
var ResultIsNumber2 = ++ENUM1;

var ResultIsNumber3 = ENUM++;
var ResultIsNumber4 = ENUM1++;

// enum type expressions
var ResultIsNumber5 = ++(ENUM[1] + ENUM[2]);
var ResultIsNumber6 = (ENUM[1] + ENUM[2])++;

// miss assignment operator
++ENUM;
++ENUM1;

ENUM++;
ENUM1++;`,
      [],
    );
  });
  test("incrementOperatorWithNumberType", async () => {
    await expectPass(
      `// ++ operator on number type
var NUMBER: number;
var NUMBER1: number[] = [1, 2];

class A {
    public a: number;
}
namespace M {
    export var n: number;
}

var objA = new A();

// number type var
var ResultIsNumber1 = ++NUMBER;

var ResultIsNumber2 = NUMBER++;

// expressions
var ResultIsNumber3 = ++objA.a;
var ResultIsNumber4 = ++M.n;

var ResultIsNumber5 = objA.a++;
var ResultIsNumber6 = M.n++;
var ResultIsNumber7 = NUMBER1[0]++;

// miss assignment operators
++NUMBER;

++NUMBER1[0];
++objA.a;
++M.n;
++objA.a, M.n;

NUMBER++;
NUMBER1[0]++;
objA.a++;
M.n++;
objA.a++, M.n++;`,
      [],
    );
  });
  test("incrementOperatorWithNumberTypeInvalidOperations", async () => {
    await expectError(
      `// ++ operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a!: number;
    static foo() { return 1; }
}
namespace M {
    export var n: number;
}

var objA = new A();

//number type var
var ResultIsNumber1 = ++NUMBER1;
var ResultIsNumber2 = NUMBER1++;

// number type literal
var ResultIsNumber3 = ++1;
var ResultIsNumber4 = ++{ x: 1, y: 2};
var ResultIsNumber5 = ++{ x: 1, y: (n: number) => { return n; } };

var ResultIsNumber6 = 1++;
var ResultIsNumber7 = { x: 1, y: 2 }++;
var ResultIsNumber8 = { x: 1, y: (n: number) => { return n; } }++;

// number type expressions
var ResultIsNumber9 = ++foo();
var ResultIsNumber10 = ++A.foo();
var ResultIsNumber11 = ++(NUMBER + NUMBER);

var ResultIsNumber12 = foo()++;
var ResultIsNumber13 = A.foo()++;
var ResultIsNumber14 = (NUMBER + NUMBER)++;

// miss assignment operator
++1;
++NUMBER1;
++foo();

1++;
NUMBER1++;
foo()++;`,
      [],
    );
  });
  test("incrementOperatorWithUnsupportedBooleanType", async () => {
    await expectError(
      `// ++ operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a!: boolean;
    static foo() { return true; }
}
namespace M {
    export var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsNumber1 = ++BOOLEAN;

var ResultIsNumber2 = BOOLEAN++;

// boolean type literal
var ResultIsNumber3 = ++true;
var ResultIsNumber4 = ++{ x: true, y: false };
var ResultIsNumber5 = ++{ x: true, y: (n: boolean) => { return n; } };

var ResultIsNumber6 = true++;
var ResultIsNumber7 = { x: true, y: false }++;
var ResultIsNumber8 = { x: true, y: (n: boolean) => { return n; } }++;

// boolean type expressions
var ResultIsNumber9 = ++objA.a;
var ResultIsNumber10 = ++M.n;
var ResultIsNumber11 = ++foo();
var ResultIsNumber12 = ++A.foo();

var ResultIsNumber13 = foo()++;
var ResultIsNumber14 = A.foo()++;
var ResultIsNumber15 = objA.a++;
var ResultIsNumber16 = M.n++;

// miss assignment operators
++true;
++BOOLEAN;
++foo();
++objA.a;
++M.n;
++objA.a, M.n;

true++;
BOOLEAN++;
foo()++;
objA.a++;
M.n++;
objA.a++, M.n++;`,
      [],
    );
  });
  test("incrementOperatorWithUnsupportedStringType", async () => {
    await expectError(
      `// ++ operator on string type
declare var STRING: string;
var STRING1: string[] = ["", ""];

function foo(): string { return ""; }

class A {
    public a!: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string;
}

var objA = new A();

// string type var
var ResultIsNumber1 = ++STRING;
var ResultIsNumber2 = ++STRING1;

var ResultIsNumber3 = STRING++;
var ResultIsNumber4 = STRING1++;

// string type literal
var ResultIsNumber5 = ++"";
var ResultIsNumber6 = ++{ x: "", y: "" };
var ResultIsNumber7 = ++{ x: "", y: (s: string) => { return s; } };

var ResultIsNumber8 = ""++;
var ResultIsNumber9 = { x: "", y: "" }++;
var ResultIsNumber10 = { x: "", y: (s: string) => { return s; } }++;

// string type expressions
var ResultIsNumber11 = ++objA.a;
var ResultIsNumber12 = ++M.n;
var ResultIsNumber13 = ++STRING1[0];
var ResultIsNumber14 = ++foo();
var ResultIsNumber15 = ++A.foo();
var ResultIsNumber16 = ++(STRING + STRING);

var ResultIsNumber17 = objA.a++;
var ResultIsNumber18 = M.n++;
var ResultIsNumber19 = STRING1[0]++;
var ResultIsNumber20 = foo()++;
var ResultIsNumber21 = A.foo()++;
var ResultIsNumber22 = (STRING + STRING)++;

// miss assignment operators
++"";
++STRING;
++STRING1;
++STRING1[0];
++foo();
++objA.a;
++M.n;
++objA.a, M.n;

""++;
STRING++;
STRING1++;
STRING1[0]++;
foo()++;
objA.a++;
M.n++;
objA.a++, M.n++;`,
      [],
    );
  });
  test("logicalNotOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator !
declare var b: number;

// operand before !
var BOOLEAN1 = b!;  //expect error

// miss parentheses
var BOOLEAN2 = !b + b;

// miss an operand
var BOOLEAN3 =!;`,
      [],
    );
  });
  test("logicalNotOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// ! operator on any type

var ANY: any;
var ANY1;
var ANY2: any[] = ["", ""];
declare var obj: () => {}
var obj1 = { x: "", y: () => { }};
function foo(): any {
    var a;
    return a;
}
class A {
    public a: any;
    static foo() {
        var a;
        return a;
    }
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsBoolean1 = !ANY1;
var ResultIsBoolean2 = !ANY2;
var ResultIsBoolean3 = !A;
var ResultIsBoolean4 = !M;
var ResultIsBoolean5 = !obj;
var ResultIsBoolean6 = !obj1;

// any type literal
var ResultIsBoolean7 = !undefined;
var ResultIsBoolean8 = !null;

// any type expressions
var ResultIsBoolean9 = !ANY2[0];
var ResultIsBoolean10 = !obj1.x;
var ResultIsBoolean11 = !obj1.y;
var ResultIsBoolean12 = !objA.a;
var ResultIsBoolean13 = !M.n;
var ResultIsBoolean14 = !foo();
var ResultIsBoolean15 = !A.foo();
var ResultIsBoolean16 = !(ANY + ANY1);
var ResultIsBoolean17 = !(null + undefined);
var ResultIsBoolean18 = !(null + null);
var ResultIsBoolean19 = !(undefined + undefined);

// multiple ! operators
var ResultIsBoolean20 = !!ANY;
var ResultIsBoolean21 = !!!(ANY + ANY1);

// miss assignment operators
!ANY;
!ANY1;
!ANY2[0];
!ANY, ANY1;
!objA.a;
!M.n;`,
      [],
    );
  });
  test("logicalNotOperatorWithBooleanType", async () => {
    await expectPass(
      `// ! operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a!: boolean;
    static foo() { return false; }
}
namespace M {
    export declare var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsBoolean1 = !BOOLEAN;

// boolean type literal
var ResultIsBoolean2 = !true;
var ResultIsBoolean3 = !{ x: true, y: false };

// boolean type expressions
var ResultIsBoolean4 = !objA.a;
var ResultIsBoolean5 = !M.n;
var ResultIsBoolean6 = !foo();
var ResultIsBoolean7 = !A.foo();

// multiple ! operators
var ResultIsBoolean = !!BOOLEAN;

// miss assignment operators
!true;
!BOOLEAN;
!foo();
!true, false;
!objA.a;
!M.n;`,
      [],
    );
  });
  test("logicalNotOperatorWithEnumType", async () => {
    await expectPass(
      `// ! operator on enum type

enum ENUM { A, B, C };
enum ENUM1 { };

// enum type var
var ResultIsBoolean1 = !ENUM;

// enum type expressions
var ResultIsBoolean2 = !ENUM["B"];
var ResultIsBoolean3 = !(ENUM.B + ENUM["C"]);

// multiple ! operators
var ResultIsBoolean4 = !!ENUM;
var ResultIsBoolean5 = !!!(ENUM["B"] + ENUM.C);

// miss assignment operators
!ENUM;
!ENUM1;
!ENUM.B;
!ENUM, ENUM1;`,
      [],
    );
  });
  test("logicalNotOperatorWithNumberType", async () => {
    await expectPass(
      `// ! operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a!: number;
    static foo() { return 1; }
}
namespace M {
    export declare var n: number;
}

var objA = new A();

// number type var
var ResultIsBoolean1 = !NUMBER;
var ResultIsBoolean2 = !NUMBER1;

// number type literal
var ResultIsBoolean3 = !1;
var ResultIsBoolean4 = !{ x: 1, y: 2};
var ResultIsBoolean5 = !{ x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsBoolean6 = !objA.a;
var ResultIsBoolean7 = !M.n;
var ResultIsBoolean8 = !NUMBER1[0];
var ResultIsBoolean9 = !foo();
var ResultIsBoolean10 = !A.foo();
var ResultIsBoolean11 = !(NUMBER + NUMBER);

// multiple ! operator
var ResultIsBoolean12 = !!NUMBER;
var ResultIsBoolean13 = !!!(NUMBER + NUMBER);

// miss assignment operators
!1;
!NUMBER;
!NUMBER1;
!foo();
!objA.a;
!M.n;
!objA.a, M.n;`,
      [],
    );
  });
  test("logicalNotOperatorWithStringType", async () => {
    await expectPass(
      `// ! operator on string type
declare var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a!: string;
    static foo() { return ""; }
}
namespace M {
    export declare var n: string;
}

var objA = new A();

// string type var
var ResultIsBoolean1 = !STRING;
var ResultIsBoolean2 = !STRING1;

// string type literal
var ResultIsBoolean3 = !"";
var ResultIsBoolean4 = !{ x: "", y: "" };
var ResultIsBoolean5 = !{ x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsBoolean6 = !objA.a;
var ResultIsBoolean7 = !M.n;
var ResultIsBoolean8 = !STRING1[0];
var ResultIsBoolean9 = !foo();
var ResultIsBoolean10 = !A.foo();
var ResultIsBoolean11 = !(STRING + STRING);
var ResultIsBoolean12 = !STRING.charAt(0);

// multiple ! operator
var ResultIsBoolean13 = !!STRING;
var ResultIsBoolean14 = !!!(STRING + STRING);

// miss assignment operators
!"";
!STRING;
!STRING1;
!foo();
!objA.a,M.n;`,
      [],
    );
  });
  test("negateOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator -

// operand before -
var NUMBER1 = var NUMBER-;  //expect error

// invalid expressions
var NUMBER2 = -(null - undefined);
var NUMBER3 = -(null - null);
var NUMBER4 = -(undefined - undefined);

// miss operand
var NUMBER =-;`,
      [],
    );
  });
  test("negateOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// - operator on any type

var ANY: any;
var ANY1: any;
var ANY2: any[] = ["", ""];
var obj: () => {}
var obj1 = { x: "", y: () => { }};

function foo(): any {
    var a;
    return a;
}
class A {
    public a!: any;
    static foo(): any {
        var a;
        return a;
    }
}
namespace M {
    export var n: any;
}
var objA = new A();

// any type var
var ResultIsNumber1 = -ANY1;
var ResultIsNumber2 = -ANY2;
var ResultIsNumber3 = -A;
var ResultIsNumber4 = -M;
var ResultIsNumber5 = -obj;
var ResultIsNumber6 = -obj1;

// any type literal
var ResultIsNumber7 = -undefined;
var ResultIsNumber = -null;

// any type expressions
var ResultIsNumber8 = -ANY2[0];
var ResultIsNumber9 = -obj1.x;
var ResultIsNumber10 = -obj1.y;
var ResultIsNumber11 = -objA.a;
var ResultIsNumber12 = -M.n;
var ResultIsNumber13 = -foo();
var ResultIsNumber14 = -A.foo();
var ResultIsNumber15 = -(ANY - ANY1);

// miss assignment operators
-ANY;
-ANY1;
-ANY2[0];
-ANY, ANY1;
-objA.a;
-M.n;`,
      [],
    );
  });
  test("negateOperatorWithBooleanType", async () => {
    await expectPass(
      `// - operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a!: boolean;
    static foo() { return false; }
}
namespace M {
    export declare var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsNumber1 = -BOOLEAN;

// boolean type literal
var ResultIsNumber2 = -true;
var ResultIsNumber3 = -{ x: true, y: false };

// boolean type expressions
var ResultIsNumber4 = -objA.a;
var ResultIsNumber5 = -M.n;
var ResultIsNumber6 = -foo();
var ResultIsNumber7 = -A.foo();

// miss assignment operators
-true;
-BOOLEAN;
-foo();
-true, false;
-objA.a;
-M.n;`,
      [],
    );
  });
  test("negateOperatorWithEnumType", async () => {
    await expectPass(
      `// - operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsNumber1 = -ENUM;

// expressions
var ResultIsNumber2 = -ENUM1["B"];
var ResultIsNumber3 = -(ENUM1.B + ENUM1[""]);

// miss assignment operators
-ENUM;
-ENUM1;
-ENUM1["B"];
-ENUM, ENUM1;`,
      [],
    );
  });
  test("negateOperatorWithNumberType", async () => {
    await expectPass(
      `// - operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a!: number;
    static foo() { return 1; }
}
namespace M {
    export declare var n: number;
}

var objA = new A();

// number type var
var ResultIsNumber1 = -NUMBER;
var ResultIsNumber2 = -NUMBER1;

// number type literal
var ResultIsNumber3 = -1;
var ResultIsNumber4 = -{ x: 1, y: 2};
var ResultIsNumber5 = -{ x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsNumber6 = -objA.a;
var ResultIsNumber7 = -M.n;
var ResultIsNumber8 = -NUMBER1[0];
var ResultIsNumber9 = -foo();
var ResultIsNumber10 = -A.foo();
var ResultIsNumber11 = -(NUMBER - NUMBER);

// miss assignment operators
-1;
-NUMBER;
-NUMBER1;
-foo();
-objA.a;
-M.n;
-objA.a, M.n;`,
      [],
    );
  });
  test("negateOperatorWithStringType", async () => {
    await expectPass(
      `// - operator on string type
declare var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a!: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string = "";
}

var objA = new A();

// string type var
var ResultIsNumber1 = -STRING;
var ResultIsNumber2 = -STRING1;

// string type literal
var ResultIsNumber3 = -"";
var ResultIsNumber4 = -{ x: "", y: "" };
var ResultIsNumber5 = -{ x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsNumber6 = -objA.a;
var ResultIsNumber7 = -M.n;
var ResultIsNumber8 = -STRING1[0];
var ResultIsNumber9 = -foo();
var ResultIsNumber10 = -A.foo();
var ResultIsNumber11 = -(STRING + STRING);
var ResultIsNumber12 = -STRING.charAt(0);

// miss assignment operators
-"";
-STRING;
-STRING1;
-foo();
-objA.a,M.n;`,
      [],
    );
  });
  test("plusOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator +
var b;

// operand before +
var result1 = b+;   //expect error

// miss  an operand
var result2 =+;`,
      [],
    );
  });
  test("plusOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// + operator on any type

declare var ANY: any;
declare var ANY1: any;
var ANY2: any[] = ["", ""];
declare var obj: () => {}
var obj1 = { x: (s: string) => { }, y: (s1) => { }};

function foo(): any {
    var a = undefined;
    return a;
}
class A {
    public a!: any;
    static foo() {
        var a: any = undefined;
        return a;
    }
}
namespace M {
    export var n: any = undefined;
}
var objA = new A();

// any other type var
var ResultIsNumber1 = +ANY1;
var ResultIsNumber2 = +ANY2;
var ResultIsNumber3 = +A;
var ResultIsNumber4 = +M;
var ResultIsNumber5 = +obj;
var ResultIsNumber6 = +obj1;

// any type literal
var ResultIsNumber7 = +undefined;
var ResultIsNumber8 = +null;

// any type expressions
var ResultIsNumber9 = +ANY2[0];
var ResultIsNumber10 = +obj1.x;
var ResultIsNumber11 = +obj1.y;
var ResultIsNumber12 = +objA.a;
var ResultIsNumber13 = +M.n;
var ResultIsNumber14 = +foo();
var ResultIsNumber15 = +A.foo();
var ResultIsNumber16 = +(ANY + ANY1);
var ResultIsNumber17 = +(null + undefined);
var ResultIsNumber18 = +(null + null);
var ResultIsNumber19 = +(undefined + undefined);

// miss assignment operators
+ANY;
+ANY1;
+ANY2[0];
+ANY, ANY1;
+objA.a;
+M.n;`,
      [],
    );
  });
  test("plusOperatorWithBooleanType", async () => {
    await expectPass(
      `// + operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a!: boolean;
    static foo() { return false; }
}
namespace M {
    export var n: boolean = false;
}

var objA = new A();

// boolean type var
var ResultIsNumber1 = +BOOLEAN;

// boolean type literal
var ResultIsNumber2 = +true;
var ResultIsNumber3 = +{ x: true, y: false };

// boolean type expressions
var ResultIsNumber4 = +objA.a;
var ResultIsNumber5 = +M.n;
var ResultIsNumber6 = +foo();
var ResultIsNumber7 = +A.foo();

// miss assignment operators
+true;
+BOOLEAN;
+foo();
+true, false;
+objA.a;
+M.n;`,
      [],
    );
  });
  test("plusOperatorWithEnumType", async () => {
    await expectPass(
      `// + operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsNumber1 = +ENUM;
var ResultIsNumber2 = +ENUM1;

// enum type expressions
var ResultIsNumber3 = +ENUM1["A"];
var ResultIsNumber4 = +(ENUM[0] + ENUM1["B"]);

// miss assignment operators
+ENUM;
+ENUM1;
+ENUM1.B;
+ENUM, ENUM1;`,
      [],
    );
  });
  test("plusOperatorWithNumberType", async () => {
    await expectPass(
      `// + operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a!: number;
    static foo() { return 1; }
}
namespace M {
    export var n: number = 0;
}

var objA = new A();

// number type var
var ResultIsNumber1 = +NUMBER;
var ResultIsNumber2 = +NUMBER1;

// number type literal
var ResultIsNumber3 = +1;
var ResultIsNumber4 = +{ x: 1, y: 2};
var ResultIsNumber5 = +{ x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsNumber6 = +objA.a;
var ResultIsNumber7 = +M.n;
var ResultIsNumber8 = +NUMBER1[0];
var ResultIsNumber9 = +foo();
var ResultIsNumber10 = +A.foo();
var ResultIsNumber11 = +(NUMBER + NUMBER);

// miss assignment operators
+1;
+NUMBER;
+NUMBER1;
+foo();
+objA.a;
+M.n;
+objA.a, M.n;`,
      [],
    );
  });
  test("plusOperatorWithStringType", async () => {
    await expectPass(
      `// + operator on string type
declare var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a!: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string = "";
}

var objA = new A();

// string type var
var ResultIsNumber1 = +STRING;
var ResultIsNumber2 = +STRING1;

// string type literal
var ResultIsNumber3 = +"";
var ResultIsNumber4 = +{ x: "", y: "" };
var ResultIsNumber5 = +{ x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsNumber6 = +objA.a;
var ResultIsNumber7 = +M.n;
var ResultIsNumber8 = +STRING1[0];
var ResultIsNumber9 = +foo();
var ResultIsNumber10 = +A.foo();
var ResultIsNumber11 = +(STRING + STRING);
var ResultIsNumber12 = +STRING.charAt(0);

// miss assignment operators
+"";
+STRING;
+STRING1;
+foo();
+objA.a,M.n;`,
      [],
    );
  });
  test("typeofOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator typeof

// opreand before typeof
var ANY = ANY typeof ;    //expect error

// miss an operand
var ANY1 = typeof ;`,
      [],
    );
  });
  test("typeofOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// typeof  operator on any type

declare var ANY: any;
declare var ANY1;
var ANY2: any[] = ["", ""];
declare var obj: () => {};
var obj1 = { x: "a", y: () => { }};

function foo(): any {
    var a!: any;
    return a;
}
class A {
    public a: any;
    static foo() {
        var a!: any;
        return a;
    }
}
namespace M {
    export var n!: any;
}
var objA = new A();

// any type var
var ResultIsString1 = typeof ANY1;
var ResultIsString2 = typeof ANY2;
var ResultIsString3 = typeof A;
var ResultIsString4 = typeof M;
var ResultIsString5 = typeof obj;
var ResultIsString6 = typeof obj1;

// any type literal
var ResultIsString7 = typeof undefined;
var ResultIsString8 = typeof null;
var ResultIsString9 = typeof {};

// any type expressions
var ResultIsString10 = typeof ANY2[0];
var ResultIsString11 = typeof objA.a;
var ResultIsString12 = typeof obj1.x;
var ResultIsString13 = typeof M.n;
var ResultIsString14 = typeof foo();
var ResultIsString15 = typeof A.foo();
var ResultIsString16 = typeof (ANY + ANY1);
var ResultIsString17 = typeof (null + undefined);
var ResultIsString18 = typeof (null + null);
var ResultIsString19 = typeof (undefined + undefined);

// multiple typeof  operators
var ResultIsString20 = typeof typeof ANY;
var ResultIsString21 = typeof typeof typeof (ANY + ANY1);

// miss assignment operators
typeof ANY;
typeof ANY1;
typeof ANY2[0];
typeof ANY, ANY1;
typeof obj1;
typeof obj1.x;
typeof objA.a;
typeof M.n;

// use typeof in type query
var z!: any;
var x!: any[];
var r!: () => any;
z: typeof ANY;
x: typeof ANY2;
r: typeof foo;
z: typeof objA.a;
z: typeof A.foo;
z: typeof M.n;
z: typeof obj1.x;`,
      [],
    );
  });
  test("typeofOperatorWithBooleanType", async () => {
    await expectPass(
      `
// typeof  operator on boolean type
declare var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a: boolean;
    static foo() { return false; }
}
namespace M {
    export var n!: boolean;
}

var objA = new A();

// boolean type var
var ResultIsString1 = typeof BOOLEAN;

// boolean type literal
var ResultIsString2 = typeof true;
var ResultIsString3 = typeof { x: true, y: false };

// boolean type expressions
var ResultIsString4 = typeof objA.a;
var ResultIsString5 = typeof M.n;
var ResultIsString6 = typeof foo();
var ResultIsString7 = typeof A.foo();

// multiple typeof  operator
var ResultIsString8 = typeof typeof BOOLEAN;

// miss assignment operators
typeof true;
typeof BOOLEAN;
typeof foo();
typeof true, false;
typeof objA.a;
typeof M.n;

// use typeof in type query
declare var z: boolean;
declare var x: boolean[];
declare var r: () => boolean;
z: typeof BOOLEAN;
r: typeof foo;
var y = { a: true, b: false};
z: typeof y.a;
z: typeof objA.a;
z: typeof A.foo;
z: typeof M.n;`,
      [],
    );
  });
  test("typeofOperatorWithEnumType", async () => {
    await expectPass(
      `
// typeof  operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsString1 = typeof ENUM;
var ResultIsString2 = typeof ENUM1;

// enum type expressions
var ResultIsString3 = typeof ENUM1["A"];
var ResultIsString4 = typeof (ENUM[0] + ENUM1["B"]);

// multiple typeof  operators
var ResultIsString5 = typeof typeof ENUM;
var ResultIsString6 = typeof typeof typeof (ENUM[0] + ENUM1.B);

// miss assignment operators
typeof ENUM;
typeof ENUM1;
typeof ENUM1["B"];
typeof ENUM, ENUM1;

// use typeof in type query
enum z { };
z: typeof ENUM;
z: typeof ENUM1;`,
      [],
    );
  });
  test("typeofOperatorWithNumberType", async () => {
    await expectPass(
      `// typeof  operator on number type
declare var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a: number;
    static foo() { return 1; }
}
namespace M {
    export var n!: number;
}

var objA = new A();

// number type var
var ResultIsString1 = typeof NUMBER;
var ResultIsString2 = typeof NUMBER1;

// number type literal
var ResultIsString3 = typeof 1;
var ResultIsString4 = typeof { x: 1, y: 2};
var ResultIsString5 = typeof { x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsString6 = typeof objA.a;
var ResultIsString7 = typeof M.n;
var ResultIsString8 = typeof NUMBER1[0];
var ResultIsString9 = typeof foo();
var ResultIsString10 = typeof A.foo();
var ResultIsString11 = typeof (NUMBER + NUMBER);

// multiple typeof  operators
var ResultIsString12 = typeof typeof NUMBER;
var ResultIsString13 = typeof typeof typeof (NUMBER + NUMBER);

// miss assignment operators
typeof 1;
typeof NUMBER;
typeof NUMBER1;
typeof foo();
typeof objA.a;
typeof M.n;
typeof objA.a, M.n;

// use typeof in type query
declare var z: number;
declare var x: number[];
declare var r: () => number;
z: typeof NUMBER;
x: typeof NUMBER1;
r: typeof foo;
var y = { a: 1, b: 2 };
z: typeof y.a;
z: typeof objA.a;
z: typeof A.foo;
z: typeof M.n;`,
      [],
    );
  });
  test("typeofOperatorWithStringType", async () => {
    await expectPass(
      `// typeof  operator on string type
declare var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a: string;
    static foo() { return ""; }
}
namespace M {
    export var n!: string;
}

var objA = new A();

// string type var
var ResultIsString1 = typeof STRING;
var ResultIsString2 = typeof STRING1;

// string type literal
var ResultIsString3 = typeof "";
var ResultIsString4 = typeof { x: "", y: "" };
var ResultIsString5 = typeof { x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsString6 = typeof objA.a;
var ResultIsString7 = typeof M.n;
var ResultIsString8 = typeof STRING1[0];
var ResultIsString9 = typeof foo();
var ResultIsString10 = typeof A.foo();
var ResultIsString11 = typeof (STRING + STRING);
var ResultIsString12 = typeof STRING.charAt(0);

// multiple typeof  operators
var ResultIsString13 = typeof typeof STRING;
var ResultIsString14 = typeof typeof typeof (STRING + STRING);

// miss assignment operators
typeof "";
typeof STRING;
typeof STRING1;
typeof foo();
typeof objA.a, M.n;

// use typeof in type query
declare var z: string;
declare var x: string[];
declare var r: () => string;
z: typeof STRING;
x: typeof STRING1;
r: typeof foo;
var y = { a: "", b: "" };
z: typeof y.a;
z: typeof objA.a;
z: typeof A.foo;
z: typeof M.n;`,
      [],
    );
  });
  test("voidOperatorInvalidOperations", async () => {
    await expectError(
      `// Unary operator void

// operand before void
var ANY = ANY void ;    //expect error

// miss an operand
var ANY1 = void ;`,
      [],
    );
  });
  test("voidOperatorWithAnyOtherType", async () => {
    await expectPass(
      `// void  operator on any type

declare var ANY: any;
declare var ANY1;
var ANY2: any[] = ["", ""];
declare var obj: () => {};
var obj1 = {x:"",y:1};

function foo(): any {
    var a!: any;
    return a;
}
class A {
    public a: any;
    static foo() {
        var a!: any;
        return a;
    }
}
namespace M {
    export var n!: any;
}
var objA = new A();

// any type var
var ResultIsAny1 = void ANY1;
var ResultIsAny2 = void ANY2;
var ResultIsAny3 = void A;
var ResultIsAny4 = void M;
var ResultIsAny5 = void obj;
var ResultIsAny6 = void obj1;

// any type literal
var ResultIsAny7 = void undefined;
var ResultIsAny8 = void null;

// any type expressions
var ResultIsAny9 = void ANY2[0]
var ResultIsAny10 = void obj1.x;
var ResultIsAny11 = void obj1.y;
var ResultIsAny12 = void objA.a;
var ResultIsAny13 = void M.n;
var ResultIsAny14 = void foo();
var ResultIsAny15 = void A.foo();
var ResultIsAny16 = void (ANY + ANY1);
var ResultIsAny17 = void (null + undefined);
var ResultIsAny18 = void (null + null);
var ResultIsAny19 = void (undefined + undefined);

// multiple void  operators
var ResultIsAny20 = void void ANY;
var ResultIsAny21 = void void void (ANY + ANY1);

// miss assignment operators
void ANY;
void ANY1;
void ANY2[0];
void ANY, ANY1;
void objA.a;
void M.n;`,
      [],
    );
  });
  test("voidOperatorWithBooleanType", async () => {
    await expectPass(
      `// void  operator on boolean type
var BOOLEAN: boolean;

function foo(): boolean { return true; }

class A {
    public a: boolean;
    static foo() { return false; }
}
namespace M {
    export var n: boolean;
}

var objA = new A();

// boolean type var
var ResultIsAny1 = void BOOLEAN;

// boolean type literal
var ResultIsAny2 = void true;
var ResultIsAny3 = void { x: true, y: false };

// boolean type expressions
var ResultIsAny4 = void objA.a;
var ResultIsAny5 = void M.n;
var ResultIsAny6 = void foo();
var ResultIsAny7 = void A.foo();

// multiple void  operator
var ResultIsAny8 = void void BOOLEAN;

// miss assignment operators
void true;
void BOOLEAN;
void foo();
void true, false;
void objA.a;
void M.n;`,
      [],
    );
  });
  test("voidOperatorWithEnumType", async () => {
    await expectPass(
      `// void  operator on enum type

enum ENUM { };
enum ENUM1 { A, B, "" };

// enum type var
var ResultIsAny1 = void ENUM;
var ResultIsAny2 = void ENUM1;

// enum type expressions
var ResultIsAny3 = void ENUM1["A"];
var ResultIsAny4 = void (ENUM[0] + ENUM1["B"]);

// multiple void  operators
var ResultIsAny5 = void void ENUM;
var ResultIsAny6 = void void void (ENUM[0] + ENUM1.B);

// miss assignment operators
void ENUM;
void ENUM1;
void ENUM1["B"];
void ENUM, ENUM1;`,
      [],
    );
  });
  test("voidOperatorWithNumberType", async () => {
    await expectPass(
      `// void  operator on number type
var NUMBER: number;
var NUMBER1: number[] = [1, 2];

function foo(): number { return 1; }

class A {
    public a: number;
    static foo() { return 1; }
}
namespace M {
    export var n: number;
}

var objA = new A();

// number type var
var ResultIsAny1 = void NUMBER;
var ResultIsAny2 = void NUMBER1;

// number type literal
var ResultIsAny3 = void 1;
var ResultIsAny4 = void { x: 1, y: 2};
var ResultIsAny5 = void { x: 1, y: (n: number) => { return n; } };

// number type expressions
var ResultIsAny6 = void objA.a;
var ResultIsAny7 = void M.n;
var ResultIsAny8 = void NUMBER1[0];
var ResultIsAny9 = void foo();
var ResultIsAny10 = void A.foo();
var ResultIsAny11 = void (NUMBER + NUMBER);

// multiple void  operators
var ResultIsAny12 = void void NUMBER;
var ResultIsAny13 = void void void (NUMBER + NUMBER);

// miss assignment operators
void 1;
void NUMBER;
void NUMBER1;
void foo();
void objA.a;
void M.n;
void objA.a, M.n;`,
      [],
    );
  });
  test("voidOperatorWithStringType", async () => {
    await expectPass(
      `// void  operator on string type
var STRING: string;
var STRING1: string[] = ["", "abc"];

function foo(): string { return "abc"; }

class A {
    public a: string;
    static foo() { return ""; }
}
namespace M {
    export var n: string;
}

var objA = new A();

// string type var
var ResultIsAny1 = void STRING;
var ResultIsAny2 = void STRING1;

// string type literal
var ResultIsAny3 = void "";
var ResultIsAny4 = void { x: "", y: "" };
var ResultIsAny5 = void { x: "", y: (s: string) => { return s; } };

// string type expressions
var ResultIsAny6 = void objA.a;
var ResultIsAny7 = void M.n;
var ResultIsAny8 = void STRING1[0];
var ResultIsAny9 = void foo();
var ResultIsAny10 = void A.foo();
var ResultIsAny11 = void (STRING + STRING);
var ResultIsAny12 = void STRING.charAt(0);

// multiple void  operators
var ResultIsAny13 = void void STRING;
var ResultIsAny14 = void void void (STRING + STRING);

// miss assignment operators
void "";
void STRING;
void STRING1;
void foo();
void objA.a,M.n;`,
      [],
    );
  });
  test("assignments", async () => {
    await expectPass(
      `// In this file:
//  Assign to a module
//  Assign to a class
//  Assign to an enum
//  Assign to a function
//  Assign to a variable
//  Assign to a parameter
//  Assign to an interface

namespace M { }
M = null; // Error

class C { }
C = null; // Error

enum E { A }
E = null; // Error
E.A = null; // OK per spec, Error per implementation (509581)

function fn() { }
fn = null; // Should be error

var v;
v = null; // OK

function fn2(p) {
    p = null; // OK
}

interface I { }
I = null; // Error`,
      [],
    );
  });
  test("assignmentToParenthesizedIdentifiers", async () => {
    await expectPass(
      `var x: number;
x = 3; // OK
(x) = 3; // OK
x = ''; // Error
(x) = ''; // Error

namespace M {
    export var y: number;
}
M.y = 3; // OK
(M).y = 3; // OK
(M.y) = 3; // OK
M.y = ''; // Error
(M).y = ''; // Error
(M.y) = ''; // Error

M = { y: 3 }; // Error
(M) = { y: 3 }; // Error

namespace M2 {
    export namespace M3 {
        export var x: number;
    }

    M3 = { x: 3 }; // Error
}
M2.M3 = { x: 3 }; // OK
(M2).M3 = { x: 3 }; // OK
(M2.M3) = { x: 3 }; // OK

M2.M3 = { x: '' }; // Error
(M2).M3 = { x: '' }; // Error
(M2.M3) = { x: '' }; // Error


function fn() { }
fn = () => 3; // Bug 823548: Should be error (fn is not a reference)
(fn) = () => 3; // Should be error

function fn2(x: number, y: { t: number }) {
    x = 3;
    (x) = 3; // OK
    x = ''; // Error
    (x) = ''; // Error

    (y).t = 3; // OK
    (y.t) = 3; // OK
    (y).t = ''; // Error
    (y.t) = ''; // Error

    y['t'] = 3; // OK
    (y)['t'] = 3; // OK
    (y['t']) = 3; // OK
    y['t'] = ''; // Error
    (y)['t'] = ''; // Error
    (y['t']) = ''; // Error
}

enum E {
    A
}
E = undefined; // Error
(E) = undefined; // Error

class C {

}

C = undefined; // Error
(C) = undefined; // Error
`,
      [],
    );
  });
});
