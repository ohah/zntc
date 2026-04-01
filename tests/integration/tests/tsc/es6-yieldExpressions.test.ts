import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/yieldExpressions", () => {
  test("generatorInAmbientContext1", async () => {
    await expectPass(
      `declare class C {
    *generator(): any;
}`,
      [],
    );
  });
  test("generatorInAmbientContext2", async () => {
    await expectPass(
      `declare namespace M {
    function *generator(): any;
}`,
      [],
    );
  });
  test("generatorInAmbientContext3.d", async () => {
    await expectPass(
      `declare class C {
    *generator(): any;
}`,
      [],
    );
  });
  test("generatorInAmbientContext4.d", async () => {
    await expectPass(
      `declare namespace M {
    function *generator(): any;
}`,
      [],
    );
  });
  test("generatorInAmbientContext5", async () => {
    await expectPass(
      `class C {
    *generator(): any { }
}`,
      [],
    );
  });
  test("generatorInAmbientContext6", async () => {
    await expectPass(
      `namespace M {
    export function *generator(): any { }
}`,
      [],
    );
  });
  test("generatorNoImplicitReturns", async () => {
    await expectPass(
      ` 
function* testGenerator () { 
  if (Math.random() > 0.5) { 
      return; 
  } 
  yield 'hello'; 
}`,
      [],
    );
  });
  test("generatorOverloads1", async () => {
    await expectPass(
      `namespace M {
    function* f(s: string): Iterable<any>;
    function* f(s: number): Iterable<any>;
    function* f(s: any): Iterable<any> { }
}`,
      [],
    );
  });
  test("generatorOverloads2", async () => {
    await expectPass(
      `declare namespace M {
    function* f(s: string): Iterable<any>;
    function* f(s: number): Iterable<any>;
    function* f(s: any): Iterable<any>;
}`,
      [],
    );
  });
  test("generatorOverloads3", async () => {
    await expectPass(
      `class C {
    *f(s: string): Iterable<any>;
    *f(s: number): Iterable<any>;
    *f(s: any): Iterable<any> { }
}`,
      [],
    );
  });
  test("generatorOverloads4", async () => {
    await expectPass(
      `class C {
    f(s: string): Iterable<any>;
    f(s: number): Iterable<any>;
    *f(s: any): Iterable<any> { }
}`,
      [],
    );
  });
  test("generatorOverloads5", async () => {
    await expectPass(
      `namespace M {
    function f(s: string): Iterable<any>;
    function f(s: number): Iterable<any>;
    function* f(s: any): Iterable<any> { }
}`,
      [],
    );
  });
  test("generatorTypeCheck1", async () => {
    await expectPass(`function* g1(): Iterator<string> { }`, []);
  });
  test("generatorTypeCheck10", async () => {
    await expectPass(
      `function* g(): IterableIterator<any> {
    return;
}`,
      [],
    );
  });
  test("generatorTypeCheck11", async () => {
    await expectPass(
      `function* g(): IterableIterator<number, number> {
    return 0;
}`,
      [],
    );
  });
  test("generatorTypeCheck12", async () => {
    await expectPass(
      `function* g(): IterableIterator<number, string> {
    return "";
}`,
      [],
    );
  });
  test("generatorTypeCheck13", async () => {
    await expectPass(
      `function* g(): IterableIterator<number, string> {
    yield 0;
    return "";
}`,
      [],
    );
  });
  test("generatorTypeCheck14", async () => {
    await expectPass(
      `function* g() {
    yield 0;
    return "";
}`,
      [],
    );
  });
  test("generatorTypeCheck15", async () => {
    await expectPass(
      `function* g() {
    return "";
}`,
      [],
    );
  });
  test("generatorTypeCheck16", async () => {
    await expectPass(
      `function* g() {
    return;
}`,
      [],
    );
  });
  test("generatorTypeCheck17", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
function* g(): IterableIterator<Foo> {
    yield;
    yield new Bar;
}`,
      [],
    );
  });
  test("generatorTypeCheck18", async () => {
    await expectPass(
      `class Foo { x: number }
class Baz { z: number }
function* g(): IterableIterator<Foo> {
    yield;
    yield new Baz;
}`,
      [],
    );
  });
  test("generatorTypeCheck19", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
function* g(): IterableIterator<Foo> {
    yield;
    yield * [new Bar];
}`,
      [],
    );
  });
  test("generatorTypeCheck2", async () => {
    await expectPass(`function* g1(): Iterable<string> { }`, []);
  });
  test("generatorTypeCheck20", async () => {
    await expectPass(
      `class Foo { x: number }
class Baz { z: number }
function* g(): IterableIterator<Foo> {
    yield;
    yield * [new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck21", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
function* g(): IterableIterator<Foo> {
    yield;
    yield * new Bar;
}`,
      [],
    );
  });
  test("generatorTypeCheck22", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
class Baz { z: number }
function* g3() {
    yield;
    yield new Bar;
    yield new Baz;
    yield *[new Bar];
    yield *[new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck23", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
class Baz { z: number }
function* g3() {
    yield;
    yield new Foo;
    yield new Bar;
    yield new Baz;
    yield *[new Bar];
    yield *[new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck24", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
class Baz { z: number }
function* g3() {
    yield;
    yield * [new Foo];
    yield new Bar;
    yield new Baz;
    yield *[new Bar];
    yield *[new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck25", async () => {
    await expectPass(
      `class Foo { x: number }
class Bar extends Foo { y: string }
class Baz { z: number }
var g3: () => Iterable<Foo> = function* () {
    yield;
    yield new Bar;
    yield new Baz;
    yield *[new Bar];
    yield *[new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck26", async () => {
    await expectPass(
      `function* g(): IterableIterator<(x: string) => number, (x: string) => number> {
    yield x => x.length;
    yield *[x => x.length];
    return x => x.length;
}`,
      [],
    );
  });
  test("generatorTypeCheck27", async () => {
    await expectPass(
      `function* g(): IterableIterator<(x: string) => number> {
    yield * function* () {
        yield x => x.length;
    } ();
}`,
      [],
    );
  });
  test("generatorTypeCheck28", async () => {
    await expectPass(
      `function* g(): IterableIterator<(x: string) => number> {
    yield * {
        *[Symbol.iterator]() {
            yield x => x.length;
        }
    };
}`,
      [],
    );
  });
  test("generatorTypeCheck29", async () => {
    await expectPass(
      `function* g2(): Iterator<Iterable<(x: string) => number>> {
    yield function* () {
        yield x => x.length;
    } ()
}`,
      [],
    );
  });
  test("generatorTypeCheck3", async () => {
    await expectPass(`function* g1(): IterableIterator<string> { }`, []);
  });
  test("generatorTypeCheck30", async () => {
    await expectPass(
      `function* g2(): Iterator<Iterable<(x: string) => number>> {
    yield function* () {
        yield x => x.length;
    } ()
}`,
      [],
    );
  });
  test("generatorTypeCheck31", async () => {
    await expectPass(
      `function* g2(): Iterator<() => Iterable<(x: string) => number>> {
    yield function* () {
        yield x => x.length;
    } ()
}`,
      [],
    );
  });
  test("generatorTypeCheck32", async () => {
    await expectError(
      `var s: string;
var f: () => number = () => yield s;`,
      [],
    );
  });
  test("generatorTypeCheck33", async () => {
    await expectPass(
      `function* g() {
    yield 0;
    function* g2() {
        yield "";
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck34", async () => {
    await expectPass(
      `function* g() {
    yield 0;
    function* g2() {
        return "";
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck35", async () => {
    await expectPass(
      `function* g() {
    yield 0;
    function g2() {
        return "";
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck36", async () => {
    await expectPass(
      `function* g() {
    yield yield 0;
}`,
      [],
    );
  });
  test("generatorTypeCheck37", async () => {
    await expectPass(
      `function* g() {
    return yield yield 0;
}`,
      [],
    );
  });
  test("generatorTypeCheck38", async () => {
    await expectPass(
      `var yield;
function* g() {
    yield 0;
    var v: typeof yield;
}`,
      [],
    );
  });
  test("generatorTypeCheck39", async () => {
    await expectError(
      `
function decorator(x: any) {
    return y => { };
}
function* g() {
    @decorator(yield 0)
    class C {
        x = yield 0;
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck4", async () => {
    await expectPass(`function* g1(): {} { }`, []);
  });
  test("generatorTypeCheck40", async () => {
    await expectPass(
      `function* g() {
    class C extends (yield 0) { }
}`,
      [],
    );
  });
  test("generatorTypeCheck41", async () => {
    await expectPass(
      `function* g() {
    let x = {
        [yield 0]: 0
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck42", async () => {
    await expectPass(
      `function* g() {
    let x = {
        [yield 0]() {

        }
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck43", async () => {
    await expectPass(
      `function* g() {
    let x = {
        *[yield 0]() {

        }
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck44", async () => {
    await expectPass(
      `function* g() {
    let x = {
        get [yield 0]() {
            return 0;
        }
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck45", async () => {
    await expectPass(
      `declare function foo<T, U>(x: T, fun: () => Iterator<(x: T) => U>, fun2: (y: U) => T): T;

foo("", function* () { yield x => x.length }, p => undefined); // T is fixed, should be string`,
      [],
    );
  });
  test("generatorTypeCheck46", async () => {
    await expectPass(
      `declare function foo<T, U>(x: T, fun: () => Iterable<(x: T) => U>, fun2: (y: U) => T): T;

foo("", function* () {
    yield* {
        *[Symbol.iterator]() {
            yield x => x.length
        }
    }
}, p => undefined); // T is fixed, should be string`,
      [],
    );
  });
  test("generatorTypeCheck47", async () => {
    await expectPass(
      `
function* g() { }`,
      [],
    );
  });
  test("generatorTypeCheck48", async () => {
    await expectPass(
      `
function* g() {
    yield;
}

function* h() {
    yield undefined;
}
`,
      [],
    );
  });
  test("generatorTypeCheck49", async () => {
    await expectPass(
      `
function* g() {
    yield 0;
}`,
      [],
    );
  });
  test("generatorTypeCheck5", async () => {
    await expectPass(`function* g1(): any { }`, []);
  });
  test("generatorTypeCheck50", async () => {
    await expectPass(
      `
function* g() {
    yield yield;
}`,
      [],
    );
  });
  test("generatorTypeCheck51", async () => {
    await expectPass(
      `
function* g() {
    function* h() {
        yield 0;
    }
}`,
      [],
    );
  });
  test("generatorTypeCheck52", async () => {
    await expectPass(
      `class Foo { x: number }
class Baz { z: number }
function* g() {
    yield new Foo;
    yield new Baz;
}`,
      [],
    );
  });
  test("generatorTypeCheck53", async () => {
    await expectPass(
      `class Foo { x: number }
class Baz { z: number }
function* g() {
    yield new Foo;
    yield* [new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck54", async () => {
    await expectPass(
      `class Foo { x: number }
class Baz { z: number }
function* g() {
    yield* [new Foo];
    yield* [new Baz];
}`,
      [],
    );
  });
  test("generatorTypeCheck55", async () => {
    await expectPass(
      `function* g() {
    var x = class C extends (yield) {};
}`,
      [],
    );
  });
  test("generatorTypeCheck56", async () => {
    await expectPass(
      `function* g() {
    var x = class C {
        *[yield 0]() {
            yield 0;
        }
    };
}`,
      [],
    );
  });
  test("generatorTypeCheck57", async () => {
    await expectError(
      `function* g() {
    class C {
        x = yield 0;
    };
}`,
      [],
    );
  });
  test("generatorTypeCheck58", async () => {
    await expectError(
      `function* g() {
    class C {
        static x = yield 0;
    };
}`,
      [],
    );
  });
  test("generatorTypeCheck59", async () => {
    await expectPass(
      `function* g() {
    class C {
        @(yield "")
        m() { }
    };
}`,
      [],
    );
  });
  test("generatorTypeCheck6", async () => {
    await expectPass(`function* g1(): number { }`, []);
  });
  test("generatorTypeCheck60", async () => {
    await expectPass(
      `function* g() {
    class C extends (yield) {};
}`,
      [],
    );
  });
  test("generatorTypeCheck61", async () => {
    await expectPass(
      `function * g() {
    @(yield 0)
    class C {};
}`,
      [],
    );
  });
  test("generatorTypeCheck62", async () => {
    await expectPass(
      `// @module: commonjs

export interface StrategicState {
    lastStrategyApplied?: string;
}

export function strategy<T extends StrategicState>(stratName: string, gen: (a: T) => IterableIterator<T | undefined, void>): (a: T) => IterableIterator<T | undefined, void> {
    return function*(state) {
        for (const next of gen(state)) {
            if (next) {
                next.lastStrategyApplied = stratName;
            }
            yield next;
        }
    }
}

export interface Strategy<T> {
    (a: T): IterableIterator<T | undefined, void>;
}

export interface State extends StrategicState {
    foo: number;
}

export const Nothing1: Strategy<State> = strategy("Nothing", function*(state: State) {
    return state; // \`return\`/\`TReturn\` isn't supported by \`strategy\`, so this should error.
});

export const Nothing2: Strategy<State> = strategy("Nothing", function*(state: State) {
    yield state;
});

export const Nothing3: Strategy<State> = strategy("Nothing", function* (state: State) {
    yield ;
    return state; // \`return\`/\`TReturn\` isn't supported by \`strategy\`, so this should error.
});
 `,
      [],
    );
  });
  test("generatorTypeCheck63", async () => {
    await expectPass(
      `// @module: commonjs

export interface StrategicState {
    lastStrategyApplied?: string;
}

export function strategy<T extends StrategicState>(stratName: string, gen: (a: T) => IterableIterator<T | undefined, void>): (a: T) => IterableIterator<T | undefined, void> {
    return function*(state) {
        for (const next of gen(state)) {
            if (next) {
                next.lastStrategyApplied = stratName;
            }
            yield next;
        }
    }
}

export interface Strategy<T> {
    (a: T): IterableIterator<T | undefined, void>;
}

export interface State extends StrategicState {
    foo: number;
}

export const Nothing: Strategy<State> = strategy("Nothing", function* (state: State) {
    yield 1; // number isn't a \`State\`, so this should error.
    return state; // \`return\`/\`TReturn\` isn't supported by \`strategy\`, so this should error.
});

export const Nothing1: Strategy<State> = strategy("Nothing", function* (state: State) {
});

export const Nothing2: Strategy<State> = strategy("Nothing", function* (state: State) {
    return 1; // \`return\`/\`TReturn\` isn't supported by \`strategy\`, so this should error.
});

export const Nothing3: Strategy<State> = strategy("Nothing", function* (state: State) {
    yield state;
    return 1; // \`return\`/\`TReturn\` isn't supported by \`strategy\`, so this should error.
});`,
      [],
    );
  });
  test("generatorTypeCheck64", async () => {
    await expectPass(
      `
function* g3(): Generator<Generator<(x: string) => number>> {
    yield function* () {
        yield x => x.length;
    } ()
}

function* g4(): Iterator<Iterable<(x: string) => number>> {
  yield (function* () {
    yield (x) => x.length;
  })();
}`,
      [],
    );
  });
  test("generatorTypeCheck7", async () => {
    await expectPass(
      `interface WeirdIter extends IterableIterator<number> {
    hello: string;
}
function* g1(): WeirdIter { }`,
      [],
    );
  });
  test("generatorTypeCheck8", async () => {
    await expectPass(
      `interface BadGenerator extends Iterator<number>, Iterable<string> { }
function* g3(): BadGenerator { }`,
      [],
    );
  });
  test("generatorTypeCheck9", async () => {
    await expectPass(`function* g3(): void { }`, []);
  });
  test("YieldExpression1_es6", async () => {
    await expectPass(`yield;`, []);
  });
  test("YieldExpression10_es6", async () => {
    await expectPass(
      `var v = { * foo() {
    yield(foo);
  }
}
`,
      [],
    );
  });
  test("YieldExpression11_es6", async () => {
    await expectPass(
      `class C {
  *foo() {
    yield(foo);
  }
}`,
      [],
    );
  });
  test("YieldExpression12_es6", async () => {
    await expectError(
      `class C {
  constructor() {
     yield foo
  }
}`,
      [],
    );
  });
  test("YieldExpression13_es6", async () => {
    await expectPass(`function* foo() { yield }`, []);
  });
  test("YieldExpression14_es6", async () => {
    await expectError(
      `class C {
  foo() {
     yield foo
  }
}`,
      [],
    );
  });
  test("YieldExpression15_es6", async () => {
    await expectError(
      `var v = () => {
     yield foo
  }`,
      [],
    );
  });
  test("YieldExpression16_es6", async () => {
    await expectError(
      `function* foo() {
  function bar() {
    yield foo;
  }
}`,
      [],
    );
  });
  test("YieldExpression17_es6", async () => {
    await expectError(`var v = { get foo() { yield foo; } }`, []);
  });
  test("YieldExpression18_es6", async () => {
    await expectError(
      `"use strict";
yield(foo);`,
      [],
    );
  });
  test("YieldExpression19_es6", async () => {
    await expectPass(
      `function*foo() {
  function bar() {
    function* quux() {
      yield(foo);
    }
  }
}`,
      [],
    );
  });
  test("YieldExpression2_es6", async () => {
    await expectError(`yield foo;`, []);
  });
  test("YieldExpression20_es6", async () => {
    await expectError(
      `
function* test() {
  return () => ({
    b: yield 2, // error
  });
}`,
      [],
    );
  });
  test("YieldExpression3_es6", async () => {
    await expectPass(
      `function* foo() {
  yield
  yield
}`,
      [],
    );
  });
  test("YieldExpression4_es6", async () => {
    await expectPass(
      `function* foo() {
  yield;
  yield;
}`,
      [],
    );
  });
  test("YieldExpression5_es6", async () => {
    await expectPass(
      `function* foo() {
  yield*
}`,
      [],
    );
  });
  test("YieldExpression6_es6", async () => {
    await expectPass(
      `function* foo() {
  yield*foo
}`,
      [],
    );
  });
  test("YieldExpression7_es6", async () => {
    await expectPass(
      `function* foo() {
  yield foo
}`,
      [],
    );
  });
  test("YieldExpression8_es6", async () => {
    await expectPass(
      `yield(foo);
function* foo() {
  yield(foo);
}`,
      [],
    );
  });
  test("YieldExpression9_es6", async () => {
    await expectPass(
      `var v = function*() {
  yield(foo);
}`,
      [],
    );
  });
  test("yieldExpressionInControlFlow", async () => {
    await expectPass(
      `function* f() {
    var o
    while (true) {
        o = yield o
    }
}

// fails in Typescript too
function* g() {
    var o = []
    while (true) {
        o = yield* o
    }
}`,
      [],
    );
  });
  test("YieldStarExpression1_es6", async () => {
    await expectPass(`yield * [];`, []);
  });
  test("YieldStarExpression2_es6", async () => {
    await expectError(`yield *;`, []);
  });
  test("YieldStarExpression3_es6", async () => {
    await expectPass(
      `function *g() {
    yield *;
}`,
      [],
    );
  });
  test("YieldStarExpression4_es6", async () => {
    await expectPass(
      `function *g() {
    yield * [];
}`,
      [],
    );
  });
});
