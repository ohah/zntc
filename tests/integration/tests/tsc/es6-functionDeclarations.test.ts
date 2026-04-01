import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/functionDeclarations", () => {
  test("FunctionDeclaration1_es6", async () => {
    await expectPass(
      `function * foo() {
}`,
      [],
    );
  });
  test("FunctionDeclaration10_es6", async () => {
    await expectError(
      `function * foo(a = yield => yield) {
}`,
      [],
    );
  });
  test("FunctionDeclaration11_es6", async () => {
    await expectPass(
      `function * yield() {
}`,
      [],
    );
  });
  test("FunctionDeclaration12_es6", async () => {
    await expectError(`var v = function * yield() { }`, []);
  });
  test("FunctionDeclaration13_es6", async () => {
    await expectPass(
      `function * foo() {
   // Legal to use 'yield' in a type context.
   var v: yield;
}
`,
      [],
    );
  });
  test("FunctionDeclaration2_es6", async () => {
    await expectPass(
      `function f(yield) {
}`,
      [],
    );
  });
  test("FunctionDeclaration3_es6", async () => {
    await expectPass(
      `function f(yield = yield) {
}`,
      [],
    );
  });
  test("FunctionDeclaration4_es6", async () => {
    await expectPass(
      `function yield() {
}`,
      [],
    );
  });
  test("FunctionDeclaration5_es6", async () => {
    await expectError(
      `function*foo(yield) {
}`,
      [],
    );
  });
  test("FunctionDeclaration6_es6", async () => {
    await expectError(
      `function*foo(a = yield) {
}`,
      [],
    );
  });
  test("FunctionDeclaration7_es6", async () => {
    await expectError(
      `function*bar() {
  // 'yield' here is an identifier, and not a yield expression.
  function*foo(a = yield) {
  }
}`,
      [],
    );
  });
  test("FunctionDeclaration8_es6", async () => {
    await expectPass(`var v = { [yield]: foo }`, []);
  });
  test("FunctionDeclaration9_es6", async () => {
    await expectPass(
      `function * foo() {
  var v = { [yield]: foo }
}`,
      [],
    );
  });
});
