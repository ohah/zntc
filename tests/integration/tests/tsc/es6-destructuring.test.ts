import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/destructuring", () => {
  test("arrayAssignmentPatternWithAny", async () => {
    await expectPass(
      `var a: any;
var x: string;
[x] = a;`,
      [],
    );
  });
  test("declarationInAmbientContext", async () => {
    await expectPass(
      `declare var [a, b];  // Error, destructuring declaration not allowed in ambient context
declare var {c, d};  // Error, destructuring declaration not allowed in ambient context
`,
      [],
    );
  });
  test("declarationsAndAssignments", async () => {
    await expectPass(
      `function f0() {
    var [] = [1, "hello"];
    var [x] = [1, "hello"];
    var [x, y] = [1, "hello"];
    var [x, y, z] = [1, "hello"];
    var [,, x] = [0, 1, 2];
    var x!: number;
    var y!: string;
}

function f1() {
    var a = [1, "hello"];
    var [x] = a;
    var [x, y] = a;
    var [x, y, z] = a;
    var x!: number | string;
    var y!: number | string;
    var z!: number | string;
}

function f2() {
    var { } = { x: 5, y: "hello" };       // Ok, empty binding pattern means nothing
    var { x } = { x: 5, y: "hello" };     // Error, no y in target
    var { y } = { x: 5, y: "hello" };     // Error, no x in target
    var { x, y } = { x: 5, y: "hello" };
    var x!: number;
    var y!: string;
    var { x: a } = { x: 5, y: "hello" };  // Error, no y in target
    var { y: b } = { x: 5, y: "hello" };  // Error, no x in target
    var { x: a, y: b } = { x: 5, y: "hello" };
    var a!: number;
    var b!: string;
}

function f3() {
    var [x, [y, [z]]] = [1, ["hello", [true]]];
    var x!: number;
    var y!: string;
    var z!: boolean;
}

function f4() {
    var { a: x, b: { a: y, b: { a: z }}} = { a: 1, b: { a: "hello", b: { a: true } } };
    var x!: number;
    var y!: string;
    var z!: boolean;
}

function f6() {
    var [x = 0, y = ""] = [1, "hello"];
    var x!: number;
    var y!: string;
}

function f7() {
    var [x = 0, y = 1] = [1, "hello"];  // Error, initializer for y must be string
    var x!: number;
    var y!: string;
}

function f8() {
    var [a, b, c] = [];   // Error, [] is an empty tuple
    var [d, e, f] = [1];  // Error, [1] is a tuple
}

function f9() {
    var [a, b] = {};                // Error, not array type
    var [c, d] = { 0: 10, 1: 20 };  // Error, not array type
    var [e, f] = [10, 20];
}

function f10() {
    var { a, b } = {};  // Error
    var { a, b } = [];  // Error
}

function f11() {
    var { x: a, y: b } = { x: 10, y: "hello" };
    var { 0: a, 1: b } = { 0: 10, 1: "hello" };
    var { "<": a, ">": b } = { "<": 10, ">": "hello" };
    var { 0: a, 1: b } = [10, "hello"];
    var a!: number;
    var b!: string;
}

function f12() {
    var [a, [b, { x, y: c }] = ["abc", { x: 10, y: false }]] = [1, ["hello", { x: 5, y: true }]];
    var a!: number;
    var b!: string;
    var x!: number;
    var c!: boolean;
}

function f13() {
    var [x, y] = [1, "hello"];
    var [a, b] = [[x, y], { x: x, y: y }];
}

function f14([a = 1, [b = "hello", { x, y: c = false }]]) {
    var a!: number;
    var b!: string;
    var c!: boolean;
}
f14([2, ["abc", { x: 0, y: true }]]);
f14([2, ["abc", { x: 0 }]]);
f14([2, ["abc", { y: false }]]);  // Error, no x

namespace M {
    export var [a, b] = [1, 2];
}

function f15() {
    var a = "hello";
    var b = 1;
    var c = true;
    return { a, b, c };
}

function f16() {
    var { a, b, c } = f15();
}

function f17({ a = "", b = 0, c = false }) {
}

f17({});
f17({ a: "hello" });
f17({ c: true });
f17(f15());

function f18() {
    var a!: number;
    var b!: string;
    var aa!: number[];
    ({ a, b } = { a, b });
    ({ a, b } = { b, a });
    [aa[0], b] = [a, b];
    [a, b] = [b, a];  // Error
    [a = 1, b = "abc"] = [2, "def"];
}

function f19() {
    var a, b;
    [a, b] = [1, 2];
    [a, b] = [b, a];
    ({ a, b } = { b, a });
    [[a, b] = [1, 2]] = [[2, 3]];
    var x = ([a, b] = [1, 2]);
}

function f20(v: [number, number, number]) {
    var x!: number;
    var y!: number;
    var z!: number;
    var a0!: [];
    var a1!: [number];
    var a2!: [number, number];
    var a3!: [number, number, number];
    var [...a3] = v;
    var [x, ...a2] = v;
    var [x, y, ...a1] = v;
    var [x, y, z, ...a0] = v;
    [...a3] = v;
    [x, ...a2] = v;
    [x, y, ...a1] = v;
    [x, y, z, ...a0] = v;
}

function f21(v: [number, string, boolean]) {
    var x!: number;
    var y!: string;
    var z!: boolean;
    var a0!: [number, string, boolean];
    var a1!: [string, boolean];
    var a2!: [boolean];
    var a3!: [];
    var [...a0] = v;
    var [x, ...a1] = v;
    var [x, y, ...a2] = v;
    var [x, y, z, ...a3] = v;
    [...a0] = v;
    [x, ...a1] = v;
    [x, y, ...a2] = v;
    [x, y, z, ...a3] = v;
}
`,
      [],
    );
  });
  test("declarationWithNoInitializer", async () => {
    await expectPass(
      `var [a, b];          // Error, no initializer
var {c, d};          // Error, no initializer
`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment1ES5", async () => {
    await expectPass(
      `// @target: es2015
/* AssignmentPattern:
 *      ObjectAssignmentPattern
 *      ArrayAssignmentPattern
 * ArrayAssignmentPattern:
 *      [Elision<opt>   AssignmentRestElementopt   ]
 *      [AssignmentElementList]
 *      [AssignmentElementList, Elision<opt>   AssignmentRestElementopt   ]
 * AssignmentElementList:
 *      Elision<opt>   AssignmentElement
 *      AssignmentElementList, Elisionopt   AssignmentElement
 * AssignmentElement:
 *      LeftHandSideExpression   Initialiseropt
 *      AssignmentPattern   Initialiseropt
 * AssignmentRestElement:
 *      ...   LeftHandSideExpression
 */

// In a destructuring assignment expression, the type of the expression on the right must be assignable to the assignment target on the left.
// An expression of type S is considered assignable to an assignment target V if one of the following is true

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is the type Any, or

var [a0, a1]: any = undefined;
var [a2 = false, a3 = 1]: any = undefined;

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is a tuple- like type (section 3.3.3) with a property named N of a type that is assignable to the target given in E,
//        where N is the numeric index of E in the array assignment pattern, or
var [b0, b1, b2] = [2, 3, 4];
var [b3, b4, b5]: [number, number, string] = [1, 2, "string"];

function foo() {
    return [1, 2, 3];
}

var [b6, b7] = foo();
var [...b8] = foo();

//      S is not a tuple- like type and the numeric index signature type of S is assignable to the target given in E.
var temp = [1,2,3]
var [c0, c1] = [...temp];
var [c2] = [];
var [[[c3]], [[[[c4]]]]] = [[[]], [[[[]]]]]
var [[c5], c6]: [[string|number], boolean] = [[1], true];
var [, c7] = [1, 2, 3];
var [,,, c8] = [1, 2, 3, 4];
var [,,, c9] = [1, 2, 3, 4];
var [,,,...c10] = [1, 2, 3, 4, "hello"];
var [c11, c12, ...c13] = [1, 2, "string"];
var [c14, c15, c16] = [1, 2, "string"];

`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment1ES5iterable", async () => {
    await expectPass(
      `// @target: es2015
/* AssignmentPattern:
 *      ObjectAssignmentPattern
 *      ArrayAssignmentPattern
 * ArrayAssignmentPattern:
 *      [Elision<opt>   AssignmentRestElementopt   ]
 *      [AssignmentElementList]
 *      [AssignmentElementList, Elision<opt>   AssignmentRestElementopt   ]
 * AssignmentElementList:
 *      Elision<opt>   AssignmentElement
 *      AssignmentElementList, Elisionopt   AssignmentElement
 * AssignmentElement:
 *      LeftHandSideExpression   Initialiseropt
 *      AssignmentPattern   Initialiseropt
 * AssignmentRestElement:
 *      ...   LeftHandSideExpression
 */

// In a destructuring assignment expression, the type of the expression on the right must be assignable to the assignment target on the left.
// An expression of type S is considered assignable to an assignment target V if one of the following is true

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is the type Any, or

var [a0, a1]: any = undefined;
var [a2 = false, a3 = 1]: any = undefined;

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is a tuple- like type (section 3.3.3) with a property named N of a type that is assignable to the target given in E,
//        where N is the numeric index of E in the array assignment pattern, or
var [b0, b1, b2] = [2, 3, 4];
var [b3, b4, b5]: [number, number, string] = [1, 2, "string"];

function foo() {
    return [1, 2, 3];
}

var [b6, b7] = foo();
var [...b8] = foo();

//      S is not a tuple- like type and the numeric index signature type of S is assignable to the target given in E.
var temp = [1,2,3]
var [c0, c1] = [...temp];
var [c2] = [];
var [[[c3]], [[[[c4]]]]] = [[[]], [[[[]]]]]
var [[c5], c6]: [[string|number], boolean] = [[1], true];
var [, c7] = [1, 2, 3];
var [,,, c8] = [1, 2, 3, 4];
var [,,, c9] = [1, 2, 3, 4];
var [,,,...c10] = [1, 2, 3, 4, "hello"];
var [c11, c12, ...c13] = [1, 2, "string"];
var [c14, c15, c16] = [1, 2, "string"];

`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment1ES6", async () => {
    await expectPass(
      `// @target: es6

/* AssignmentPattern:
 *      ObjectAssignmentPattern
 *      ArrayAssignmentPattern
 * ArrayAssignmentPattern:
 *      [Elision<opt>   AssignmentRestElementopt   ]
 *      [AssignmentElementList]
 *      [AssignmentElementList, Elision<opt>   AssignmentRestElementopt   ]
 * AssignmentElementList:
 *      Elision<opt>   AssignmentElement
 *      AssignmentElementList, Elisionopt   AssignmentElement
 * AssignmentElement:
 *      LeftHandSideExpression   Initialiseropt
 *      AssignmentPattern   Initialiseropt
 * AssignmentRestElement:
 *      ...   LeftHandSideExpression
 */

// In a destructuring assignment expression, the type of the expression on the right must be assignable to the assignment target on the left.
// An expression of type S is considered assignable to an assignment target V if one of the following is true

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is the type Any, or

var [a0, a1]: any = undefined;
var [a2 = false, a3 = 1]: any = undefined;

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is a tuple- like type (section 3.3.3) with a property named N of a type that is assignable to the target given in E,
//        where N is the numeric index of E in the array assignment pattern, or
var [b0, b1, b2] = [2, 3, 4];
var [b3, b4, b5]: [number, number, string] = [1, 2, "string"];

function foo() {
    return [1, 2, 3];
}

var [b6, b7] = foo();
var [...b8] = foo();

//      S is not a tuple- like type and the numeric index signature type of S is assignable to the target given in E.
var temp = [1,2,3]
var [c0, c1] = [...temp];
var [c2] = [];
var [[[c3]], [[[[c4]]]]] = [[[]], [[[[]]]]]
var [[c5], c6]: [[string|number], boolean] = [[1], true];
var [, c7] = [1, 2, 3];
var [,,, c8] = [1, 2, 3, 4];
var [,,, c9] = [1, 2, 3, 4];
var [,,,...c10] = [1, 2, 3, 4, "hello"];
var [c11, c12, ...c13] = [1, 2, "string"];
var [c14, c15, c16] = [1, 2, "string"];`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment2", async () => {
    await expectPass(
      `// @target: es2015
// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is the type Any, or
var [[a0], [[a1]]] = []         // Error
var [[a2], [[a3]]] = undefined  // Error

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is a tuple- like type (section 3.3.3) with a property named N of a type that is assignable to the target given in E,
//        where N is the numeric index of E in the array assignment pattern, or
var [b0, b1, b2]: [number, boolean, string] = [1, 2, "string"];  // Error
interface J extends Array<Number> {
    2: number;
}

function bar(): J {
    return <[number, number, number]>[1, 2, 3];
}
var [b3 = "string", b4, b5] = bar();  // Error

// V is an array assignment pattern, S is the type Any or an array-like type (section 3.3.2), and, for each assignment element E in V,
//      S is not a tuple- like type and the numeric index signature type of S is assignable to the target given in E.
var temp = [1, 2, 3]
var [c0, c1]: [number, number] = [...temp];  // Error
var [c2, c3]: [string, string] = [...temp];  // Error

interface F {
    [idx: number]: boolean
}

function foo(idx: number): F {
    return {
        2: true
    }
}
var [c4, c5, c6] = foo(1);  // Error`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment3", async () => {
    await expectPass(
      `const [a, b = a] = [1]; // ok
const [c, d = c, e = e] = [1]; // error for e = e
const [f, g = f, h = i, i = f] = [1]; // error for h = i

(function ([a, b = a]) { // ok
})([1]);
(function ([c, d = c, e = e]) { // error for e = e
})([1]);
(function ([f, g = f, h = i, i = f]) { // error for h = i
})([1])`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment4", async () => {
    await expectPass(
      `// #35497


declare const data: number[] | null;
const [value] = data; // Error`,
      [],
    );
  });
  test("destructuringArrayBindingPatternAndAssignment5SiblingInitializer", async () => {
    await expectPass(
      `
// To be inferred as \`number\`
function f1() {
    const [a1, b1 = a1] = [1];
    const [a2, b2 = 1 + a2] = [1];
}

// To be inferred as \`string\`
function f2() {
    const [a1, b1 = a1] = ['hi'];
    const [a2, b2 = a2 + '!'] = ['hi'];
}

// To be inferred as \`string | number\`
function f3() {
    const [a1, b1 = a1] = ['hi', 1];
    const [a2, b2 = a2 + '!'] = ['hi', 1];
}

// Based on comment:
//   - https://github.com/microsoft/TypeScript/issues/49989#issuecomment-1852694486
declare const yadda: [number, number] | undefined
function f4() {
    const [ a, b = a ] = yadda ?? [];
}`,
      [],
    );
  });
  test("destructuringAssignabilityCheck", async () => {
    await expectPass(
      `
const [] = {}; // should be error
const {} = undefined; // error correctly
(([]) => 0)({}); // should be error
(({}) => 0)(undefined); // should be error

function foo({}: undefined) {
    return 0
}
function bar([]: {}) {
    return 0
}

const { }: undefined = 1

const []: {} = {}`,
      [],
    );
  });
  test("destructuringCatch", async () => {
    await expectPass(
      `
try {
    throw [0, 1];
}
catch ([a, b]) {
    a + b;
}

try {
    throw { a: 0, b: 1 };
}
catch ({a, b}) {
    a + b;
}

try {
    throw [{ x: [0], z: 1 }];
}
catch ([{x: [y], z}]) {
    y + z;
}

// Test of comment ranges. A fix to GH#11755 should update this.
try {
}
catch (/*Test comment ranges*/[/*a*/a]) {

}
`,
      [],
    );
  });
  test("destructuringControlFlow", async () => {
    await expectPass(
      `
function f1(obj: { a?: string }) {
    if (obj.a) {
        obj = {};
        let a1 = obj["a"];  // string | undefined
        let a2 = obj.a;  // string | undefined
    }
}

function f2(obj: [number, string] | null[]) {
    let a0 = obj[0];  // number | null
    let a1 = obj[1];  // string | null
    let [b0, b1] = obj;
    ([a0, a1] = obj);
    if (obj[0] && obj[1]) {
        let c0 = obj[0];  // number
        let c1 = obj[1];  // string
        let [d0, d1] = obj;
        ([c0, c1] = obj);
    }
}

function f3(obj: { a?: number, b?: string }) {
    if (obj.a && obj.b) {
        let { a, b } = obj;  // number, string
        ({ a, b } = obj);
    }
}

function f4() {
    let x: boolean;
    ({ x } = 0);  // Error
    ({ ["x"]: x } = 0);  // Error
    ({ ["x" + ""]: x } = 0);  // Errpr
}

// Repro from #31770

type KeyValue = [string, string?];
let [key, value]: KeyValue = ["foo"];
value.toUpperCase();  // Error
`,
      [],
    );
  });
  test("destructuringEvaluationOrder", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/39205
let trace: any[] = [];
let order = (n: any): any => trace.push(n);

// order(0) should evaluate before order(1) because the first element is undefined
let [{ [order(1)]: x } = order(0)] = [];

// order(0) should not evaluate because the first element is defined
let [{ [order(1)]: y } = order(0)] = [{}];

// order(0) should evaluate first (destructuring of object literal {})
// order(1) should evaluate next (initializer because property is undefined)
// order(2) should evaluate last (evaluate object binding pattern from initializer)
let { [order(0)]: { [order(2)]: z } = order(1), ...w } = {} as any;


// https://github.com/microsoft/TypeScript/issues/39181

// b = a must occur *after* 'a' has been assigned
let [{ ...a }, b = a]: any[] = [{ x: 1 }]
`,
      [],
    );
  });
  test("destructuringInFunctionType", async () => {
    await expectPass(
      `
interface a { a }
interface b { b }
interface c { c }

type T1 = ([a, b, c]);
type F1 = ([a, b, c]) => void;

type T2 = ({ a });
type F2 = ({ a }) => void;

type T3 = ([{ a: b }, { b: a }]);
type F3 = ([{ a: b }, { b: a }]) => void;

type T4 = ([{ a: [b, c] }]);
type F4 = ([{ a: [b, c] }]) => void;

type C1 = new ([{ a: [b, c] }]) => void;

var v1 = ([a, b, c]) => "hello";
var v2: ([a, b, c]) => string;
`,
      [],
    );
  });
  test("destructuringObjectAssignmentPatternWithNestedSpread", async () => {
    await expectPass(
      `let a: any, b: any, c: any = {x: {a: 1, y: 2}}, d: any;
({x: {a, ...b} = d} = c);`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment1ES5", async () => {
    await expectPass(
      `// @strict: false
// In a destructuring assignment expression, the type of the expression on the right must be assignable to the assignment target on the left.
// An expression of type S is considered assignable to an assignment target V if one of the following is true

// V is an object assignment pattern and, for each assignment property P in V,
//      S is the type Any, or
var { a1 }: any = undefined;
var { a2 }: any = {};

// V is an object assignment pattern and, for each assignment property P in V,
//      S has an apparent property with the property name specified in
//          P of a type that is assignable to the target given in P, or
var { b1, } = { b1:1, };
var { b2: { b21 } = { b21: "string" }  } = { b2: { b21: "world" } };
var {1: b3} = { 1: "string" };
var {b4 = 1}: any = { b4: 100000 };
var {b5: { b52 }  } = { b5: { b52 } };

// V is an object assignment pattern and, for each assignment property P in V,
//      P specifies a numeric property name and S has a numeric index signature
//          of a type that is assignable to the target given in P, or

interface F {
    [idx: number]: boolean;
}

function foo(): F {
    return {
        1: true
    };
}

function bar(): F {
    return {
        2: true
    };
}
var {1: c0} = foo();
var {1: c1} = bar();

// V is an object assignment pattern and, for each assignment property P in V,
//      S has a string index signature of a type that is assignable to the target given in P

interface F1 {
    [str: string]: number;
}

function foo1(): F1 {
    return {
        "prop1": 2
    }
}

var {"prop1": d1} = foo1();
var {"prop2": d1} = foo1();`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment1ES6", async () => {
    await expectPass(
      `// @strict: false
// In a destructuring assignment expression, the type of the expression on the right must be assignable to the assignment target on the left.
// An expression of type S is considered assignable to an assignment target V if one of the following is true

// V is an object assignment pattern and, for each assignment property P in V,
//      S is the type Any, or
var { a1 }: any = undefined;
var { a2 }: any = {};

// V is an object assignment pattern and, for each assignment property P in V,
//      S has an apparent property with the property name specified in
//          P of a type that is assignable to the target given in P, or
var { b1, } = { b1:1, };
var { b2: { b21 } = { b21: "string" }  } = { b2: { b21: "world" } };
var {1: b3} = { 1: "string" };
var {b4 = 1}: any = { b4: 100000 };
var {b5: { b52 }  } = { b5: { b52 } };

// V is an object assignment pattern and, for each assignment property P in V,
//      P specifies a numeric property name and S has a numeric index signature
//          of a type that is assignable to the target given in P, or

interface F {
    [idx: number]: boolean;
}

function foo(): F {
    return {
        1: true
    };
}

function bar(): F {
    return {
        2: true
    };
}
var {1: c0} = foo();
var {1: c1} = bar();

// V is an object assignment pattern and, for each assignment property P in V,
//      S has a string index signature of a type that is assignable to the target given in P

interface F1 {
    [str: string]: number;
}

function foo1(): F1 {
    return {
        "prop1": 2
    }
}

var {"prop1": d1} = foo1();
var {"prop2": d1} = foo1();`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment3", async () => {
    await expectError(
      `// @target: es2015
// Error
var {h?} = { h?: 1 };
var {i}: string | number = { i: 2 };
var {i1}: string | number| {} = { i1: 2 };
var { f2: {f21} = { f212: "string" } }: any = undefined;
var {1} = { 1 };
var {"prop"} = { "prop": 1 };
`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment4", async () => {
    await expectPass(
      `const {
    a = 1,
    b = 2,
    c = b, // ok
    d = a, // ok
    e = f, // error
    f = f  // error
} = { } as any;`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment5", async () => {
    await expectPass(
      `function a () {
    let x: number;
    let y: any
    ({ x, ...y } = ({ } as any));
}`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment6", async () => {
    await expectPass(
      `
const a = "a";
const b = "b";

const { [a]: aVal, [b]: bVal } = (() => {
	return { [a]: 1, [b]: 1 };
})();
console.log(aVal, bVal);`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment7", async () => {
    await expectPass(
      `
enum K {
    a = "a",
    b = "b"
}
const { [K.a]: aVal, [K.b]: bVal } = (() => {
	return { [K.a]: 1, [K.b]: 1 };
})();
console.log(aVal, bVal);`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment8", async () => {
    await expectPass(
      `
const K = {
    a: "a",
    b: "b"
}
const { [K.a]: aVal, [K.b]: bVal } = (() => {
	return { [K.a]: 1, [K.b]: 1 };
})();
console.log(aVal, bVal);`,
      [],
    );
  });
  test("destructuringObjectBindingPatternAndAssignment9SiblingInitializer", async () => {
    await expectPass(
      `
// To be inferred as \`number\`
function f1() {
    const { a1, b1 = a1 } = { a1: 1 };
    const { a2, b2 = 1 + a2 } = { a2: 1 };
}

// To be inferred as \`string\`
function f2() {
    const { a1, b1 = a1 } = { a1: 'hi' };
    const { a2, b2 = a2 + '!' } = { a2: 'hi' };
}

// To be inferred as \`string | number\`
function f3() {
    const { a1, b1 = a1 } = { a1: 'hi', b1: 1 };
    const { a2, b2 = a2 + '!' } = { a2: 'hi', b2: 1 };
}

// Based on comment:
//   - https://github.com/microsoft/TypeScript/issues/49989#issuecomment-1852694486
declare const yadda: { a?: number, b?: number } | undefined
function f4() {
    const { a, b = a } = yadda ?? {};
}
`,
      [],
    );
  });
  test("destructuringParameterDeclaration10", async () => {
    await expectPass(
      `
export function prepareConfig({
    additionalFiles: {
        json = []
    } = {}
}: {
  additionalFiles?: Partial<Record<"json" | "jsonc" | "json5", string[]>>;
} = {}) {
    json // string[]
}

export function prepareConfigWithoutAnnotation({
    additionalFiles: {
        json = []
    } = {}
} = {}) {
    json
}

export const prepareConfigWithContextualSignature: (param:{
  additionalFiles?: Partial<Record<"json" | "jsonc" | "json5", string[]>>;
}) => void = ({
    additionalFiles: {
        json = []
    } = {}
} = {}) => {
    json // string[]
}`,
      [],
    );
  });
  test("destructuringParameterDeclaration1ES5", async () => {
    await expectPass(
      `// @target: es2015
// A parameter declaration may specify either an identifier or a binding pattern.
// The identifiers specified in parameter declarations and binding patterns
// in a parameter list must be unique within that parameter list.

// If the declaration includes a type annotation, the parameter is of that type
function a1([a, b, [[c]]]: [number, number, string[][]]) { }
function a2(o: { x: number, a: number }) { }
function a3({j, k, l: {m, n}, q: [a, b, c]}: { j: number, k: string, l: { m: boolean, n: number }, q: (number|string)[] }) { };
function a4({x, a}: { x: number, a: number }) { }

a1([1, 2, [["world"]]]);
a1([1, 2, [["world"]], 3]);

// If the declaration includes an initializer expression (which is permitted only
// when the parameter list occurs in conjunction with a function body),
// the parameter type is the widened form (section 3.11) of the type of the initializer expression.

function b1(z = [undefined, null]) { };
function b2(z = null, o = { x: 0, y: undefined }) { }
function b3({z: {x, y: {j}}} = { z: { x: "hi", y: { j: 1 } } }) { }

interface F1 {
    b5(z, y, [, a, b], {p, m: { q, r}});
}

function b6([a, z, y] = [undefined, null, undefined]) { }
function b7([[a], b, [[c, d]]] = [[undefined], undefined, [[undefined, undefined]]]) { }

b1([1, 2, 3]);  // z is widen to the type any[]
b2("string", { x: 200, y: "string" });
b2("string", { x: 200, y: true });
b6(["string", 1, 2]);                    // Shouldn't be an error
b7([["string"], 1, [[true, false]]]);    // Shouldn't be an error


// If the declaration specifies a binding pattern, the parameter type is the implied type of that binding pattern (section 5.1.3)
enum Foo { a }
function c0({z: {x, y: {j}}}) { }
function c1({z} = { z: 10 }) { }
function c2({z = 10}) { }
function c3({b}: { b: number|string} = { b: "hello" }) { }
function c5([a, b, [[c]]]) { }
function c6([a, b, [[c=1]]]) { }

c0({z : { x: 1, y: { j: "world" } }});      // Implied type is { z: {x: any, y: {j: any}} }
c0({z : { x: "string", y: { j: true } }});  // Implied type is { z: {x: any, y: {j: any}} }

c1();             // Implied type is {z:number}?
c1({ z: 1 })      // Implied type is {z:number}? 

c2({});         // Implied type is {z?: number}
c2({z:1});      // Implied type is {z?: number}

c3({ b: 1 });     // Implied type is { b: number|string }.

c5([1, 2, [["string"]]]);               // Implied type is is [any, any, [[any]]]
c5([1, 2, [["string"]], false, true]);  // Implied type is is [any, any, [[any]]]

// A parameter can be marked optional by following its name or binding pattern with a question mark (?)
// or by including an initializer.

function d0(x?) { }
function d0(x = 10) { }

interface F2 {
    d3([a, b, c]?);
    d4({x, y, z}?);
    e0([a, b, c]);
}

class C2 implements F2 {
    constructor() { }
    d3() { }
    d4() { }
    e0([a, b, c]) { }
}

class C3 implements F2 {
    d3([a, b, c]) { }
    d4({x, y, z}) { }
    e0([a, b, c]) { }
}


function d5({x, y} = { x: 1, y: 2 }) { }
d5();  // Parameter is optional as its declaration included an initializer

// Destructuring parameter declarations do not permit type annotations on the individual binding patterns,
// as such annotations would conflict with the already established meaning of colons in object literals.
// Type annotations must instead be written on the top- level parameter declaration

function e1({x: number}) { }  // x has type any NOT number
function e2({x}: { x: number }) { }  // x is type number
function e3({x}: { x?: number }) { }  // x is an optional with type number
function e4({x: [number,string,any] }) { }  // x has type [any, any, any]
function e5({x: [a, b, c]}: { x: [number, number, number] }) { }  // x has type [any, any, any]
`,
      [],
    );
  });
  test("destructuringParameterDeclaration1ES5iterable", async () => {
    await expectPass(
      `// @target: es2015
// A parameter declaration may specify either an identifier or a binding pattern.
// The identifiers specified in parameter declarations and binding patterns
// in a parameter list must be unique within that parameter list.

// If the declaration includes a type annotation, the parameter is of that type
function a1([a, b, [[c]]]: [number, number, string[][]]) { }
function a2(o: { x: number, a: number }) { }
function a3({j, k, l: {m, n}, q: [a, b, c]}: { j: number, k: string, l: { m: boolean, n: number }, q: (number|string)[] }) { };
function a4({x, a}: { x: number, a: number }) { }

a1([1, 2, [["world"]]]);
a1([1, 2, [["world"]], 3]);

// If the declaration includes an initializer expression (which is permitted only
// when the parameter list occurs in conjunction with a function body),
// the parameter type is the widened form (section 3.11) of the type of the initializer expression.

function b1(z = [undefined, null]) { };
function b2(z = null, o = { x: 0, y: undefined }) { }
function b3({z: {x, y: {j}}} = { z: { x: "hi", y: { j: 1 } } }) { }

interface F1 {
    b5(z, y, [, a, b], {p, m: { q, r}});
}

function b6([a, z, y] = [undefined, null, undefined]) { }
function b7([[a], b, [[c, d]]] = [[undefined], undefined, [[undefined, undefined]]]) { }

b1([1, 2, 3]);  // z is widen to the type any[]
b2("string", { x: 200, y: "string" });
b2("string", { x: 200, y: true });
b6(["string", 1, 2]);                    // Shouldn't be an error
b7([["string"], 1, [[true, false]]]);    // Shouldn't be an error


// If the declaration specifies a binding pattern, the parameter type is the implied type of that binding pattern (section 5.1.3)
enum Foo { a }
function c0({z: {x, y: {j}}}) { }
function c1({z} = { z: 10 }) { }
function c2({z = 10}) { }
function c3({b}: { b: number|string} = { b: "hello" }) { }
function c5([a, b, [[c]]]) { }
function c6([a, b, [[c=1]]]) { }

c0({z : { x: 1, y: { j: "world" } }});      // Implied type is { z: {x: any, y: {j: any}} }
c0({z : { x: "string", y: { j: true } }});  // Implied type is { z: {x: any, y: {j: any}} }

c1();             // Implied type is {z:number}?
c1({ z: 1 })      // Implied type is {z:number}?

c2({});         // Implied type is {z?: number}
c2({z:1});      // Implied type is {z?: number}

c3({ b: 1 });     // Implied type is { b: number|string }.

c5([1, 2, [["string"]]]);               // Implied type is is [any, any, [[any]]]
c5([1, 2, [["string"]], false, true]);  // Implied type is is [any, any, [[any]]]

// A parameter can be marked optional by following its name or binding pattern with a question mark (?)
// or by including an initializer.

function d0(x?) { }
function d0(x = 10) { }

interface F2 {
    d3([a, b, c]?);
    d4({x, y, z}?);
    e0([a, b, c]);
}

class C2 implements F2 {
    constructor() { }
    d3() { }
    d4() { }
    e0([a, b, c]) { }
}

class C3 implements F2 {
    d3([a, b, c]) { }
    d4({x, y, z}) { }
    e0([a, b, c]) { }
}


function d5({x, y} = { x: 1, y: 2 }) { }
d5();  // Parameter is optional as its declaration included an initializer

// Destructuring parameter declarations do not permit type annotations on the individual binding patterns,
// as such annotations would conflict with the already established meaning of colons in object literals.
// Type annotations must instead be written on the top- level parameter declaration

function e1({x: number}) { }  // x has type any NOT number
function e2({x}: { x: number }) { }  // x is type number
function e3({x}: { x?: number }) { }  // x is an optional with type number
function e4({x: [number,string,any] }) { }  // x has type [any, any, any]
function e5({x: [a, b, c]}: { x: [number, number, number] }) { }  // x has type [any, any, any]
`,
      [],
    );
  });
  test("destructuringParameterDeclaration1ES6", async () => {
    await expectError(
      `// Conformance for emitting ES6

// A parameter declaration may specify either an identifier or a binding pattern.
// The identifiers specified in parameter declarations and binding patterns
// in a parameter list must be unique within that parameter list.

// If the declaration includes a type annotation, the parameter is of that type
function a1([a, b, [[c]]]: [number, number, string[][]]) { }
function a2(o: { x: number, a: number }) { }
function a3({j, k, l: {m, n}, q: [a, b, c]}: { j: number, k: string, l: { m: boolean, n: number }, q: (number|string)[] }) { };
function a4({x, a}: { x: number, a: number }) { }

a1([1, 2, [["world"]]]);
a1([1, 2, [["world"]], 3]);


// If the declaration includes an initializer expression (which is permitted only
// when the parameter list occurs in conjunction with a function body),
// the parameter type is the widened form (section 3.11) of the type of the initializer expression.

function b1(z = [undefined, null]) { };
function b2(z = null, o = { x: 0, y: undefined }) { }
function b3({z: {x, y: {j}}} = { z: { x: "hi", y: { j: 1 } } }) { }

interface F1 {
    b5(z, y, [, a, b], {p, m: { q, r}});
}

function b6([a, z, y] = [undefined, null, undefined]) { }
function b7([[a], b, [[c, d]]] = [[undefined], undefined, [[undefined, undefined]]]) { }

b1([1, 2, 3]);  // z is widen to the type any[]
b2("string", { x: 200, y: "string" });
b2("string", { x: 200, y: true });


// If the declaration specifies a binding pattern, the parameter type is the implied type of that binding pattern (section 5.1.3)
enum Foo { a }
function c0({z: {x, y: {j}}}) { }
function c1({z} = { z: 10 }) { }
function c2({z = 10}) { }
function c3({b}: { b: number|string} = { b: "hello" }) { }
function c5([a, b, [[c]]]) { }
function c6([a, b, [[c=1]]]) { }

c0({z : { x: 1, y: { j: "world" } }});      // Implied type is { z: {x: any, y: {j: any}} }
c0({z : { x: "string", y: { j: true } }});  // Implied type is { z: {x: any, y: {j: any}} }

c1();             // Implied type is {z:number}?
c1({ z: 1 })      // Implied type is {z:number}? 

c2({});         // Implied type is {z?: number}
c2({z:1});      // Implied type is {z?: number}

c3({ b: 1 });     // Implied type is { b: number|string }.

c5([1, 2, [["string"]]]);               // Implied type is is [any, any, [[any]]]
c5([1, 2, [["string"]], false, true]);  // Implied type is is [any, any, [[any]]]


// A parameter can be marked optional by following its name or binding pattern with a question mark (?)
// or by including an initializer.

interface F2 {
    d3([a, b, c]?);
    d4({x, y, z}?);
    e0([a, b, c]);
}

class C2 implements F2 {
    constructor() { }
    d3() { }
    d4() { }
    e0([a, b, c]) { }
}

class C3 implements F2 {
    d3([a, b, c]) { }
    d4({x, y, z}) { }
    e0([a, b, c]) { }
}

function d5({x, y} = { x: 1, y: 2 }) { }
d5();  // Parameter is optional as its declaration included an initializer

// Destructuring parameter declarations do not permit type annotations on the individual binding patterns,
// as such annotations would conflict with the already established meaning of colons in object literals.
// Type annotations must instead be written on the top- level parameter declaration

function e1({x: number}) { }  // x has type any NOT number
function e2({x}: { x: number }) { }  // x is type number
function e3({x}: { x?: number }) { }  // x is an optional with type number
function e4({x: [number,string,any] }) { }  // x has type [any, any, any]
function e5({x: [a, b, c]}: { x: [number, number, number] }) { }  // x has type [any, any, any]

function e6({x: [number, number, number]}) { }  // error, duplicate identifier;


`,
      [],
    );
  });
  test("destructuringParameterDeclaration2", async () => {
    await expectError(
      `// @target: es2015
// A parameter declaration may specify either an identifier or a binding pattern.
// The identifiers specified in parameter declarations and binding patterns
// in a parameter list must be unique within that parameter list.

// If the declaration includes a type annotation, the parameter is of that type
function a0([a, b, [[c]]]: [number, number, string[][]]) { }
a0([1, "string", [["world"]]);      // Error
a0([1, 2, [["world"]], "string"]);  // Error


// If the declaration includes an initializer expression (which is permitted only
// when the parameter list occurs in conjunction with a function body),
// the parameter type is the widened form (section 3.11) of the type of the initializer expression.

interface F1 {
    b0(z = 10, [[a, b], d, {u}] = [[1, 2], "string", { u: false }]);  // Error, no function body
}

function b1(z = null, o = { x: 0, y: undefined }) { }
function b2([a, z, y] = [undefined, null, undefined]) { }
function b3([[a], b, [[c, d]]] = [[undefined], undefined, [[undefined, undefined]]]) { }

b1("string", { x: "string", y: true });  // Error

// If the declaration specifies a binding pattern, the parameter type is the implied type of that binding pattern (section 5.1.3)
function c0({z: {x, y: {j}}}) { }
function c1({z} = { z: 10 }) { }
function c2({z = 10}) { }
function c3({b}: { b: number|string } = { b: "hello" }) { }
function c4([z], z: number) { }  // Error Duplicate identifier
function c5([a, b, [[c]]]) { }
function c6([a, b, [[c = 1]]]) { }

c0({ z: 1 });      // Error, implied type is { z: {x: any, y: {j: any}} }
c1({});            // Error, implied type is {z:number}?
c1({ z: true });   // Error, implied type is {z:number}?
c2({ z: false });  // Error, implied type is {z?: number}
c3({ b: true });   // Error, implied type is { b: number|string }. 
c5([1, 2, false, true]);   // Error, implied type is [any, any, [[any]]]
c6([1, 2, [["string"]]]);  // Error, implied type is [any, any, [[number]]]  // Use initializer

// A parameter can be marked optional by following its name or binding pattern with a question mark (?)
// or by including an initializer.  Initializers (including binding property or element initializers) are
// permitted only when the parameter list occurs in conjunction with a function body

function d1([a, b, c]?) { }  // Error, binding pattern can't be optional in implementation signature
function d2({x, y, z}?) { }  // Error, binding pattern can't be optional in implementation signature

interface F2 {
    d3([a, b, c]?);
    d4({x, y, z}?);
    e0([a, b, c]);
}

class C4 implements F2 {
    d3([a, b, c]?) { }  // Error, binding pattern can't be optional in implementation signature
    d4({x, y, c}) { }
    e0([a, b, q]) { }
}

// Destructuring parameter declarations do not permit type annotations on the individual binding patterns,
// as such annotations would conflict with the already established meaning of colons in object literals.
// Type annotations must instead be written on the top- level parameter declaration

function e0({x: [number, number, number]}) { }  // error, duplicate identifier;


`,
      [],
    );
  });
  test("destructuringParameterDeclaration3ES5", async () => {
    await expectPass(
      `// @target: es6

// If the parameter is a rest parameter, the parameter type is any[]
// A type annotation for a rest parameter must denote an array type.

// RestParameter:
//     ...   Identifier   TypeAnnotation(opt)

type arrayString = Array<String>
type someArray = Array<String> | number[];
type stringOrNumArray = Array<String|Number>;

function a1(...x: (number|string)[]) { }
function a2(...a) { }
function a3(...a: Array<String>) { }
function a4(...a: arrayString) { }
function a5(...a: stringOrNumArray) { }
function a9([a, b, [[c]]]) { }
function a10([a, b, [[c]], ...x]) { }
function a11([a, b, c, ...x]: number[]) { }


var array = [1, 2, 3];
var array2 = [true, false, "hello"];
a2([...array]);
a1(...array);

a9([1, 2, [["string"]], false, true]);   // Parameter type is [any, any, [[any]]]

a10([1, 2, [["string"]], false, true]);   // Parameter type is any[]
a10([1, 2, 3, false, true]);              // Parameter type is any[]
a10([1, 2]);                              // Parameter type is any[]
a11([1, 2]);                              // Parameter type is number[]

// Rest parameter with generic
function foo<T>(...a: T[]) { }
foo<number|string>("hello", 1, 2);
foo("hello", "world");

enum E { a, b }
const enum E1 { a, b }
function foo1<T extends Number>(...a: T[]) { }
foo1(1, 2, 3, E.a);
foo1(1, 2, 3, E1.a, E.b);


`,
      [],
    );
  });
  test("destructuringParameterDeclaration3ES5iterable", async () => {
    await expectPass(
      `// @target: es5, es2015

// If the parameter is a rest parameter, the parameter type is any[]
// A type annotation for a rest parameter must denote an array type.

// RestParameter:
//     ...   Identifier   TypeAnnotation(opt)

type arrayString = Array<String>
type someArray = Array<String> | number[];
type stringOrNumArray = Array<String|Number>;

function a1(...x: (number|string)[]) { }
function a2(...a) { }
function a3(...a: Array<String>) { }
function a4(...a: arrayString) { }
function a5(...a: stringOrNumArray) { }
function a9([a, b, [[c]]]) { }
function a10([a, b, [[c]], ...x]) { }
function a11([a, b, c, ...x]: number[]) { }


var array = [1, 2, 3];
var array2 = [true, false, "hello"];
a2([...array]);
a1(...array);

a9([1, 2, [["string"]], false, true]);   // Parameter type is [any, any, [[any]]]

a10([1, 2, [["string"]], false, true]);   // Parameter type is any[]
a10([1, 2, 3, false, true]);              // Parameter type is any[]
a10([1, 2]);                              // Parameter type is any[]
a11([1, 2]);                              // Parameter type is number[]

// Rest parameter with generic
function foo<T>(...a: T[]) { }
foo<number|string>("hello", 1, 2);
foo("hello", "world");

enum E { a, b }
const enum E1 { a, b }
function foo1<T extends Number>(...a: T[]) { }
foo1(1, 2, 3, E.a);
foo1(1, 2, 3, E1.a, E.b);


`,
      [],
    );
  });
  test("destructuringParameterDeclaration3ES6", async () => {
    await expectPass(
      `// @target: es6

// If the parameter is a rest parameter, the parameter type is any[]
// A type annotation for a rest parameter must denote an array type.

// RestParameter:
//     ...   Identifier   TypeAnnotation(opt)

type arrayString = Array<String>
type someArray = Array<String> | number[];
type stringOrNumArray = Array<String|Number>;

function a1(...x: (number|string)[]) { }
function a2(...a) { }
function a3(...a: Array<String>) { }
function a4(...a: arrayString) { }
function a5(...a: stringOrNumArray) { }
function a9([a, b, [[c]]]) { }
function a10([a, b, [[c]], ...x]) { }
function a11([a, b, c, ...x]: number[]) { }


var array = [1, 2, 3];
var array2 = [true, false, "hello"];
a2([...array]);
a1(...array);

a9([1, 2, [["string"]], false, true]);   // Parameter type is [any, any, [[any]]]

a10([1, 2, [["string"]], false, true]);   // Parameter type is any[]
a10([1, 2, 3, false, true]);              // Parameter type is any[]
a10([1, 2]);                              // Parameter type is any[]
a11([1, 2]);                              // Parameter type is number[]

// Rest parameter with generic
function foo<T>(...a: T[]) { }
foo<number|string>("hello", 1, 2);
foo("hello", "world");

enum E { a, b }
const enum E1 { a, b }
function foo1<T extends Number>(...a: T[]) { }
foo1(1, 2, 3, E.a);
foo1(1, 2, 3, E1.a, E.b);


`,
      [],
    );
  });
  test("destructuringParameterDeclaration4", async () => {
    await expectError(
      `// @target: es2015
// If the parameter is a rest parameter, the parameter type is any[]
// A type annotation for a rest parameter must denote an array type.

// RestParameter:
//     ...   Identifier   TypeAnnotation(opt)

type arrayString = Array<String>
type someArray = Array<String> | number[];
type stringOrNumArray = Array<String|Number>;

function a0(...x: [number, number, string]) { }  // Error, rest parameter must be array type
function a1(...x: (number|string)[]) { }
function a2(...a: someArray) { }  // Error, rest parameter must be array type
function a3(...b?) { }            // Error, can't be optional
function a4(...b = [1,2,3]) { }   // Error, can't have initializer
function a5([a, b, [[c]]]) { }
function a6([a, b, c, ...x]: number[]) { }


a1(1, 2, "hello", true);  // Error, parameter type is (number|string)[]
a1(...array2);            // Error parameter type is (number|string)[]
a5([1, 2, "string", false, true]);       // Error, parameter type is [any, any, [[any]]]
a5([1, 2]);                              // Error, parameter type is [any, any, [[any]]]
a6([1, 2, "string"]);                   // Error, parameter type is number[]


var temp = [1, 2, 3];
class C {
    constructor(public ...temp) { }  // Error, rest parameter can't have properties
}

// Rest parameter with generic
function foo1<T extends Number>(...a: T[]) { }
foo1(1, 2, "string", E1.a, E.b);  // Error


`,
      [],
    );
  });
  test("destructuringParameterDeclaration5", async () => {
    await expectPass(
      `// @target: es2015
// Parameter Declaration with generic

interface F { }
class Class implements F {
    constructor() { }
}

class SubClass extends Class {
    foo: boolean;
    constructor() { super(); }
}

class D implements F {
    foo: boolean
    constructor() { }
}

class SubD extends D {
    bar: number
    constructor() {
        super();
    }
}


function d0<T extends Class>({x} = { x: new Class() }) { }
function d1<T extends F>({x}: { x: F }) { }
function d2<T extends Class>({x}: { x: Class }) { }
function d3<T extends D>({y}: { y: D }) { }
function d4<T extends D>({y} = { y: new D() }) { }

var obj = new Class();
d0({ x: 1 });
d0({ x: {} });
d0({ x: "string" });

d1({ x: new Class() });
d1({ x: {} });
d1({ x: "string" });

d2({ x: new SubClass() });
d2({ x: {} });

d3({ y: new SubD() });
d3({ y: new SubClass() });
// Error
d3({ y: new Class() });
d3({});
d3({ y: 1 });
d3({ y: "world" });`,
      [],
    );
  });
  test("destructuringParameterDeclaration6", async () => {
    await expectError(
      `// @target: es2015
// A parameter declaration may specify either an identifier or a binding pattern.

// Reserved words are not allowed to be used as an identifier in parameter declaration
"use strict"

// Error
function a({while}) { }
function a1({public}) { }
function a4([while, for, public]){ }
function a5(...while) { }
function a6(...public) { }
function a7(...a: string) { }
a({ while: 1 });

// No Error
function b1({public: x}) { }
function b2({while: y}) { }
b1({ public: 1 });
b2({ while: 1 });

`,
      [],
    );
  });
  test("destructuringParameterDeclaration7ES5", async () => {
    await expectPass(
      `// @target: es5, es2015

interface ISomething {
    foo: string,
    bar: string
}

function foo({}, {foo, bar}: ISomething) {}

function baz([], {foo, bar}: ISomething) {}

function one([], {}) {}

function two([], [a, b, c]: number[]) {}
`,
      [],
    );
  });
  test("destructuringParameterDeclaration7ES5iterable", async () => {
    await expectPass(
      `// @target: es5, es2015

interface ISomething {
    foo: string,
    bar: string
}

function foo({}, {foo, bar}: ISomething) {}

function baz([], {foo, bar}: ISomething) {}

function one([], {}) {}

function two([], [a, b, c]: number[]) {}
`,
      [],
    );
  });
  test("destructuringParameterDeclaration8", async () => {
    await expectPass(
      `// explicit type annotation should cause \`method\` to have type 'x' | 'y'
// both inside and outside \`test\`.
function test({
    method = 'z',
    nested: { p = 'c' }
}: {
    method?: 'x' | 'y',
    nested?: { p: 'a' | 'b' }
})
{
    method
    p
}

test({});
test({ method: 'x', nested: { p: 'a' } })
test({ method: 'z', nested: { p: 'b' } })
test({ method: 'one', nested: { p: 'a' } })`,
      [],
    );
  });
  test("destructuringParameterDeclaration9", async () => {
    await expectPass(
      `
// https://github.com/microsoft/TypeScript/issues/59936


/**
 * @param {Object} [config]
 * @param {Partial<Record<'json' | 'jsonc' | 'json5', string[]>>} [config.additionalFiles]
 */
export function prepareConfig({
    additionalFiles: {
        json = []
    } = {}
} = {}) {
    json // string[]
}

export function prepareConfigWithoutAnnotation({
    additionalFiles: {
        json = []
    } = {}
} = {}) {
    json
}

/** @type {(param: {
  additionalFiles?: Partial<Record<"json" | "jsonc" | "json5", string[]>>;
}) => void} */
export const prepareConfigWithContextualSignature = ({
    additionalFiles: {
        json = []
    } = {}
} = {})=>  {
    json // string[]
}

// Additional repros from https://github.com/microsoft/TypeScript/issues/59936

/**
 * @param {{ a?: { json?: string[] }}} [config]
 */
function f1({ a: { json = [] } = {} } = {}) { return json }

/**
 * @param {[[string[]?]?]} [x]
 */
function f2([[json = []] = []] = []) { return json }`,
      [],
    );
  });
  test("destructuringParameterProperties1", async () => {
    await expectPass(
      `// @module: commonjs
class C1 {
    constructor(public [x, y, z]: string[]) {
    }
}

type TupleType1 = [string, number, boolean];

class C2 {
    constructor(public [x, y, z]: TupleType1) {
    }
}

type ObjType1 = { x: number; y: string; z: boolean }

class C3 {
    constructor(public { x, y, z }: ObjType1) {
    }
}

var c1 = new C1([]);
c1 = new C1(["larry", "{curly}", "moe"]);
var useC1Properties = c1.x === c1.y && c1.y === c1.z;

var c2 = new C2(["10", 10, !!10]);
var [c2_x, c2_y, c2_z] = [c2.x, c2.y, c2.z];

var c3 = new C3({x: 0, y: "", z: false});
c3 = new C3({x: 0, "y": "y", z: true});
var [c3_x, c3_y, c3_z] = [c3.x, c3.y, c3.z];`,
      [],
    );
  });
  test("destructuringParameterProperties2", async () => {
    await expectPass(
      `// @module: commonjs
class C1 {
    constructor(private k: number, private [a, b, c]: [number, string, boolean]) {
        if ((b === undefined && c === undefined) || (this.b === undefined && this.c === undefined)) {
            this.a = a || k;
        }
    }

    public getA() {
        return this.a
    }

    public getB() {
        return this.b
    }

    public getC() {
        return this.c;
    }
}

var x = new C1(undefined, [0, undefined, ""]);
var [x_a, x_b, x_c] = [x.getA(), x.getB(), x.getC()];

var y = new C1(10, [0, "", true]);
var [y_a, y_b, y_c] = [y.getA(), y.getB(), y.getC()];

var z = new C1(10, [undefined, "", null]);
var [z_a, z_b, z_c] = [z.getA(), z.getB(), z.getC()];
`,
      [],
    );
  });
  test("destructuringParameterProperties3", async () => {
    await expectPass(
      `// @module: commonjs
class C1<T, U, V> {
    constructor(private k: T, private [a, b, c]: [T,U,V]) {
        if ((b === undefined && c === undefined) || (this.b === undefined && this.c === undefined)) {
            this.a = a || k;
        }
    }

    public getA() {
        return this.a
    }

    public getB() {
        return this.b
    }

    public getC() {
        return this.c;
    }
}

var x = new C1(undefined, [0, true, ""]);
var [x_a, x_b, x_c] = [x.getA(), x.getB(), x.getC()];

var y = new C1(10, [0, true, true]);
var [y_a, y_b, y_c] = [y.getA(), y.getB(), y.getC()];

var z = new C1(10, [undefined, "", ""]);
var [z_a, z_b, z_c] = [z.getA(), z.getB(), z.getC()];

var w = new C1(10, [undefined, undefined, undefined]);
var [z_a, z_b, z_c] = [z.getA(), z.getB(), z.getC()];
`,
      [],
    );
  });
  test("destructuringParameterProperties4", async () => {
    await expectPass(
      `// @target: es6

class C1<T, U, V> {
    constructor(private k: T, protected [a, b, c]: [T,U,V]) {
        if ((b === undefined && c === undefined) || (this.b === undefined && this.c === undefined)) {
            this.a = a || k;
        }
    }

    public getA() {
        return this.a
    }

    public getB() {
        return this.b
    }

    public getC() {
        return this.c;
    }
}

class C2 extends C1<number, string, boolean> {
    public doSomethingWithSuperProperties() {
        return \`\${this.a} \${this.b} \${this.c}\`;
    }
}
`,
      [],
    );
  });
  test("destructuringParameterProperties5", async () => {
    await expectPass(
      `// @module: commonjs
type ObjType1 = { x: number; y: string; z: boolean }
type TupleType1 = [ObjType1, number, string]

class C1 {
    constructor(public [{ x1, x2, x3 }, y, z]: TupleType1) {
        var foo: any = x1 || x2 || x3 || y || z;
        var bar: any = this.x1 || this.x2 || this.x3 || this.y || this.z;
    }
}

var a = new C1([{ x1: 10, x2: "", x3: true }, "", false]);
var [a_x1, a_x2, a_x3, a_y, a_z] = [a.x1, a.x2, a.x3, a.y, a.z];`,
      [],
    );
  });
  test("destructuringReassignsRightHandSide", async () => {
    await expectPass(
      `var foo: any = { foo: 1, bar: 2 };
var bar: any;

// reassignment in destructuring pattern
({ foo, bar } = foo);

// reassignment in subsequent var
var { foo, baz } = foo;`,
      [],
    );
  });
  test("destructuringSameNames", async () => {
    await expectPass(
      `// Valid cases

let { foo, foo: bar } = { foo: 1 };
({ foo, foo } = { foo: 2 });
({ foo, foo: bar } = { foo: 3 });
({ foo: bar, foo } = { foo: 4 });
({ foo, bar: foo } = { foo: 3, bar: 33 });
({ bar: foo, foo } = { foo: 4, bar: 44 });
({ foo: bar, foo: bar } = { foo: 5 });
({ foo: bar, bar: foo } = { foo: 6, bar: 66 });
({ foo: bar, foo: bar } = { foo: 7 });

[foo, foo] = [111, 1111];
[foo, foo] = [222, 2222];
[bar, foo, foo] = [333, 3333, 33333];
[foo, bar, foo] = [333, 3333, 33333];
[foo, foo, bar] = [444, 4444, 44444];

// Error cases

let { foo1, foo1 } = { foo1: 10 };
let { foo2, bar2: foo2 } = { foo2: 20, bar2: 220 };
let { bar3: foo3, foo3 } = { foo3: 30, bar3: 330 };
const { foo4, foo4 } = { foo4: 40 };
const { foo5, bar5: foo5 } = { foo5: 50, bar5: 550 };
const { bar6: foo6, foo6 } = { foo6: 60, bar6: 660 };

let [blah1, blah1] = [111, 222];
const [blah2, blah2] = [333, 444];`,
      [],
    );
  });
  test("destructuringSpread", async () => {
    await expectPass(
      `const { x } = {
  ...{},
  x: 0
};

const { y } = {
  y: 0,
  ...{}
};

const { z, a, b } = {
  z: 0,
  ...{ a: 0, b: 0 }
};

const { c, d, e, f, g } = {
  ...{
    ...{
      ...{
        c: 0,
      },
      d: 0
    },
    e: 0
  },
  f: 0
};`,
      [],
    );
  });
  test("destructuringTypeAssertionsES5_1", async () => {
    await expectPass(`var { x } = <any>foo();`, []);
  });
  test("destructuringTypeAssertionsES5_2", async () => {
    await expectPass(`var { x } = (<any>foo());`, []);
  });
  test("destructuringTypeAssertionsES5_3", async () => {
    await expectPass(`var { x } = <any>(foo());`, []);
  });
  test("destructuringTypeAssertionsES5_4", async () => {
    await expectPass(`var { x } = <any><any>foo();`, []);
  });
  test("destructuringTypeAssertionsES5_5", async () => {
    await expectPass(`var { x } = <any>0;`, []);
  });
  test("destructuringTypeAssertionsES5_6", async () => {
    await expectPass(`var { x } = <any>new Foo;`, []);
  });
  test("destructuringTypeAssertionsES5_7", async () => {
    await expectPass(`var { x } = <any><any>new Foo;`, []);
  });
  test("destructuringVariableDeclaration1ES5", async () => {
    await expectPass(
      `// @target: es2015
// The type T associated with a destructuring variable declaration is determined as follows:
//      If the declaration includes a type annotation, T is that type.
var {a1, a2}: { a1: number, a2: string } = { a1: 10, a2: "world" }
var [a3, [[a4]], a5]: [number, [[string]], boolean] = [1, [["hello"]], true];

// The type T associated with a destructuring variable declaration is determined as follows:
//      Otherwise, if the declaration includes an initializer expression, T is the type of that initializer expression.
var { b1: { b11 } = { b11: "string" }  } = { b1: { b11: "world" } };
var temp = { t1: true, t2: "false" };
var [b2 = 3, b3 = true, b4 = temp] = [3, false, { t1: false, t2: "hello" }];
var [b5 = 3, b6 = true, b7 = temp] = [undefined, undefined, undefined];

// The type T associated with a binding element is determined as follows:
//      If the binding element is a rest element, T is an array type with
//          an element type E, where E is the type of the numeric index signature of S.
var [...c1] = [1,2,3]; 
var [...c2] = [1,2,3, "string"]; 

// The type T associated with a binding element is determined as follows:
//      Otherwise, if S is a tuple- like type (section 3.3.3):
//          	Let N be the zero-based index of the binding element in the array binding pattern.
// 	            If S has a property with the numerical name N, T is the type of that property.
var [d1,d2] = [1,"string"]	

// The type T associated with a binding element is determined as follows:
//      Otherwise, if S is a tuple- like type (section 3.3.3):
//              Otherwise, if S has a numeric index signature, T is the type of the numeric index signature.
var temp1 = [true, false, true]
var [d3, d4] = [1, "string", ...temp1];

//  Combining both forms of destructuring,
var {e: [e1, e2, e3 = { b1: 1000, b4: 200 }]} = { e: [1, 2, { b1: 4, b4: 0 }] }; 
var {f: [f1, f2, { f3: f4, f5 }, , ]} = { f: [1, 2, { f3: 4, f5: 0 }] };

// When a destructuring variable declaration, binding property, or binding element specifies
// an initializer expression, the type of the initializer expression is required to be assignable
// to the widened form of the type associated with the destructuring variable declaration, binding property, or binding element.
var {g: {g1 = [undefined, null]}}: { g: { g1: any[] } } = { g: { g1: [1, 2] } };
var {h: {h1 = [undefined, null]}}: { h: { h1: number[] } } = { h: { h1: [1, 2] } };

`,
      [],
    );
  });
  test("destructuringVariableDeclaration1ES5iterable", async () => {
    await expectPass(
      `// @target: es5,es2015
// The type T associated with a destructuring variable declaration is determined as follows:
//      If the declaration includes a type annotation, T is that type.
var {a1, a2}: { a1: number, a2: string } = { a1: 10, a2: "world" }
var [a3, [[a4]], a5]: [number, [[string]], boolean] = [1, [["hello"]], true];

// The type T associated with a destructuring variable declaration is determined as follows:
//      Otherwise, if the declaration includes an initializer expression, T is the type of that initializer expression.
var { b1: { b11 } = { b11: "string" }  } = { b1: { b11: "world" } };
var temp = { t1: true, t2: "false" };
var [b2 = 3, b3 = true, b4 = temp] = [3, false, { t1: false, t2: "hello" }];
var [b5 = 3, b6 = true, b7 = temp] = [undefined, undefined, undefined];

// The type T associated with a binding element is determined as follows:
//      If the binding element is a rest element, T is an array type with
//          an element type E, where E is the type of the numeric index signature of S.
var [...c1] = [1,2,3];
var [...c2] = [1,2,3, "string"];

// The type T associated with a binding element is determined as follows:
//      Otherwise, if S is a tuple- like type (section 3.3.3):
//          	Let N be the zero-based index of the binding element in the array binding pattern.
// 	            If S has a property with the numerical name N, T is the type of that property.
var [d1,d2] = [1,"string"]

// The type T associated with a binding element is determined as follows:
//      Otherwise, if S is a tuple- like type (section 3.3.3):
//              Otherwise, if S has a numeric index signature, T is the type of the numeric index signature.
var temp1 = [true, false, true]
var [d3, d4] = [1, "string", ...temp1];

//  Combining both forms of destructuring,
var {e: [e1, e2, e3 = { b1: 1000, b4: 200 }]} = { e: [1, 2, { b1: 4, b4: 0 }] };
var {f: [f1, f2, { f3: f4, f5 }, , ]} = { f: [1, 2, { f3: 4, f5: 0 }] };

// When a destructuring variable declaration, binding property, or binding element specifies
// an initializer expression, the type of the initializer expression is required to be assignable
// to the widened form of the type associated with the destructuring variable declaration, binding property, or binding element.
var {g: {g1 = [undefined, null]}}: { g: { g1: any[] } } = { g: { g1: [1, 2] } };
var {h: {h1 = [undefined, null]}}: { h: { h1: number[] } } = { h: { h1: [1, 2] } };

`,
      [],
    );
  });
  test("destructuringVariableDeclaration1ES6", async () => {
    await expectPass(
      `// @target: es6
// The type T associated with a destructuring variable declaration is determined as follows:
//      If the declaration includes a type annotation, T is that type.
var {a1, a2}: { a1: number, a2: string } = { a1: 10, a2: "world" }
var [a3, [[a4]], a5]: [number, [[string]], boolean] = [1, [["hello"]], true];

// The type T associated with a destructuring variable declaration is determined as follows:
//      Otherwise, if the declaration includes an initializer expression, T is the type of that initializer expression.
var { b1: { b11 } = { b11: "string" }  } = { b1: { b11: "world" } };
var temp = { t1: true, t2: "false" };
var [b2 = 3, b3 = true, b4 = temp] = [3, false, { t1: false, t2: "hello" }];
var [b5 = 3, b6 = true, b7 = temp] = [undefined, undefined, undefined];

// The type T associated with a binding element is determined as follows:
//      If the binding element is a rest element, T is an array type with
//          an element type E, where E is the type of the numeric index signature of S.
var [...c1] = [1,2,3]; 
var [...c2] = [1,2,3, "string"]; 

// The type T associated with a binding element is determined as follows:
//      Otherwise, if S is a tuple- like type (section 3.3.3):
//          	Let N be the zero-based index of the binding element in the array binding pattern.
// 	            If S has a property with the numerical name N, T is the type of that property.
var [d1,d2] = [1,"string"]	

// The type T associated with a binding element is determined as follows:
//      Otherwise, if S is a tuple- like type (section 3.3.3):
//              Otherwise, if S has a numeric index signature, T is the type of the numeric index signature.
var temp1 = [true, false, true]
var [d3, d4] = [1, "string", ...temp1];

//  Combining both forms of destructuring,
var {e: [e1, e2, e3 = { b1: 1000, b4: 200 }]} = { e: [1, 2, { b1: 4, b4: 0 }] }; 
var {f: [f1, f2, { f3: f4, f5 }, , ]} = { f: [1, 2, { f3: 4, f5: 0 }] };

// When a destructuring variable declaration, binding property, or binding element specifies
// an initializer expression, the type of the initializer expression is required to be assignable
// to the widened form of the type associated with the destructuring variable declaration, binding property, or binding element.
var {g: {g1 = [undefined, null]}}: { g: { g1: any[] } } = { g: { g1: [1, 2] } };
var {h: {h1 = [undefined, null]}}: { h: { h1: number[] } } = { h: { h1: [1, 2] } };

`,
      [],
    );
  });
  test("destructuringVariableDeclaration2", async () => {
    await expectPass(
      `// @target: es2015
// The type T associated with a destructuring variable declaration is determined as follows:
//      If the declaration includes a type annotation, T is that type.
var {a1, a2}: { a1: number, a2: string } = { a1: true, a2: 1 }               // Error
var [a3, [[a4]], a5]: [number, [[string]], boolean] = [1, [[false]], true];  // Error

// The type T associated with a destructuring variable declaration is determined as follows:
//      Otherwise, if the declaration includes an initializer expression, T is the type of that initializer expression.
var temp = { t1: true, t2: "false" };
var [b0 = 3, b1 = true, b2 = temp] = [3, false, { t1: false, t2: 5}];  // Error

// The type T associated with a binding element is determined as follows:
//      If the binding element is a rest element, T is an array type with
//          an element type E, where E is the type of the numeric index signature of S.
var [c1, c2, { c3: c4, c5 }, , ...c6] = [1, 2, { c3: 4, c5: 0 }];  // Error

// When a destructuring variable declaration, binding property, or binding element specifies
// an initializer expression, the type of the initializer expression is required to be assignable
// to the widened form of the type associated with the destructuring variable declaration, binding property, or binding element.
var {d: {d1 = ["string", null]}}: { d: { d1: number[] } } = { d: { d1: [1, 2] } };  // Error`,
      [],
    );
  });
  test("destructuringVoid", async () => {
    await expectPass(
      `declare const v: void;
const {} = v;
`,
      [],
    );
  });
  test("destructuringVoidStrictNullChecks", async () => {
    await expectPass(
      `declare const v: void;
const {} = v;
`,
      [],
    );
  });
  test("destructuringWithLiteralInitializers", async () => {
    await expectPass(
      `// (arg: { x: any, y: any }) => void
function f1({ x, y }) { }
f1({ x: 1, y: 1 });

// (arg: { x: any, y?: number }) => void
function f2({ x, y = 0 }) { }
f2({ x: 1 });
f2({ x: 1, y: 1 });

// (arg: { x?: number, y?: number }) => void
function f3({ x = 0, y = 0 }) { }
f3({});
f3({ x: 1 });
f3({ y: 1 });
f3({ x: 1, y: 1 });

// (arg?: { x: number, y: number }) => void
function f4({ x, y } = { x: 0, y: 0 }) { }
f4();
f4({ x: 1, y: 1 });

// (arg?: { x: number, y?: number }) => void
function f5({ x, y = 0 } = { x: 0 }) { }
f5();
f5({ x: 1 });
f5({ x: 1, y: 1 });

// (arg?: { x?: number, y?: number }) => void
function f6({ x = 0, y = 0 } = {}) { }
f6();
f6({});
f6({ x: 1 });
f6({ y: 1 });
f6({ x: 1, y: 1 });

// (arg?: { a: { x?: number, y?: number } }) => void
function f7({ a: { x = 0, y = 0 } } = { a: {} }) { }
f7();
f7({ a: {} });
f7({ a: { x: 1 } });
f7({ a: { y: 1 } });
f7({ a: { x: 1, y: 1 } });

// (arg: [any, any]) => void
function g1([x, y]) { }
g1([1, 1]);

// (arg: [number, number]) => void
function g2([x = 0, y = 0]) { }
g2([1, 1]);

// (arg?: [number, number]) => void
function g3([x, y] = [0, 0]) { }
g3();
g3([1, 1]);

// (arg?: [number, number]) => void
function g4([x, y = 0] = [0]) { }
g4();
g4([1, 1]);

// (arg?: [number, number]) => void
function g5([x = 0, y = 0] = []) { }
g5();
g5([1, 1]);
`,
      [],
    );
  });
  test("destructuringWithLiteralInitializers2", async () => {
    await expectPass(
      `
function f00([x, y]) {}
function f01([x, y] = []) {}
function f02([x, y] = [1]) {}
function f03([x, y] = [1, 'foo']) {}

function f10([x = 0, y]) {}
function f11([x = 0, y] = []) {}
function f12([x = 0, y] = [1]) {}
function f13([x = 0, y] = [1, 'foo']) {}

function f20([x = 0, y = 'bar']) {}
function f21([x = 0, y = 'bar'] = []) {}
function f22([x = 0, y = 'bar'] = [1]) {}
function f23([x = 0, y = 'bar'] = [1, 'foo']) {}

declare const nx: number | undefined;
declare const sx: string | undefined;

function f30([x = 0, y = 'bar']) {}
function f31([x = 0, y = 'bar'] = []) {}
function f32([x = 0, y = 'bar'] = [nx]) {}
function f33([x = 0, y = 'bar'] = [nx, sx]) {}

function f40([x = 0, y = 'bar']) {}
function f41([x = 0, y = 'bar'] = []) {}
function f42([x = 0, y = 'bar'] = [sx]) {}
function f43([x = 0, y = 'bar'] = [sx, nx]) {}
`,
      [],
    );
  });
  test("emptyArrayBindingPatternParameter01", async () => {
    await expectPass(
      `
function f([]) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyArrayBindingPatternParameter02", async () => {
    await expectPass(
      `
function f(a, []) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyArrayBindingPatternParameter03", async () => {
    await expectPass(
      `
function f(a, []) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyArrayBindingPatternParameter04", async () => {
    await expectPass(
      `
function f([] = [1,2,3,4]) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyAssignmentPatterns01_ES5", async () => {
    await expectPass(
      `
var a: any;

({} = a);
([] = a);

var [,] = [1,2];`,
      [],
    );
  });
  test("emptyAssignmentPatterns01_ES5iterable", async () => {
    await expectPass(
      `
var a: any;

({} = a);
([] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns01_ES6", async () => {
    await expectPass(
      `
var a: any;

({} = a);
([] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns02_ES5", async () => {
    await expectPass(
      `
var a: any;
let x, y, z, a1, a2, a3;

({} = { x, y, z } = a);
([] = [ a1, a2, a3] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns02_ES5iterable", async () => {
    await expectPass(
      `
var a: any;
let x, y, z, a1, a2, a3;

({} = { x, y, z } = a);
([] = [ a1, a2, a3] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns02_ES6", async () => {
    await expectPass(
      `
var a: any;
let x, y, z, a1, a2, a3;

({} = { x, y, z } = a);
([] = [ a1, a2, a3] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns03_ES5", async () => {
    await expectPass(
      `
var a: any;

({} = {} = a);
([] = [] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns03_ES5iterable", async () => {
    await expectPass(
      `
var a: any;

({} = {} = a);
([] = [] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns03_ES6", async () => {
    await expectPass(
      `
var a: any;

({} = {} = a);
([] = [] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns04_ES5", async () => {
    await expectPass(
      `
var a: any;
let x, y, z, a1, a2, a3;

({ x, y, z } = {} = a);
([ a1, a2, a3] = [] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns04_ES5iterable", async () => {
    await expectPass(
      `
var a: any;
let x, y, z, a1, a2, a3;

({ x, y, z } = {} = a);
([ a1, a2, a3] = [] = a);`,
      [],
    );
  });
  test("emptyAssignmentPatterns04_ES6", async () => {
    await expectPass(
      `
var a: any;
let x, y, z, a1, a2, a3;

({ x, y, z } = {} = a);
([ a1, a2, a3] = [] = a);`,
      [],
    );
  });
  test("emptyObjectBindingPatternParameter01", async () => {
    await expectPass(
      `
function f({}) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyObjectBindingPatternParameter02", async () => {
    await expectPass(
      `
function f(a, {}) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyObjectBindingPatternParameter03", async () => {
    await expectPass(
      `
function f({}, a) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyObjectBindingPatternParameter04", async () => {
    await expectPass(
      `
function f({} = {a: 1, b: "2", c: true}) {
    var x, y, z;
}`,
      [],
    );
  });
  test("emptyVariableDeclarationBindingPatterns01_ES5", async () => {
    await expectPass(
      `
(function () {
    var a: any;

    var {} = a;
    let {} = a;
    const {} = a;

    var [] = a;
    let [] = a;
    const [] = a;

    var {} = a, [] = a;
    let {} = a, [] = a;
    const {} = a, [] = a;

    var { p1: {}, p2: [] } = a;
    let { p1: {}, p2: [] } = a;
    const { p1: {}, p2: [] } = a;

    for (var {} = {}, {} = {}; false; void 0) {
    }

    function f({} = a, [] = a, { p: {} = a} = a) {
        return ({} = a, [] = a, { p: {} = a } = a) => a;
    }
})();

(function () {
    const ns: number[][] = [];

    for (var {} of ns) {
    }

    for (let {} of ns) {
    }

    for (const {} of ns) {
    }

    for (var [] of ns) {
    }

    for (let [] of ns) {
    }

    for (const [] of ns) {
    }
})();`,
      [],
    );
  });
  test("emptyVariableDeclarationBindingPatterns01_ES5iterable", async () => {
    await expectPass(
      `
(function () {
    var a: any;

    var {} = a;
    let {} = a;
    const {} = a;

    var [] = a;
    let [] = a;
    const [] = a;

    var {} = a, [] = a;
    let {} = a, [] = a;
    const {} = a, [] = a;

    var { p1: {}, p2: [] } = a;
    let { p1: {}, p2: [] } = a;
    const { p1: {}, p2: [] } = a;

    for (var {} = {}, {} = {}; false; void 0) {
    }

    function f({} = a, [] = a, { p: {} = a} = a) {
        return ({} = a, [] = a, { p: {} = a } = a) => a;
    }
})();

(function () {
    const ns: number[][] = [];

    for (var {} of ns) {
    }

    for (let {} of ns) {
    }

    for (const {} of ns) {
    }

    for (var [] of ns) {
    }

    for (let [] of ns) {
    }

    for (const [] of ns) {
    }
})();`,
      [],
    );
  });
  test("emptyVariableDeclarationBindingPatterns01_ES6", async () => {
    await expectPass(
      `
(function () {
    var a: any;

    var {} = a;
    let {} = a;
    const {} = a;

    var [] = a;
    let [] = a;
    const [] = a;

    var {} = a, [] = a;
    let {} = a, [] = a;
    const {} = a, [] = a;

    var { p1: {}, p2: [] } = a;
    let { p1: {}, p2: [] } = a;
    const { p1: {}, p2: [] } = a;

    for (var {} = {}, {} = {}; false; void 0) {
    }

    function f({} = a, [] = a, { p: {} = a} = a) {
        return ({} = a, [] = a, { p: {} = a } = a) => a;
    }
})();

(function () {
    const ns: number[][] = [];

    for (var {} of ns) {
    }

    for (let {} of ns) {
    }

    for (const {} of ns) {
    }

    for (var [] of ns) {
    }

    for (let [] of ns) {
    }

    for (const [] of ns) {
    }
})();`,
      [],
    );
  });
  test("emptyVariableDeclarationBindingPatterns02_ES5", async () => {
    await expectError(
      `
(function () {
    var {};
    let {};
    const {};

    var [];
    let [];
    const [];
})();`,
      [],
    );
  });
  test("emptyVariableDeclarationBindingPatterns02_ES5iterable", async () => {
    await expectError(
      `
(function () {
    var {};
    let {};
    const {};

    var [];
    let [];
    const [];
})();`,
      [],
    );
  });
  test("emptyVariableDeclarationBindingPatterns02_ES6", async () => {
    await expectError(
      `
(function () {
    var {};
    let {};
    const {};

    var [];
    let [];
    const [];
})();`,
      [],
    );
  });
  test("iterableArrayPattern1", async () => {
    await expectPass(
      `class SymbolIterator {
    next() {
        return {
            value: Symbol(),
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var [a, b] = new SymbolIterator;`,
      [],
    );
  });
  test("iterableArrayPattern10", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun([a, b]) { }
fun(new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern11", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun([a, b] = new FooIterator) { }
fun(new FooIterator);
`,
      [],
    );
  });
  test("iterableArrayPattern12", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun([a, ...b] = new FooIterator) { }
fun(new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern13", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun([a, ...b]) { }
fun(new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern14", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun(...[a, ...b]) { }
fun(new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern15", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun(...[a, b]: Bar[]) { }
fun(...new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern16", async () => {
    await expectPass(
      `function fun(...[a, b]: [Bar, Bar][]) { }
fun(...new FooIteratorIterator);
class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

class FooIteratorIterator {
    next() {
        return {
            value: new FooIterator,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}`,
      [],
    );
  });
  test("iterableArrayPattern17", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun(...[a, b]: Bar[]) { }
fun(new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern18", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun([a, b]: Bar[]) { }
fun(new FooIterator);`,
      [],
    );
  });
  test("iterableArrayPattern19", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooArrayIterator {
    next() {
        return {
            value: [new Foo],
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun([[a], b]: Bar[][]) { }
fun(new FooArrayIterator);`,
      [],
    );
  });
  test("iterableArrayPattern2", async () => {
    await expectPass(
      `class SymbolIterator {
    next() {
        return {
            value: Symbol(),
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var [a, ...b] = new SymbolIterator;`,
      [],
    );
  });
  test("iterableArrayPattern20", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooArrayIterator {
    next() {
        return {
            value: [new Foo],
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

function fun(...[[a = new Foo], b = [new Foo]]: Bar[][]) { }
fun(...new FooArrayIterator);`,
      [],
    );
  });
  test("iterableArrayPattern21", async () => {
    await expectPass(`var [a, b] = { 0: "", 1: true };`, []);
  });
  test("iterableArrayPattern22", async () => {
    await expectPass(`var [...a] = { 0: "", 1: true };`, []);
  });
  test("iterableArrayPattern23", async () => {
    await expectPass(
      `var a: string, b: boolean;
[a, b] = { 0: "", 1: true };`,
      [],
    );
  });
  test("iterableArrayPattern24", async () => {
    await expectPass(
      `var a: string, b: boolean[];
[a, ...b] = { 0: "", 1: true };`,
      [],
    );
  });
  test("iterableArrayPattern25", async () => {
    await expectPass(
      `function takeFirstTwoEntries(...[[k1, v1], [k2, v2]]) { }
takeFirstTwoEntries(new Map([["", 0], ["hello", 1]]));`,
      [],
    );
  });
  test("iterableArrayPattern26", async () => {
    await expectPass(
      `function takeFirstTwoEntries(...[[k1, v1], [k2, v2]]: [string, number][]) { }
takeFirstTwoEntries(new Map([["", 0], ["hello", 1]]));`,
      [],
    );
  });
  test("iterableArrayPattern27", async () => {
    await expectPass(
      `function takeFirstTwoEntries(...[[k1, v1], [k2, v2]]: [string, number][]) { }
takeFirstTwoEntries(...new Map([["", 0], ["hello", 1]]));`,
      [],
    );
  });
  test("iterableArrayPattern28", async () => {
    await expectPass(
      `function takeFirstTwoEntries(...[[k1, v1], [k2, v2]]: [string, number][]) { }
takeFirstTwoEntries(...new Map([["", 0], ["hello", true]]));`,
      [],
    );
  });
  test("iterableArrayPattern29", async () => {
    await expectPass(
      `function takeFirstTwoEntries(...[[k1, v1], [k2, v2]]: [string, number][]) { }
takeFirstTwoEntries(...new Map([["", true], ["hello", true]]));`,
      [],
    );
  });
  test("iterableArrayPattern3", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var a: Bar, b: Bar;
[a, b] = new FooIterator;`,
      [],
    );
  });
  test("iterableArrayPattern30", async () => {
    await expectPass(`const [[k1, v1], [k2, v2]] = new Map([["", true], ["hello", true]])`, []);
  });
  test("iterableArrayPattern4", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var a: Bar, b: Bar[];
[a, ...b] = new FooIterator`,
      [],
    );
  });
  test("iterableArrayPattern5", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var a: Bar, b: string;
[a, b] = new FooIterator;`,
      [],
    );
  });
  test("iterableArrayPattern6", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var a: Bar, b: string[];
[a, ...b] = new FooIterator;`,
      [],
    );
  });
  test("iterableArrayPattern7", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var a: Bar, b: string[];
[a, b] = new FooIterator;`,
      [],
    );
  });
  test("iterableArrayPattern8", async () => {
    await expectPass(
      `class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var a: Bar, b: string;
[a, ...b] = new FooIterator;`,
      [],
    );
  });
  test("iterableArrayPattern9", async () => {
    await expectPass(
      `function fun([a, b] = new FooIterator) { }
class Bar { x }
class Foo extends Bar { y }
class FooIterator {
    next() {
        return {
            value: new Foo,
            done: false
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}`,
      [],
    );
  });
  test("missingAndExcessProperties", async () => {
    await expectPass(
      `// Missing properties
function f1() {
    var { x, y } = {};
    var { x = 1, y } = {};
    var { x, y = 1 } = {};
    var { x = 1, y = 1 } = {};
}

// Missing properties
function f2() {
    var x: number, y: number;
    ({ x, y } = {});
    ({ x: x = 1, y } = {});
    ({ x, y: y = 1 } = {});
    ({ x: x = 1, y: y = 1 } = {});
}

// Excess properties
function f3() {
    var { } = { x: 0, y: 0 };
    var { x } = { x: 0, y: 0 };
    var { y } = { x: 0, y: 0 };
    var { x, y } = { x: 0, y: 0 };
}

// Excess properties
function f4() {
    var x: number, y: number;
    ({ } = { x: 0, y: 0 });
    ({ x } = { x: 0, y: 0 });
    ({ y } = { x: 0, y: 0 });
    ({ x, y } = { x: 0, y: 0 });
}
`,
      [],
    );
  });
  test("nonIterableRestElement1", async () => {
    await expectPass(
      `var c = {};
[...c] = ["", 0];`,
      [],
    );
  });
  test("nonIterableRestElement2", async () => {
    await expectPass(
      `var c = {};
[...c] = ["", 0];`,
      [],
    );
  });
  test("nonIterableRestElement3", async () => {
    await expectPass(
      `var c = { bogus: 0 };
[...c] = ["", 0];`,
      [],
    );
  });
  test("objectBindingPatternKeywordIdentifiers01", async () => {
    await expectError(
      `// @target: es2015

var { while } = { while: 1 }`,
      [],
    );
  });
  test("objectBindingPatternKeywordIdentifiers02", async () => {
    await expectError(
      `// @target: es2015

var { while: while } = { while: 1 }`,
      [],
    );
  });
  test("objectBindingPatternKeywordIdentifiers03", async () => {
    await expectError(
      `// @target: es2015

var { "while" } = { while: 1 }`,
      [],
    );
  });
  test("objectBindingPatternKeywordIdentifiers04", async () => {
    await expectError(
      `// @target: es2015

var { "while": while } = { while: 1 }`,
      [],
    );
  });
  test("objectBindingPatternKeywordIdentifiers05", async () => {
    await expectPass(
      `// @target: es2015

var { as } = { as: 1 }`,
      [],
    );
  });
  test("objectBindingPatternKeywordIdentifiers06", async () => {
    await expectPass(
      `// @target: es2015

var { as: as } = { as: 1 }`,
      [],
    );
  });
  test("optionalBindingParameters1", async () => {
    await expectPass(
      `// @target: es2015

function foo([x,y,z]?: [string, number, boolean]) {

}

foo(["", 0, false]);

foo([false, 0, ""]);`,
      [],
    );
  });
  test("optionalBindingParameters2", async () => {
    await expectPass(
      `// @target: es2015

function foo({ x, y, z }?: { x: string; y: number; z: boolean }) {

}

foo({ x: "", y: 0, z: false });

foo({ x: false, y: 0, z: "" });`,
      [],
    );
  });
  test("optionalBindingParameters3", async () => {
    await expectPass(
      `// @target: es2015

/**
 * @typedef Foo
 * @property {string} a
 */

/**
 * @param {Foo} [options]
 */
function f({ a = "a" }) {}
`,
      [],
    );
  });
  test("optionalBindingParameters4", async () => {
    await expectPass(
      `
/** 
* @param {{ cause?: string }} [options] 
*/ 
function foo({ cause } = {}) {
    return cause;
}
`,
      [],
    );
  });
  test("optionalBindingParametersInOverloads1", async () => {
    await expectPass(
      `// @target: es2015

function foo([x, y, z] ?: [string, number, boolean]);
function foo(...rest: any[]) {

}

foo(["", 0, false]);

foo([false, 0, ""]);`,
      [],
    );
  });
  test("optionalBindingParametersInOverloads2", async () => {
    await expectPass(
      `// @target: es2015

function foo({ x, y, z }?: { x: string; y: number; z: boolean });
function foo(...rest: any[]) {

}

foo({ x: "", y: 0, z: false });

foo({ x: false, y: 0, z: "" });`,
      [],
    );
  });
  test("restElementWithAssignmentPattern1", async () => {
    await expectPass(
      `var a: string, b: number;
[...[a, b = 0]] = ["", 1];`,
      [],
    );
  });
  test("restElementWithAssignmentPattern2", async () => {
    await expectPass(
      `var a: string, b: number;
[...{ 0: a = "", b }] = ["", 1];`,
      [],
    );
  });
  test("restElementWithAssignmentPattern3", async () => {
    await expectPass(
      `var a: string, b: number;
var tuple: [string, number] = ["", 1];
[...[a, b = 0]] = tuple;`,
      [],
    );
  });
  test("restElementWithAssignmentPattern4", async () => {
    await expectPass(
      `var a: string, b: number;
var tuple: [string, number] = ["", 1];
[...{ 0: a = "", b }] = tuple;`,
      [],
    );
  });
  test("restElementWithAssignmentPattern5", async () => {
    await expectPass(
      `var s: string, s2: string;
[...[s, s2]] = ["", ""];`,
      [],
    );
  });
  test("restElementWithBindingPattern", async () => {
    await expectPass(`var [...[a, b]] = [0, 1];`, []);
  });
  test("restElementWithBindingPattern2", async () => {
    await expectPass(`var [...{0: a, b }] = [0, 1];`, []);
  });
  test("restElementWithInitializer1", async () => {
    await expectError(
      `declare var a: number[];
var [...x = a] = a;  // Error, rest element cannot have initializer
`,
      [],
    );
  });
  test("restElementWithInitializer2", async () => {
    await expectError(
      `declare var a: number[];
var x: number[];
[...x = a] = a;  // Error, rest element cannot have initializer
`,
      [],
    );
  });
  test("restElementWithNullInitializer", async () => {
    await expectPass(
      `function foo1([...r] = null) {
}

function foo2([...r] = undefined) {
}

function foo3([...r] = {}) {
}

function foo4([...r] = []) {
}
`,
      [],
    );
  });
  test("restPropertyWithBindingPattern", async () => {
    await expectError(
      `({...{}} = {});
({...({})} = {});
({...[]} = {});
({...([])} = {});`,
      [],
    );
  });
});
