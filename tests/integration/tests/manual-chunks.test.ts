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

  test("resolver 호출 횟수 = 모듈 수 (중복 없음)", async () => {
    // 20개 모듈 fixture 에서 resolver 가 정확히 모듈 수만큼 호출되는지.
    // NAPI TSFN 호출은 비싸므로 pre-pass 캐싱이 작동하는지 검증.
    const files: Record<string, string> = {
      "entry.ts": "",
    };
    const imports: string[] = [];
    const usages: string[] = [];
    for (let i = 0; i < 20; i++) {
      files[`mod${i}.ts`] = `export const v${i} = "M${i}";`;
      imports.push(`import { v${i} } from "./mod${i}";`);
      usages.push(`v${i}`);
    }
    files["entry.ts"] = imports.join("\n") + `\nconsole.log(${usages.join(", ")});`;

    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;

    const seen = new Map<string, number>();
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id) => {
        seen.set(id, (seen.get(id) ?? 0) + 1);
        return null;
      },
    });

    // entry + 20 modules = 21 모듈. 각 1회씩 호출.
    expect(seen.size).toBe(21);
    for (const count of seen.values()) expect(count).toBe(1);
  });

  test("resolver 가 throw 하면 번들이 중단되지 않고 null 로 처리", async () => {
    // JS function throw 는 TSFN 경로에서 catch — 해당 모듈을 null 취급 (auto 분배).
    const fixture = await createFixture({
      "entry.ts": 'import { x } from "./lib"; console.log(x);',
      "lib.ts": 'export const x = "LIB_MARKER";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id) => {
        if (id.includes("lib")) throw new Error("nope");
        return null;
      },
    });

    // throw 된 모듈도 null 처리라 auto 분배 — 단일 청크 유지, 번들 성공
    const outs = result.outputFiles!;
    expect(outs.length).toBe(1);
    expect(outs[0].text).toContain("LIB_MARKER");
  });

  test("Non-string 반환 (undefined, 0, false) 는 null 동일 취급", async () => {
    // Rollup 스펙 — null/undefined/void 모두 auto 분배. 숫자/boolean 은 spec 외.
    // ZTS 구현은 string 만 accept, 나머지는 null 취급.
    const fixture = await createFixture({
      "entry.ts": `
        import { a } from "./mod-a";
        import { b } from "./mod-b";
        import { c } from "./mod-c";
        console.log(a, b, c);
      `,
      "mod-a.ts": 'export const a = "A_MARKER";',
      "mod-b.ts": 'export const b = "B_MARKER";',
      "mod-c.ts": 'export const c = "C_MARKER";',
    });
    cleanup = fixture.cleanup;

    let call = 0;
    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      manualChunks: ((id: string): any => {
        if (id.includes("mod-a")) return undefined;
        if (id.includes("mod-b")) return 0;
        if (id.includes("mod-c")) return false;
        return null;
      }) as (id: string) => string | null | undefined,
    });

    void call;
    // 모든 모듈이 null 취급되어 단일 청크
    const outs = result.outputFiles!;
    expect(outs.length).toBe(1);
    expect(outs[0].text).toContain("A_MARKER");
    expect(outs[0].text).toContain("B_MARKER");
    expect(outs[0].text).toContain("C_MARKER");
  });

  // ============================================================
  // manualChunks(id, meta) — Rollup/rolldown 호환 meta 파라미터
  // ============================================================

  test("meta.getModuleInfo: 엔트리 모듈 isEntry=true, 일반 모듈 isEntry=false", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { a } from "./lib"; console.log(a);`,
      "lib.ts": 'export const a = "LIB";',
    });
    cleanup = fixture.cleanup;

    const entryPath = join(fixture.dir, "entry.ts");
    const seen = new Map<string, { isEntry: boolean }>();
    await build({
      entryPoints: [entryPath],
      splitting: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      manualChunks: ((id: string, meta: any) => {
        const info = meta?.getModuleInfo?.(id);
        if (info) seen.set(id, { isEntry: info.isEntry });
        return null;
      }) as (id: string) => string | null,
    });

    const entryInfo = [...seen.entries()].find(([k]) => k.endsWith("entry.ts"));
    const libInfo = [...seen.entries()].find(([k]) => k.endsWith("lib.ts"));
    expect(entryInfo).toBeDefined();
    expect(libInfo).toBeDefined();
    expect(entryInfo![1].isEntry).toBe(true);
    expect(libInfo![1].isEntry).toBe(false);
  });

  test("meta.getModuleInfo: importers — 누가 이 모듈을 import 하는가", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { a } from "./shared"; console.log(a);`,
      "other.ts": `import { a } from "./shared"; export const x = a;`,
      "shared.ts": 'export const a = "S";',
    });
    cleanup = fixture.cleanup;

    // 두 엔트리 — shared 는 양쪽에서 import
    const seen = new Map<string, string[]>();
    await build({
      entryPoints: [join(fixture.dir, "entry.ts"), join(fixture.dir, "other.ts")],
      splitting: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      manualChunks: ((id: string, meta: any) => {
        const info = meta?.getModuleInfo?.(id);
        if (info) seen.set(id, info.importers ?? []);
        return null;
      }) as (id: string) => string | null,
    });

    const sharedEntry = [...seen.entries()].find(([k]) => k.endsWith("shared.ts"));
    expect(sharedEntry).toBeDefined();
    const importers = sharedEntry![1];
    expect(importers.length).toBe(2);
    expect(importers.some((p) => p.endsWith("entry.ts"))).toBe(true);
    expect(importers.some((p) => p.endsWith("other.ts"))).toBe(true);
  });

  test("meta.getModuleInfo: importedIds — 이 모듈이 import 하는 것", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { a } from "./foo";
        import { b } from "./bar";
        console.log(a, b);
      `,
      "foo.ts": 'export const a = "FOO";',
      "bar.ts": 'export const b = "BAR";',
    });
    cleanup = fixture.cleanup;

    const seen = new Map<string, string[]>();
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      manualChunks: ((id: string, meta: any) => {
        const info = meta?.getModuleInfo?.(id);
        if (info) seen.set(id, info.importedIds ?? []);
        return null;
      }) as (id: string) => string | null,
    });

    const entryIds = [...seen.entries()].find(([k]) => k.endsWith("entry.ts"))![1];
    expect(entryIds.length).toBe(2);
    expect(entryIds.some((p) => p.endsWith("foo.ts"))).toBe(true);
    expect(entryIds.some((p) => p.endsWith("bar.ts"))).toBe(true);
  });

  test("meta 기반 실용 패턴: shared 모듈만 vendor 로", async () => {
    // 실전 "importers 수 >= 2 면 shared 로" 패턴 — 자동 청크 분할 규칙 커스터마이즈
    const fixture = await createFixture({
      "pageA.ts": `import { s } from "./shared"; import { a } from "./only-a"; console.log(s, a);`,
      "pageB.ts": `import { s } from "./shared"; import { b } from "./only-b"; console.log(s, b);`,
      "shared.ts": 'export const s = "SHARED";',
      "only-a.ts": 'export const a = "A";',
      "only-b.ts": 'export const b = "B";',
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "pageA.ts"), join(fixture.dir, "pageB.ts")],
      splitting: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      manualChunks: ((id: string, meta: any) => {
        const info = meta?.getModuleInfo?.(id);
        if (info && info.importers && info.importers.length >= 2) return "shared-chunk";
        return null;
      }) as (id: string) => string | null,
    });

    const sharedChunk = result.outputFiles!.find((o) => o.path.includes("shared-chunk"));
    expect(sharedChunk).toBeDefined();
    expect(sharedChunk!.moduleIds!.some((id) => id.endsWith("shared.ts"))).toBe(true);
    // only-a, only-b 는 shared-chunk 에 안 들어감 (importers=1)
    expect(sharedChunk!.moduleIds!.every((id) => !id.includes("only-"))).toBe(true);
  });
});
