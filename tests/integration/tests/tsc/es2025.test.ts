import { describe, test } from "bun:test";
import { expectPass } from "./helpers";

describe("TSC: es2025", () => {
  test("float16Array", async () => {
    await expectPass(
      `
const float16 = new Float16Array(4);`,
      [],
    );
  });
  test("intlDurationFormat", async () => {
    await expectPass(
      `
new Intl.DurationFormat('en').format({
  years: 1,
  hours: 20,
  minutes: 15,
  seconds: 35
});`,
      [],
    );
  });
  test("regExpEscape", async () => {
    await expectPass(
      `
const regExp = new RegExp(RegExp.escape("foo.bar"));
regExp.test("foo.bar");`,
      [],
    );
  });
  test("syncIteratorHelpers", async () => {
    await expectPass(
      `
[1, 2, 3, 4].values()
    .filter((x) => x % 2 === 0)
    .map((x) => x * 10)
    .toArray();`,
      [],
    );
  });
});
