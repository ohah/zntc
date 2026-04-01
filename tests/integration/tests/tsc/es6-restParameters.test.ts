import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/restParameters", () => {
  test("emitRestParametersFunction", async () => {
    await expectPass(
      `// @strict: false
function bar(...rest) { }
function foo(x: number, y: string, ...rest) { }`,
      [],
    );
  });
  test("emitRestParametersFunctionES6", async () => {
    await expectPass(
      `// @strict: false
function bar(...rest) { }
function foo(x: number, y: string, ...rest) { }`,
      [],
    );
  });
  test("emitRestParametersFunctionExpression", async () => {
    await expectPass(
      `// @strict: false
var funcExp = (...rest) => { }
var funcExp1 = (X: number, ...rest) => { }
var funcExp2 = function (...rest) { }
var funcExp3 = (function (...rest) { })()
`,
      [],
    );
  });
  test("emitRestParametersFunctionExpressionES6", async () => {
    await expectPass(
      `// @strict: false
var funcExp = (...rest) => { }
var funcExp1 = (X: number, ...rest) => { }
var funcExp2 = function (...rest) { }
var funcExp3 = (function (...rest) { })()`,
      [],
    );
  });
  test("emitRestParametersFunctionProperty", async () => {
    await expectPass(
      `// @strict: false
var obj: {
    func1: (...rest) => void
}

var obj2 = {
    func(...rest) { }
}`,
      [],
    );
  });
  test("emitRestParametersFunctionPropertyES6", async () => {
    await expectPass(
      `// @strict: false
var obj: {
    func1: (...rest) => void
}

var obj2 = {
    func(...rest) { }
}`,
      [],
    );
  });
  test("emitRestParametersMethod", async () => {
    await expectPass(
      `// @strict: false
class C {
    constructor(name: string, ...rest) { }

    public bar(...rest) { }
    public foo(x: number, ...rest) { }
}

class D {
    constructor(...rest) { }

    public bar(...rest) { }
    public foo(x: number, ...rest) { }
}`,
      [],
    );
  });
  test("emitRestParametersMethodES6", async () => {
    await expectPass(
      `// @strict: false
class C {
    constructor(name: string, ...rest) { }

    public bar(...rest) { }
    public foo(x: number, ...rest) { }
}

class D {
    constructor(...rest) { }

    public bar(...rest) { }
    public foo(x: number, ...rest) { }
}
`,
      [],
    );
  });
  test("readonlyRestParameters", async () => {
    await expectPass(
      `
function f0(a: string, b: string) {
    f0(a, b);
    f1(a, b);
    f2(a, b);
}

function f1(...args: readonly string[]) {
    f0(...args);  // Error
    f1('abc', 'def');
    f1('abc', ...args);
    f1(...args);
}

function f2(...args: readonly [string, string]) {
    f0(...args);
    f1('abc', 'def');
    f1('abc', ...args);
    f1(...args);
    f2('abc', 'def');
    f2('abc', ...args);  // Error
    f2(...args);
}

function f4(...args: readonly string[]) {
    args[0] = 'abc';  // Error
}
`,
      [],
    );
  });
});
