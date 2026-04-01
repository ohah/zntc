import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/classExpressions", () => {
  test("classExpressionES61", async () => {
    await expectPass(`var v = class C {};`, []);
  });
  test("classExpressionES62", async () => {
    await expectPass(
      `class D { }
var v = class C extends D {};`,
      [],
    );
  });
  test("classExpressionES63", async () => {
    await expectPass(
      `let C = class extends class extends class { a = 1 } { b = 2 } { c = 3 };
let c = new C();
c.a;
c.b;
c.c;
`,
      [],
    );
  });
  test("typeArgumentInferenceWithClassExpression1", async () => {
    await expectPass(
      `function foo<T>(x = class { static prop: T }): T {
    return undefined;
}

foo(class { static prop = "hello" }).length;`,
      [],
    );
  });
  test("typeArgumentInferenceWithClassExpression2", async () => {
    await expectPass(
      `function foo<T>(x = class { prop: T }): T {
    return undefined;
}

// Should not infer string because it is a static property
foo(class { static prop = "hello" }).length;`,
      [],
    );
  });
  test("typeArgumentInferenceWithClassExpression3", async () => {
    await expectPass(
      `function foo<T>(x = class { prop: T }): T {
    return undefined;
}

foo(class { prop = "hello" }).length;`,
      [],
    );
  });
});
