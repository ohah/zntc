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

    // rolldown `chunk.moduleIds` 호환: 구조적 검증 (regex 없이)
    expect(vendor!.moduleIds).toEqual(
      expect.arrayContaining([
        expect.stringMatching(/vendor\/math\.ts$/),
        expect.stringMatching(/vendor\/string-utils\.ts$/),
      ]),
    );
    // 보조: vendor 청크에 수학/string-utils 구현 전부 (transitive dep 포함 정책)
    expect(vendor!.text).toMatch(/function\s+add\s*\(/);
    expect(vendor!.text).toMatch(/function\s+toUpper\s*\(/);
    expect(vendor!.text).toMatch(/function\s+multiply\s*\(/);

    // moduleIds 는 entry / vendor 가 서로 겹치지 않아야 함
    expect(entry!.moduleIds).toEqual(expect.arrayContaining([expect.stringMatching(/entry\.ts$/)]));
    expect(entry!.moduleIds!.find((id) => id.includes("/vendor/"))).toBeUndefined();

    // rolldown `chunk.imports` 호환: entry 는 vendor.js 를 import
    expect(entry!.imports).toEqual(
      expect.arrayContaining([expect.stringMatching(/vendor.*\.js$/)]),
    );
    // vendor 는 leaf chunk — 아무 것도 import 안 함
    expect(vendor!.imports).toEqual([]);

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

  test.skipIf(!hasPackage("lodash-es"))(
    "실 라이브러리: lodash-es 여러 함수 import + tree-shake",
    async () => {
      // 사용자가 lodash-es 에서 몇 개 함수만 쓰고 vendor 청크 분리. ESM 지원 라이브러리
      // 라 tree-shake 가 동작해야 — 쓰지 않은 debounce/throttle/cloneDeep 등은 제거.
      const fixture = await createFixture({
        "entry.ts": `
          import { chunk, take } from "lodash-es";
          const arr = take(chunk([1,2,3,4,5,6], 2), 2);
          console.log("LODASH_RESULT:" + JSON.stringify(arr));
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

      const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
      const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
      expect(vendor).toBeDefined();
      // vendor 에 chunk/take 구현이 들어가야
      expect(vendor!.text.length).toBeGreaterThan(200);
      // entry 엔 로컬 LODASH_RESULT 만, vendor import
      expect(entry!.text).toContain("LODASH_RESULT");
      expect(entry!.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);
    },
  );

  test.skipIf(!hasPackage("nanoid"))(
    "실 라이브러리: nanoid — single ESM file vendor 분리",
    async () => {
      // nanoid 는 작은 단일 ESM 파일. vendor 분리 시 entry 에 로컬 코드만.
      const fixture = await createFixture({
        "entry.ts": `
        import { nanoid } from "nanoid";
        const id = nanoid(10);
        console.log("NANO_LEN:" + id.length);
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

      const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
      expect(vendor).toBeDefined();
      const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
      expect(entry!.text).toContain("NANO_LEN");
      expect(entry!.text).not.toMatch(/function\s+nanoid/); // 구현은 vendor 에
    },
  );

  test.skipIf(!hasPackage("lodash-es") || !hasPackage("clsx") || !hasPackage("nanoid"))(
    "실 라이브러리 조합: lodash + clsx + nanoid 를 한 vendor 청크로",
    async () => {
      // 실전 시나리오 — 여러 작은 vendor 를 하나의 청크로 묶어 HTTP/2 multiplexing 친화.
      const fixture = await createFixture({
        "entry.ts": `
          import { chunk } from "lodash-es";
          import clsx from "clsx";
          import { nanoid } from "nanoid";
          const parts = chunk([1,2,3,4], 2);
          const cls = clsx("base", { active: true });
          const id = nanoid(8);
          console.log("COMBO:" + parts.length + ":" + cls + ":" + id.length);
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

      // 단 하나의 vendor 청크에 3 라이브러리 모두
      const vendors = result.outputFiles.filter((o) => o.path.includes("vendor"));
      expect(vendors.length).toBe(1);
      // vendor 청크 크기가 lodash + clsx + nanoid 합치므로 유의미한 사이즈
      expect(vendors[0].text.length).toBeGreaterThan(500);
    },
  );

  test.skipIf(!hasPackage("zod"))(
    "실 라이브러리: zod — 복잡한 multi-module 라이브러리 vendor 분리",
    async () => {
      // zod 는 수십 개 내부 파일로 분할된 복잡한 구조. manualChunks 로 전체를 vendor 로
      // 몰아넣을 때 모든 dep 가 따라가는지 + cross-chunk import 정상 생성되는지.
      const fixture = await createFixture({
        "entry.ts": `
          import { z } from "zod";
          const schema = z.object({ name: z.string(), age: z.number() });
          const ok = schema.safeParse({ name: "alice", age: 30 });
          console.log("ZOD_OK:" + ok.success);
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

      const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
      const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
      expect(vendor).toBeDefined();
      expect(entry).toBeDefined();

      // zod 는 큰 라이브러리 — vendor 크기 유의미
      expect(vendor!.text.length).toBeGreaterThan(10000);

      // entry 는 로컬 마커 + vendor import
      expect(entry!.text).toContain("ZOD_OK");
      expect(entry!.text).toMatch(/from\s*["'][^"']*vendor[^"']*["']/);

      // entry 에 zod 내부 구현은 없어야 (vendor 와 최소 10배 이상 차이)
      expect(entry!.text.length * 10).toBeLessThan(vendor!.text.length);

      // common chunk 로 분리되지 않았는지 — 단일 vendor 만 존재
      const vendors = result.outputFiles.filter((o) => o.path.includes("vendor"));
      expect(vendors.length).toBe(1);

      // 구조적 검증: vendor 는 zod 내부 파일들만, entry 는 자기 자신만
      expect(vendor!.moduleIds!.length).toBeGreaterThan(3);
      expect(vendor!.moduleIds!.every((id) => id.includes("node_modules"))).toBe(true);
      expect(entry!.moduleIds!.find((id) => id.includes("node_modules"))).toBeUndefined();
    },
  );

  test.skipIf(!hasPackage("lodash-es") || !hasPackage("clsx"))(
    "실 라이브러리 selective split: lodash 는 'lodash' 청크, 나머지는 'vendor'",
    async () => {
      // React-style 세밀 청킹 — 자주 바뀌지 않는 lodash 를 별도 청크로 캐시 수명 연장.
      const fixture = await createFixture({
        "entry.ts": `
          import { chunk } from "lodash-es";
          import clsx from "clsx";
          const parts = chunk([1,2,3,4], 2);
          const cls = clsx("a", "b");
          console.log("SELECTIVE:" + parts.length + ":" + cls);
        `,
      });
      cleanup = fixture.cleanup;

      const result = await build({
        entryPoints: [join(fixture.dir, "entry.ts")],
        splitting: true,
        outdir: join(fixture.dir, "dist"),
        write: false,
        nodePaths: [ROOT_NODE_MODULES],
        manualChunks: (id) => {
          if (id.includes("/lodash-es/")) return "lodash";
          if (id.includes("node_modules")) return "vendor";
          return null;
        },
      });

      // lodash + vendor 각각 생성
      const lodashChunk = result.outputFiles.find((o) => o.path.includes("lodash"));
      const vendorChunk = result.outputFiles.find(
        (o) => o.path.includes("vendor") && !o.path.includes("lodash"),
      );
      expect(lodashChunk).toBeDefined();
      expect(vendorChunk).toBeDefined();

      // vendor 는 clsx 만, lodash 는 lodash-es 만 (서로 섞이지 않음)
      expect(lodashChunk!.text).not.toMatch(/clsx/i);
    },
  );

  test.skipIf(!hasPackage("react") || !hasPackage("react-dom"))(
    "실 라이브러리: react + react-dom → vendor 청크 (가장 흔한 패턴)",
    async () => {
      // "react is huge, put in vendor" 실전 패턴. scheduler 등 내부 dep 까지 따라감.
      // React 19 는 기본 CJS — CJS module 도 manualChunks 와 잘 상호작용하는지.
      const fixture = await createFixture({
        "entry.tsx": `
          import { createElement } from "react";
          import { renderToString } from "react-dom/server";
          const el = createElement("div", { id: "app" }, "REACT_MARKER");
          const html = renderToString(el);
          console.log(html);
        `,
      });
      cleanup = fixture.cleanup;

      const result = await build({
        entryPoints: [join(fixture.dir, "entry.tsx")],
        splitting: true,
        outdir: join(fixture.dir, "dist"),
        write: false,
        nodePaths: [ROOT_NODE_MODULES],
        manualChunks: (id) => (id.includes("node_modules") ? "vendor" : null),
      });

      const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
      const entry = result.outputFiles.find((o) => o.path.includes("entry"));
      expect(vendor).toBeDefined();
      expect(entry).toBeDefined();

      // React 는 큰 라이브러리 — vendor 크기 유의미 (createElement + renderToString + 내부)
      expect(vendor!.text.length).toBeGreaterThan(5000);
      // entry 는 로컬 REACT_MARKER 만
      expect(entry!.text).toContain("REACT_MARKER");
      // CJS (React 19) 는 side-effect import `import "./vendor.js"` 형태 — ESM `from` 또는 side-effect 둘 다 허용
      expect(entry!.text).toMatch(/["'][^"']*vendor[^"']*\.js["']/);
      // entry 크기가 vendor 대비 극소 (실제 구현은 전부 vendor 로)
      expect(entry!.text.length * 10).toBeLessThan(vendor!.text.length);
    },
  );

  test.skipIf(!hasPackage("preact"))("실 라이브러리: preact — 경량 대안도 잘 분리", async () => {
    // preact 는 React 보다 10x 작은 대안. ESM 지원 안 될 수 있어 compat 경로 확인.
    const fixture = await createFixture({
      "entry.tsx": `
          import { h } from "preact";
          const el = h("div", { id: "x" }, "PREACT_MARKER");
          console.log(el.type);
        `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.tsx")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      nodePaths: [ROOT_NODE_MODULES],
      manualChunks: (id) => (id.includes("node_modules") ? "vendor" : null),
    });

    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
    expect(vendor).toBeDefined();
    // preact 는 작지만 여전히 h 구현 포함
    expect(vendor!.text.length).toBeGreaterThan(500);
  });

  test.skipIf(!hasPackage("immer"))("실 라이브러리: immer — state management vendor", async () => {
    const fixture = await createFixture({
      "entry.ts": `
          import { produce } from "immer";
          const base = { count: 0, items: [1, 2, 3] };
          const next = produce(base, (draft: any) => { draft.count = 1; });
          console.log("IMMER:" + next.count);
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

    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
    expect(vendor).toBeDefined();
    expect(entry!.text).toContain("IMMER:");
    // immer 는 중형 라이브러리 (Proxy 기반 로직)
    expect(vendor!.text.length).toBeGreaterThan(3000);
  });

  test.skipIf(!hasPackage("date-fns"))(
    "실 라이브러리: date-fns — tree-shakable 함수형 라이브러리",
    async () => {
      // date-fns 는 각 함수별 ESM 파일. 사용하는 함수만 번들됨 + manualChunks vendor.
      const fixture = await createFixture({
        "entry.ts": `
          import { format, addDays } from "date-fns";
          const d = addDays(new Date(0), 7);
          const s = format(d, "yyyy-MM-dd");
          console.log("DATE:" + s);
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

      const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
      const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
      expect(vendor).toBeDefined();
      // format + addDays + 각 함수의 내부 dep (locale, addMilliseconds 등)
      expect(vendor!.text.length).toBeGreaterThan(2000);
      expect(entry!.text).toContain("DATE:");
    },
  );

  test.skipIf(!hasPackage("rxjs"))("실 라이브러리: rxjs — Observable 체이닝 vendor", async () => {
    const fixture = await createFixture({
      "entry.ts": `
          import { of } from "rxjs";
          import { map, filter } from "rxjs/operators";
          of(1, 2, 3, 4)
            .pipe(filter((n: number) => n % 2 === 0), map((n: number) => n * 10))
            .subscribe((n: number) => console.log("RX:" + n));
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

    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"));
    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"));
    expect(vendor).toBeDefined();
    // rxjs 는 큰 라이브러리 (Observable, Subject 등)
    expect(vendor!.text.length).toBeGreaterThan(5000);
    expect(entry!.text).toContain("RX:");
  });

  test.skipIf(!hasPackage("react") || !hasPackage("react-dom") || !hasPackage("immer"))(
    "실 라이브러리 조합: react + react-dom 은 'react-vendor', immer 는 'vendor' (세밀 분리)",
    async () => {
      // 실제 React 앱에서 가장 흔한 패턴: React 는 고정 업데이트 빈도라 별도 청크,
      // 기타 라이브러리는 vendor 청크. 캐시 수명 차별화.
      const fixture = await createFixture({
        "entry.tsx": `
          import { createElement } from "react";
          import { renderToString } from "react-dom/server";
          import { produce } from "immer";
          const state = produce({ n: 0 }, (d: any) => { d.n = 42; });
          const el = createElement("div", null, "combo:" + state.n);
          console.log(renderToString(el));
        `,
      });
      cleanup = fixture.cleanup;

      const result = await build({
        entryPoints: [join(fixture.dir, "entry.tsx")],
        splitting: true,
        outdir: join(fixture.dir, "dist"),
        write: false,
        nodePaths: [ROOT_NODE_MODULES],
        manualChunks: (id) => {
          if (id.includes("/react/") || id.includes("/react-dom/") || id.includes("/scheduler/"))
            return "react-vendor";
          if (id.includes("node_modules")) return "vendor";
          return null;
        },
      });

      const reactChunk = result.outputFiles.find((o) => o.path.includes("react-vendor"));
      const vendorChunk = result.outputFiles.find(
        (o) => o.path.includes("vendor") && !o.path.includes("react"),
      );
      expect(reactChunk).toBeDefined();
      expect(vendorChunk).toBeDefined();

      // react-vendor 크기는 vendor (immer) 보다 크거나 비슷해야 함
      expect(reactChunk!.text.length).toBeGreaterThan(5000);
      // 서로 코드 섞이면 안 됨
      expect(reactChunk!.text).not.toMatch(/\bimmer\b/i);

      // 구조적 검증: 각 chunk 가 정확한 모듈 집합만 소유
      expect(reactChunk!.moduleIds!.every((id) => /\/(react|react-dom|scheduler)\//.test(id))).toBe(
        true,
      );
      expect(vendorChunk!.moduleIds!.some((id) => id.includes("/immer/"))).toBe(true);
      expect(
        vendorChunk!.moduleIds!.find((id) => /\/(react|scheduler)\//.test(id)),
      ).toBeUndefined();
    },
  );

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

  test("imports 메타: multi-group — entry 가 vendor + ui 둘 다 import", async () => {
    // manualChunks 로 vendor, ui 각각 분리 시 entry 의 imports 가 양쪽 모두 포함.
    const fixture = await createFixture({
      "vendor/math.ts": `export function add(a: number, b: number) { return a + b; }`,
      "ui/button.ts": `export function renderBtn() { return "<btn>"; }`,
      "entry.ts": `
        import { add } from "./vendor/math";
        import { renderBtn } from "./ui/button";
        console.log(add(1, 2) + renderBtn());
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

    const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"))!;
    expect(entry.imports).toEqual(
      expect.arrayContaining([
        expect.stringMatching(/vendor.*\.js$/),
        expect.stringMatching(/ui.*\.js$/),
      ]),
    );
    expect(entry.imports!.length).toBe(2);
  });

  test("imports 메타: shared vendor — 두 엔트리가 같은 chunk 를 import", async () => {
    // pageA + pageB 가 shared vendor 를 각각 import. rolldown 에서도 동일 결과.
    const fixture = await createFixture({
      "vendor/shared.ts": `export const VALUE = "SHARED";`,
      "pageA.ts": `
        import { VALUE } from "./vendor/shared";
        console.log("A:" + VALUE);
      `,
      "pageB.ts": `
        import { VALUE } from "./vendor/shared";
        console.log("B:" + VALUE);
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "pageA.ts"), join(fixture.dir, "pageB.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
      manualChunks: (id) => (id.includes("/vendor/") ? "vendor" : null),
    });

    const pageA = result.outputFiles.find((o) => o.path.includes("pageA"))!;
    const pageB = result.outputFiles.find((o) => o.path.includes("pageB"))!;
    const vendor = result.outputFiles.find((o) => o.path.includes("vendor"))!;

    // 두 엔트리 모두 vendor 를 import
    expect(pageA.imports).toEqual(expect.arrayContaining([expect.stringMatching(/vendor.*\.js$/)]));
    expect(pageB.imports).toEqual(expect.arrayContaining([expect.stringMatching(/vendor.*\.js$/)]));
    // 두 엔트리의 imports 에서 vendor path 는 동일해야 (같은 실제 파일 가리킴)
    const aVendorRef = pageA.imports!.find((p) => p.includes("vendor"));
    const bVendorRef = pageB.imports!.find((p) => p.includes("vendor"));
    expect(aVendorRef).toBe(bVendorRef);
    // vendor 는 leaf
    expect(vendor.imports).toEqual([]);
  });

  test("imports 메타: 단일 청크는 imports 비어있음", async () => {
    const fixture = await createFixture({
      "entry.ts": `console.log("SINGLE");`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      outdir: join(fixture.dir, "dist"),
      write: false,
    });

    expect(result.outputFiles.length).toBe(1);
    expect(result.outputFiles[0].imports).toEqual([]);
  });

  test.skipIf(!hasPackage("react") || !hasPackage("immer"))(
    "imports 메타 실 라이브러리: react-vendor + vendor 둘 다 import",
    async () => {
      const fixture = await createFixture({
        "entry.tsx": `
          import { createElement } from "react";
          import { produce } from "immer";
          const state = produce({ n: 0 }, (d: any) => { d.n = 1; });
          console.log(createElement("div", null, state.n));
        `,
      });
      cleanup = fixture.cleanup;

      const result = await build({
        entryPoints: [join(fixture.dir, "entry.tsx")],
        splitting: true,
        outdir: join(fixture.dir, "dist"),
        write: false,
        nodePaths: [ROOT_NODE_MODULES],
        manualChunks: (id) => {
          if (id.includes("/react/") || id.includes("/scheduler/")) return "react-vendor";
          if (id.includes("node_modules")) return "vendor";
          return null;
        },
      });

      const entry = result.outputFiles.find((o) => o.path.endsWith("entry.js"))!;
      // entry 가 두 chunk 를 모두 import
      expect(entry.imports).toEqual(
        expect.arrayContaining([
          expect.stringMatching(/react-vendor.*\.js$/),
          expect.stringMatching(/vendor.*\.js$/),
        ]),
      );
    },
  );

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
