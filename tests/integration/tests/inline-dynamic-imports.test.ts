import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { join } from "node:path";
import { createFixture } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

// `inlineDynamicImports` 구조 검증 — dynamic import target 이 별도 async chunk 로
// 분리되지 않고 importer 의 chunk 에 포함되는지. 런타임 실행은 후속 PR 에서 다룸.

describe("inlineDynamicImports (structural)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("기본 (false): dynamic target 이 별도 async chunk 로", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() { const m = await import("./lazy"); console.log(m.v); }
        boot();
      `,
      "lazy.ts": 'export const v = "LAZY_MARK";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
    });

    // 2개 chunk: entry + lazy
    const outs = result.outputFiles!;
    expect(outs.length).toBe(2);
    const lazyChunk = outs.find((o) => o.text.includes("LAZY_MARK"))!;
    const entryChunk = outs.find((o) => o.moduleIds?.some((m) => m.endsWith("entry.ts")))!;
    expect(lazyChunk.path).not.toBe(entryChunk.path);
    expect(entryChunk.moduleIds!.some((m) => m.endsWith("lazy.ts"))).toBe(false);
  });

  test("true: dynamic target 이 entry chunk 에 흡수 — 단일 chunk", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() { const m = await import("./lazy"); console.log(m.v); }
        boot();
      `,
      "lazy.ts": 'export const v = "LAZY_MARK";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
    });

    const outs = result.outputFiles!;
    expect(outs.length).toBe(1);
    expect(outs[0].moduleIds!.some((m) => m.endsWith("entry.ts"))).toBe(true);
    expect(outs[0].moduleIds!.some((m) => m.endsWith("lazy.ts"))).toBe(true);
    // LAZY_MARK 가 entry chunk 안에 직접 들어있어야 함
    expect(outs[0].text).toContain("LAZY_MARK");
  });

  test("true: transitive static dep 도 entry chunk 로 흡수", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() {
          const m = await import("./lazy");
          console.log(m.run());
        }
        boot();
      `,
      "lazy.ts": `
        import { util } from "./util";
        export const run = () => util() + "_LAZY";
      `,
      "util.ts": 'export const util = () => "UTIL_MARK";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
    });

    const outs = result.outputFiles!;
    expect(outs.length).toBe(1);
    const mods = outs[0].moduleIds!;
    expect(mods.some((m) => m.endsWith("entry.ts"))).toBe(true);
    expect(mods.some((m) => m.endsWith("lazy.ts"))).toBe(true);
    expect(mods.some((m) => m.endsWith("util.ts"))).toBe(true);
    expect(outs[0].text).toContain("UTIL_MARK");
  });

  test("true: same-chunk dynamic import 는 specifier 그대로 유지 (런타임 위임)", async () => {
    // inline 모드에서도 `import("./lazy")` 호출 텍스트는 남아있어야 한다 (A 범위 스펙).
    // 런타임 registry 를 통한 해석은 후속 PR.
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() { const m = await import("./lazy"); console.log(m.v); }
        boot();
      `,
      "lazy.ts": 'export const v = "MARK";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
    });

    // 청크 파일명으로 specifier 가 재작성되지 않고 원본 유지되는지
    // (재작성됐으면 "./lazy.js" 같은 .js 확장자가 따라붙는다)
    expect(result.outputFiles![0].text).toMatch(/import\s*\(\s*["']\.\/lazy["']\s*\)/);
  });

  test("meta.getModuleInfo 는 dynamic 관계를 그대로 관찰", async () => {
    // 청크 구조만 바뀌고 그래프 토폴로지 자체는 불변 — dynamicallyImportedIds 유지.
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() { await import("./lazy"); }
        boot();
      `,
      "lazy.ts": "export const v = 1;",
    });
    cleanup = fixture.cleanup;

    let observedDyn: string[] | undefined;
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          observedDyn = meta.getModuleInfo(id)?.dynamicallyImportedIds;
        }
        return null;
      },
    });

    expect(observedDyn).toBeDefined();
    expect(observedDyn!.some((p) => p.endsWith("lazy.ts"))).toBe(true);
  });
});
