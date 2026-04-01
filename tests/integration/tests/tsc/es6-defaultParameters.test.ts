import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/defaultParameters", () => {
  test("emitDefaultParametersFunction", async () => {
    await expectPass(
      `// @strict: false
function foo(x: string, y = 10) { }
function baz(x: string, y = 5, ...rest) { }
function bar(y = 10) { }
function bar1(y = 10, ...rest) { }`,
      [],
    );
  });
  test("emitDefaultParametersFunctionES6", async () => {
    await expectPass(
      `// @strict: false
function foo(x: string, y = 10) { }
function baz(x: string, y = 5, ...rest) { }
function bar(y = 10) { }
function bar1(y = 10, ...rest) { }`,
      [],
    );
  });
  test("emitDefaultParametersFunctionExpression", async () => {
    await expectPass(
      `// @strict: false
var lambda1 = (y = "hello") => { }
var lambda2 = (x: number, y = "hello") => { }
var lambda3 = (x: number, y = "hello", ...rest) => { }
var lambda4 = (y = "hello", ...rest) => { }

var x = function (str = "hello", ...rest) { }
var y = (function (num = 10, boo = false, ...rest) { })()
var z = (function (num: number, boo = false, ...rest) { })(10)
`,
      [],
    );
  });
  test("emitDefaultParametersFunctionExpressionES6", async () => {
    await expectPass(
      `// @strict: false
var lambda1 = (y = "hello") => { }
var lambda2 = (x: number, y = "hello") => { }
var lambda3 = (x: number, y = "hello", ...rest) => { }
var lambda4 = (y = "hello", ...rest) => { }

var x = function (str = "hello", ...rest) { }
var y = (function (num = 10, boo = false, ...rest) { })()
var z = (function (num: number, boo = false, ...rest) { })(10)`,
      [],
    );
  });
  test("emitDefaultParametersFunctionProperty", async () => {
    await expectPass(
      `// @strict: false
var obj2 = {
    func1(y = 10, ...rest) { },
    func2(x = "hello") { },
    func3(x: string, z: number, y = "hello") { },
    func4(x: string, z: number, y = "hello", ...rest) { },
}
`,
      [],
    );
  });
  test("emitDefaultParametersFunctionPropertyES6", async () => {
    await expectPass(
      `// @strict: false
var obj2 = {
    func1(y = 10, ...rest) { },
    func2(x = "hello") { },
    func3(x: string, z: number, y = "hello") { },
    func4(x: string, z: number, y = "hello", ...rest) { },
}`,
      [],
    );
  });
  test("emitDefaultParametersMethod", async () => {
    await expectPass(
      `// @strict: false
class C {
    constructor(t: boolean, z: string, x: number, y = "hello") { }

    public foo(x: string, t = false) { }
    public foo1(x: string, t = false, ...rest) { }
    public bar(t = false) { }
    public boo(t = false, ...rest) { }
}

class D {
    constructor(y = "hello") { }
}

class E {
    constructor(y = "hello", ...rest) { }
}
`,
      [],
    );
  });
  test("emitDefaultParametersMethodES6", async () => {
    await expectPass(
      `// @strict: false
class C {
    constructor(t: boolean, z: string, x: number, y = "hello") { }

    public foo(x: string, t = false) { }
    public foo1(x: string, t = false, ...rest) { }
    public bar(t = false) { }
    public boo(t = false, ...rest) { }
}

class D {
    constructor(y = "hello") { }
}

class E {
    constructor(y = "hello", ...rest) { }
}`,
      [],
    );
  });
});
