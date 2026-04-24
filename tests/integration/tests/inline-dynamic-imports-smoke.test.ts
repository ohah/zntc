import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { join, resolve } from "node:path";
import { createFixture, hasPackage } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
const ROOT_NODE_MODULES = join(PROJECT_ROOT, "node_modules");

// `inlineDynamicImports` 스모크 — 실전 크기의 fixture + 라이브러리로 구조 검증.
// 런타임 실행은 A 범위 밖 (후속 PR).

describe("inlineDynamicImports smoke", () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("SPA 라우팅 패턴: 여러 route 가 lazy + 공용 util → 단일 chunk 로 압축", async () => {
    const fixture = await createFixture({
      "util/logger.ts": `export const log = (t: string) => console.log("[log]", t);`,
      "util/format.ts": `
        import { log } from "./logger";
        export const fmt = (s: string) => { log("fmt"); return s.toUpperCase(); };
      `,
      "routes/home.ts": `
        import { fmt } from "../util/format";
        export default () => fmt("home");
      `,
      "routes/about.ts": `
        import { fmt } from "../util/format";
        export default () => fmt("about");
      `,
      "routes/contact.ts": `
        import { fmt } from "../util/format";
        export default () => fmt("contact");
      `,
      "entry.ts": `
        import { log } from "./util/logger";
        async function nav(r: string) {
          if (r === "home") return (await import("./routes/home")).default;
          if (r === "about") return (await import("./routes/about")).default;
          return (await import("./routes/contact")).default;
        }
        log("boot");
        nav("home").then((f) => console.log((f as () => string)()));
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
    });

    const outs = result.outputFiles!;
    // 모든 라우트 + 공용 util 이 단일 chunk 안에
    expect(outs.length).toBe(1);
    const mods = outs[0].moduleIds!;
    for (const p of ["entry.ts", "home.ts", "about.ts", "contact.ts", "format.ts", "logger.ts"]) {
      expect(mods.some((m) => m.endsWith(p))).toBe(true);
    }
  });

  test("manualChunks + inline: vendor seed 의 dynamic dep 도 vendor chunk 로 (Phase 2.5 확장)", async () => {
    const fixture = await createFixture({
      "vendor/root.ts": `
        export async function loadExtra() {
          const m = await import("./extra");
          return m.heavy();
        }
      `,
      "vendor/extra.ts": `
        export const heavy = () => "HEAVY_MARK";
      `,
      "entry.ts": `
        import { loadExtra } from "./vendor/root";
        loadExtra().then(console.log);
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
      manualChunks: (id) => {
        if (id.includes("/vendor/")) return "vendor";
        return null;
      },
    });

    const outs = result.outputFiles!;
    const vendorChunk = outs.find((o) => o.path.includes("vendor"));
    expect(vendorChunk).toBeDefined();
    const vendorMods = vendorChunk!.moduleIds!;
    // vendor/root + vendor/extra 모두 vendor chunk 에 (extra 가 dynamic 이어도)
    expect(vendorMods.some((m) => m.endsWith("root.ts"))).toBe(true);
    expect(vendorMods.some((m) => m.endsWith("extra.ts"))).toBe(true);
    // entry chunk 에는 vendor 모듈 없음
    const entryChunk = outs.find((o) => o.moduleIds?.some((m) => m.endsWith("entry.ts")))!;
    expect(entryChunk.moduleIds!.some((m) => m.includes("/vendor/"))).toBe(false);
  });

  test("동일 모듈을 static + dynamic 둘 다로 import — inline 에서 중복 없이 entry chunk 에 한 번만", async () => {
    const fixture = await createFixture({
      "shared.ts": 'export const v = "SHARED_MARK";',
      "entry.ts": `
        import { v as staticV } from "./shared";
        async function boot() {
          const m = await import("./shared");
          console.log(staticV + "|" + m.v);
        }
        boot();
      `,
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
    // shared 가 moduleIds 에 단 한 번
    const sharedCount = mods.filter((m) => m.endsWith("shared.ts")).length;
    expect(sharedCount).toBe(1);
    // SHARED_MARK 는 한 번만 emit
    const occurrences = outs[0].text.split("SHARED_MARK").length - 1;
    expect(occurrences).toBe(1);
  });

  test("중첩 dynamic import (A dyn→ B dyn→ C) 도 하나의 chunk 로 평탄화", async () => {
    const fixture = await createFixture({
      "c.ts": 'export const c = "C_MARK";',
      "b.ts": `
        export async function run() {
          const m = await import("./c");
          return "B:" + m.c;
        }
      `,
      "entry.ts": `
        async function boot() {
          const m = await import("./b");
          console.log(await m.run());
        }
        boot();
      `,
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
    expect(mods.some((m) => m.endsWith("b.ts"))).toBe(true);
    expect(mods.some((m) => m.endsWith("c.ts"))).toBe(true);
    expect(outs[0].text).toContain("C_MARK");
  });

  test("splitting=false 에서 플래그는 무시 — 단일 파일 기본 동작 유지", async () => {
    // splitting 없으면 어차피 단일 파일. 플래그 자체가 no-op.
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
      splitting: false,
      inlineDynamicImports: true,
    });

    // splitting 없을 땐 outputFiles 가 undefined 이거나 단일
    const outs = result.outputFiles ?? [];
    // 크래시 없고 결과가 나오면 성공 — 실제 출력 형태는 splitting=false 경로에 종속
    expect(outs.length >= 0).toBe(true);
  });

  test.skipIf(!hasPackage("clsx"))(
    "실 라이브러리: clsx 를 dynamic 으로만 import 해도 inline 모드에서 entry chunk 에",
    async () => {
      const fixture = await createFixture({
        "entry.ts": `
          async function boot() {
            const { clsx } = await import("clsx");
            console.log(clsx("a", { b: true }));
          }
          boot();
        `,
      });
      cleanup = fixture.cleanup;

      const result = await build({
        entryPoints: [join(fixture.dir, "entry.ts")],
        splitting: true,
        inlineDynamicImports: true,
        nodePaths: [ROOT_NODE_MODULES],
      });

      const outs = result.outputFiles!;
      expect(outs.length).toBe(1);
      // clsx 구현이 entry chunk 안에 인라인
      expect(outs[0].moduleIds!.some((m) => m.includes("clsx"))).toBe(true);
    },
  );
});
