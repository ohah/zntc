import { describe, test, expect, afterEach } from "bun:test";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { bundleAndRun, createFixture, runZts } from "./helpers";

// #1608 Option C: bundle-wide slot coloring으로 top-level + nested를 한 번에 mangle.
// `--bundle-wide-mangler` 플래그 기반 — 기본 off, 검증 후 default on 예정.
describe("mangler --bundle-wide-mangler (#1608)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("cross-module 같은 이름 변수가 rename 충돌 없이 분리된다", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          import { foo } from "./a";
          import { bar } from "./b";
          console.log(foo() + bar());
        `,
        "a.ts": `
          const value = 10;
          export function foo() { return value; }
        `,
        "b.ts": `
          const value = 20;
          export function bar() { return value; }
        `,
      },
      "index.ts",
      ["--minify", "--bundle-wide-mangler", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain("SyntaxError");
    expect(result.runStderr).not.toContain("ReferenceError");
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("30");
  });

  test("nested 함수의 로컬 변수가 outer 호출과 shadowing되지 않는다", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          import { compute } from "./lib";
          console.log(compute(3, 4));
        `,
        "lib.ts": `
          function square(n: number): number {
            const tmp = n * n;
            return tmp;
          }
          export function compute(a: number, b: number): number {
            const sumSq = square(a) + square(b);
            return sumSq;
          }
        `,
      },
      "index.ts",
      ["--minify", "--bundle-wide-mangler", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("25");
  });

  test("9-param 함수 + 1글자 param이 충돌하지 않는다 (#1609 bundle-wide 버전)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          function pipe(a: any, ab: any, bc: any, cd: any, de: any, ef: any, fg: any, gh: any, hi: any): any {
            switch (arguments.length) {
              case 1: return a;
              case 2: return ab(a);
              case 3: return bc(ab(a));
              case 4: return cd(bc(ab(a)));
              case 5: return de(cd(bc(ab(a))));
              case 6: return ef(de(cd(bc(ab(a)))));
              case 7: return fg(ef(de(cd(bc(ab(a))))));
              case 8: return gh(fg(ef(de(cd(bc(ab(a)))))));
              case 9: return hi(gh(fg(ef(de(cd(bc(ab(a))))))));
            }
          }
          console.log(pipe(1, (x: number) => x + 1, (x: number) => x * 2));
        `,
      },
      "index.ts",
      ["--minify", "--bundle-wide-mangler", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain("SyntaxError");
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("4");
  });

  test("엔트리 모듈의 named export는 mangling에서 보존된다", async () => {
    // 엔트리의 top-level 심볼 `myApi`가 exported이므로 bundle-wide mangler가 skip해야 한다.
    // 번들 출력 파일 내용을 읽어 original 이름이 남아 있는지 직접 확인.
    const fixture = await createFixture({
      "index.ts": `
        export const myApi = 42;
      `,
    });
    cleanup = fixture.cleanup;

    const outFile = join(fixture.dir, "out.js");
    const r = await runZts([
      "--bundle",
      join(fixture.dir, "index.ts"),
      "-o",
      outFile,
      "--minify",
      "--bundle-wide-mangler",
      "--platform=node",
      "--format=esm",
    ]);
    expect(r.exitCode).toBe(0);

    const src = readFileSync(outFile, "utf8");
    // minify된 출력에 `export ... myApi` 또는 `var myApi = ...` 형태로 원본 이름이
    // 살아 있어야 함 (단순 toContain은 string 내부 문자열과도 매칭되므로 선언 패턴까지 검증).
    expect(src).toMatch(/export\s*\{[^}]*\bmyApi\b|\bmyApi\s*=/);
  });

  test("중첩 scope 간 liveness가 올바르게 유지된다", async () => {
    // 외부 변수 outerVal이 내부 함수에서 참조되므로 inner 함수의 로컬과 충돌 불가.
    // bundle-wide liveness가 ancestor path를 올바르게 마킹해야 한다.
    const result = await bundleAndRun(
      {
        "index.ts": `
          const outerVal = 100;
          function outer() {
            function inner() {
              const localVal = 5;
              return outerVal + localVal;
            }
            return inner();
          }
          console.log(outer());
        `,
      },
      "index.ts",
      ["--minify", "--bundle-wide-mangler", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("105");
  });
});
