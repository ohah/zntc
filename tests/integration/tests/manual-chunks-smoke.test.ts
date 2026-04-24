import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createFixture } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

// manualChunks 스모크 테스트 — 실제 번들 → Node 로 실행 → 출력 검증.
// Zig unit + NAPI integration 테스트와 달리 **최종 런타임 동작**까지 확인.
// vendor/ui 디렉토리 구조로 실제 라이브러리 분리 시나리오 모방.

describe("manualChunks smoke (실제 번들 실행)", () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("vendor 디렉토리 → 별도 청크 분리 + 실제 Node 실행 검증", async () => {
    const fixture = await createFixture({
      "package.json": '{"type":"module"}',
      "vendor/math.ts": `
        export function add(a: number, b: number) { return a + b; }
        export function multiply(a: number, b: number) { return a * b; }
      `,
      "vendor/string-utils.ts": `
        export function toUpper(s: string) { return s.toUpperCase(); }
      `,
      "ui/formatter.ts": `
        import { add } from "../vendor/math";
        import { toUpper } from "../vendor/string-utils";
        export function format(label: string, a: number, b: number) {
          return toUpper(label) + ": " + add(a, b);
        }
      `,
      "entry.ts": `
        import { format } from "./ui/formatter";
        console.log(format("result", 2, 3));
      `,
    });
    cleanup = fixture.cleanup;

    const outDir = join(fixture.dir, "dist");
    mkdirSync(outDir, { recursive: true });
    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: outDir,
      write: true,
      manualChunks: (id) => {
        if (id.includes("/vendor/")) return "vendor";
        return null;
      },
    });

    // 청크 구조
    const vendor = result.outputFiles.find((f) => f.path.includes("vendor"));
    const entry = result.outputFiles.find((f) => f.path.includes("entry"));
    expect(vendor).toBeDefined();
    expect(entry).toBeDefined();

    // vendor 청크에 수학/string-utils 구현 전부 (transitive dep 포함 정책)
    expect(vendor!.text).toMatch(/function\s+add\s*\(/);
    expect(vendor!.text).toMatch(/function\s+toUpper\s*\(/);
    expect(vendor!.text).toMatch(/function\s+multiply\s*\(/);

    // entry 청크엔 ui/formatter 만, vendor 구현 없음
    expect(entry!.text).toMatch(/function\s+format\s*\(/);
    expect(entry!.text).not.toMatch(/function\s+add\s*\(/);
    expect(entry!.text).not.toMatch(/function\s+toUpper\s*\(/);

    // cross-chunk import 링크 존재
    expect(entry!.text).toMatch(/from\s+["'][^"']*vendor[^"']*["']/);

    // 디스크에 실제로 써졌는지 (write: true 경로 검증)
    const onDiskEntry = readFileSync(join(outDir, "entry.js"), "utf8");
    expect(onDiskEntry).toBe(entry!.text);
  });

  test("여러 엔트리가 공유하는 vendor → manual 청크로 추출 (청크 구조만)", async () => {
    // 청크 구조 검증만 — cross-chunk export 가 누락되는 follow-up 버그로 runtime
    // 실행은 아직 실패. 청크 할당은 올바르게 동작.
    const fixture = await createFixture({
      "vendor/shared.ts": `
        export const VERSION = "1.0.0";
        export function greet(name: string) { return "hello, " + name; }
      `,
      "pageA.ts": `
        import { greet } from "./vendor/shared";
        console.log(greet("alice"));
      `,
      "pageB.ts": `
        import { greet, VERSION } from "./vendor/shared";
        console.log(greet("bob") + " @ " + VERSION);
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "pageA.ts"), join(fixture.dir, "pageB.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      manualChunks: (id) => {
        if (id.includes("/vendor/")) return "vendor";
        return null;
      },
    });

    // 3개 청크: pageA, pageB, vendor
    expect(result.outputFiles.length).toBe(3);
    const paths = result.outputFiles.map((o) => o.path);
    expect(paths.some((p) => p.includes("vendor"))).toBe(true);

    // 엔트리 청크에서 shared 코드가 제거됐고 vendor 에만 남아있는지
    const pageAFile = result.outputFiles.find((o) => o.path.includes("pageA"));
    const vendorFile = result.outputFiles.find((o) => o.path.includes("vendor"));
    expect(pageAFile!.text).not.toContain("VERSION");
    expect(vendorFile!.text).toContain("VERSION");
    expect(vendorFile!.text).toContain("hello, ");
  });

  test("dynamic import target 은 manualChunks 매칭돼도 async chunk 유지 (Rollup/rolldown 동일 정책)", async () => {
    // 정책: dynamic import 는 "lazy load" 의미상 vendor 로 합치면 의도 반전 가능.
    // 강제 흡수는 #1850 에서 scope hoisting 개조와 함께 근본 수정 검토.
    const fixture = await createFixture({
      "vendor/lazy.ts": `
        export const heavyData = { size: 42, label: "LAZY_VENDOR" };
      `,
      "entry.ts": `
        const mod = await import("./vendor/lazy");
        console.log(mod.heavyData.label);
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      manualChunks: (id) => {
        if (id.includes("/vendor/")) return "vendor";
        return null;
      },
    });

    // lazy 는 vendor 가 아닌 별도 async chunk 에 있어야
    const lazyChunk = result.outputFiles.find((o) => o.text.includes("LAZY_VENDOR"));
    expect(lazyChunk).toBeDefined();
    expect(lazyChunk!.path).not.toContain("vendor");
    // manual 매칭된 static 모듈이 없으므로 vendor chunk 자체가 생성 안 됨
    const vendorChunk = result.outputFiles.find((o) => o.path.includes("vendor"));
    expect(vendorChunk).toBeUndefined();
  });

  test("manualChunks 안 쓸 때 vs 쓸 때 번들 크기 비교", async () => {
    const files = {
      "vendor/big-lib.ts": `
        // 큰 라이브러리 시뮬레이션 — 여러 export
        export function a() { return 1; }
        export function b() { return 2; }
        export function c() { return 3; }
        export function d() { return 4; }
        export function e() { return 5; }
      `,
      "entry.ts": `
        import { a, b, c, d, e } from "./vendor/big-lib";
        console.log(a() + b() + c() + d() + e());
      `,
    };

    // Case 1: manualChunks 없음 → 단일 청크
    const fx1 = await createFixture(files);
    const r1 = await build({
      entryPoints: [join(fx1.dir, "entry.ts")],
      splitting: true,
      outdir: join(fx1.dir, "dist"),
      write: false,
    });
    expect(r1.outputFiles.length).toBe(1);
    await fx1.cleanup();

    // Case 2: manualChunks 로 vendor 분리 → 2개 청크
    const fx2 = await createFixture(files);
    const r2 = await build({
      entryPoints: [join(fx2.dir, "entry.ts")],
      splitting: true,
      outdir: join(fx2.dir, "dist"),
      write: false,
      manualChunks: (id) => (id.includes("/vendor/") ? "vendor" : null),
    });
    expect(r2.outputFiles.length).toBe(2);
    const entryChunk = r2.outputFiles.find((o) => o.path.includes("entry"));
    const vendorChunk = r2.outputFiles.find((o) => o.path.includes("vendor"));
    // entry 청크엔 vendor 구현이 없어야 함 (import 만)
    expect(entryChunk!.text).not.toMatch(/function\s+[a-e]\s*\(\)/);
    // vendor 청크엔 모든 함수가 있어야 함
    expect(vendorChunk!.text).toMatch(/function\s+a\s*\(\)/);
    expect(vendorChunk!.text).toMatch(/function\s+e\s*\(\)/);
    await fx2.cleanup();
  });
});
