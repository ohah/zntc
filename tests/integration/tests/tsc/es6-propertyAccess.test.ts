import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es6/propertyAccess", () => {
  test("propertyAccessNumericLiterals.es6", async () => {
    await expectPass(
      `0xffffffff.toString();
0o01234.toString();
0b01101101.toString();
1234..toString();
1e0.toString();
`,
      [],
    );
  });
});
