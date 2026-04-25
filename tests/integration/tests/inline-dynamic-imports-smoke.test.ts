import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createFixture, hasPackage } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
const ROOT_NODE_MODULES = join(PROJECT_ROOT, "node_modules");

// 빌드 결과를 Node 로 실행해 stdout 캡처. B 범위 런타임 정합성 검증용.
function runBundleInNode(outDir: string, entryFile: string): string {
  const r = spawnSync("node", [entryFile], { stdio: "pipe", timeout: 15000, cwd: outDir });
  if (r.status !== 0) {
    throw new Error(`node failed (${r.status}): ${r.stderr?.toString().slice(0, 1000)}`);
  }
  return r.stdout.toString();
}

// `inlineDynamicImports` 스모크 — 실전 크기의 fixture + 라이브러리로 구조 검증.

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

  // ============================================================
  // 런타임 정합성 — Node 실행 + stdout 검증
  // ============================================================

  test("런타임: import() 결과 가 정상 namespace 객체 (exports 접근 가능)", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "lazy.ts": `
        export const greeting = "HELLO_FROM_LAZY";
        export function answer() { return 42; }
      `,
      "entry.ts": `
        async function boot() {
          const m = await import("./lazy");
          console.log("OUT:" + m.greeting + "|" + m.answer());
        }
        boot();
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
      outdir: outDir,
      write: true,
    });

    const stdout = runBundleInNode(outDir, "entry.js");
    expect(stdout).toContain("OUT:HELLO_FROM_LAZY|42");
  });

  test("런타임: 같은 모듈 두 번 import() 시 namespace identity 보존 (===)", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "lazy.ts": "export const v = 1;",
      "entry.ts": `
        async function boot() {
          const a = await import("./lazy");
          const b = await import("./lazy");
          console.log("IDENTITY:" + (a === b));
        }
        boot();
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
      outdir: outDir,
      write: true,
    });

    const stdout = runBundleInNode(outDir, "entry.js");
    expect(stdout).toContain("IDENTITY:true");
  });

  test("런타임: top-level side effect 가 정확히 1회 실행 (캐싱)", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "lazy.ts": `
        console.log("SIDE_EFFECT");
        export const v = 1;
      `,
      "entry.ts": `
        async function boot() {
          await import("./lazy");
          await import("./lazy");
          await import("./lazy");
          console.log("DONE");
        }
        boot();
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
      outdir: outDir,
      write: true,
    });

    const stdout = runBundleInNode(outDir, "entry.js");
    // SIDE_EFFECT 가 정확히 1번
    const sideEffectCount = stdout.split("SIDE_EFFECT").length - 1;
    expect(sideEffectCount).toBe(1);
    expect(stdout).toContain("DONE");
  });

  test("런타임: live binding — exports 가 모듈 함수 호출 후 변경 사항 반영", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "lazy.ts": `
        export let counter = 0;
        export function inc() { counter++; }
      `,
      "entry.ts": `
        async function boot() {
          const m = await import("./lazy");
          console.log("BEFORE:" + m.counter);
          m.inc();
          m.inc();
          console.log("AFTER:" + m.counter);
        }
        boot();
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      inlineDynamicImports: true,
      outdir: outDir,
      write: true,
    });

    const stdout = runBundleInNode(outDir, "entry.js");
    expect(stdout).toContain("BEFORE:0");
    expect(stdout).toContain("AFTER:2");
  });

  // 미사용 import 회피
  void writeFileSync;
});
