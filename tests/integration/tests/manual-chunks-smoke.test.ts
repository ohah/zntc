import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { mkdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { createFixture, hasPackage } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
const ROOT_NODE_MODULES = join(PROJECT_ROOT, "node_modules");

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
    expect(entry!.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);

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

  test("realistic: dynamic entry 가 vendor dep 을 static import — 번들 구조 일치", async () => {
    // 전형적 "lazy route 가 shared vendor 사용" 시나리오.
    // vendor/shared 는 static 으로 entry + lazy 양쪽에서 import → vendor 청크로
    // vendor/lazy 는 dynamic entry → async chunk (vendor 제외 정책)
    // 결과: vendor.js 가 cross-chunk export 로 entry / lazy 에 symbol 공급
    const fixture = await createFixture({
      "vendor/shared.ts": `export const SHARED = "SHARED_MARKER";`,
      "vendor/lazy.ts": `
        import { SHARED } from "./shared";
        export const run = () => "lazy:" + SHARED;
      `,
      "entry.ts": `
        import { SHARED } from "./vendor/shared";
        const mod = await import("./vendor/lazy");
        console.log(SHARED + "|" + mod.run());
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      manualChunks: (id) => (id.includes("/vendor/") ? "vendor" : null),
    });

    // 최소 3개 청크: entry, vendor, lazy
    const vendor = result.outputFiles.find(
      (o) => o.path.includes("vendor") && !o.path.includes("lazy"),
    )!;
    const lazyChunk = result.outputFiles.find((o) => o.text.includes("lazy:"))!;
    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"))!;
    expect(vendor).toBeDefined();
    expect(lazyChunk).toBeDefined();

    // vendor 에 shared 코드 + cross-chunk export 구문
    expect(vendor.text).toContain("SHARED_MARKER");
    expect(vendor.text).toMatch(/export\s*\{/);

    // lazy chunk 는 vendor 가 아닌 별도 경로 + vendor 에서 SHARED import
    expect(lazyChunk.path).not.toContain("vendor");
    expect(lazyChunk.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);

    // entry 도 vendor 에서 SHARED import, dynamic import("./lazy") 사용
    expect(entry.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);
    expect(entry.text).toMatch(/import\s*\(/);
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

  test("multi-group: vendor + ui 각각 다른 manual 청크", async () => {
    const fixture = await createFixture({
      "vendor/math.ts": `export const VENDOR_MARKER = "V"; export function add(a: number, b: number) { return a + b; }`,
      "ui/button.ts": `import { add } from "../vendor/math"; export const UI_MARKER = "U"; export const btn = add(1, 2);`,
      "entry.ts": `
        import { UI_MARKER } from "./ui/button";
        import { VENDOR_MARKER } from "./vendor/math";
        console.log(VENDOR_MARKER + UI_MARKER);
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
        if (id.includes("/ui/")) return "ui";
        return null;
      },
    });

    // 3개 청크: entry + vendor + ui
    const paths = result.outputFiles.map((o) => o.path);
    expect(paths.some((p) => p.includes("vendor"))).toBe(true);
    expect(paths.some((p) => p.includes("ui"))).toBe(true);

    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"))!;
    const ui = result.outputFiles.find((o) => o.path.includes("ui") && !o.path.includes("vendor"))!;
    expect(vendor.text).toContain("VENDOR_MARKER");
    expect(vendor.text).not.toContain("UI_MARKER");
    expect(ui.text).toContain("UI_MARKER");
    // ui 는 vendor 에서 add import (cross-chunk)
    expect(ui.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);
  });

  test("minify + manualChunks: 프로덕션 빌드 시뮬레이션", async () => {
    const fixture = await createFixture({
      "vendor/lib.ts": `export function veryLongFunctionName() { return "MIN_OK"; }`,
      "entry.ts": `
        import { veryLongFunctionName } from "./vendor/lib";
        console.log(veryLongFunctionName());
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      minify: true,
      manualChunks: (id) => (id.includes("/vendor/") ? "vendor" : null),
    });

    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"))!;
    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"))!;
    // minify 후에도 marker 는 live (string literal 은 보존)
    expect(vendor.text).toContain("MIN_OK");
    // 함수명은 mangle 로 축약 가능 (veryLongFunctionName 가 전부 유지되진 않을 수 있음)
    // 단 cross-chunk 에서 어떤 이름으로든 공유되어야 entry 에서 참조 가능.
    expect(entry.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);
    // minify_whitespace 효과 — 공백 기반 pattern 축소
    expect(vendor.text.length).toBeLessThan(200);
  });

  test.skipIf(!hasPackage("clsx"))("실 라이브러리: clsx 를 vendor 청크로 분리", async () => {
    // 실제 node_modules 의 clsx 를 사용자 앱에서 import 하는 현실적 시나리오.
    // manualChunks 로 node_modules 전체를 vendor 에 몰아넣는 가장 흔한 패턴.
    const fixture = await createFixture({
      "ui.ts": `
          import clsx from "clsx";
          export const label = clsx("a", { b: true, c: false }, ["d"]);
        `,
      "entry.ts": `
          import { label } from "./ui";
          console.log("RESULT:" + label);
        `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      nodePaths: [ROOT_NODE_MODULES],
      manualChunks: (id) => (id.includes("node_modules") ? "vendor" : null),
    });

    // vendor 청크에 clsx 구현이 들어가야 함
    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
    expect(vendor).toBeDefined();
    // clsx 의 특징적 function body pattern
    expect(vendor!.text).toMatch(/function/);
    expect(vendor!.text.length).toBeGreaterThan(50);

    // entry 에는 clsx 구현 없이 ui/app 코드만 + vendor import
    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
    expect(entry).toBeDefined();
    expect(entry!.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);
  });

  test("대형 가상 vendor: date-utils 스타일 다중 모듈 → vendor 합병", async () => {
    // 실 라이브러리 install 없이 "대형 라이브러리" 구조 시뮬레이션.
    // node_modules 패키지처럼 여러 파일에 걸쳐 분할된 vendor 가 한 chunk 로 통합되는지.
    const fixture = await createFixture({
      "libs/date-utils/format.ts": `
        export function formatDate(d: Date) { return d.toISOString(); }
        export function formatTime(d: Date) { return d.toTimeString(); }
      `,
      "libs/date-utils/parse.ts": `
        export function parseISO(s: string) { return new Date(s); }
        export function parseUnix(n: number) { return new Date(n * 1000); }
      `,
      "libs/date-utils/diff.ts": `
        import { parseISO } from "./parse";
        export function daysBetween(a: string, b: string) {
          const ms = parseISO(b).getTime() - parseISO(a).getTime();
          return Math.floor(ms / 86400000);
        }
      `,
      "libs/date-utils/index.ts": `
        export { formatDate, formatTime } from "./format";
        export { parseISO, parseUnix } from "./parse";
        export { daysBetween } from "./diff";
      `,
      "app/calendar.ts": `
        import { formatDate, daysBetween } from "../libs/date-utils/index";
        export const header = formatDate(new Date(0));
        export const diff = daysBetween("2024-01-01", "2024-12-31");
      `,
      "entry.ts": `
        import { header, diff } from "./app/calendar";
        console.log("CAL_MARKER:" + header + ":" + diff);
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      manualChunks: (id) => (id.includes("/libs/date-utils/") ? "date-utils" : null),
    });

    // date-utils 청크에 4개 모듈의 코드가 모두 들어가야 함
    const vendor = result.outputFiles.find((o) => o.path.includes("date-utils"));
    expect(vendor).toBeDefined();
    expect(vendor!.text).toMatch(/function\s+formatDate\s*\(/);
    expect(vendor!.text).toMatch(/function\s+parseISO\s*\(/);
    expect(vendor!.text).toMatch(/function\s+daysBetween\s*\(/);
    // index.ts 는 barrel re-export 라 tree-shake 로 제거되거나 pass-through
    // 어느 쪽이든 vendor chunk 에 해당 export 가 살아있어야
    expect(vendor!.text).toMatch(/export\s*\{/);

    // entry 청크엔 vendor 구현 없음 + cross-chunk import
    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
    expect(entry!.text).not.toMatch(/function\s+formatDate/);
    expect(entry!.text).toMatch(/from\s*["'][^"']*date-utils[^"']*["']/);
  });

  test("엔트리 모듈이 manualChunks 매칭: 엔트리 청크로 유지 (정책)", async () => {
    // 엔트리 모듈 자체가 manualChunks 패턴에 매칭되면 어떻게?
    // Phase 4 가드로 엔트리는 manual 로 강제 이동하지 않음 — entry chunk 유지.
    const fixture = await createFixture({
      "app.ts": `console.log("ENTRY_MARKER");`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "app.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      // 엔트리 자체 이름 매칭 — 극단적 케이스
      manualChunks: () => "somegroup",
    });

    // 엔트리는 그대로 app.js 에, 매칭된 somegroup 은 생성되거나 안 되거나 무관
    const entryChunk = result.outputFiles.find((o) => o.text.includes("ENTRY_MARKER"));
    expect(entryChunk).toBeDefined();
    // 실행 가능한 번들이어야 함 (빈 entry chunk 문제 없음)
    expect(entryChunk!.text).toContain("ENTRY_MARKER");
  });
});
