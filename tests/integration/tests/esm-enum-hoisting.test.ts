import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun, createFixture, runZts } from "./helpers";
import { join } from "node:path";
import { readFileSync } from "node:fs";

describe("ESM enum hoisting in scope hoisting (__esm wrap)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("TS enum is declared at top level, not inside __esm factory", async () => {
    const fixture = await createFixture({
      "index.ts": `
        import { Color } from "./colors";
        console.log(Color.Red);
      `,
      "colors.ts": `
        export enum Color { Red = 1, Green = 2, Blue = 3 }
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
    ]);
    expect(bundle.exitCode).toBe(0);

    const code = readFileSync(outFile, "utf-8");

    // enum var should be at top level (outside __esm factory)
    expect(code).toMatch(/^var\s+Color[,;]/m);

    // Inside factory: assignment only (no "var" keyword before enum IIFE)
    // Find enum IIFE line: "Color = /* @__PURE__ */ ((Color) => ..."
    const iifeLines = code
      .split("\n")
      .filter((l) => l.includes("@__PURE__") && l.includes("Color"));
    expect(iifeLines.length).toBeGreaterThan(0);
    // The IIFE line should NOT start with "var"
    for (const line of iifeLines) {
      expect(line.trim().startsWith("var ")).toBe(false);
    }
  });

  test("enum value is accessible from other modules' hoisted functions", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { getRuntimeKind, RuntimeKind } from "./runtime";
        import { check } from "./checker";
        console.log(getRuntimeKind() + "," + check() + "," + RuntimeKind.UI);
      `,
        "runtime.ts": `
        export enum RuntimeKind { ReactNative = 1, UI = 2, Worker = 3 }
        export function getRuntimeKind() { return RuntimeKind.ReactNative; }
      `,
        "checker.ts": `
        import { RuntimeKind } from "./runtime";
        export function check() { return RuntimeKind.Worker; }
      `,
      },
      "index.ts",
      ["--dev"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("1,3,2");
  });

  test("exported enum used at module top level works correctly", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { MODE, getMode } from "./config";
        console.log(MODE + "," + getMode());
      `,
        "config.ts": `
        export enum AppMode { Dev = "dev", Prod = "prod", Test = "test" }
        export const MODE = AppMode.Dev;
        export function getMode() { return AppMode.Prod; }
      `,
      },
      "index.ts",
      ["--dev"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("dev,prod");
  });

  test("enum with same-name member (self-reference) works after hoisting", async () => {
    // Edge case: enum member name matches enum name → codegen uses _Name param
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { Status } from "./status";
        console.log(Status.Status + "," + Status.Active);
      `,
        "status.ts": `
        export enum Status { Status = "status", Active = "active", Inactive = "inactive" }
      `,
      },
      "index.ts",
      ["--dev"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("status,active");
  });

  test("multiple enums from different modules don't collide", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
        import { Color } from "./colors";
        import { Size } from "./sizes";
        import { getColor, getSize } from "./utils";
        console.log(getColor() + "," + getSize() + "," + Color.Blue + "," + Size.Large);
      `,
        "colors.ts": `export enum Color { Red = 1, Green = 2, Blue = 3 }`,
        "sizes.ts": `export enum Size { Small = 10, Medium = 20, Large = 30 }`,
        "utils.ts": `
        import { Color } from "./colors";
        import { Size } from "./sizes";
        export function getColor() { return Color.Red; }
        export function getSize() { return Size.Medium; }
      `,
      },
      "index.ts",
      ["--dev"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("1,20,3,30");
  });
});
