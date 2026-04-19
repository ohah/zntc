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
});
