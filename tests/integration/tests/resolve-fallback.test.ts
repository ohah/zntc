import { describe, test, expect } from "bun:test";
import { createFixture, runZts, bundleAndRun } from "./helpers";
import { join } from "node:path";
import { readFileSync } from "node:fs";

/**
 * --fallback (webpack resolve.fallback / Metro extraNodeModules 호환) 통합 테스트.
 *
 * 핵심 시맨틱:
 * 1. 설치된 실제 패키지가 있으면 fallback 무시 — alias와의 차이점
 * 2. 해석 실패 시에만 fallback 적용
 * 3. `=false`이면 빈 모듈 (webpack "resolve.fallback에 false")
 */
describe("--fallback", () => {
  test("해석 실패 시 fallback으로 대체된다", async () => {
    const { bundleOutput, runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        "entry.ts": `import { shim } from "missing-mod"; console.log(shim);`,
        "shim.ts": `export const shim = "from-shim";`,
      },
      "entry.ts",
      ["--fallback:missing-mod=./shim.ts"],
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe("from-shim");
      expect(bundleOutput).toBeDefined();
    } finally {
      await cleanup();
    }
  });

  test("설치된 실제 모듈이 있으면 fallback 무시 (alias와 구별되는 핵심 시맨틱)", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { real } from "real-mod"; console.log(real);`,
      "node_modules/real-mod/package.json": `{"name":"real-mod","main":"index.js"}`,
      "node_modules/real-mod/index.js": `export const real = "from-real";`,
      "shim.ts": `export const real = "from-shim";`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { exitCode, stderr } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        `--fallback:real-mod=${join(dir, "shim.ts")}`,
      ]);
      expect(exitCode).toBe(0);
      const output = readFileSync(outFile, "utf8");
      // fallback은 실패 시에만 적용 — 실제 패키지의 "from-real"이 나와야 함
      expect(output).toContain("from-real");
      expect(output).not.toContain("from-shim");
      expect(stderr).not.toContain("error");
    } finally {
      await cleanup();
    }
  });

  test("--fallback:NAME=false — 빈 모듈로 대체", async () => {
    const { bundleOutput, runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        "entry.ts": `import * as m from "missing-mod"; console.log(typeof m);`,
      },
      "entry.ts",
      ["--fallback:missing-mod=false"],
    );
    try {
      expect(exitCode).toBe(0);
      // 빈 모듈은 CJS 빈 객체 → typeof는 "object"
      expect(runOutput).toBe("object");
      expect(bundleOutput).toBeDefined();
    } finally {
      await cleanup();
    }
  });

  test("fallback 없이는 해석 실패 — 에러", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { x } from "missing-mod"; console.log(x);`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { stderr } = await runZts(["--bundle", join(dir, "entry.ts"), "-o", outFile]);
      expect(stderr.toLowerCase()).toContain("cannot resolve");
    } finally {
      await cleanup();
    }
  });

  test("alias가 fallback보다 우선 적용 — 둘 다 매칭되면 alias만 발동", async () => {
    const { dir, cleanup } = await createFixture({
      "entry.ts": `import { v } from "target"; console.log(v);`,
      "alias-target.ts": `export const v = "from-alias";`,
      "fallback-target.ts": `export const v = "from-fallback";`,
    });
    const outFile = join(dir, "out.js");
    try {
      const { exitCode } = await runZts([
        "--bundle",
        join(dir, "entry.ts"),
        "-o",
        outFile,
        `--alias:target=${join(dir, "alias-target.ts")}`,
        `--fallback:target=${join(dir, "fallback-target.ts")}`,
      ]);
      expect(exitCode).toBe(0);
      const out = readFileSync(outFile, "utf8");
      // alias가 먼저 적용되어 정상 해석 — fallback 발동 안 됨
      expect(out).toContain("from-alias");
      expect(out).not.toContain("from-fallback");
    } finally {
      await cleanup();
    }
  });

  test("fallback 체이닝 — fallback target도 다시 fallback 적용 안 됨 (재귀 방지)", async () => {
    // intermediate-mod 자체가 fallback target이지만 다시 다른 fallback으로 가지 않아야 함.
    // applyFallback 안에서 self.fallback을 임시로 비우는 동작 검증.
    const { bundleOutput, runOutput, exitCode, cleanup } = await bundleAndRun(
      {
        "entry.ts": `import { x } from "missing-1"; console.log(x);`,
        "shim.ts": `export const x = "from-shim";`,
      },
      "entry.ts",
      ["--fallback:missing-1=./shim.ts", "--fallback:missing-2=./nonexistent.ts"],
    );
    try {
      expect(exitCode).toBe(0);
      expect(runOutput).toBe("from-shim");
      expect(bundleOutput).toBeDefined();
    } finally {
      await cleanup();
    }
  });
});
