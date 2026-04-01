import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/computedProperties", () => {
  test("computedPropertyNames1_ES5", async () => {
    await expectPass(
      `var v = {
    get [0 + 1]() { return 0 },
    set [0 + 1](v: string) { } //No error
}`,
      [],
    );
  });
  test("computedPropertyNames1_ES6", async () => {
    await expectPass(
      `var v = {
    get [0 + 1]() { return 0 },
    set [0 + 1](v: string) { } //No error
}`,
      [],
    );
  });
  test("computedPropertyNames10_ES5", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
var v = {
    [s]() { },
    [n]() { },
    [s + s]() { },
    [s + n]() { },
    [+s]() { },
    [""]() { },
    [0]() { },
    [a]() { },
    [<any>true]() { },
    [\`hello bye\`]() { },
    [\`hello \${a} bye\`]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames10_ES6", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
var v = {
    [s]() { },
    [n]() { },
    [s + s]() { },
    [s + n]() { },
    [+s]() { },
    [""]() { },
    [0]() { },
    [a]() { },
    [<any>true]() { },
    [\`hello bye\`]() { },
    [\`hello \${a} bye\`]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames11_ES5", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
var v = {
    get [s]() { return 0; },
    set [n](v) { },
    get [s + s]() { return 0; },
    set [s + n](v) { },
    get [+s]() { return 0; },
    set [""](v) { },
    get [0]() { return 0; },
    set [a](v) { },
    get [<any>true]() { return 0; },
    set [\`hello bye\`](v) { },
    get [\`hello \${a} bye\`]() { return 0; }
}`,
      [],
    );
  });
  test("computedPropertyNames11_ES6", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
var v = {
    get [s]() { return 0; },
    set [n](v) { },
    get [s + s]() { return 0; },
    set [s + n](v) { },
    get [+s]() { return 0; },
    set [""](v) { },
    get [0]() { return 0; },
    set [a](v) { },
    get [<any>true]() { return 0; },
    set [\`hello bye\`](v) { },
    get [\`hello \${a} bye\`]() { return 0; }
}`,
      [],
    );
  });
  test("computedPropertyNames12_ES5", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
class C {
    [s]: number;
    [n] = n;
    static [s + s]: string;
    [s + n] = 2;
    [+s]: typeof s;
    static [""]: number;
    [0]: number;
    [a]: number;
    static [<any>true]: number;
    [\`hello bye\`] = 0;
    static [\`hello \${a} bye\`] = 0
}`,
      [],
    );
  });
  test("computedPropertyNames12_ES6", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
class C {
    [s]: number;
    [n] = n;
    static [s + s]: string;
    [s + n] = 2;
    [+s]: typeof s;
    static [""]: number;
    [0]: number;
    [a]: number;
    static [<any>true]: number;
    [\`hello bye\`] = 0;
    static [\`hello \${a} bye\`] = 0
}`,
      [],
    );
  });
  test("computedPropertyNames13_ES5", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
class C {
    [s]() {}
    [n]() { }
    static [s + s]() { }
    [s + n]() { }
    [+s]() { }
    static [""]() { }
    [0]() { }
    [a]() { }
    static [<any>true]() { }
    [\`hello bye\`]() { }
    static [\`hello \${a} bye\`]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames13_ES6", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
class C {
    [s]() {}
    [n]() { }
    static [s + s]() { }
    [s + n]() { }
    [+s]() { }
    static [""]() { }
    [0]() { }
    [a]() { }
    static [<any>true]() { }
    [\`hello bye\`]() { }
    static [\`hello \${a} bye\`]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames14_ES5", async () => {
    await expectPass(
      `var b: boolean;
class C {
    [b]() {}
    static [true]() { }
    [[]]() { }
    static [{}]() { }
    [undefined]() { }
    static [null]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames14_ES6", async () => {
    await expectPass(
      `var b: boolean;
class C {
    [b]() {}
    static [true]() { }
    [[]]() { }
    static [{}]() { }
    [undefined]() { }
    static [null]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames15_ES5", async () => {
    await expectPass(
      `var p1: number | string;
var p2: number | number[];
var p3: string | boolean;
class C {
    [p1]() { }
    [p2]() { }
    [p3]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames15_ES6", async () => {
    await expectPass(
      `var p1: number | string;
var p2: number | number[];
var p3: string | boolean;
class C {
    [p1]() { }
    [p2]() { }
    [p3]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames16_ES5", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
class C {
    get [s]() { return 0;}
    set [n](v) { }
    static get [s + s]() { return 0; }
    set [s + n](v) { }
    get [+s]() { return 0; }
    static set [""](v) { }
    get [0]() { return 0; }
    set [a](v) { }
    static get [<any>true]() { return 0; }
    set [\`hello bye\`](v) { }
    get [\`hello \${a} bye\`]() { return 0; }
}`,
      [],
    );
  });
  test("computedPropertyNames16_ES6", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
class C {
    get [s]() { return 0;}
    set [n](v) { }
    static get [s + s]() { return 0; }
    set [s + n](v) { }
    get [+s]() { return 0; }
    static set [""](v) { }
    get [0]() { return 0; }
    set [a](v) { }
    static get [<any>true]() { return 0; }
    set [\`hello bye\`](v) { }
    get [\`hello \${a} bye\`]() { return 0; }
}`,
      [],
    );
  });
  test("computedPropertyNames17_ES5", async () => {
    await expectPass(
      `var b: boolean;
class C {
    get [b]() { return 0;}
    static set [true](v) { }
    get [[]]() { return 0; }
    set [{}](v) { }
    static get [undefined]() { return 0; }
    set [null](v) { }
}`,
      [],
    );
  });
  test("computedPropertyNames17_ES6", async () => {
    await expectPass(
      `var b: boolean;
class C {
    get [b]() { return 0;}
    static set [true](v) { }
    get [[]]() { return 0; }
    set [{}](v) { }
    static get [undefined]() { return 0; }
    set [null](v) { }
}`,
      [],
    );
  });
  test("computedPropertyNames18_ES5", async () => {
    await expectPass(
      `function foo() {
    var obj = {
        [this.bar]: 0
    }
}`,
      [],
    );
  });
  test("computedPropertyNames18_ES6", async () => {
    await expectPass(
      `function foo() {
    var obj = {
        [this.bar]: 0
    }
}`,
      [],
    );
  });
  test("computedPropertyNames19_ES5", async () => {
    await expectPass(
      `namespace M {
    var obj = {
        [this.bar]: 0
    }
}`,
      [],
    );
  });
  test("computedPropertyNames19_ES6", async () => {
    await expectPass(
      `namespace M {
    var obj = {
        [this.bar]: 0
    }
}`,
      [],
    );
  });
  test("computedPropertyNames2_ES5", async () => {
    await expectPass(
      `var methodName = "method";
var accessorName = "accessor";
class C {
    [methodName]() { }
    static [methodName]() { }
    get [accessorName]() { }
    set [accessorName](v) { }
    static get [accessorName]() { }
    static set [accessorName](v) { }
}`,
      [],
    );
  });
  test("computedPropertyNames2_ES6", async () => {
    await expectPass(
      `var methodName = "method";
var accessorName = "accessor";
class C {
    [methodName]() { }
    static [methodName]() { }
    get [accessorName]() { }
    set [accessorName](v) { }
    static get [accessorName]() { }
    static set [accessorName](v) { }
}`,
      [],
    );
  });
  test("computedPropertyNames20_ES5", async () => {
    await expectPass(
      `var obj = {
    [this.bar]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames20_ES6", async () => {
    await expectPass(
      `var obj = {
    [this.bar]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames21_ES5", async () => {
    await expectPass(
      `class C {
    bar() {
        return 0;
    }
    [this.bar()]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames21_ES6", async () => {
    await expectPass(
      `class C {
    bar() {
        return 0;
    }
    [this.bar()]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames22_ES5", async () => {
    await expectPass(
      `class C {
    bar() {
        var obj = {
            [this.bar()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames22_ES6", async () => {
    await expectPass(
      `class C {
    bar() {
        var obj = {
            [this.bar()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames23_ES5", async () => {
    await expectPass(
      `class C {
    bar() {
        return 0;
    }
    [
        { [this.bar()]: 1 }[0]
    ]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames23_ES6", async () => {
    await expectPass(
      `class C {
    bar() {
        return 0;
    }
    [
        { [this.bar()]: 1 }[0]
    ]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames24_ES5", async () => {
    await expectError(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    [super.bar()]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames24_ES6", async () => {
    await expectError(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    // Gets emitted as super, not _super, which is consistent with
    // use of super in static properties initializers.
    [super.bar()]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames25_ES5", async () => {
    await expectPass(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    foo() {
        var obj = {
            [super.bar()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames25_ES6", async () => {
    await expectPass(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    foo() {
        var obj = {
            [super.bar()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames26_ES5", async () => {
    await expectError(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    [
        { [super.bar()]: 1 }[0]
    ]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames26_ES6", async () => {
    await expectError(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    // Gets emitted as super, not _super, which is consistent with
    // use of super in static properties initializers.
    [
        { [super.bar()]: 1 }[0]
    ]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames27_ES5", async () => {
    await expectError(
      `class Base {
}
class C extends Base {
    [(super(), "prop")]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames27_ES6", async () => {
    await expectError(
      `class Base {
}
class C extends Base {
    [(super(), "prop")]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames28_ES5", async () => {
    await expectPass(
      `class Base {
}
class C extends Base {
    constructor() {
        super();
        var obj = {
            [(super(), "prop")]() { }
        };
    }
}`,
      [],
    );
  });
  test("computedPropertyNames28_ES6", async () => {
    await expectPass(
      `class Base {
}
class C extends Base {
    constructor() {
        super();
        var obj = {
            [(super(), "prop")]() { }
        };
    }
}`,
      [],
    );
  });
  test("computedPropertyNames29_ES5", async () => {
    await expectPass(
      `class C {
    bar() {
        () => {
            var obj = {
                [this.bar()]() { } // needs capture
            };
        }
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames29_ES6", async () => {
    await expectPass(
      `class C {
    bar() {
        () => {
            var obj = {
                [this.bar()]() { } // needs capture
            };
        }
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames3_ES5", async () => {
    await expectError(
      `var id;
class C {
    [0 + 1]() { }
    static [() => { }]() { }
    get [delete id]() { }
    set [[0, 1]](v) { }
    static get [<String>""]() { }
    static set [id.toString()](v) { }
}`,
      [],
    );
  });
  test("computedPropertyNames3_ES6", async () => {
    await expectError(
      `var id;
class C {
    [0 + 1]() { }
    static [() => { }]() { }
    get [delete id]() { }
    set [[0, 1]](v) { }
    static get [<String>""]() { }
    static set [id.toString()](v) { }
}`,
      [],
    );
  });
  test("computedPropertyNames30_ES5", async () => {
    await expectPass(
      `class Base {
}
class C extends Base {
    constructor() {
        super();
        () => {
            var obj = {
                // Ideally, we would capture this. But the reference is
                // illegal, and not capturing this is consistent with
                //treatment of other similar violations.
                [(super(), "prop")]() { }
            };
        }
    }
}`,
      [],
    );
  });
  test("computedPropertyNames30_ES6", async () => {
    await expectPass(
      `class Base {
}
class C extends Base {
    constructor() {
        super();
        () => {
            var obj = {
                // Ideally, we would capture this. But the reference is
                // illegal, and not capturing this is consistent with
                //treatment of other similar violations.
                [(super(), "prop")]() { }
            };
        }
    }
}`,
      [],
    );
  });
  test("computedPropertyNames31_ES5", async () => {
    await expectPass(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    foo() {
        () => {
            var obj = {
                [super.bar()]() { } // needs capture
            };
        }
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames31_ES6", async () => {
    await expectPass(
      `class Base {
    bar() {
        return 0;
    }
}
class C extends Base {
    foo() {
        () => {
            var obj = {
                [super.bar()]() { } // needs capture
            };
        }
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames32_ES5", async () => {
    await expectPass(
      `function foo<T>() { return '' }
class C<T> {
    bar() {
        return 0;
    }
    [foo<T>()]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames32_ES6", async () => {
    await expectPass(
      `function foo<T>() { return '' }
class C<T> {
    bar() {
        return 0;
    }
    [foo<T>()]() { }
}`,
      [],
    );
  });
  test("computedPropertyNames33_ES5", async () => {
    await expectPass(
      `function foo<T>() { return '' }
class C<T> {
    bar() {
        var obj = {
            [foo<T>()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames33_ES6", async () => {
    await expectPass(
      `function foo<T>() { return '' }
class C<T> {
    bar() {
        var obj = {
            [foo<T>()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames34_ES5", async () => {
    await expectPass(
      `function foo<T>() { return '' }
class C<T> {
    static bar() {
        var obj = {
            [foo<T>()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames34_ES6", async () => {
    await expectPass(
      `function foo<T>() { return '' }
class C<T> {
    static bar() {
        var obj = {
            [foo<T>()]() { }
        };
        return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNames35_ES5", async () => {
    await expectError(
      `function foo<T>() { return '' }
interface I<T> {
    bar(): string;
    [foo<T>()](): void;
}`,
      [],
    );
  });
  test("computedPropertyNames35_ES6", async () => {
    await expectError(
      `function foo<T>() { return '' }
interface I<T> {
    bar(): string;
    [foo<T>()](): void;
}`,
      [],
    );
  });
  test("computedPropertyNames36_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;

    // Computed properties
    get ["get1"]() { return new Foo }
    set ["set1"](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames36_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;

    // Computed properties
    get ["get1"]() { return new Foo }
    set ["set1"](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames37_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: number]: Foo2;

    // Computed properties
    get ["get1"]() { return new Foo }
    set ["set1"](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames37_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: number]: Foo2;

    // Computed properties
    get ["get1"]() { return new Foo }
    set ["set1"](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames38_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;

    // Computed properties
    get [1 << 6]() { return new Foo }
    set [1 << 6](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames38_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;

    // Computed properties
    get [1 << 6]() { return new Foo }
    set [1 << 6](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames39_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: number]: Foo2;

    // Computed properties
    get [1 << 6]() { return new Foo }
    set [1 << 6](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames39_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: number]: Foo2;

    // Computed properties
    get [1 << 6]() { return new Foo }
    set [1 << 6](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames4_ES5", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
var v = {
    [s]: 0,
    [n]: n,
    [s + s]: 1,
    [s + n]: 2,
    [+s]: s,
    [""]: 0,
    [0]: 0,
    [a]: 1,
    [<any>true]: 0,
    [\`hello bye\`]: 0,
    [\`hello \${a} bye\`]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames4_ES6", async () => {
    await expectPass(
      `var s: string;
var n: number;
var a: any;
var v = {
    [s]: 0,
    [n]: n,
    [s + s]: 1,
    [s + n]: 2,
    [+s]: s,
    [""]: 0,
    [0]: 0,
    [a]: 1,
    [<any>true]: 0,
    [\`hello bye\`]: 0,
    [\`hello \${a} bye\`]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames40_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: () => Foo2;

    // Computed properties
    [""]() { return new Foo }
    [""]() { return new Foo2 }
}`,
      [],
    );
  });
  test("computedPropertyNames40_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: () => Foo2;

    // Computed properties
    [""]() { return new Foo }
    [""]() { return new Foo2 }
}`,
      [],
    );
  });
  test("computedPropertyNames41_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: () => Foo2;

    // Computed properties
    static [""]() { return new Foo }
}`,
      [],
    );
  });
  test("computedPropertyNames41_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: () => Foo2;

    // Computed properties
    static [""]() { return new Foo }
}`,
      [],
    );
  });
  test("computedPropertyNames42_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;

    // Computed properties
    [""]: Foo;
}`,
      [],
    );
  });
  test("computedPropertyNames42_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;

    // Computed properties
    [""]: Foo;
}`,
      [],
    );
  });
  test("computedPropertyNames43_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;
}

class D extends C {
    // Computed properties
    get ["get1"]() { return new Foo }
    set ["set1"](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames43_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;
}

class D extends C {
    // Computed properties
    get ["get1"]() { return new Foo }
    set ["set1"](p: Foo2) { }
}`,
      [],
    );
  });
  test("computedPropertyNames44_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;
    get ["get1"]() { return new Foo }
}

class D extends C {
    set ["set1"](p: Foo) { }
}`,
      [],
    );
  });
  test("computedPropertyNames44_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    [s: string]: Foo2;
    get ["get1"]() { return new Foo }
}

class D extends C {
    set ["set1"](p: Foo) { }
}`,
      [],
    );
  });
  test("computedPropertyNames45_ES5", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    get ["get1"]() { return new Foo }
}

class D extends C {
    // No error when the indexer is in a class more derived than the computed property
    [s: string]: Foo2;
    set ["set1"](p: Foo) { }
}`,
      [],
    );
  });
  test("computedPropertyNames45_ES6", async () => {
    await expectPass(
      `class Foo { x }
class Foo2 { x; y }

class C {
    get ["get1"]() { return new Foo }
}

class D extends C {
    // No error when the indexer is in a class more derived than the computed property
    [s: string]: Foo2;
    set ["set1"](p: Foo) { }
}`,
      [],
    );
  });
  test("computedPropertyNames46_ES5", async () => {
    await expectPass(
      `var o = {
    ["" || 0]: 0
};`,
      [],
    );
  });
  test("computedPropertyNames46_ES6", async () => {
    await expectPass(
      `var o = {
    ["" || 0]: 0
};`,
      [],
    );
  });
  test("computedPropertyNames47_ES5", async () => {
    await expectPass(
      `enum E1 { x }
enum E2 { x }
var o = {
    [E1.x || E2.x]: 0
};`,
      [],
    );
  });
  test("computedPropertyNames47_ES6", async () => {
    await expectPass(
      `enum E1 { x }
enum E2 { x }
var o = {
    [E1.x || E2.x]: 0
};`,
      [],
    );
  });
  test("computedPropertyNames48_ES5", async () => {
    await expectPass(
      `declare function extractIndexer<T>(p: { [n: number]: T }): T;

enum E { x }

var a: any;

extractIndexer({
    [a]: ""
}); // Should return string

extractIndexer({
    [E.x]: ""
}); // Should return string

extractIndexer({
    ["" || 0]: ""
}); // Should return any (widened form of undefined)`,
      [],
    );
  });
  test("computedPropertyNames48_ES6", async () => {
    await expectPass(
      `declare function extractIndexer<T>(p: { [n: number]: T }): T;

enum E { x }

var a: any;

extractIndexer({
    [a]: ""
}); // Should return string

extractIndexer({
    [E.x]: ""
}); // Should return string

extractIndexer({
    ["" || 0]: ""
}); // Should return any (widened form of undefined)`,
      [],
    );
  });
  test("computedPropertyNames49_ES5", async () => {
    await expectPass(
      `
var x = {
    p1: 10,
    get [1 + 1]() {
        throw 10;
    },
    get [1 + 1]() {
        return 10;
    },
    set [1 + 1]() {
        // just throw
        throw 10;
    },
    get foo() {
        if (1 == 1) {
            return 10;
        }
    },
    get foo() {
        if (2 == 2) {
            return 20;
        }
    },
    p2: 20
}`,
      [],
    );
  });
  test("computedPropertyNames49_ES6", async () => {
    await expectPass(
      `
var x = {
    p1: 10,
    get [1 + 1]() {
        throw 10;
    },
    get [1 + 1]() {
        return 10;
    },
    set [1 + 1]() {
        // just throw
        throw 10;
    },
    get foo() {
        if (1 == 1) {
            return 10;
        }
    },
    get foo() {
        if (2 == 2) {
            return 20;
        }
    },
    p2: 20
}`,
      [],
    );
  });
  test("computedPropertyNames5_ES5", async () => {
    await expectPass(
      `declare var b: boolean;
var v = {
    [b]: 0,
    [true]: 1,
    [[]]: 0,
    [{}]: 0,
    [undefined]: undefined,
    [null]: null
}`,
      [],
    );
  });
  test("computedPropertyNames5_ES6", async () => {
    await expectPass(
      `declare var b: boolean;
var v = {
    [b]: 0,
    [true]: 1,
    [[]]: 0,
    [{}]: 0,
    [undefined]: undefined,
    [null]: null
}`,
      [],
    );
  });
  test("computedPropertyNames50_ES5", async () => {
    await expectPass(
      `
var x = {
    p1: 10,
    get foo() {
        if (1 == 1) {
            return 10;
        }
    },
    get [1 + 1]() {
        throw 10;
    },
    set [1 + 1]() {
        // just throw
        throw 10;
    },
    get [1 + 1]() {
        return 10;
    },
    get foo() {
        if (2 == 2) {
            return 20;
        }
    },
    p2: 20
}`,
      [],
    );
  });
  test("computedPropertyNames50_ES6", async () => {
    await expectPass(
      `
var x = {
    p1: 10,
    get foo() {
        if (1 == 1) {
            return 10;
        }
    },
    get [1 + 1]() {
        throw 10;
    },
    set [1 + 1]() {
        // just throw
        throw 10;
    },
    get [1 + 1]() {
        return 10;
    },
    get foo() {
        if (2 == 2) {
            return 20;
        }
    },
    p2: 20
}`,
      [],
    );
  });
  test("computedPropertyNames51_ES5", async () => {
    await expectPass(
      `function f<T, K extends keyof T>() {
    var t!: T;
    var k!: K;
    var v = {
        [t]: 0,
        [k]: 1
    };
}`,
      [],
    );
  });
  test("computedPropertyNames51_ES6", async () => {
    await expectPass(
      `function f<T, K extends keyof T>() {
    var t!: T;
    var k!: K;
    var v = {
        [t]: 0,
        [k]: 1
    };
}`,
      [],
    );
  });
  test("computedPropertyNames52", async () => {
    await expectPass(
      `const array = [];
for (let i = 0; i < 10; ++i) {
    array.push(class C {
        [i] = () => C;
        static [i] = 100;
    })
}`,
      [],
    );
  });
  test("computedPropertyNames6_ES5", async () => {
    await expectPass(
      `declare var p1: number | string;
declare var p2: number | number[];
declare var p3: string | boolean;
var v = {
    [p1]: 0,
    [p2]: 1,
    [p3]: 2
}`,
      [],
    );
  });
  test("computedPropertyNames6_ES6", async () => {
    await expectPass(
      `declare var p1: number | string;
declare var p2: number | number[];
declare var p3: string | boolean;
var v = {
    [p1]: 0,
    [p2]: 1,
    [p3]: 2
}`,
      [],
    );
  });
  test("computedPropertyNames7_ES5", async () => {
    await expectPass(
      `enum E {
    member
}
var v = {
    [E.member]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames7_ES6", async () => {
    await expectPass(
      `enum E {
    member
}
var v = {
    [E.member]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames8_ES5", async () => {
    await expectPass(
      `function f<T, U extends string>() {
    var t!: T;
    var u!: U;
    var v = {
        [t]: 0,
        [u]: 1
    };
}`,
      [],
    );
  });
  test("computedPropertyNames8_ES6", async () => {
    await expectPass(
      `function f<T, U extends string>() {
    var t!: T;
    var u!: U;
    var v = {
        [t]: 0,
        [u]: 1
    };
}`,
      [],
    );
  });
  test("computedPropertyNames9_ES5", async () => {
    await expectPass(
      `function f(s: string): string;
function f(n: number): number;
function f<T>(x: T): T;
function f(x): any { }

var v = {
    [f("")]: 0,
    [f(0)]: 0,
    [f(true)]: 0
}`,
      [],
    );
  });
  test("computedPropertyNames9_ES6", async () => {
    await expectPass(
      `function f(s: string): string;
function f(n: number): number;
function f<T>(x: T): T;
function f(x): any { }

var v = {
    [f("")]: 0,
    [f(0)]: 0,
    [f(true)]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType1_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: (x: string) => number;
    [s: number]: (x: any) => number; // Doesn't get hit
}

var o: I = {
    ["" + 0](y) { return y.length; },
    ["" + 1]: y => y.length
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType1_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: (x: string) => number;
    [s: number]: (x: any) => number; // Doesn't get hit
}

var o: I = {
    ["" + 0](y) { return y.length; },
    ["" + 1]: y => y.length
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType10_ES5", async () => {
    await expectPass(
      `interface I {
    [s: number]: boolean;
}

var o: I = {
    [+"foo"]: "",
    [+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType10_ES6", async () => {
    await expectPass(
      `interface I {
    [s: number]: boolean;
}

var o: I = {
    [+"foo"]: "",
    [+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType2_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: (x: any) => number; // Doesn't get hit
    [s: number]: (x: string) => number;
}

var o: I = {
    [+"foo"](y) { return y.length; },
    [+"bar"]: y => y.length
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType2_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: (x: any) => number; // Doesn't get hit
    [s: number]: (x: string) => number;
}

var o: I = {
    [+"foo"](y) { return y.length; },
    [+"bar"]: y => y.length
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType3_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: (x: string) => number;
}

var o: I = {
    [+"foo"](y) { return y.length; },
    [+"bar"]: y => y.length
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType3_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: (x: string) => number;
}

var o: I = {
    [+"foo"](y) { return y.length; },
    [+"bar"]: y => y.length
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType4_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: any;
    [s: number]: any;
}

var o: I = {
    [""+"foo"]: "",
    [""+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType4_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: any;
    [s: number]: any;
}

var o: I = {
    [""+"foo"]: "",
    [""+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType5_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: any;
    [s: number]: any;
}

var o: I = {
    [+"foo"]: "",
    [+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType5_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: any;
    [s: number]: any;
}

var o: I = {
    [+"foo"]: "",
    [+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType6_ES5", async () => {
    await expectPass(
      `interface I<T> {
    [s: string]: T;
}

declare function foo<T>(obj: I<T>): T

foo({
    p: "",
    0: () => { },
    ["hi" + "bye"]: true,
    [0 + 1]: 0,
    [+"hi"]: [0]
});`,
      [],
    );
  });
  test("computedPropertyNamesContextualType6_ES6", async () => {
    await expectPass(
      `interface I<T> {
    [s: string]: T;
}

declare function foo<T>(obj: I<T>): T

foo({
    p: "",
    0: () => { },
    ["hi" + "bye"]: true,
    [0 + 1]: 0,
    [+"hi"]: [0]
});`,
      [],
    );
  });
  test("computedPropertyNamesContextualType7_ES5", async () => {
    await expectPass(
      `interface I<T> {
    [n: number]: T;
}
interface J<T> {
    [s: string]: T;
}

declare function foo<T>(obj: I<T>): T;
declare function g<T>(obj: J<T>): T;

foo({
    0: () => { },
    ["hi" + "bye"]: true,
    [0 + 1]: 0,
    [+"hi"]: [0]
});

g({ p: "" });
`,
      [],
    );
  });
  test("computedPropertyNamesContextualType7_ES6", async () => {
    await expectPass(
      `interface I<T> {
    [n: number]: T;
}
interface J<T> {
    [s: string]: T;
}

declare function foo<T>(obj: I<T>): T;
declare function g<T>(obj: J<T>): T;

foo({
    0: () => { },
    ["hi" + "bye"]: true,
    [0 + 1]: 0,
    [+"hi"]: [0]
});

g({ p: "" });
`,
      [],
    );
  });
  test("computedPropertyNamesContextualType8_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: boolean;
    [s: number]: boolean;
}

var o: I = {
    [""+"foo"]: "",
    [""+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType8_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: boolean;
    [s: number]: boolean;
}

var o: I = {
    [""+"foo"]: "",
    [""+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType9_ES5", async () => {
    await expectPass(
      `interface I {
    [s: string]: boolean;
    [s: number]: boolean;
}

var o: I = {
    [+"foo"]: "",
    [+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesContextualType9_ES6", async () => {
    await expectPass(
      `interface I {
    [s: string]: boolean;
    [s: number]: boolean;
}

var o: I = {
    [+"foo"]: "",
    [+"bar"]: 0
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit1_ES5", async () => {
    await expectPass(
      `class C {
    ["" + ""]() { }
    get ["" + ""]() { return 0; }
    set ["" + ""](x) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit1_ES6", async () => {
    await expectPass(
      `class C {
    ["" + ""]() { }
    get ["" + ""]() { return 0; }
    set ["" + ""](x) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit2_ES5", async () => {
    await expectPass(
      `class C {
    static ["" + ""]() { }
    static get ["" + ""]() { return 0; }
    static set ["" + ""](x) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit2_ES6", async () => {
    await expectPass(
      `class C {
    static ["" + ""]() { }
    static get ["" + ""]() { return 0; }
    static set ["" + ""](x) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit3_ES5", async () => {
    await expectPass(
      `interface I {
    ["" + ""](): void;
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit3_ES6", async () => {
    await expectPass(
      `interface I {
    ["" + ""](): void;
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit4_ES5", async () => {
    await expectPass(
      `var v: {
    ["" + ""](): void;
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit4_ES6", async () => {
    await expectPass(
      `var v: {
    ["" + ""](): void;
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit5_ES5", async () => {
    await expectPass(
      `var v = {
    ["" + ""]: 0,
    ["" + ""]() { },
    get ["" + ""]() { return 0; },
    set ["" + ""](x) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit5_ES6", async () => {
    await expectPass(
      `var v = {
    ["" + ""]: 0,
    ["" + ""]() { },
    get ["" + ""]() { return 0; },
    set ["" + ""](x) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit6_ES5", async () => {
    await expectPass(
      `var v = {
  [-1]: {},
  [+1]: {},
  [~1]: {},
  [!1]: {}
}`,
      [],
    );
  });
  test("computedPropertyNamesDeclarationEmit6_ES6", async () => {
    await expectPass(
      `var v = {
  [-1]: {},
  [+1]: {},
  [~1]: {},
  [!1]: {}
}`,
      [],
    );
  });
  test("computedPropertyNamesOnOverloads_ES5", async () => {
    await expectPass(
      `var methodName = "method";
var accessorName = "accessor";
class C {
    [methodName](v: string);
    [methodName]();
    [methodName](v?: string) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesOnOverloads_ES6", async () => {
    await expectPass(
      `var methodName = "method";
var accessorName = "accessor";
class C {
    [methodName](v: string);
    [methodName]();
    [methodName](v?: string) { }
}`,
      [],
    );
  });
  test("computedPropertyNamesSourceMap1_ES5", async () => {
    await expectPass(
      `class C {
    ["hello"]() {
        debugger;
    }
    get ["goodbye"]() {
		return 0;
    }
}`,
      [],
    );
  });
  test("computedPropertyNamesSourceMap1_ES6", async () => {
    await expectPass(
      `class C {
    ["hello"]() {
        debugger;
	}
	get ["goodbye"]() {
		return 0;
	}
}`,
      [],
    );
  });
  test("computedPropertyNamesSourceMap2_ES5", async () => {
    await expectPass(
      `var v = {
    ["hello"]() {
        debugger;
	},
    get ["goodbye"]() {
		return 0;
	}
}`,
      [],
    );
  });
  test("computedPropertyNamesSourceMap2_ES6", async () => {
    await expectPass(
      `var v = {
    ["hello"]() {
        debugger;
	},
	get ["goodbye"]() {
		return 0;
	}
}`,
      [],
    );
  });
  test("computedPropertyNamesWithStaticProperty", async () => {
    await expectPass(
      `class C1 {
    static staticProp = 10;
    get [C1.staticProp]() {
        return "hello";
    }
    set [C1.staticProp](x: string) {
        var y = x;
    }
    [C1.staticProp]() { }
}

(class C2 {
    static staticProp = 10;
    get [C2.staticProp]() {
        return "hello";
    }
    set [C2.staticProp](x: string) {
        var y = x;
    }
    [C2.staticProp]() { }
})
`,
      [],
    );
  });
});
