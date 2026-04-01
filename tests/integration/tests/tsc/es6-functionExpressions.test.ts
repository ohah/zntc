import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/functionExpressions", () => {
  test("FunctionExpression1_es6", async () => {
    await expectPass(`var v = function * () { }`, []);
  });
  test("FunctionExpression2_es6", async () => {
    await expectPass(`var v = function * foo() { }`, []);
  });
});
