import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/Symbols", () => {
  test("symbolDeclarationEmit1", async () => {
    await expectPass(
      `class C {
    [Symbol.toPrimitive]: number;
}`,
      [],
    );
  });
  test("symbolDeclarationEmit10", async () => {
    await expectPass(
      `var obj = {
    get [Symbol.isConcatSpreadable]() { return '' },
    set [Symbol.isConcatSpreadable](x) { }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit11", async () => {
    await expectPass(
      `class C {
    static [Symbol.iterator] = 0;
    static [Symbol.isConcatSpreadable]() { }
    static get [Symbol.toPrimitive]() { return ""; }
    static set [Symbol.toPrimitive](x) { }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit12", async () => {
    await expectPass(
      `namespace M {
    interface I { }
    export class C {
        [Symbol.iterator]: I;
        [Symbol.toPrimitive](x: I) { }
        [Symbol.isConcatSpreadable](): I {
            return undefined
        }
        get [Symbol.toPrimitive]() { return undefined; }
        set [Symbol.toPrimitive](x: I) { }
    }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit13", async () => {
    await expectPass(
      `class C {
    get [Symbol.toPrimitive]() { return ""; }
    set [Symbol.toStringTag](x) { }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit14", async () => {
    await expectPass(
      `class C {
    get [Symbol.toPrimitive]() { return ""; }
    get [Symbol.toStringTag]() { return ""; }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit2", async () => {
    await expectPass(
      `class C {
    [Symbol.toPrimitive] = "";
}`,
      [],
    );
  });
  test("symbolDeclarationEmit3", async () => {
    await expectPass(
      `class C {
    [Symbol.toPrimitive](x: number);
    [Symbol.toPrimitive](x: string);
    [Symbol.toPrimitive](x: any) { }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit4", async () => {
    await expectPass(
      `class C {
    get [Symbol.toPrimitive]() { return ""; }
    set [Symbol.toPrimitive](x) { }
}`,
      [],
    );
  });
  test("symbolDeclarationEmit5", async () => {
    await expectError(
      `interface I {
    [Symbol.isConcatSpreadable](): string;
}`,
      [],
    );
  });
  test("symbolDeclarationEmit6", async () => {
    await expectError(
      `interface I {
    [Symbol.isConcatSpreadable]: string;
}`,
      [],
    );
  });
  test("symbolDeclarationEmit7", async () => {
    await expectError(
      `var obj: {
    [Symbol.isConcatSpreadable]: string;
}`,
      [],
    );
  });
  test("symbolDeclarationEmit8", async () => {
    await expectPass(
      `var obj = {
    [Symbol.isConcatSpreadable]: 0
}`,
      [],
    );
  });
  test("symbolDeclarationEmit9", async () => {
    await expectPass(
      `var obj = {
    [Symbol.isConcatSpreadable]() { }
}`,
      [],
    );
  });
  test("symbolProperty1", async () => {
    await expectPass(
      `var s: symbol;
var x = {
    [s]: 0,
    [s]() { },
    get [s]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty10", async () => {
    await expectError(
      `class C {
    [Symbol.iterator]: { x; y };
}
interface I {
    [Symbol.iterator]?: { x };
}

var i: I;
i = new C;
var c: C = i;`,
      [],
    );
  });
  test("symbolProperty11", async () => {
    await expectError(
      `class C { }
interface I {
    [Symbol.iterator]?: { x };
}

var i: I;
i = new C;
var c: C = i;`,
      [],
    );
  });
  test("symbolProperty12", async () => {
    await expectError(
      `class C {
    private [Symbol.iterator]: { x };
}
interface I {
    [Symbol.iterator]: { x };
}

var i: I;
i = new C;
var c: C = i;`,
      [],
    );
  });
  test("symbolProperty13", async () => {
    await expectError(
      `class C {
    [Symbol.iterator]: { x; y };
}
interface I {
    [Symbol.iterator]: { x };
}

declare function foo(i: I): I;
declare function foo(a: any): any;

declare function bar(i: C): C;
declare function bar(a: any): any;

foo(new C);
var i: I;
bar(i);`,
      [],
    );
  });
  test("symbolProperty14", async () => {
    await expectError(
      `class C {
    [Symbol.iterator]: { x; y };
}
interface I {
    [Symbol.iterator]?: { x };
}

declare function foo(i: I): I;
declare function foo(a: any): any;

declare function bar(i: C): C;
declare function bar(a: any): any;

foo(new C);
var i: I;
bar(i);`,
      [],
    );
  });
  test("symbolProperty15", async () => {
    await expectError(
      `class C { }
interface I {
    [Symbol.iterator]?: { x };
}

declare function foo(i: I): I;
declare function foo(a: any): any;

declare function bar(i: C): C;
declare function bar(a: any): any;

foo(new C);
var i: I;
bar(i);`,
      [],
    );
  });
  test("symbolProperty16", async () => {
    await expectError(
      `class C {
    private [Symbol.iterator]: { x };
}
interface I {
    [Symbol.iterator]: { x };
}

declare function foo(i: I): I;
declare function foo(a: any): any;

declare function bar(i: C): C;
declare function bar(a: any): any;

foo(new C);
var i: I;
bar(i);`,
      [],
    );
  });
  test("symbolProperty17", async () => {
    await expectError(
      `interface I {
    [Symbol.iterator]: number;
    [s: symbol]: string;
    "__@iterator": string;
}

declare var i: I;
var it = i[Symbol.iterator];`,
      [],
    );
  });
  test("symbolProperty18", async () => {
    await expectPass(
      `var i = {
    [Symbol.iterator]: 0,
    [Symbol.toStringTag]() { return "" },
    set [Symbol.toPrimitive](p: boolean) { }
}

var it = i[Symbol.iterator];
var str = i[Symbol.toStringTag]();
i[Symbol.toPrimitive] = false;`,
      [],
    );
  });
  test("symbolProperty19", async () => {
    await expectPass(
      `var i = {
    [Symbol.iterator]: { p: null },
    [Symbol.toStringTag]() { return { p: undefined }; }
}

var it = i[Symbol.iterator];
var str = i[Symbol.toStringTag]();`,
      [],
    );
  });
  test("symbolProperty2", async () => {
    await expectPass(
      `var s = Symbol();
var x = {
    [s]: 0,
    [s]() { },
    get [s]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty20", async () => {
    await expectError(
      `interface I {
    [Symbol.iterator]: (s: string) => string;
    [Symbol.toStringTag](s: number): number;
}

var i: I = {
    [Symbol.iterator]: s => s,
    [Symbol.toStringTag](n) { return n; }
}`,
      [],
    );
  });
  test("symbolProperty21", async () => {
    await expectError(
      `interface I<T, U> {
    [Symbol.unscopables]: T;
    [Symbol.isConcatSpreadable]: U;
}

declare function foo<T, U>(p: I<T, U>): { t: T; u: U };

foo({
    [Symbol.isConcatSpreadable]: "",
    [Symbol.toPrimitive]: 0,
    [Symbol.unscopables]: true
});`,
      [],
    );
  });
  test("symbolProperty22", async () => {
    await expectError(
      `interface I<T, U> {
    [Symbol.unscopables](x: T): U;
}

declare function foo<T, U>(p1: T, p2: I<T, U>): U;

foo("", { [Symbol.unscopables]: s => s.length });`,
      [],
    );
  });
  test("symbolProperty23", async () => {
    await expectError(
      `interface I {
    [Symbol.toPrimitive]: () => boolean;
}

class C implements I {
    [Symbol.toPrimitive]() {
        return true;
    }
}`,
      [],
    );
  });
  test("symbolProperty24", async () => {
    await expectError(
      `interface I {
    [Symbol.toPrimitive]: () => boolean;
}

class C implements I {
    [Symbol.toPrimitive]() {
        return "";
    }
}`,
      [],
    );
  });
  test("symbolProperty25", async () => {
    await expectError(
      `interface I {
    [Symbol.toPrimitive]: () => boolean;
}

class C implements I {
    [Symbol.toStringTag]() {
        return "";
    }
}`,
      [],
    );
  });
  test("symbolProperty26", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return "";
    }
}

class C2 extends C1 {
    [Symbol.toStringTag]() {
        return "";
    }
}`,
      [],
    );
  });
  test("symbolProperty27", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return {};
    }
}

class C2 extends C1 {
    [Symbol.toStringTag]() {
        return "";
    }
}`,
      [],
    );
  });
  test("symbolProperty28", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}

class C2 extends C1 { }

var c: C2;
var obj = c[Symbol.toStringTag]().x;`,
      [],
    );
  });
  test("symbolProperty29", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
    [s: symbol]: () => { x: string };
}`,
      [],
    );
  });
  test("symbolProperty3", async () => {
    await expectPass(
      `var s = Symbol;
var x = {
    [s]: 0,
    [s]() { },
    get [s]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty30", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
    [s: symbol]: () => { x: number };
}`,
      [],
    );
  });
  test("symbolProperty31", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}
class C2 extends C1 {
    [s: symbol]: () => { x: string };
}`,
      [],
    );
  });
  test("symbolProperty32", async () => {
    await expectPass(
      `class C1 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}
class C2 extends C1 {
    [s: symbol]: () => { x: number };
}`,
      [],
    );
  });
  test("symbolProperty33", async () => {
    await expectPass(
      `class C1 extends C2 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}
class C2 {
    [s: symbol]: () => { x: string };
}`,
      [],
    );
  });
  test("symbolProperty34", async () => {
    await expectPass(
      `class C1 extends C2 {
    [Symbol.toStringTag]() {
        return { x: "" };
    }
}
class C2 {
    [s: symbol]: () => { x: number };
}`,
      [],
    );
  });
  test("symbolProperty35", async () => {
    await expectError(
      `interface I1 {
    [Symbol.toStringTag](): { x: string }
}
interface I2 {
    [Symbol.toStringTag](): { x: number }
}

interface I3 extends I1, I2 { }`,
      [],
    );
  });
  test("symbolProperty36", async () => {
    await expectPass(
      `var x = {
    [Symbol.isConcatSpreadable]: 0,
    [Symbol.isConcatSpreadable]: 1
}`,
      [],
    );
  });
  test("symbolProperty37", async () => {
    await expectError(
      `interface I {
    [Symbol.isConcatSpreadable]: string;
    [Symbol.isConcatSpreadable]: string;
}`,
      [],
    );
  });
  test("symbolProperty38", async () => {
    await expectError(
      `interface I {
    [Symbol.isConcatSpreadable]: string;
}
interface I {
    [Symbol.isConcatSpreadable]: string;
}`,
      [],
    );
  });
  test("symbolProperty39", async () => {
    await expectPass(
      `class C {
    [Symbol.iterator](x: string): string;
    [Symbol.iterator](x: number): number;
    [Symbol.iterator](x: any) {
        return undefined;
    }
    [Symbol.iterator](x: any) {
        return undefined;
    }
}`,
      [],
    );
  });
  test("symbolProperty4", async () => {
    await expectPass(
      `var x = {
    [Symbol()]: 0,
    [Symbol()]() { },
    get [Symbol()]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty40", async () => {
    await expectPass(
      `class C {
    [Symbol.iterator](x: string): string;
    [Symbol.iterator](x: number): number;
    [Symbol.iterator](x: any) {
        return undefined;
    }
}

var c = new C;
c[Symbol.iterator]("");
c[Symbol.iterator](0);
`,
      [],
    );
  });
  test("symbolProperty41", async () => {
    await expectPass(
      `class C {
    [Symbol.iterator](x: string): { x: string };
    [Symbol.iterator](x: "hello"): { x: string; hello: string };
    [Symbol.iterator](x: any) {
        return undefined;
    }
}

var c = new C;
c[Symbol.iterator]("");
c[Symbol.iterator]("hello");
`,
      [],
    );
  });
  test("symbolProperty42", async () => {
    await expectPass(
      `class C {
    [Symbol.iterator](x: string): string;
    static [Symbol.iterator](x: number): number;
    [Symbol.iterator](x: any) {
        return undefined;
    }
}`,
      [],
    );
  });
  test("symbolProperty43", async () => {
    await expectPass(
      `class C {
    [Symbol.iterator](x: string): string;
    [Symbol.iterator](x: number): number;
}`,
      [],
    );
  });
  test("symbolProperty44", async () => {
    await expectPass(
      `class C {
    get [Symbol.hasInstance]() {
        return "";
    }
    get [Symbol.hasInstance]() {
        return "";
    }
}`,
      [],
    );
  });
  test("symbolProperty45", async () => {
    await expectPass(
      `class C {
    get [Symbol.hasInstance]() {
        return "";
    }
    get [Symbol.toPrimitive]() {
        return "";
    }
}`,
      [],
    );
  });
  test("symbolProperty46", async () => {
    await expectPass(
      `class C {
    get [Symbol.hasInstance]() {
        return "";
    }
    // Should take a string
    set [Symbol.hasInstance](x) {
    }
}

(new C)[Symbol.hasInstance] = 0;
(new C)[Symbol.hasInstance] = "";`,
      [],
    );
  });
  test("symbolProperty47", async () => {
    await expectPass(
      `class C {
    get [Symbol.hasInstance]() {
        return "";
    }
    // Should take a string
    set [Symbol.hasInstance](x: number) {
    }
}

(new C)[Symbol.hasInstance] = 0;
(new C)[Symbol.hasInstance] = "";`,
      [],
    );
  });
  test("symbolProperty48", async () => {
    await expectPass(
      `namespace M {
    var Symbol;

    class C {
        [Symbol.iterator]() { }
    }
}`,
      [],
    );
  });
  test("symbolProperty49", async () => {
    await expectPass(
      `namespace M {
    export var Symbol;

    class C {
        [Symbol.iterator]() { }
    }
}`,
      [],
    );
  });
  test("symbolProperty5", async () => {
    await expectPass(
      `var x = {
    [Symbol.iterator]: 0,
    [Symbol.toPrimitive]() { },
    get [Symbol.toStringTag]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty50", async () => {
    await expectPass(
      `namespace M {
    interface Symbol { }

    class C {
        [Symbol.iterator]() { }
    }
}`,
      [],
    );
  });
  test("symbolProperty51", async () => {
    await expectPass(
      `namespace M {
    namespace Symbol { }

    class C {
        [Symbol.iterator]() { }
    }
}`,
      [],
    );
  });
  test("symbolProperty52", async () => {
    await expectPass(
      `var obj = {
    [Symbol.nonsense]: 0
};

obj = {};

obj[Symbol.nonsense];`,
      [],
    );
  });
  test("symbolProperty53", async () => {
    await expectPass(
      `var obj = {
    [Symbol.for]: 0
};

obj[Symbol.for];`,
      [],
    );
  });
  test("symbolProperty54", async () => {
    await expectPass(
      `var obj = {
    [Symbol.prototype]: 0
};`,
      [],
    );
  });
  test("symbolProperty55", async () => {
    await expectPass(
      `var obj = {
    [Symbol.iterator]: 0
};

namespace M {
    var Symbol: SymbolConstructor;
    // The following should be of type 'any'. This is because even though obj has a property keyed by Symbol.iterator,
    // the key passed in here is the *wrong* Symbol.iterator. It is not the iterator property of the global Symbol.
    obj[Symbol.iterator];
}`,
      [],
    );
  });
  test("symbolProperty56", async () => {
    await expectPass(
      `var obj = {
    [Symbol.iterator]: 0
};

namespace M {
    var Symbol: {};
    // The following should be of type 'any'. This is because even though obj has a property keyed by Symbol.iterator,
    // the key passed in here is the *wrong* Symbol.iterator. It is not the iterator property of the global Symbol.
    obj[Symbol["iterator"]];
}`,
      [],
    );
  });
  test("symbolProperty57", async () => {
    await expectPass(
      `var obj = {
    [Symbol.iterator]: 0
};

// Should give type 'any'.
obj[Symbol["nonsense"]];`,
      [],
    );
  });
  test("symbolProperty58", async () => {
    await expectPass(
      `interface SymbolConstructor {
    foo: string;
}

var obj = {
    [Symbol.foo]: 0
}`,
      [],
    );
  });
  test("symbolProperty59", async () => {
    await expectError(
      `interface I {
    [Symbol.keyFor]: string;
}`,
      [],
    );
  });
  test("symbolProperty6", async () => {
    await expectPass(
      `class C {
    [Symbol.iterator] = 0;
    [Symbol.unscopables]: number;
    [Symbol.toPrimitive]() { }
    get [Symbol.toStringTag]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty60", async () => {
    await expectError(
      `// https://github.com/Microsoft/TypeScript/issues/20146
interface I1 {
    [Symbol.toStringTag]: string;
    [key: string]: number;
}

interface I2 {
    [Symbol.toStringTag]: string;
    [key: number]: boolean;
}

declare const mySymbol: unique symbol;

interface I3 {
    [mySymbol]: string;
    [key: string]: number;
}

interface I4 {
    [mySymbol]: string;
    [key: number]: boolean;
}`,
      [],
    );
  });
  test("symbolProperty61", async () => {
    await expectError(
      `
declare global {
  interface SymbolConstructor {
    readonly obs: symbol
  }
}

const observable: typeof Symbol.obs = Symbol.obs

export class MyObservable<T> {
    constructor(private _val: T) {}

    subscribe(next: (val: T) => void) {
        next(this._val)
    }

    [observable]() {
        return this
    }
}

type InteropObservable<T> = {
    [Symbol.obs]: () => { subscribe(next: (val: T) => void): void }
}

function from<T>(obs: InteropObservable<T>) {
    return obs[Symbol.obs]()
}

from(new MyObservable(42))`,
      [],
    );
  });
  test("symbolProperty7", async () => {
    await expectPass(
      `class C {
    [Symbol()] = 0;
    [Symbol()]: number;
    [Symbol()]() { }
    get [Symbol()]() {
        return 0;
    }
}`,
      [],
    );
  });
  test("symbolProperty8", async () => {
    await expectError(
      `interface I {
    [Symbol.unscopables]: number;
    [Symbol.toPrimitive]();
}`,
      [],
    );
  });
  test("symbolProperty9", async () => {
    await expectError(
      `class C {
    [Symbol.iterator]: { x; y };
}
interface I {
    [Symbol.iterator]: { x };
}

var i: I;
i = new C;
var c: C = i;`,
      [],
    );
  });
  test("symbolType1", async () => {
    await expectPass(
      `Symbol() instanceof Symbol;
Symbol instanceof Symbol();
(Symbol() || {}) instanceof Object; // This one should be okay, it's a valid way of distinguishing types
Symbol instanceof (Symbol() || {});`,
      [],
    );
  });
  test("symbolType10", async () => {
    await expectPass(
      `var s = Symbol.for("bitwise");
s & s;
s | s;
s ^ s;

s & 0;
0 | s;`,
      [],
    );
  });
  test("symbolType11", async () => {
    await expectPass(
      `var s = Symbol.for("logical");
s && s;
s && [];
0 && s;
s || s;
s || 1;
({}) || s;`,
      [],
    );
  });
  test("symbolType12", async () => {
    await expectPass(
      `var s = Symbol.for("assign");
var str = "";
s *= s;
s *= 0;
s /= s;
s /= 0;
s %= s;
s %= 0;
s += s;
s += 0;
s += "";
str += s;
s -= s;
s -= 0;
s <<= s;
s <<= 0;
s >>= s;
s >>= 0;
s >>>= s;
s >>>= 0;
s &= s;
s &= 0;
s ^= s;
s ^= 0;
s |= s;
s |= 0;

str += (s || str);`,
      [],
    );
  });
  test("symbolType13", async () => {
    await expectPass(
      `var s = Symbol();
var x: any;

for (s in {}) { }
for (x in s) { }
for (var y in s) { }`,
      [],
    );
  });
  test("symbolType14", async () => {
    await expectPass(`new Symbol();`, []);
  });
  test("symbolType15", async () => {
    await expectPass(
      `declare var sym: symbol;
var symObj: Symbol;

symObj = sym;
sym = symObj;`,
      [],
    );
  });
  test("symbolType16", async () => {
    await expectPass(
      `interface Symbol {
    newSymbolProp: number;
}

var sym: symbol;
sym.newSymbolProp;`,
      [],
    );
  });
  test("symbolType17", async () => {
    await expectPass(
      `interface Foo { prop }
var x: symbol | Foo;

x;
if (typeof x === "symbol") {
    x;
}
else {
    x;
}`,
      [],
    );
  });
  test("symbolType18", async () => {
    await expectPass(
      `interface Foo { prop }
var x: symbol | Foo;

x;
if (typeof x === "object") {
    x;
}
else {
    x;
}`,
      [],
    );
  });
  test("symbolType19", async () => {
    await expectPass(
      `enum E { }
var x: symbol | E;

x;
if (typeof x === "number") {
    x;
}
else {
    x;
}`,
      [],
    );
  });
  test("symbolType2", async () => {
    await expectPass(
      `Symbol.isConcatSpreadable in {};
"" in Symbol.toPrimitive;`,
      [],
    );
  });
  test("symbolType20", async () => {
    await expectPass(
      `//@target: ES6
interface symbol { }`,
      [],
    );
  });
  test("symbolType3", async () => {
    await expectPass(
      `var s = Symbol();
delete Symbol.iterator;
void Symbol.toPrimitive;
typeof Symbol.toStringTag;
++s;
--s;
+ Symbol();
- Symbol();
~ Symbol();
! Symbol();

+(Symbol() || 0);`,
      [],
    );
  });
  test("symbolType4", async () => {
    await expectPass(
      `var s = Symbol.for("postfix");
s++;
s--;`,
      [],
    );
  });
  test("symbolType5", async () => {
    await expectPass(
      `var s = Symbol.for("multiply");
s * s;
s / s;
s % s;

s * 0;
0 / s;`,
      [],
    );
  });
  test("symbolType6", async () => {
    await expectPass(
      `var s = Symbol.for("add");
var a: any;
s + s;
s - s;
s + "";
s + a;
s + 0;
"" + s;
a + s;
0 + s;
s - 0;
0 - s;

(s || "") + "";
"" + (s || "");`,
      [],
    );
  });
  test("symbolType7", async () => {
    await expectPass(
      `var s = Symbol.for("shift");
s << s;
s << 0;
s >> s;
s >> 0;
s >>> s;
s >>> 0;`,
      [],
    );
  });
  test("symbolType8", async () => {
    await expectPass(
      `var s = Symbol.for("compare");
s < s;
s < 0;
s > s;
s > 0;
s <= s;
s <= 0;
s >= s;
s >= 0;

0 >= (s || 0);
(s || 0) >= s;`,
      [],
    );
  });
  test("symbolType9", async () => {
    await expectPass(
      `var s = Symbol.for("equal");
s == s;
s == true;
s != s;
0 != s;
s === s;
s === 1;
s !== s;
false !== s;`,
      [],
    );
  });
});
