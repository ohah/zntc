import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/arrowFunction", () => {
  test("disallowLineTerminatorBeforeArrow", async () => {
    await expectError(
      `var f1 = ()
    => { }
var f2 = (x: string, y: string) /*
  */  => { }
var f3 = (x: string, y: number, ...rest)
    => { }
var f4 = (x: string, y: number, ...rest) /*
  */  => { }
var f5 = (...rest)
    => { }
var f6 = (...rest) /*
  */  => { }
var f7 = (x: string, y: number, z = 10)
    => { }
var f8 = (x: string, y: number, z = 10) /*
  */  => { }
var f9 = (a: number): number
    => a;
var f10 = (a: number) :
  number
    => a
var f11 = (a: number): number /*
    */ => a;
var f12 = (a: number) :
  number /*
    */ => a

// Should be valid.
var f11 = (a: number
    ) => a;

// Should be valid.
var f12 = (a: number)
    : number => a;

// Should be valid.
var f13 = (a: number):
    number => a;

// Should be valid.
var f14 = () /* */ => {}

// Should be valid.
var f15 = (a: number): number /* */ => a

// Should be valid.
var f16 = (a: number, b = 10):
  number /* */ => a + b;

function foo(func: () => boolean) { }
foo(()
    => true);
foo(()
    => { return false; });

namespace m {
    class City {
        constructor(x: number, thing = ()
            => 100) {
        }

        public m = ()
            => 2 * 2 * 2
    }

    export enum Enum {
        claw = (()
            => 10)()
    }

    export var v = x
        => new City(Enum.claw);
}
`,
      [],
    );
  });
  test("emitArrowFunction", async () => {
    await expectPass(
      `// @strict: false
var f1 = () => { }
var f2 = (x: string, y: string) => { }
var f3 = (x: string, y: number, ...rest) => { }
var f4 = (x: string, y: number, z = 10) => { }
function foo(func: () => boolean) { }
foo(() => true);
foo(() => { return false; });`,
      [],
    );
  });
  test("emitArrowFunctionAsIs", async () => {
    await expectPass(
      `// @strict: false
var arrow1 = a => { };
var arrow2 = (a) => { };

var arrow3 = (a, b) => { };`,
      [],
    );
  });
  test("emitArrowFunctionAsIsES6", async () => {
    await expectPass(
      `// @strict: false
var arrow1 =  a => { };
var arrow2 = (a) => { };

var arrow3 = (a, b) => { };`,
      [],
    );
  });
  test("emitArrowFunctionES6", async () => {
    await expectPass(
      `// @strict: false
var f1 = () => { }
var f2 = (x: string, y: string) => { }
var f3 = (x: string, y: number, ...rest) => { }
var f4 = (x: string, y: number, z=10) => { }
function foo(func: () => boolean) { }
foo(() => true);
foo(() => { return false; });

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
`,
      [],
    );
  });
  test("emitArrowFunctionsAsIs", async () => {
    await expectPass(
      `// @strict: false
var arrow1 = a => { };
var arrow2 = (a) => { };

var arrow3 = (a, b) => { };`,
      [],
    );
  });
  test("emitArrowFunctionsAsIsES6", async () => {
    await expectPass(
      `// @strict: false
var arrow1 =  a => { };
var arrow2 = (a) => { };

var arrow3 = (a, b) => { };`,
      [],
    );
  });
  test("emitArrowFunctionThisCapturing", async () => {
    await expectPass(
      `// @strict: false
var f1 = () => {
    this.age = 10
};

var f2 = (x: string) => {
    this.name = x
}

function foo(func: () => boolean) { }
foo(() => {
    this.age = 100;
    return true;
});
`,
      [],
    );
  });
  test("emitArrowFunctionThisCapturingES6", async () => {
    await expectPass(
      `// @strict: false
var f1 = () => {
    this.age = 10
};

var f2 = (x: string) => {
    this.name = x
}

function foo(func: () => boolean){ }
foo(() => {
    this.age = 100;
    return true;
});
`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments01_ES6", async () => {
    await expectPass(
      `// @strict: false
var a = () => {
    var arg = arguments[0];  // error
}

var b = function () {
    var a = () => {
        var arg = arguments[0];  // error
    }
}

function baz() {
	() => {
		var arg = arguments[0];
	}
}

function foo(inputFunc: () => void) { }
foo(() => {
    var arg = arguments[0];  // error
});

function bar() {
    var arg = arguments[0];  // no error
}


() => {
	function foo() {
		var arg = arguments[0];  // no error
	}
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments01", async () => {
    await expectPass(
      `// @strict: false
var a = () => {
    var arg = arguments[0];  // error
}

var b = function () {
    var a = () => {
        var arg = arguments[0];  // error
    }
}

function baz() {
	() => {
		var arg = arguments[0];
	}
}

function foo(inputFunc: () => void) { }
foo(() => {
    var arg = arguments[0];  // error
});

function bar() {
    var arg = arguments[0];  // no error
}


() => {
	function foo() {
		var arg = arguments[0];  // no error
	}
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments02_ES6", async () => {
    await expectPass(
      `// @strict: false

var a = () => arguments;`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments02", async () => {
    await expectPass(
      `// @strict: false

var a = () => arguments;`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments03_ES6", async () => {
    await expectError(
      `
var arguments;
var a = () => arguments;`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments03", async () => {
    await expectError(
      `
var arguments;
var a = () => arguments;`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments04_ES6", async () => {
    await expectError(
      `
function f() {
    var arguments;
    var a = () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments04", async () => {
    await expectError(
      `
function f() {
    var arguments;
    var a = () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments05_ES6", async () => {
    await expectError(
      `
function f(arguments) {
    var a = () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments05", async () => {
    await expectError(
      `
function f(arguments) {
    var a = () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments06_ES6", async () => {
    await expectError(
      `
function f(arguments) {
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments06", async () => {
    await expectError(
      `
function f(arguments) {
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments07_ES6", async () => {
    await expectError(
      `
function f(arguments) {
    var a = (arguments) => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments07", async () => {
    await expectError(
      `
function f(arguments) {
    var a = (arguments) => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments08_ES6", async () => {
    await expectError(
      `
function f(arguments) {
    var a = () => (arguments) => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments08", async () => {
    await expectError(
      `
function f(arguments) {
    var a = () => (arguments) => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments09_ES6", async () => {
    await expectPass(
      `// @strict: false

function f(_arguments) {
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments09", async () => {
    await expectPass(
      `// @strict: false

function f(_arguments) {
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments10_ES6", async () => {
    await expectPass(
      `// @strict: false

function f() {
    var _arguments = 10;
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments10", async () => {
    await expectPass(
      `// @strict: false

function f() {
    var _arguments = 10;
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments11_ES6", async () => {
    await expectError(
      `
function f(arguments) {
    var _arguments = 10;
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments11", async () => {
    await expectError(
      `
function f(arguments) {
    var _arguments = 10;
    var a = () => () => arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments12_ES6", async () => {
    await expectError(
      `// @strict: false

class C {
    f(arguments) {
        var a = () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments12", async () => {
    await expectError(
      `// @strict: false

class C {
    f(arguments) {
        var a = () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments13_ES6", async () => {
    await expectError(
      `
function f() {
    var _arguments = 10;
    var a = (arguments) => () => _arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments13", async () => {
    await expectError(
      `
function f() {
    var _arguments = 10;
    var a = (arguments) => () => _arguments;
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments14_ES6", async () => {
    await expectError(
      `
function f() {
    if (Math.random()) {
        let arguments = 100;
        return () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments14", async () => {
    await expectError(
      `
function f() {
    if (Math.random()) {
        const arguments = 100;
        return () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments15_ES6", async () => {
    await expectError(
      `
function f() {
    var arguments = "hello";
    if (Math.random()) {
        const arguments = 100;
        return () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments15", async () => {
    await expectError(
      `
function f() {
    var arguments = "hello";
    if (Math.random()) {
        const arguments = 100;
        return () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments16_ES6", async () => {
    await expectError(
      `
function f() {
    var arguments = "hello";
    if (Math.random()) {
        return () => arguments[0];
    }
    var arguments = "world";
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments16", async () => {
    await expectError(
      `
function f() {
    var arguments = "hello";
    if (Math.random()) {
        return () => arguments[0];
    }
    var arguments = "world";
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments17_ES6", async () => {
    await expectError(
      `
function f() {
    var { arguments } = { arguments: "hello" };
    if (Math.random()) {
        return () => arguments[0];
    }
    var arguments = "world";
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments17", async () => {
    await expectError(
      `
function f() {
    var { arguments } = { arguments: "hello" };
    if (Math.random()) {
        return () => arguments[0];
    }
    var arguments = "world";
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments18_ES6", async () => {
    await expectPass(
      `// @strict: false

function f() {
    var { arguments: args } = { arguments };
    if (Math.random()) {
        return () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments18", async () => {
    await expectPass(
      `// @strict: false

function f() {
    var { arguments: args } = { arguments };
    if (Math.random()) {
        return () => arguments;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments19_ES6", async () => {
    await expectPass(
      `// @strict: false

function f() {
    function g() {
        var _arguments = 10;                // No capture in 'g', so no conflict.
        function h() {
            var capture = () => arguments;  // Should trigger an '_arguments' capture into function 'h'
            foo(_arguments);                // Error as this does not resolve to the user defined '_arguments'
        }
    }

    function foo(x: any) {
        return 100;
    }
}`,
      [],
    );
  });
  test("emitArrowFunctionWhenUsingArguments19", async () => {
    await expectPass(
      `// @strict: false

function f() {
    function g() {
        var _arguments = 10;                // No capture in 'g', so no conflict.
        function h() {
            var capture = () => arguments;  // Should trigger an '_arguments' capture into function 'h'
            foo(_arguments);                // Error as this does not resolve to the user defined '_arguments'
        }
    }

    function foo(x: any) {
        return 100;
    }
}`,
      [],
    );
  });
});
