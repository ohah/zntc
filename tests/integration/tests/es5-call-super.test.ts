import { afterEach, describe, expect, test } from "bun:test";
import { bundleAndRun } from "./helpers";

describe("ES5 __callSuper", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("derived constructor arrow 안의 super()도 lexical NewTarget을 사용한다", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `class Base { x: string; constructor(arg: string) { this.x = arg; } }
class Child extends Base {
  constructor() {
    const callSuper = () => super("foo");
    callSuper();
  }
}
const c = new Child();
console.log(c.x + ":" + (c instanceof Child) + ":" + (c instanceof Base));`,
      },
      "index.ts",
      ["--target=es5"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("foo:true:true");
  });
});
