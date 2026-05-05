import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { build, close, init } from "../../../packages/core/index";
import { createFixture } from "./helpers";

// #2576 — entry 의 `export *` re-export 가 ESM 출력에 정확히 평탄화되는지 검증.
// scope-hoisted 평탄화 (`export { a, b, c }` 단일 문).

/** dist/index.js 에서 ESM `export { internal as exported }` 의 외부 노출 이름 set. */
function extractExportNames(out: string): Set<string> {
  const match = out.match(/export\s*\{([^}]+)\}/);
  if (!match) return new Set();
  return new Set(
    match[1]
      .split(",")
      .map((s) => {
        const parts = s.trim().split(/\s+as\s+/);
        return parts[parts.length - 1]!.trim();
      })
      .filter((s) => s.length > 0),
  );
}

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
    expect(extractExportNames(out)).toEqual(new Set(["HMR_MSG", "tick", "v"]));
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
    expect(extractExportNames(out)).toEqual(new Set(["leaf"]));
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
    // ECMAScript 15.2.3.5 — export * 는 default 제외.
    expect(extractExportNames(out)).toEqual(new Set(["x"]));
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
    // entry 의 foo 가 우선. b 의 foo 는 `seen` first-wins 로 entry export 에 못
    // 들어가지만 module 전체 scope 안에선 충돌 회피용 rename (`foo$1` 등) 가 본문에
    // 잔존 가능. 확인할 invariant 는 (a) `foo` 가 export 됨, (b) entry 값 ("from-
    // entry") 이 산출에 있음, (c) bar 도 entry export 에 포함.
    const names = extractExportNames(out);
    expect(names.has("foo")).toBe(true);
    expect(names.has("bar")).toBe(true);
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
    // visited map 으로 중복 방문 방지 — d 의 `shared` export 가 export 문에 1회만.
    expect(extractExportNames(out)).toEqual(new Set(["shared"]));
  });

  // namespace re-export 가 entry 의 export 로 들어오는 경우 — collectExportsRecursive
  // 가 NsExportPair.ns_target_mod 를 채우는 path. buildFinalExports 의 평탄화에서
  // namespace 객체 자체를 emit (선언은 emitter 의 ns_inline / hoisting 단계가 처리).
  test("entry 의 `export * as ns from ./x` 는 ns 자체를 named export 로 emit", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `export * as helpers from "./helpers.ts";\n`,
      "src/helpers.ts": `export const a = 1;\nexport const b = 2;\n`,
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
    // helpers 가 entry 의 export 로 들어옴 — 단일 namespace 이름으로 평탄화.
    expect(extractExportNames(out)).toEqual(new Set(["helpers"]));
  });

  test("entry 의 `import * as ns from ./x; export { ns }` 도 ns 1개 export", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "src/index.ts": `import * as utils from "./utils.ts";\nexport { utils };\n`,
      "src/utils.ts": `export const x = 1;\n`,
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
    expect(extractExportNames(out)).toEqual(new Set(["utils"]));
  });
});
