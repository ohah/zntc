import { describe, test, expect, afterEach } from "bun:test";
import { runZts, createFixture } from "./helpers";
import { readFileSync } from "node:fs";
import { join } from "node:path";

describe("배치 E: CLI 옵션", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("--packages=external: bare import가 external 처리됨", async () => {
    const fixture = await createFixture({
      "index.ts": `import React from "react";\nimport { useState } from "react";\nconst x = 1;\nconsole.log(x);`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");

    const result = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--packages=external",
      "--format=esm",
    ]);

    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, "utf-8");
    // external이므로 react가 require/import로 보존되어야 함
    expect(output).toContain('"react"');
    expect(output).toContain("const x = 1");
  });

  test("--packages=external: 상대 경로는 번들에 포함됨", async () => {
    const fixture = await createFixture({
      "index.ts": `import { foo } from "./lib";\nconsole.log(foo);`,
      "lib.ts": `export const foo = 42;`,
    });
    cleanup = fixture.cleanup;
    const outFile = join(fixture.dir, "out.js");

    const result = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--packages=external",
      "--format=esm",
    ]);

    expect(result.exitCode).toBe(0);
    const output = readFileSync(outFile, "utf-8");
    // 상대 경로는 번들에 포함
    expect(output).toContain("42");
    // import './lib' 문은 scope hoisting으로 제거됨
    expect(output).not.toContain('from "./lib"');
  });

  test("--allow-overwrite: 알 수 없는 옵션으로 에러 안 남", async () => {
    const result = await runZts(["--allow-overwrite", "--help"]);
    // --allow-overwrite가 파싱되고 --help가 실행됨
    expect(result.exitCode).toBe(0);
  });

  test("--log-limit: 숫자가 아니면 에러 메시지 출력", async () => {
    const result = await runZts(["--log-limit=abc", "dummy.ts"]);
    expect(result.stderr).toContain("--log-limit requires a number");
  });

  test("--line-limit: 숫자가 아니면 에러 메시지 출력", async () => {
    const result = await runZts(["--line-limit=xyz", "dummy.ts"]);
    expect(result.stderr).toContain("--line-limit requires a number");
  });

  test("--jsx-side-effects: 파싱됨", async () => {
    const result = await runZts(["--jsx-side-effects", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--ignore-annotations: 파싱됨", async () => {
    const result = await runZts(["--ignore-annotations", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--drop-labels: 라벨 파싱됨", async () => {
    const result = await runZts(["--drop-labels=DEV,TEST", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--pure: 파싱됨", async () => {
    const result = await runZts(["--pure:console.log", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--tsconfig-raw: 파싱됨", async () => {
    const result = await runZts(["--tsconfig-raw={}", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--node-paths: 파싱됨", async () => {
    const result = await runZts(["--node-paths=/usr/lib/node", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--watch-delay: 파싱됨", async () => {
    const result = await runZts(["--watch-delay=200", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--watch-delay: 숫자가 아니면 에러 메시지 출력", async () => {
    const result = await runZts(["--watch-delay=slow", "dummy.ts"]);
    expect(result.stderr).toContain("--watch-delay requires a number");
  });

  test("--clean: 파싱됨", async () => {
    const result = await runZts(["--clean", "--help"]);
    expect(result.exitCode).toBe(0);
  });

  test("--outbase: 파싱됨", async () => {
    const result = await runZts(["--outbase=src", "--help"]);
    expect(result.exitCode).toBe(0);
  });
});
