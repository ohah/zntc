import { describe, test, expect, afterEach, beforeAll, afterAll } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createFixture, runZts } from "./helpers";
import { init, close } from "../../../packages/core/index";

// PR 4: --stop-after=<phase> — 파이프라인 조기 종료. debug/profile 용.
// 지정한 phase 이후 단계를 skip 하고 빈 output 반환.
// 실측 격리 (특정 phase 비용만 측정) 에 유용 — `--profile` 과 조합.

describe("--stop-after", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  async function runAndGetOutput(stopAfter: string, extraArgs: string[] = []) {
    const fixture = await createFixture({
      "index.ts": `
        export const x: number = 1;
        export function foo(a: string): number {
          return x + a.length;
        }
        export class K { constructor(public name: string) {} }
      `,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      `--stop-after=${stopAfter}`,
      "-o",
      outFile,
      ...extraArgs,
    ]);

    const output = result.exitCode === 0 ? readFileSync(outFile, "utf-8") : "";
    return { result, output };
  }

  test("--stop-after=scan 은 성공 종료 + 빈 output", async () => {
    const { result, output } = await runAndGetOutput("scan");
    expect(result.exitCode).toBe(0);
    expect(output).toBe("");
  });

  test("--stop-after=parse 은 성공 종료 + 빈 output", async () => {
    const { result, output } = await runAndGetOutput("parse");
    expect(result.exitCode).toBe(0);
    expect(output).toBe("");
  });

  test("--stop-after=semantic 은 성공 종료 + 빈 output", async () => {
    const { result, output } = await runAndGetOutput("semantic");
    expect(result.exitCode).toBe(0);
    expect(output).toBe("");
  });

  test("--stop-after=transform 은 성공 종료 + 빈 output", async () => {
    const { result, output } = await runAndGetOutput("transform");
    expect(result.exitCode).toBe(0);
    expect(output).toBe("");
  });

  test("--stop-after=codegen 은 정상 transpile (full 파이프라인 실행)", async () => {
    const { result, output } = await runAndGetOutput("codegen");
    expect(result.exitCode).toBe(0);
    // codegen 까지 실행 → 실제 JS 출력됨
    expect(output.length).toBeGreaterThan(0);
    expect(output).toContain("x = 1");
  });

  test("--stop-after 없으면 full 파이프라인 (기본 동작)", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x: number = 1;`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");

    const result = await runZts([join(fixture.dir, "index.ts"), "-o", outFile]);
    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, "utf-8");
    expect(output).toContain("x = 1");
  });

  test("잘못된 --stop-after 값은 exit 1", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--stop-after=bogus",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("invalid --stop-after");
  });

  test("--stop-after=parse --profile=parse 조합: 격리 측정", async () => {
    const fixture = await createFixture({
      "index.ts": `export const x: number = 1;`,
    });
    cleanup = fixture.cleanup;

    const result = await runZts([
      join(fixture.dir, "index.ts"),
      "--stop-after=parse",
      "--profile=parse",
      "--profile-format=json",
      "-o",
      join(fixture.dir, "out.js"),
    ]);

    expect(result.exitCode).toBe(0);
    const json = JSON.parse(result.stderr.slice(result.stderr.indexOf("{")));
    // parse phase 는 기록되었고
    expect(json.phases.parse).toBeDefined();
    expect(json.phases.parse.total_ms).toBeGreaterThan(0);
    // 이후 phase 는 없어야 (transform/codegen 등은 기록 없음)
    expect(json.phases.transform).toBeUndefined();
    expect(json.phases.codegen).toBeUndefined();
  });

  test("--help 에 --stop-after 섹션 포함", async () => {
    const result = await runZts(["--help"]);
    expect(result.stdout).toContain("--stop-after=");
    expect(result.stdout).toContain("scan | parse | semantic | transform | codegen");
  });
});

describe("NAPI stopAfter option", () => {
  beforeAll(() => init());
  afterAll(() => close());

  test("transpile({ stopAfter: 'parse' }) 성공 + 빈 code", async () => {
    const { transpile } = await import("../../../packages/core/index");
    const result = transpile("export const x: number = 1;", {
      filename: "input.ts",
      stopAfter: "parse",
    });
    expect(result.code).toBe("");
  });

  test("transpile({ stopAfter: 'codegen' }) 는 full 파이프라인 (기본 동작)", async () => {
    const { transpile } = await import("../../../packages/core/index");
    const result = transpile("export const x: number = 1;", {
      filename: "input.ts",
      stopAfter: "codegen",
    });
    expect(result.code).toContain("x = 1");
  });

  test("transpile({}) 은 stopAfter 기본 null → full 파이프라인", async () => {
    const { transpile } = await import("../../../packages/core/index");
    const result = transpile("export const x: number = 1;", { filename: "input.ts" });
    expect(result.code).toContain("x = 1");
  });
});
