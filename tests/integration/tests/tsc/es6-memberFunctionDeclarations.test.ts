import { describe, test } from "bun:test";
import { expectPass, expectError } from "./helpers";

describe("TSC: es6/memberFunctionDeclarations", () => {
  test("MemberFunctionDeclaration1_es6", async () => {
    await expectPass(
      `class C {
   *foo() { }
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration2_es6", async () => {
    await expectPass(
      `class C {
   public * foo() { }
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration3_es6", async () => {
    await expectPass(
      `class C {
   *[foo]() { }
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration4_es6", async () => {
    await expectError(
      `class C {
   *() { }
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration5_es6", async () => {
    await expectError(
      `class C {
   *
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration6_es6", async () => {
    await expectPass(
      `class C {
   *foo
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration7_es6", async () => {
    await expectPass(
      `class C {
   *foo<T>() { }
}`,
      [],
    );
  });
  test("MemberFunctionDeclaration8_es6", async () => {
    await expectError(
      `class C {
  foo() {
    // Make sure we don't think of *bar as the start of a generator method.
    if (a) ¬ * bar;
    return bar;
  }
}`,
      [],
    );
  });
});
