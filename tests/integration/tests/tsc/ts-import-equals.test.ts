import { describe, test, expect } from "bun:test";
import { createFixture, runZts } from "../helpers";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// #1802 B2 리뷰 중 surface 된 케이스 회귀 방지.
//
// `ts_import_equals_declaration` 은 audit 스크립트에 "cosmetic" 으로 보이지만
// (layout=.extra, parser stored=.binary), 실제로는 transformer 가
// `data.binary.left/right` 를 읽어서 `const X = require("...")` 런타임 코드를
// 생성한다 → strip target 이 아님. parser 를 empty `.extra` 로 바꾸면
// silent failure (`const <none> = <none>` emit 또는 visitNode(.none) crash).
//
// audit 이 codegen 만 스캔하고 transformer 는 안 보는 한계 때문에 놓치기 쉬운
// 케이스 — 통합 테스트로 고정.

describe("TSC: import-equals declaration (#1802 follow-up)", () => {
  test("import X = require('fs') emit 에서 binary.left(name) / binary.right(value) 보존", async () => {
    // transformer 가 빈 `.extra` 를 받으면 `const <none> = <none>` 이 찍혀 emit 에
    // `= require` 자체가 누락되거나 변수명이 사라진다. 이 테스트는 emit 문자열로
    // 해당 silent failure 를 고정 (런타임 실행은 이후 Namespace 테스트가 커버).
    const { dir, cleanup } = await createFixture({
      "index.ts": `
        import Fs = require("fs");
        console.log(typeof Fs);
      `,
    });
    const outFile = join(dir, "out.js");
    const transpile = await runZts([join(dir, "index.ts"), "-o", outFile]);
    expect(transpile.exitCode).toBe(0);

    const out = readFileSync(outFile, "utf-8");
    // 변수명 + require 호출 + specifier 모두 살아있어야 한다.
    expect(out).toMatch(/(?:const|var)\s+Fs\s*=\s*require\s*\(\s*["']fs["']\s*\)/);
    await cleanup();
  });

  test("import X = Namespace.Member → const X = Namespace.Member", async () => {
    const { dir, cleanup } = await createFixture({
      "index.ts": `
        namespace NS {
          export const value = 42;
          export namespace Inner {
            export const nested = 7;
          }
        }
        import Root = NS;
        import Deep = NS.Inner;
        console.log(Root.value, Deep.nested);
      `,
    });
    const outFile = join(dir, "out.js");
    const transpile = await runZts([join(dir, "index.ts"), "-o", outFile]);
    expect(transpile.exitCode).toBe(0);

    const out = readFileSync(outFile, "utf-8");
    // transformer 가 binary.left(name) / binary.right(value) 를 읽어 const 선언 생성.
    // empty `.extra` 로 치환되면 `const <none> = <none>` 또는 crash.
    expect(out).toContain("Root");
    expect(out).toContain("Deep");
    expect(out).toContain("NS.Inner");
    await cleanup();
  });

  test("import X = require('fs') 가 ESM import 가 아닌 const 로 emit", async () => {
    const { dir, cleanup } = await createFixture({
      "index.ts": `
        import Fs = require("fs");
        console.log(typeof Fs);
      `,
    });
    const outFile = join(dir, "out.js");
    const transpile = await runZts([join(dir, "index.ts"), "-o", outFile]);
    expect(transpile.exitCode).toBe(0);

    const out = readFileSync(outFile, "utf-8");
    // TS CJS 호환 구문이라 ESM import 로 변환되면 안 된다.
    expect(out).not.toContain('import Fs from "fs"');
    // const 선언 + require 호출이 있어야 한다.
    expect(out).toMatch(/(?:const|var)\s+Fs\s*=/);
    expect(out).toMatch(/require\s*\(\s*["']fs["']\s*\)/);
    await cleanup();
  });
});
