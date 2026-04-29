/// #2209 회귀 가드:
/// `--bundle` default (single-file output) 모드에서 dynamic import 자동 lazy-wrap.
/// `--splitting`, `--preserve-modules`, `--no-inline-dynamic-imports` 명시 시 자동 승격
/// 막히도록 분리 정책 우선.

import { describe, test, expect, afterEach } from "bun:test";
import { spawn } from "bun";
import { join } from "node:path";
import { writeFileSync, readFileSync } from "node:fs";
import { bundleAndRun, createFixture, runZts, ZTS_BIN } from "./helpers";

describe("#2209: dynamic import default lazy-wrap", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("default single-file 모드: dynamic import 가 lazy wrap 으로 자동 변환", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          async function run() {
            const m = await import("./dyn.ts");
            return m.value;
          }
          run().then(v => console.log(v));
        `,
        "dyn.ts": `
          export const value = "dynamic-loaded";
          console.log("dyn evaluated");
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runStderr).not.toContain("Cannot find module");
    expect(result.runOutput).toBe("dyn evaluated\ndynamic-loaded");
  });

  test("--splitting 모드: 별도 chunk 로 분리 (자동 승격 안 함)", async () => {
    const fixture = await createFixture({
      "index.ts": `
        async function run() {
          const m = await import("./dyn.ts");
          return m.value;
        }
        run().then(v => console.log(v));
      `,
      "dyn.ts": `
        export const value = "dynamic-loaded";
        console.log("dyn evaluated");
      `,
    });
    cleanup = fixture.cleanup;

    const r = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--splitting",
      "--outdir",
      join(fixture.dir, "out"),
      "--format=esm",
      "--platform=node",
    ]);
    expect(r.exitCode).toBe(0);

    const exec = spawn({
      cmd: ["bun", "run", join(fixture.dir, "out", "index.js")],
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = (await new Response(exec.stdout).text()).trimEnd();
    expect(out).toBe("dyn evaluated\ndynamic-loaded");
  });

  test("--no-inline-dynamic-imports + single-file 은 명확한 에러", async () => {
    const fixture = await createFixture({
      "index.ts": `
        async function run() {
          const m = await import("./dyn.ts");
          return m.value;
        }
        run().then(v => console.log(v));
      `,
      "dyn.ts": `export const value = "x";`,
    });
    cleanup = fixture.cleanup;

    const r = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      join(fixture.dir, "out.js"),
      "--no-inline-dynamic-imports",
    ]);

    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("--no-inline-dynamic-imports");
    expect(r.stderr).toContain("--splitting");
  });

  test("--no-inline-dynamic-imports + --splitting 은 정상 chunk 분리", async () => {
    const fixture = await createFixture({
      "index.ts": `
        async function run() { return (await import("./dyn.ts")).value; }
        run().then(v => console.log(v));
      `,
      "dyn.ts": `export const value = "split-mode";`,
    });
    cleanup = fixture.cleanup;

    const r = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--splitting",
      "--outdir",
      join(fixture.dir, "out"),
      "--format=esm",
      "--platform=node",
      "--no-inline-dynamic-imports",
    ]);
    expect(r.exitCode).toBe(0);

    const exec = spawn({
      cmd: ["bun", "run", join(fixture.dir, "out", "index.js")],
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = (await new Response(exec.stdout).text()).trimEnd();
    expect(out).toBe("split-mode");
  });

  // dynamic import target 의 transitive static dep 중복 평가 / cycle 마킹 확장은
  // 별도 follow-up 이슈로 분리. 본 PR 은 default lazy-wrap + 명시 false 진단 처리에
  // 한정.
});
