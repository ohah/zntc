import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { createFixture } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

// #1961: code splitting + target=es5 시 dynamic chunk 의 helper (`__generator` 등)
// 정의 누락 → ReferenceError. 새 모델은 helper 를 graph 의 1급 모듈로 분배 (oxc 식
// virtual module + named import). 이 회귀 테스트는 모든 chunk 가 helper 를 named
// import 으로 가져오는지 + Node 실행 시 ReferenceError 0 인지 검증.

describe("runtime helper virtual module (#1961)", () => {
  beforeAll(() => init());
  afterAll(() => close());

  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("dynamic chunk async/await + target=es5: __generator/__async 가 named import 으로 분배", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "main.ts": `
        async function load() {
          const { greet } = await import("./greet");
          return greet("ZTS");
        }
        load().then((s) => console.log(s));
      `,
      "greet.ts": `
        export async function greet(name: string): Promise<string> {
          return "hello, " + name;
        }
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    await build({
      entryPoints: [join(fixture.dir, "main.ts")],
      target: "es5",
      splitting: true,
      outdir: outDir,
      write: true,
    });

    const fs = await import("node:fs");
    const files = fs.readdirSync(outDir).filter((f) => f.endsWith(".js"));
    const main = fs.readFileSync(join(outDir, "main.js"), "utf8");
    const greet = fs.readFileSync(join(outDir, "greet.js"), "utf8");

    const helperChunkName = files.find((f) => f.startsWith("chunk-"));
    expect(helperChunkName).toBeDefined();
    const helperChunk = fs.readFileSync(join(outDir, helperChunkName!), "utf8");

    // 1) main / greet 가 named import 으로 helper 받음
    expect(main).toMatch(/import\s*\{[^}]*__async[^}]*\}\s*from\s*["']\.\/chunk-/);
    expect(main).toMatch(/import\s*\{[^}]*__generator[^}]*\}\s*from\s*["']\.\/chunk-/);
    expect(greet).toMatch(/import\s*\{[^}]*__async[^}]*\}\s*from\s*["']\.\/chunk-/);

    // 2) helper chunk 안에 두 helper 정의 + named export
    expect(helperChunk).toMatch(/(var|function)\s+__async/);
    expect(helperChunk).toMatch(/(var|function)\s+__generator/);
    expect(helperChunk).toMatch(/export\s*\{[^}]*__async[^}]*\}/);
    expect(helperChunk).toMatch(/export\s*\{[^}]*__generator[^}]*\}/);

    // 3) main / greet 안에 helper 정의 자체는 없어야 (graph 분배 작동 증거)
    expect(main).not.toMatch(/var\s+__async\s*=\s*function/);
    expect(main).not.toMatch(/var\s+__generator\s*=\s*function/);

    // 4) 실제 Node 실행 — ReferenceError 0 인지 확인
    const proc = spawnSync("node", [join(outDir, "main.js")], { encoding: "utf8" });
    expect(proc.status).toBe(0);
    expect(proc.stderr).toBe("");
    expect(proc.stdout.trim()).toBe("hello, ZTS");
  });

  test("출력에 NULL byte (\\x00) / 'zts:runtime/' raw prefix 가 새지 않음", async () => {
    // sanitize 검증의 minimal 형태 — 모든 chunk 출력 텍스트를 검사.
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "main.ts": `
        async function go() {
          const m = await import("./helper");
          return m.run();
        }
        go().then((v) => console.log(v));
      `,
      "helper.ts": `
        export async function run() { return "ok"; }
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    await build({
      entryPoints: [join(fixture.dir, "main.ts")],
      target: "es5",
      splitting: true,
      outdir: outDir,
      write: true,
    });

    const fs = await import("node:fs");
    for (const f of fs.readdirSync(outDir)) {
      const text = fs.readFileSync(join(outDir, f), "utf8");
      expect(text).not.toContain("\x00");
      expect(text).not.toContain("zts:runtime/");
    }
  });
});
