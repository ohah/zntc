import { describe, test, expect, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bundleAndRun, runZts } from "./helpers";

/// Transpile-only (no --bundle) helper. mangler 의 *transpile* path 동작을 격리
/// 검증할 때 사용. bundleAndRun 은 --bundle 을 강제하므로 inner-name elision 같은
/// 별도 pass 와 섞여 mangler 단독 동작을 잡아내기 어렵다 (#2197).
async function transpileAndRun(source: string, extraArgs: string[] = []) {
  const dir = mkdtempSync(join(tmpdir(), "zts-mangler-"));
  const inFile = join(dir, "in.ts");
  const outFile = join(dir, "out.js");
  writeFileSync(inFile, source);
  const r = await runZts([inFile, "-o", outFile, ...extraArgs]);
  const exec = spawnSync("bun", ["run", outFile], { encoding: "utf-8", timeout: 10000 });
  return {
    transpileExitCode: r.exitCode,
    transpileStderr: r.stderr,
    runOutput: (exec.stdout || "").trimEnd(),
    runStderr: (exec.stderr || "").trimEnd(),
    cleanup: async () => rmSync(dir, { recursive: true, force: true }),
  };
}

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

  // post-transform semantic refresh가 module.semantic을 교체하면 기존 ExportBinding.symbol이
  // 이전 symbol table을 가리킬 수 있다. named local export alias가 새 semantic symbol로
  // 다시 연결되지 않으면 importer의 참조와 declaration 이름이 어긋난다.
  test("post-transform semantic refresh 후 named export alias가 새 심볼을 가리킨다", async () => {
    const result = await bundleAndRun(
      {
        "dep.js": `
          const localValue = globalThis.RUNTIME_FLAG ? "bad" : "ok";
          export { localValue as value };
        `,
        "index.js": `
          import { value } from './dep.js';
          globalThis.RUNTIME_FLAG = true;
          console.log(value);
        `,
      },
      "index.js",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    // dep.js 평가 시점에는 RUNTIME_FLAG가 undefined라 falsy.
    expect(result.runOutput).toBe("ok");
  });

  // source 모듈의 default export 심볼이 post-transform semantic 기준으로 갱신되지 않으면
  // barrel re-export가 stale SymbolRef를 따라가며 default 값 연결을 잃는다.
  test("post-transform semantic refresh 후 default re-export chain이 stale 심볼을 쓰지 않는다", async () => {
    const result = await bundleAndRun(
      {
        "dep.js": `export default globalThis.RUNTIME_FLAG ? "bad" : "ok";`,
        "barrel.js": `export { default as value } from './dep.js';`,
        "index.js": `
          import { value } from './barrel.js';
          globalThis.RUNTIME_FLAG = true;
          console.log(value);
        `,
      },
      "index.js",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("ok");
  });

  // namespace import는 current-side local_symbol과 local export symbol 양쪽을 모두 사용한다.
  // semantic refresh 후 ExportBinding.symbol만 낡으면 `export { ns }` 경로에서 namespace 객체가
  // 잘못된 mangled 이름으로 노출될 수 있다.
  test("post-transform semantic refresh 후 namespace import local export가 유지된다", async () => {
    const result = await bundleAndRun(
      {
        "dep.js": `
          export const left = "L";
          export const right = "R";
        `,
        "barrel.js": `
          import * as ns from './dep.js';
          export { ns };
        `,
        "index.js": `
          import { ns } from './barrel.js';
          console.log(ns.left + ns.right);
        `,
      },
      "index.js",
      ["--minify", "--platform=node"],
    );
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("LR");
  });

  // #2197: named class expression 의 inner name 은 mangle 대상에서 제외해야 함.
  // 외부 var 와 inner class name 이 같은 slot 으로 합쳐지면 `.name` 프로퍼티가 mangled
  // 식별자로 바뀌어 spec 위반 (ECMA: class expression inner name binding 은 외부 scope 에
  // 안 보이지만 .name 으로 관찰 가능).
  //
  // 격리: transpile-only path. --bundle 모드에는 inner-name elision pass 가 별도로
  // 동작 (esbuild 와 동일한 minifier convention) 하므로 그 path 와 섞이지 않게 분리.
  test("named class expression 의 .name 이 mangle 후에도 보존된다 (#2197)", async () => {
    const result = await transpileAndRun("const Foo = class Bar {};\nconsole.log(Foo.name);\n", [
      "--minify",
    ]);
    cleanup = result.cleanup;

    expect(result.transpileExitCode).toBe(0);
    expect(result.runOutput).toBe("Bar");
  });

  // class body 안에서 inner name 으로 self-reference 하는 경우에도 동일하게 보존되어야
  // 함 (Bar 가 mangle 되면 self-ref 와 .name 둘 다 깨짐).
  test("class expression body 의 self-reference 와 .name 이 모두 보존된다 (#2197)", async () => {
    const result = await transpileAndRun(
      [
        "const Foo = class Bar {",
        "  static n = 0;",
        "  static count() { return ++Bar.n; }",
        "};",
        "console.log(Foo.count(), Foo.count(), Foo.name);",
      ].join("\n"),
      ["--minify"],
    );
    cleanup = result.cleanup;

    expect(result.transpileExitCode).toBe(0);
    expect(result.runOutput).toBe("1 2 Bar");
  });
});
