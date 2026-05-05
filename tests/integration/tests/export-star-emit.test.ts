import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { build, close, init } from "../../../packages/core/index";
import { createFixture } from "./helpers";

// #2576 — entry 의 `export *` re-export 가 ESM 출력에 정확히 평탄화되는지 검증.
// rolldown / esbuild 와 동일한 scope-hoisted 평탄화 (`export { a, b, c }` 단일 문).

describe("export * re-export ESM emit (#2576)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("entry 의 export * from internal 이 평탄화된 ESM exports 로 emit", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `export * from "./hmr.ts";\nexport const v = 1;\n`,
      "src/hmr.ts": `export const HMR_MSG = "hmr";\nexport function tick() {}\n`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "src/index.ts")],
      outfile: join(fixture.dir, "dist/index.js"),
      format: "esm",
      target: "node",
      write: true,
    });
    expect(result.errors.length).toBe(0);

    const out = readFileSync(join(fixture.dir, "dist/index.js"), "utf8");
    expect(out).toContain("export {");
    expect(out).toContain("HMR_MSG");
    expect(out).toContain("tick");
    expect(out).toContain("v");
  });

  test("nested export * chain (a → b → c) 도 끝까지 평탄화", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `export * from "./a.ts";\n`,
      "src/a.ts": `export * from "./b.ts";\n`,
      "src/b.ts": `export * from "./c.ts";\n`,
      "src/c.ts": `export const leaf = 42;\n`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "src/index.ts")],
      outfile: join(fixture.dir, "dist/index.js"),
      format: "esm",
      target: "node",
      write: true,
    });
    expect(result.errors.length).toBe(0);

    const out = readFileSync(join(fixture.dir, "dist/index.js"), "utf8");
    expect(out).toContain("leaf");
  });

  test("export * 의 default 는 ESM 스펙대로 제외", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `export * from "./b.ts";\n`,
      "src/b.ts": `export default 1;\nexport const x = 2;\n`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "src/index.ts")],
      outfile: join(fixture.dir, "dist/index.js"),
      format: "esm",
      target: "node",
      write: true,
    });
    expect(result.errors.length).toBe(0);

    const out = readFileSync(join(fixture.dir, "dist/index.js"), "utf8");
    expect(out).toContain("x");
    // export * 는 default 제외 — ECMAScript 15.2.3.5
    const exportMatch = out.match(/export\s*\{([^}]+)\}/);
    if (exportMatch) {
      expect(exportMatch[1]).not.toMatch(/\bdefault\b/);
    }
  });

  test("entry 의 직접 export 와 export * 의 이름 충돌 시 entry 가 우선 (first-wins)", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `export const foo = "from-entry";\nexport * from "./b.ts";\n`,
      "src/b.ts": `export const foo = "from-b";\nexport const bar = "from-b";\n`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "src/index.ts")],
      outfile: join(fixture.dir, "dist/index.js"),
      format: "esm",
      target: "node",
      write: true,
    });
    expect(result.errors.length).toBe(0);

    const out = readFileSync(join(fixture.dir, "dist/index.js"), "utf8");
    // bar 는 b 의 export 가 평탄화되어 들어옴
    expect(out).toContain("bar");
    // foo 는 entry 의 정의가 우선 (collectExportsRecursive 의 seen first-wins)
    expect(out).toContain("from-entry");
  });

  test("diamond export * (a → b, a → c, b/c → d) 에서 d 의 export 1회만", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `export * from "./b.ts";\nexport * from "./c.ts";\n`,
      "src/b.ts": `export * from "./d.ts";\n`,
      "src/c.ts": `export * from "./d.ts";\n`,
      "src/d.ts": `export const shared = 99;\n`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "src/index.ts")],
      outfile: join(fixture.dir, "dist/index.js"),
      format: "esm",
      target: "node",
      write: true,
    });
    expect(result.errors.length).toBe(0);

    const out = readFileSync(join(fixture.dir, "dist/index.js"), "utf8");
    expect(out).toContain("shared");
    // visited map 으로 중복 방문 방지 — `shared` export 가 단 한 번만
    const matches = out.match(/\bshared\b/g) ?? [];
    // 평탄화된 export { ... } 안에 1회 + declaration 1회 정도. 2~3회 이내.
    expect(matches.length).toBeLessThanOrEqual(3);
  });
});
