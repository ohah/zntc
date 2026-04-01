import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/for-ofStatements", () => {
  test("for-of-excess-declarations", async () => {
    await expectError(
      `for (const a, { [b]: c} of [1]) {

}`,
      [],
    );
  });
  test("for-of1", async () => {
    await expectPass(
      `//@target: ES6
var v;
for (v of []) { }`,
      [],
    );
  });
  test("for-of10", async () => {
    await expectPass(
      `//@target: ES6
var v: string;
for (v of [0]) { }`,
      [],
    );
  });
  test("for-of11", async () => {
    await expectPass(
      `//@target: ES6
var v: string;
for (v of [0, ""]) { }`,
      [],
    );
  });
  test("for-of12", async () => {
    await expectPass(
      `//@target: ES6
var v: string;
for (v of [0, ""].values()) { }`,
      [],
    );
  });
  test("for-of13", async () => {
    await expectPass(
      `//@target: ES6
var v: string;
for (v of [""].values()) { }`,
      [],
    );
  });
  test("for-of14", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return "";
    }
}

var v: string;
for (v of new MyStringIterator) { } // Should fail because the iterator is not iterable`,
      [],
    );
  });
  test("for-of15", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return "";
    }
    [Symbol.iterator]() {
        return this;
    }
}

var v: string;
for (v of new MyStringIterator) { } // Should fail`,
      [],
    );
  });
  test("for-of16", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    [Symbol.iterator]() {
        return this;
    }
}

var v: string;
for (v of new MyStringIterator) { } // Should fail

for (v of new MyStringIterator) { } // Should still fail (related errors should still be shown even though type is cached).`,
      [],
    );
  });
  test("for-of17", async () => {
    await expectPass(
      `//@target: ES6
class NumberIterator {
    next() {
        return {
            value: 0,
            done: false
        };
    }
    [Symbol.iterator]() {
        return this;
    }
}

var v: string;
for (v of new NumberIterator) { } // Should succeed`,
      [],
    );
  });
  test("for-of18", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return {
            value: "",
            done: false
        };
    }
    [Symbol.iterator]() {
        return this;
    }
}

var v: string;
for (v of new MyStringIterator) { } // Should succeed`,
      [],
    );
  });
  test("for-of19", async () => {
    await expectPass(
      `//@target: ES6
class Foo { }
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

for (var v of new FooIterator) {
    v;
}`,
      [],
    );
  });
  test("for-of2", async () => {
    await expectError(
      `//@target: ES6
const v;
for (v of []) { }`,
      [],
    );
  });
  test("for-of20", async () => {
    await expectPass(
      `//@target: ES6
class Foo { }
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

for (let v of new FooIterator) {
    v;
}`,
      [],
    );
  });
  test("for-of21", async () => {
    await expectPass(
      `//@target: ES6
class Foo { }
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

for (const v of new FooIterator) {
    v;
}`,
      [],
    );
  });
  test("for-of22", async () => {
    await expectPass(
      `//@target: ES6
class Foo { }
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

v;
for (var v of new FooIterator) {
    
}`,
      [],
    );
  });
  test("for-of23", async () => {
    await expectPass(
      `//@target: ES6
class Foo { }
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

for (const v of new FooIterator) {
    const v = 0; // new scope
}`,
      [],
    );
  });
  test("for-of24", async () => {
    await expectPass(
      `//@target: ES6
var x: any;
for (var v of x) { }
`,
      [],
    );
  });
  test("for-of25", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    [Symbol.iterator]() {
        return x;
    }
}

var x: any;
for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of26", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return x;
    }
    [Symbol.iterator]() {
        return this;
    }
}

var x: any;
for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of27", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    [Symbol.iterator]: any;
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of28", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next: any;
    [Symbol.iterator]() {
        return this;
    }
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of29", async () => {
    await expectError(
      `//@target: ES6
declare var iterableWithOptionalIterator: {
    [Symbol.iterator]?(): Iterator<string>
};

for (var v of iterableWithOptionalIterator) { }
`,
      [],
    );
  });
  test("for-of3", async () => {
    await expectError(
      `//@target: ES6
var v: any;
for (v++ of []) { }`,
      [],
    );
  });
  test("for-of30", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return {
            done: false,
            value: ""
        }
    }

    return = 0;

    [Symbol.iterator]() {
        return this;
    }
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of31", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return {
            // no done property
            value: ""
        }
    }

    [Symbol.iterator]() {
        return this;
    }
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of32", async () => {
    await expectPass(
      `//@target: ES6
for (var v of v) { }`,
      [],
    );
  });
  test("for-of33", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    [Symbol.iterator]() {
        return v;
    }
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of34", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return v;
    }

    [Symbol.iterator]() {
        return this;
    }
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of35", async () => {
    await expectPass(
      `//@target: ES6
class MyStringIterator {
    next() {
        return {
            done: true,
            value: v
        }
    }

    [Symbol.iterator]() {
        return this;
    }
}

for (var v of new MyStringIterator) { }`,
      [],
    );
  });
  test("for-of36", async () => {
    await expectPass(
      `//@target: ES6
var tuple: [string, boolean] = ["", true];
for (var v of tuple) {
    v;
}`,
      [],
    );
  });
  test("for-of37", async () => {
    await expectPass(
      `//@target: ES6
var map = new Map([["", true]]);
for (var v of map) {
    v;
}`,
      [],
    );
  });
  test("for-of38", async () => {
    await expectPass(
      `//@target: ES6
var map = new Map([["", true]]);
for (var [k, v] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of39", async () => {
    await expectPass(
      `// @lib: es2015
var map = new Map([["", true], ["", 0]]);
for (var [k, v] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of4", async () => {
    await expectPass(
      `//@target: ES6
for (var v of [0]) {
    v;
}`,
      [],
    );
  });
  test("for-of40", async () => {
    await expectPass(
      `//@target: ES6
var map = new Map([["", true]]);
for (var [k = "", v = false] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of41", async () => {
    await expectPass(
      `//@target: ES6
var array = [{x: [0], y: {p: ""}}]
for (var {x: [a], y: {p}} of array) {
    a;
    p;
}`,
      [],
    );
  });
  test("for-of42", async () => {
    await expectPass(
      `//@target: ES6
var array = [{ x: "", y: 0 }]
for (var {x: a, y: b} of array) {
    a;
    b;
}`,
      [],
    );
  });
  test("for-of43", async () => {
    await expectPass(
      `//@target: ES6
var array = [{ x: "", y: 0 }]
for (var {x: a = "", y: b = true} of array) {
    a;
    b;
}`,
      [],
    );
  });
  test("for-of44", async () => {
    await expectPass(
      `//@target: ES6
var array: [number, string | boolean | symbol][] = [[0, ""], [0, true], [1, Symbol()]]
for (var [num, strBoolSym] of array) {
    num;
    strBoolSym;
}`,
      [],
    );
  });
  test("for-of45", async () => {
    await expectPass(
      `//@target: ES6
var k: string, v: boolean;
var map = new Map([["", true]]);
for ([k = "", v = false] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of46", async () => {
    await expectPass(
      `//@target: ES6
var k: string, v: boolean;
var map = new Map([["", true]]);
for ([k = false, v = ""] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of47", async () => {
    await expectPass(
      `//@target: ES6
var x: string, y: number;
var array = [{ x: "", y: true }]
enum E { x }
for ({x, y: y = E.x} of array) {
    x;
    y;
}`,
      [],
    );
  });
  test("for-of48", async () => {
    await expectPass(
      `//@target: ES6
var x: string, y: number;
var array = [{ x: "", y: true }]
enum E { x }
for ({x, y = E.x} of array) {
    x;
    y;
}`,
      [],
    );
  });
  test("for-of49", async () => {
    await expectPass(
      `//@target: ES6
var k: string, v: boolean;
var map = new Map([["", true]]);
for ([k, ...[v]] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of5", async () => {
    await expectPass(
      `//@target: ES6
for (let v of [0]) {
    v;
}`,
      [],
    );
  });
  test("for-of50", async () => {
    await expectPass(
      `//@target: ES6
var map = new Map([["", true]]);
for (const [k, v] of map) {
    k;
    v;
}`,
      [],
    );
  });
  test("for-of51", async () => {
    await expectError(
      `//@target: ES6
for (let let of []) {}`,
      [],
    );
  });
  test("for-of52", async () => {
    await expectPass(
      `//@target: ES6
for (let [v, v] of [[]]) {}`,
      [],
    );
  });
  test("for-of53", async () => {
    await expectPass(
      `//@target: ES6
for (let v of []) {
    var v;
}`,
      [],
    );
  });
  test("for-of54", async () => {
    await expectPass(
      `//@target: ES6
for (let v of []) {
    var v = 0;
}`,
      [],
    );
  });
  test("for-of55", async () => {
    await expectPass(
      `//@target: ES6
let v = [1];
for (let v of v) {
    v;
}`,
      [],
    );
  });
  test("for-of56", async () => {
    await expectPass(`for (var let of []) {}`, []);
  });
  test("for-of57", async () => {
    await expectPass(
      `var iter: Iterable<number>;
for (let num of iter) { }`,
      [],
    );
  });
  test("for-of58", async () => {
    await expectPass(
      `type X = { x: 'x' };
type Y = { y: 'y' };

declare const arr: X[] & Y[];

for (const item of arr) {
    item.x;
    item.y;
}`,
      [],
    );
  });
  test("for-of6", async () => {
    await expectPass(
      `//@target: ES6
for (v of [0]) {
    let v;
}`,
      [],
    );
  });
  test("for-of7", async () => {
    await expectPass(
      `//@target: ES6
v;
for (let v of [0]) { }`,
      [],
    );
  });
  test("for-of8", async () => {
    await expectPass(
      `//@target: ES6
v;
for (var v of [0]) { }`,
      [],
    );
  });
  test("for-of9", async () => {
    await expectPass(
      `//@target: ES6
var v: string;
for (v of ["hello"]) { }
for (v of "hello") { }`,
      [],
    );
  });
});
