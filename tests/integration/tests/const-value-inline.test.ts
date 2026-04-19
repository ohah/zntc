import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

// 크로스-모듈 const_value 인라인의 correctness 보장.
// 핵심 버그: `let` 재할당이 있는데도 초기값을 const처럼 인라인하는 pre-existing 이슈.
// 수정: analyzer.zig가 `.variable_const`만 const_value 대상으로 제한.
describe("const_value cross-module 인라인 correctness", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // ========================================================================
  // 버그 재현 케이스: let 재할당 → 초기값 인라인 금지
  // ========================================================================

  test("let 숫자를 += 로 재할당하면 import 시점의 현재 값이 보여야 한다", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let counter = 42;
          export function inc() { counter += 1; }
        `,
        "index.ts": `
          import { counter, inc } from "./lib";
          inc();
          console.log(counter);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("43");
  });

  test("let 숫자를 = 로 직접 재할당해도 올바른 값이 보여야 한다", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let value = 100;
          export function set(n: number) { value = n; }
        `,
        "index.ts": `
          import { value, set } from "./lib";
          set(999);
          console.log(value);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("999");
  });

  test("let 문자열 재할당 시 초기값 인라인 금지", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let label = "initial";
          export function rename(n: string) { label = n; }
        `,
        "index.ts": `
          import { label, rename } from "./lib";
          rename("updated");
          console.log(label);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("updated");
  });

  test("let boolean 재할당", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let flag = true;
          export function toggle() { flag = !flag; }
        `,
        "index.ts": `
          import { flag, toggle } from "./lib";
          toggle();
          console.log(flag);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("false");
  });

  test("let null → 다른 값으로 재할당", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let state: number | null = null;
          export function set() { state = 7; }
        `,
        "index.ts": `
          import { state, set } from "./lib";
          set();
          console.log(state);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("7");
  });

  test("let ++ 증감 연산자", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let n = 0;
          export function bump() { n++; }
        `,
        "index.ts": `
          import { n, bump } from "./lib";
          bump(); bump(); bump();
          console.log(n);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("3");
  });

  test("--minify와 함께 작동", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let score = 10;
          export function update(x: number) { score = x; }
        `,
        "index.ts": `
          import { score, update } from "./lib";
          update(555);
          console.log(score);
        `,
      },
      "index.ts",
      ["--platform=node", "--minify"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("555");
  });

  // ========================================================================
  // 긍정 케이스: const는 여전히 인라인되어야 한다
  // ========================================================================

  test("const true는 cross-module에서 인라인된다", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `export const ENABLED = true;`,
        "index.ts": `
          import { ENABLED } from "./lib";
          console.log(ENABLED);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("true");
  });

  test("const false 인라인", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `export const DISABLED = false;`,
        "index.ts": `
          import { DISABLED } from "./lib";
          console.log(DISABLED);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("false");
  });

  test("const null 인라인", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `export const EMPTY = null;`,
        "index.ts": `
          import { EMPTY } from "./lib";
          console.log(EMPTY);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("null");
  });

  test("const undefined 인라인", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `export const NONE = undefined;`,
        "index.ts": `
          import { NONE } from "./lib";
          console.log(NONE);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("undefined");
  });

  // ========================================================================
  // Edge cases: local let (not exported) / 같은 모듈 내 참조
  // ========================================================================

  test("local let이 같은 모듈 내에서만 쓰여도 인라인되지 않는다", async () => {
    const r = await bundleAndRun(
      {
        "index.ts": `
          let local = 1;
          function update() { local = 99; }
          update();
          console.log(local);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("99");
  });

  test("closure 내 let 재할당도 안전 (const_value 인라인 금지)", async () => {
    const r = await bundleAndRun(
      {
        "lib.ts": `
          export let count = 5;
          const mutator = () => { count = count * 2; };
          export function run() { mutator(); }
        `,
        "index.ts": `
          import { count, run } from "./lib";
          run(); run();
          console.log(count);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("20");
  });

  test("let 재할당 없이 초기값만 있어도 cross-module export는 인라인되지 않음 (보수적)", async () => {
    // 재할당이 없는 let이라도 현재 수정은 const_value를 설정하지 않음 (보수적 처리).
    // 즉 인라인은 안 되지만 정상 동작은 해야 한다.
    const r = await bundleAndRun(
      {
        "lib.ts": `export let immutable = 7;`,
        "index.ts": `
          import { immutable } from "./lib";
          console.log(immutable);
        `,
      },
      "index.ts",
      ["--platform=node"],
    );
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    expect(r.runOutput).toBe("7");
  });
});
