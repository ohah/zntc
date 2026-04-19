import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

describe("mangler --minify 회귀", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // #1609: shouldSkip(name.len<=1) 파라미터의 원본 이름이 reserved 처리되지 않아
  // base54 카운터가 같은 이름을 다른 param에 재할당 → "Duplicate parameter name" SyntaxError.
  // Effect의 pipe(a, ab, ..., hi) 9-param 시그니처가 전형적인 재현 케이스.
  test("9-param 함수에서 1글자 param과 slot base54 이름이 충돌하지 않는다 (#1609)", async () => {
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
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain("SyntaxError");
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("4");
  });

  // outer(module) 스코프의 1글자 const를 nested 함수가 참조하는데, base54 결과가
  // 동일 이름을 함수 param에 할당하면 outer 참조가 shadowing되어 잘못된 값을 반환.
  test("outer 1글자 const가 nested 함수 param에 shadowing되지 않는다 (#1609)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          const i = 100;
          function compute(aa: number, ab: number, ac: number, ad: number, ae: number, af: number, ag: number, ah: number): number {
            return i + aa + ab + ac + ad + ae + af + ag + ah;
          }
          console.log(compute(1, 2, 3, 4, 5, 6, 7, 8));
        `,
      },
      "index.ts",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain("SyntaxError");
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("136"); // 100 + (1+2+...+8)
  });

  // for-loop의 `i`/`j` counter와 sibling 파라미터가 같은 함수에 공존할 때
  // base54가 `i`/`j`를 param에 재할당하면 loop counter 참조가 오염됨.
  test("loop counter i/j가 sibling param과 충돌하지 않는다 (#1609)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          function sum(aa: number[], ab: number[], ac: number[], ad: number[], ae: number[], af: number[], ag: number[]): number {
            let total = 0;
            for (let i = 0; i < aa.length; i++) total += aa[i];
            for (let j = 0; j < ab.length; j++) total += ab[j];
            return total + ac.length + ad.length + ae.length + af.length + ag.length;
          }
          console.log(sum([1, 2], [3], [4], [], [], [], []));
        `,
      },
      "index.ts",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain("SyntaxError");
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("7"); // (1+2) + 3 + 1 (ac.length) + 0*4
  });

  // base54 앞자리 0~4가 모두 1글자 local(e,t,n,r,i)로 reserved인 극단 케이스.
  // 카운터가 5칸 밀려도 이후 이름(c,l,u,d,f,p,m,h,g)이 정상 할당되는지 검증.
  test("base54 앞자리 5개(e,t,n,r,i)가 전부 reserved여도 번들 성공 (#1609)", async () => {
    const result = await bundleAndRun(
      {
        "index.ts": `
          function run(aa: number, ab: number, ac: number, ad: number, ae: number, af: number, ag: number, ah: number, ai: number): number {
            let e = aa, t = ab, n = ac, r = ad, i = ae;
            return e + t + n + r + i + af + ag + ah + ai;
          }
          console.log(run(1, 2, 3, 4, 5, 6, 7, 8, 9));
        `,
      },
      "index.ts",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.runStderr).not.toContain("SyntaxError");
    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("45"); // 1+2+...+9
  });

  // #1623: import binding이 mangling candidates에 포함되면 자체 mangle name을 받고,
  // buildMetadataForAst의 self-rename 루프가 그 이름으로 cross-module rename을 덮어써
  // declaration과 reference가 서로 다른 이름으로 mangle돼 ReferenceError 발생.
  test("cross-module default import의 declaration과 reference 이름이 일치한다 (#1623)", async () => {
    const result = await bundleAndRun(
      {
        // 런타임 표현식이라 컴파일타임 inline이 안 돼 _default가 var로 남고
        // use.js의 flag 참조도 var로 남는 — 양쪽 이름이 일치해야 동작.
        "dep.js": `export default globalThis.RUNTIME_FLAG;`,
        "use.js": `
          import flag from './dep.js';
          export var x = flag ? new Set() : null;
          export function f() { return flag ? new Set() : null; }
        `,
        "index.js": `
          import { x, f } from './use.js';
          globalThis.RUNTIME_FLAG = false;
          console.log(x, f());
        `,
      },
      "index.js",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    // RUNTIME_FLAG는 dep.js 평가 시점에 undefined → falsy → 양쪽 null
    expect(result.runOutput).toBe("null null");
  });
});
