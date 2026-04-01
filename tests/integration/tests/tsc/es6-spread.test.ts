import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/spread", () => {
  test("arrayLiteralSpread", async () => {
    await expectPass(
      `function f0() {
    var a = [1, 2, 3];
    var a1 = [...a];
    var a2 = [1, ...a];
    var a3 = [1, 2, ...a];
    var a4 = [...a, 1];
    var a5 = [...a, 1, 2];
    var a6 = [1, 2, ...a, 1, 2];
    var a7 = [1, ...a, 2, ...a];
    var a8 = [...a, ...a, ...a];
}

function f1() {
    var a = [1, 2, 3];
    var b = ["hello", ...a, true];
    var b: (string | number | boolean)[];
}

function f2() {
    var a = [...[...[...[...[...[]]]]]];
    var b = [...[...[...[...[...[5]]]]]];
}
`,
      [],
    );
  });
  test("arrayLiteralSpreadES5iterable", async () => {
    await expectPass(
      `function f0() {
    var a = [1, 2, 3];
    var a1 = [...a];
    var a2 = [1, ...a];
    var a3 = [1, 2, ...a];
    var a4 = [...a, 1];
    var a5 = [...a, 1, 2];
    var a6 = [1, 2, ...a, 1, 2];
    var a7 = [1, ...a, 2, ...a];
    var a8 = [...a, ...a, ...a];
}

function f1() {
    var a = [1, 2, 3];
    var b = ["hello", ...a, true];
    var b: (string | number | boolean)[];
}

function f2() {
    var a = [...[...[...[...[...[]]]]]];
    var b = [...[...[...[...[...[5]]]]]];
}
`,
      [],
    );
  });
  test("arraySpreadImportHelpers", async () => {
    await expectPass(
      `
export {};
const k = [1, , 2];
const o = [3, ...k, 4];

// this is a pre-TS4.4 versions of emit helper, which always forced array packing
declare module "tslib" {
    function __spreadArray(to: any[], from: any[]): any[];
}
`,
      [],
    );
  });
  test("arraySpreadInCall", async () => {
    await expectPass(
      `
declare function f1(a: number, b: number, c: number, d: number, e: number, f: number): void;
f1(1, 2, 3, 4, ...[5, 6]);
f1(...[1], 2, 3, 4, 5, 6);
f1(1, 2, ...[3, 4], 5, 6);
f1(1, 2, ...[3], 4, ...[5, 6]);
f1(...[1, 2], ...[3, 4], ...[5, 6]);
f1(...(([1, 2])), ...(((([3, 4])))), ...([5, 6]));

declare function f2<T extends unknown[]>(...args: T): T;
const x21 = f2(...[1, 'foo'])
const x22 = f2(true, ...[1, 'foo'])
const x23 = f2(...([1, 'foo']))
const x24 = f2(true, ...([1, 'foo']))

declare function f3<T extends readonly unknown[]>(...args: T): T;
const x31 = f3(...[1, 'foo'])
const x32 = f3(true, ...[1, 'foo'])
const x33 = f3(...([1, 'foo']))
const x34 = f3(true, ...([1, 'foo']))

declare function f4<const T extends readonly unknown[]>(...args: T): T;
const x41 = f4(...[1, 'foo'])
const x42 = f4(true, ...[1, 'foo'])
const x43 = f4(...([1, 'foo']))
const x44 = f4(true, ...([1, 'foo']))

// dicovered in #52845#issuecomment-1459132562
interface IAction {
    run(event?: unknown): unknown;
}
declare const action: IAction
action.run(...[100, 'foo']) // error`,
      [],
    );
  });
  test("iteratorSpreadInArray", async () => {
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

var array = [...new SymbolIterator];
`,
      [],
    );
  });
  test("iteratorSpreadInArray10", async () => {
    await expectPass(
      `class SymbolIterator {
    [Symbol.iterator]() {
        return this;
    }
}

var array = [...new SymbolIterator];`,
      [],
    );
  });
  test("iteratorSpreadInArray11", async () => {
    await expectPass(
      `var iter: Iterable<number>;
var array = [...iter];`,
      [],
    );
  });
  test("iteratorSpreadInArray2", async () => {
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

var array = [...new NumberIterator, ...new SymbolIterator];
`,
      [],
    );
  });
  test("iteratorSpreadInArray3", async () => {
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

var array = [...[0, 1], ...new SymbolIterator];`,
      [],
    );
  });
  test("iteratorSpreadInArray4", async () => {
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

var array = [0, 1, ...new SymbolIterator];`,
      [],
    );
  });
  test("iteratorSpreadInArray5", async () => {
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

var array: number[] = [0, 1, ...new SymbolIterator];`,
      [],
    );
  });
  test("iteratorSpreadInArray6", async () => {
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

var array: number[] = [0, 1];
array.concat([...new SymbolIterator]);`,
      [],
    );
  });
  test("iteratorSpreadInArray7", async () => {
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

var array: symbol[];
array.concat([...new SymbolIterator]);`,
      [],
    );
  });
  test("iteratorSpreadInArray8", async () => {
    await expectPass(
      `class SymbolIterator {
    next() {
        return {
            value: Symbol(),
            done: false
        };
    }
}

var array = [...new SymbolIterator];`,
      [],
    );
  });
  test("iteratorSpreadInArray9", async () => {
    await expectPass(
      `class SymbolIterator {
    next() {
        return {
            value: Symbol()
        };
    }

    [Symbol.iterator]() {
        return this;
    }
}

var array = [...new SymbolIterator];`,
      [],
    );
  });
  test("iteratorSpreadInCall", async () => {
    await expectPass(
      `function foo(s: symbol) { }
class SymbolIterator {
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

foo(...new SymbolIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall10", async () => {
    await expectPass(
      `function foo<T>(s: T[]) { return s[0] }
class SymbolIterator {
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

foo(...new SymbolIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall11", async () => {
    await expectPass(
      `function foo<T>(...s: T[]) { return s[0] }
class SymbolIterator {
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

foo(...new SymbolIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall12", async () => {
    await expectPass(
      `class Foo<T> {
    constructor(...s: T[]) { }
}

class SymbolIterator {
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

class _StringIterator {
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

new Foo(...[...new SymbolIterator, ...[...new _StringIterator]]);`,
      [],
    );
  });
  test("iteratorSpreadInCall2", async () => {
    await expectPass(
      `function foo(s: symbol[]) { }
class SymbolIterator {
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

foo(...new SymbolIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall3", async () => {
    await expectPass(
      `function foo(...s: symbol[]) { }
class SymbolIterator {
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

foo(...new SymbolIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall4", async () => {
    await expectPass(
      `function foo(s1: symbol, ...s: symbol[]) { }
class SymbolIterator {
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

foo(...new SymbolIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall5", async () => {
    await expectPass(
      `function foo(...s: (symbol | string)[]) { }
class SymbolIterator {
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

class _StringIterator {
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

foo(...new SymbolIterator, ...new _StringIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall6", async () => {
    await expectPass(
      `function foo(...s: (symbol | number)[]) { }
class SymbolIterator {
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

class _StringIterator {
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

foo(...new SymbolIterator, ...new _StringIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall7", async () => {
    await expectPass(
      `function foo<T>(...s: T[]) { return s[0]; }
class SymbolIterator {
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

class _StringIterator {
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

foo(...new SymbolIterator, ...new _StringIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall8", async () => {
    await expectPass(
      `class Foo<T> {
    constructor(...s: T[]) { }
}

class SymbolIterator {
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

class _StringIterator {
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

new Foo(...new SymbolIterator, ...new _StringIterator);`,
      [],
    );
  });
  test("iteratorSpreadInCall9", async () => {
    await expectPass(
      `class Foo<T> {
    constructor(...s: T[]) { }
}

class SymbolIterator {
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

class _StringIterator {
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

new Foo(...new SymbolIterator, ...[...new _StringIterator]);
`,
      [],
    );
  });
});
