import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun, createFixture, runZts } from "./helpers";
import { join } from "node:path";
import { readFileSync } from "node:fs";

describe("strict execution order (--dev + scope hoisting)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("function forward reference works inside module", async () => {
    // Pattern: call a function before its declaration (relies on JS hoisting).
    // strict_execution_order converts function decl → assignment at top of factory.
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { value } from "./mod";
        console.log(value);
      `,
        "mod.ts": `
        export const value = getGreeting();
        function getGreeting() { return "hello"; }
      `,
      },
      "index.ts",
      ["--dev", "--platform=react-native"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello");
  });

  test("cross-module function access works with strict order", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { run } from "./a";
        console.log(run());
      `,
        "a.ts": `
        import { helper } from "./b";
        export function run() { return helper() + "!"; }
      `,
        "b.ts": `
        export function helper() { return "ok"; }
      `,
      },
      "index.ts",
      ["--dev", "--platform=react-native"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok!");
  });

  test("functions are placed before other statements in factory body", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { val } from "./mod";
        console.log(val);
      `,
      "mod.ts": `
        export const val = compute();
        function compute() { return 42; }
      `,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const bundle = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--dev",
      "--platform=react-native",
    ]);
    expect(bundle.exitCode).toBe(0);

    const code = readFileSync(outFile, "utf-8");

    // Function should be converted to assignment (not hoisted outside factory)
    // Pattern: "compute = function()" should appear in the code
    expect(code).toContain("compute = function");

    // There should be NO "function compute" as a top-level hoisted declaration
    // (it should be inside the factory as an assignment)
    const lines = code.split("\n");
    const topLevelFuncDecl = lines.filter((l) => /^function compute\b/.test(l.trim()));
    expect(topLevelFuncDecl.length).toBe(0);
  });

  test("multiple modules with forward references all resolve correctly", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { a } from "./mod-a";
        import { b } from "./mod-b";
        import { c } from "./mod-c";
        console.log([a, b, c].join(","));
      `,
        "mod-a.ts": `
        export const a = getA();
        function getA() { return "A"; }
      `,
        "mod-b.ts": `
        export const b = getB();
        function getB() { return "B"; }
      `,
        "mod-c.ts": `
        export const c = getC();
        function getC() { return "C"; }
      `,
      },
      "index.ts",
      ["--dev", "--platform=react-native"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("A,B,C");
  });

  test("mutual function references within a module work", async () => {
    // Functions referencing each other — both need to be hoisted
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { result } from "./mutual";
        console.log(result);
      `,
        "mutual.ts": `
        export const result = isEven(4) + "," + isOdd(3);
        function isEven(n: number): string {
          return n === 0 ? "true" : isOdd(n - 1);
        }
        function isOdd(n: number): string {
          return n === 0 ? "false" : isEven(n - 1);
        }
      `,
      },
      "index.ts",
      ["--dev", "--platform=react-native"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("true,true");
  });

  test("enum + function combination works in strict mode", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { describe } from "./types";
        console.log(describe());
      `,
        "types.ts": `
        export enum Status { Active = "active", Inactive = "inactive" }
        export function describe() { return Status.Active + ":" + Status.Inactive; }
      `,
      },
      "index.ts",
      ["--dev", "--platform=react-native"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("active:inactive");
  });
});
