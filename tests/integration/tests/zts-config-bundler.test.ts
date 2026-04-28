/**
 * #2105 — Zig CLI (`zts-bin`) 의 `applyZtsConfigJson` 이 bundler-only 옵션을
 * `zts.config.json` 에서 읽어들여 BundleOptions 까지 forward 하는지 검증한다.
 *
 * JS CLI (`zts.mjs`) 의 동일 동작은 `packages/core/bin/zts.test.ts` 가 검증.
 */

import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { createFixture, runZtsInDir } from "./helpers";

describe("Zig CLI: zts.config.json bundler-only 옵션 (#2105)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("external: bare specifier 가 require/import 로 보존됨", async () => {
    const fixture = await createFixture({
      "index.ts": `import * as fs from "node:fs";\nconsole.log(fs);`,
      "zts.config.json": JSON.stringify({ external: ["node:fs"] }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--format=esm",
    ]);
    expect(result.exitCode).toBe(0);
    const out = readFileSync(outFile, "utf8");
    // external 이면 import 가 보존됨 (인라인 안 됨).
    expect(out).toMatch(/from\s+["']node:fs["']/);
  });

  test("alias: from→to 매핑이 적용됨", async () => {
    const fixture = await createFixture({
      "src/real.ts": `export const tag = "ALIAS_OK";`,
      "index.ts": `import { tag } from "@target";\nconsole.log(tag);`,
      "zts.config.json": "", // 동적 생성 (절대 경로 필요)
    });
    cleanup = fixture.cleanup;
    writeFileSync(
      join(fixture.dir, "zts.config.json"),
      JSON.stringify({ alias: [{ from: "@target", to: join(fixture.dir, "src/real.ts") }] }),
    );

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    expect(readFileSync(outFile, "utf8")).toContain("ALIAS_OK");
  });

  test("define: 키-값 쌍 → 정적 치환", async () => {
    const fixture = await createFixture({
      "index.ts": `console.log(__VER__);`,
      "zts.config.json": JSON.stringify({
        define: [{ key: "__VER__", value: '"v1.0.0"' }],
      }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    const out = readFileSync(outFile, "utf8");
    expect(out).toContain('"v1.0.0"');
    expect(out).not.toContain("__VER__");
  });

  test("banner / footer 가 출력에 포함됨", async () => {
    const fixture = await createFixture({
      "index.ts": "console.log('mid');",
      "zts.config.json": JSON.stringify({
        banner: "/* banner-line */",
        footer: "/* footer-line */",
      }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    const out = readFileSync(outFile, "utf8");
    expect(out.indexOf("banner-line")).toBeGreaterThanOrEqual(0);
    expect(out.indexOf("footer-line")).toBeGreaterThanOrEqual(0);
    expect(out.indexOf("banner-line")).toBeLessThan(out.indexOf("mid"));
    expect(out.indexOf("footer-line")).toBeGreaterThan(out.indexOf("mid"));
  });

  test("conditions: package.json exports 분기에 사용", async () => {
    const fixture = await createFixture({
      "node_modules/lib/package.json": JSON.stringify({
        name: "lib",
        exports: {
          ".": {
            "test-cond": "./test.js",
            default: "./default.js",
          },
        },
      }),
      "node_modules/lib/test.js": `export const tag = "CONDITION_OK";`,
      "node_modules/lib/default.js": `export const tag = "DEFAULT_FALLBACK";`,
      "index.ts": `import { tag } from "lib";\nconsole.log(tag);`,
      "zts.config.json": JSON.stringify({ conditions: ["test-cond"] }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    const out = readFileSync(outFile, "utf8");
    expect(out).toContain("CONDITION_OK");
    expect(out).not.toContain("DEFAULT_FALLBACK");
  });

  test("resolveExtensions: 명시 확장자 우선순위로 resolve", async () => {
    const fixture = await createFixture({
      "src/util.web.ts": `export const tag = "WEB_VARIANT";`,
      "src/util.ts": `export const tag = "DEFAULT_VARIANT";`,
      "index.ts": `import { tag } from "./src/util";\nconsole.log(tag);`,
      "zts.config.json": JSON.stringify({
        resolveExtensions: [".web.ts", ".ts"],
      }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    expect(readFileSync(outFile, "utf8")).toContain("WEB_VARIANT");
  });

  test("loader: 확장자별 로더 매핑 — file 로더는 URL 문자열 export", async () => {
    const fixture = await createFixture({
      "logo.png": "fake-png-content",
      "index.ts": `import url from "./logo.png";\nconsole.log(url);`,
      "zts.config.json": JSON.stringify({
        loader: [{ ext: ".png", loader: "file" }],
      }),
    });
    cleanup = fixture.cleanup;

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--outdir",
      join(fixture.dir, "dist"),
    ]);
    expect(result.exitCode).toBe(0);
    // file 로더가 활성화되면 빌드 성공 (이전엔 unknown loader 로 실패).
    // 출력 디렉토리에 hash 가 붙은 파일이 emit 됨.
  });

  test("preserveModules: bundler 가 모듈 1개 → 출력 1개로 emit", async () => {
    const fixture = await createFixture({
      "src/a.ts": `export const a = 1;`,
      "src/b.ts": `import { a } from "./a";\nexport const b = a + 1;`,
      "index.ts": `export { b } from "./src/b";`,
      "zts.config.json": JSON.stringify({ preserveModules: true }),
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "--outdir",
      outDir,
      "--format=esm",
    ]);
    expect(result.exitCode).toBe(0);
    // preserveModules 시 a.js, b.js, index.js 등 분리 emit.
    const { readdirSync } = require("node:fs");
    const files = readdirSync(outDir);
    expect(files.length).toBeGreaterThan(1);
  });

  test("CLI flag 가 config 를 override (CLI > config 우선순위)", async () => {
    const fixture = await createFixture({
      "index.ts": "console.log('hi');",
      "zts.config.json": JSON.stringify({
        banner: "/* FROM_CONFIG */",
      }),
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--banner:js=/* FROM_CLI */",
    ]);
    expect(result.exitCode).toBe(0);
    const out = readFileSync(outFile, "utf8");
    expect(out).toContain("FROM_CLI");
    expect(out).not.toContain("FROM_CONFIG");
  });

  test("config 부재: 기존 동작 회귀 없음", async () => {
    const fixture = await createFixture({
      "index.ts": "console.log('NO_CONFIG');",
      // zts.config.json 없음
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
    ]);
    expect(result.exitCode).toBe(0);
    expect(readFileSync(outFile, "utf8")).toContain("NO_CONFIG");
  });
});
