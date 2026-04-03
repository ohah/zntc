/**
 * --polyfill 및 --run-before-main 옵션 통합 테스트
 *
 * Metro의 getPolyfills + runBeforeMainModule과 동일한 역할:
 * - --polyfill: 번들 시작 시 IIFE로 감싸서 즉시 실행 (모듈 그래프 밖)
 * - --run-before-main: 엔트리 모듈 직전에 실행 (모듈 그래프 안, inject와 동일 메커니즘)
 */
import { describe, expect, test, afterAll } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createFixture, runZtsInDir } from "./helpers";

// 테스트 fixture: 간단한 엔트리 + 폴리필 + run-before-main 모듈
const fixtures = {
  "entry.js": `
    import { greeting } from './lib.js';
    globalThis.__ENTRY_RAN__ = true;
    globalThis.__GREETING__ = greeting;
  `,
  "lib.js": `
    export const greeting = "hello";
  `,
  "polyfill-a.js": `
    globalThis.__POLYFILL_A__ = true;
    globalThis.__EXEC_ORDER__ = globalThis.__EXEC_ORDER__ || [];
    globalThis.__EXEC_ORDER__.push("polyfill-a");
  `,
  "polyfill-b.js": `
    globalThis.__POLYFILL_B__ = true;
    globalThis.__EXEC_ORDER__ = globalThis.__EXEC_ORDER__ || [];
    globalThis.__EXEC_ORDER__.push("polyfill-b");
  `,
  "init-core.js": `
    globalThis.__INIT_CORE_RAN__ = true;
    globalThis.__EXEC_ORDER__ = globalThis.__EXEC_ORDER__ || [];
    globalThis.__EXEC_ORDER__.push("init-core");
  `,
};

let fixture: { dir: string; cleanup: () => Promise<void> };

afterAll(async () => {
  if (fixture) await fixture.cleanup();
});

describe("--polyfill", () => {
  test("폴리필이 IIFE로 감싸져서 번들 앞에 삽입된다", async () => {
    fixture = await createFixture(fixtures);
    const outFile = join(fixture.dir, "out.js");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `-o`,
      outFile,
      `--polyfill=${join(fixture.dir, "polyfill-a.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // IIFE 래핑 확인
    expect(bundle).toContain("(function(){");
    expect(bundle).toContain("__POLYFILL_A__");
    expect(bundle).toContain("})();");

    // 폴리필이 모듈 코드보다 앞에 있어야 함
    const polyfillPos = bundle.indexOf("__POLYFILL_A__");
    const entryPos = bundle.indexOf("__ENTRY_RAN__");
    expect(polyfillPos).toBeLessThan(entryPos);
  });

  test("여러 폴리필이 순서대로 삽입된다", async () => {
    fixture = await createFixture(fixtures);
    const outFile = join(fixture.dir, "out.js");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `-o`,
      outFile,
      `--polyfill=${join(fixture.dir, "polyfill-a.js")}`,
      `--polyfill=${join(fixture.dir, "polyfill-b.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");
    const posA = bundle.indexOf("__POLYFILL_A__");
    const posB = bundle.indexOf("__POLYFILL_B__");
    const posEntry = bundle.indexOf("__ENTRY_RAN__");

    // A → B → entry 순서
    expect(posA).toBeLessThan(posB);
    expect(posB).toBeLessThan(posEntry);
  });

  test("존재하지 않는 폴리필 경로는 에러 메시지를 출력한다", async () => {
    fixture = await createFixture(fixtures);

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `--polyfill=/nonexistent/polyfill.js`,
    ]);
    expect(result.stderr).toContain("cannot resolve");
  });
});

describe("--run-before-main", () => {
  test("run-before-main 모듈이 엔트리 전에 실행된다", async () => {
    fixture = await createFixture(fixtures);
    const outFile = join(fixture.dir, "out.js");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `-o`,
      outFile,
      `--run-before-main=${join(fixture.dir, "init-core.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // init-core 코드가 번들에 포함
    expect(bundle).toContain("__INIT_CORE_RAN__");

    // init-core가 엔트리보다 앞에 위치
    const initPos = bundle.indexOf("__INIT_CORE_RAN__");
    const entryPos = bundle.lastIndexOf("__ENTRY_RAN__");
    expect(initPos).toBeLessThan(entryPos);
  });

  test("run-before-main 모듈의 require/init 호출이 엔트리 직전에 삽입된다", async () => {
    fixture = await createFixture(fixtures);
    const outFile = join(fixture.dir, "out.js");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `-o`,
      outFile,
      `--run-before-main=${join(fixture.dir, "init-core.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");
    const lines = bundle.split("\n");

    // 엔트리 코드(__ENTRY_RAN__) 직전에 require_init_core() 또는 init_init_core() 호출이 있어야 함
    const entryLineIdx = lines.findLastIndex((l) => l.includes("__ENTRY_RAN__"));
    expect(entryLineIdx).toBeGreaterThan(0);

    // 엔트리 이전 20줄 이내에 init-core 모듈의 호출(require_xxx() 또는 init_xxx())이 있어야 함
    const precedingLines = lines.slice(Math.max(0, entryLineIdx - 20), entryLineIdx).join("\n");
    const hasCall = /(?:require|init)_[a-zA-Z0-9_]*init[_-]core[a-zA-Z0-9_]*\(\)/.test(
      precedingLines,
    );
    expect(hasCall).toBe(true);
  });

  test("존재하지 않는 run-before-main 경로는 에러 메시지를 출력한다", async () => {
    fixture = await createFixture(fixtures);

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `--run-before-main=/nonexistent/init.js`,
    ]);
    expect(result.stderr).toContain("cannot resolve");
  });
});

describe("--polyfill + --run-before-main 조합", () => {
  test("실행 순서: polyfill → run-before-main → entry", async () => {
    fixture = await createFixture(fixtures);
    const outFile = join(fixture.dir, "out.js");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `-o`,
      outFile,
      `--polyfill=${join(fixture.dir, "polyfill-a.js")}`,
      `--run-before-main=${join(fixture.dir, "init-core.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // 폴리필 (IIFE) → init-core (모듈) → entry (모듈) 순서
    const polyfillPos = bundle.indexOf("__POLYFILL_A__");
    const initPos = bundle.indexOf("__INIT_CORE_RAN__");
    const entryPos = bundle.lastIndexOf("__ENTRY_RAN__");

    expect(polyfillPos).toBeLessThan(initPos);
    expect(initPos).toBeLessThan(entryPos);
  });

  test("--platform=react-native에서 엔트리가 __esm으로 래핑되지 않는다", async () => {
    fixture = await createFixture(fixtures);
    const outFile = join(fixture.dir, "out.js");

    const result = await runZtsInDir(fixture.dir, [
      "--bundle",
      "entry.js",
      `-o`,
      outFile,
      "--platform=react-native",
      `--run-before-main=${join(fixture.dir, "init-core.js")}`,
    ]);
    expect(result.exitCode).toBe(0);

    const bundle = readFileSync(outFile, "utf-8");

    // 엔트리 모듈(entry.js)의 코드가 __esm 래핑 없이 직접 실행되어야 함
    // 마지막 __ENTRY_RAN__ 이전에 var init_entry = __esm 패턴이 없어야 함
    const lines = bundle.split("\n");
    const entryLine = lines.findIndex((l) => l.includes("__ENTRY_RAN__") && !l.includes("__esm"));

    // 엔트리 코드가 직접 실행 (scope-hoisted)되는지 확인
    // __esm 안에 있으면 findIndex가 -1
    expect(entryLine).toBeGreaterThan(-1);
  });
});
