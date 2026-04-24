import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { join } from "node:path";
import { createFixture } from "./helpers";
import { init, close, build } from "../../../packages/core/index";

// Phase 2 NAPI 브리지 integration 테스트 — JS manualChunks 함수가 Zig resolver 로
// 연결되는지 실제 번들 결과로 검증. Zig 유닛테스트 (bundler_test/manual_chunks.zig)
// 는 fake resolver 로 로직만 검증, 이 테스트는 NAPI TSFN 경로까지 전부 커버.

describe("manualChunks NAPI bridge", () => {
  let cleanup: (() => Promise<void>) | undefined;

  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("manualChunks 함수가 반환한 이름으로 청크 분리", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { a } from "./vendor-lib";
        import { b } from "./app-lib";
        console.log(a, b);
      `,
      "vendor-lib.ts": 'export const a = "VENDOR_MARKER";',
      "app-lib.ts": 'export const b = "APP_MARKER";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id) => {
        if (id.includes("vendor-lib")) return "vendor";
        return null;
      },
    });

    expect(result.outputFiles).toBeDefined();
    const outs = result.outputFiles!;

    const vendorChunk = outs.find((o) => o.text.includes("VENDOR_MARKER"));
    const appChunk = outs.find((o) => o.text.includes("APP_MARKER"));
    expect(vendorChunk).toBeDefined();
    expect(vendorChunk!.path).toContain("vendor");
    expect(appChunk).toBeDefined();
    expect(appChunk!.path).not.toContain("vendor");
  });

  test("manualChunks 가 null 반환 시 기존 자동 분배", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { a } from "./lib";
        console.log(a);
      `,
      "lib.ts": 'export const a = "ONLY_MARKER";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: () => null,
    });

    const outs = result.outputFiles!;
    // dynamic import 없으므로 단일 청크
    expect(outs.length).toBe(1);
    expect(outs[0].text).toContain("ONLY_MARKER");
  });

  test("manualChunks 없으면 JS 함수 호출 없이 정상 번들", async () => {
    const fixture = await createFixture({
      "entry.ts": 'console.log("NO_MANUAL");',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
    });

    const outs = result.outputFiles!;
    expect(outs.length).toBe(1);
    expect(outs[0].text).toContain("NO_MANUAL");
  });
});
