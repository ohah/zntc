import { describe, test, expect, beforeAll, afterAll, afterEach } from "bun:test";
import { join } from "node:path";
import { createFixture } from "./helpers";
import { init, close, build } from "../../../packages/core/index";
import type { ManualChunksModuleInfo } from "../../../packages/core/index";

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

  // meta.getModuleInfo 를 각 모듈에 대해 호출해 pick 결과를 Map 으로 수집.
  async function collectMeta<T>(
    dir: string,
    entries: string[],
    pick: (info: ManualChunksModuleInfo) => T,
  ): Promise<Map<string, T>> {
    const seen = new Map<string, T>();
    await build({
      entryPoints: entries.map((e) => join(dir, e)),
      splitting: true,
      manualChunks: (id, meta) => {
        const info = meta.getModuleInfo(id);
        if (info) seen.set(id, pick(info));
        return null;
      },
    });
    return seen;
  }

  test("meta.getModuleInfo: 엔트리 모듈 isEntry=true, 일반 모듈 isEntry=false", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { a } from "./lib"; console.log(a);`,
      "lib.ts": 'export const a = "LIB";',
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.isEntry);
    const entryInfo = [...seen.entries()].find(([k]) => k.endsWith("entry.ts"));
    const libInfo = [...seen.entries()].find(([k]) => k.endsWith("lib.ts"));
    expect(entryInfo).toBeDefined();
    expect(libInfo).toBeDefined();
    expect(entryInfo![1]).toBe(true);
    expect(libInfo![1]).toBe(false);
  });

  test("meta.getModuleInfo: importers — 누가 이 모듈을 import 하는가", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { a } from "./shared"; console.log(a);`,
      "other.ts": `import { a } from "./shared"; export const x = a;`,
      "shared.ts": 'export const a = "S";',
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts", "other.ts"], (info) => info.importers);
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

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.importedIds);
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
      manualChunks: (id, meta) => {
        const info = meta.getModuleInfo(id);
        if (info && info.importers.length >= 2) return "shared-chunk";
        return null;
      },
    });

    const sharedChunk = result.outputFiles!.find((o) => o.path.includes("shared-chunk"));
    expect(sharedChunk).toBeDefined();
    expect(sharedChunk!.moduleIds!.some((id) => id.endsWith("shared.ts"))).toBe(true);
    // only-a, only-b 는 shared-chunk 에 안 들어감 (importers=1)
    expect(sharedChunk!.moduleIds!.every((id) => !id.includes("only-"))).toBe(true);
  });

  // ============================================================
  // meta API 경계값 / 토폴로지 / 실사용 패턴
  // ============================================================

  test("meta.getModuleInfo: 빈 문자열 / 존재하지 않는 경로 → null", async () => {
    const fixture = await createFixture({
      "entry.ts": "console.log(1);",
    });
    cleanup = fixture.cleanup;

    const results: Array<{ empty: unknown; missing: unknown }> = [];
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        results.push({
          empty: meta.getModuleInfo(""),
          missing: meta.getModuleInfo("/does-not-exist.ts"),
        });
        return null;
      },
    });

    expect(results.length).toBeGreaterThan(0);
    for (const r of results) {
      expect(r.empty).toBeNull();
      expect(r.missing).toBeNull();
    }
  });

  test("meta.getModuleInfo: resolver 안 다회 호출 안전 (NAPI reentrance)", async () => {
    const fixture = await createFixture({
      "entry.ts": 'import { a } from "./lib"; console.log(a);',
      "lib.ts": "export const a = 1;",
    });
    cleanup = fixture.cleanup;

    let callCount = 0;
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        // 동일 id 로 여러 번 + 서로 다른 id 로도 섞어서
        meta.getModuleInfo(id);
        meta.getModuleInfo(id);
        meta.getModuleInfo(id);
        callCount++;
        return null;
      },
    });
    expect(callCount).toBeGreaterThan(0);
  });

  test("meta.getModuleInfo: deep chain (A → B → C) 토폴로지", async () => {
    const fixture = await createFixture({
      "a.ts": 'import { b } from "./b"; console.log(b);',
      "b.ts": 'export { c as b } from "./c";',
      "c.ts": "export const c = 1;",
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["a.ts"], (info) => ({
      importers: info.importers,
      imported: info.importedIds,
    }));

    const a = [...seen.entries()].find(([k]) => k.endsWith("a.ts"))![1];
    const b = [...seen.entries()].find(([k]) => k.endsWith("b.ts"))![1];
    const c = [...seen.entries()].find(([k]) => k.endsWith("c.ts"))![1];

    expect(a.importers.length).toBe(0);
    expect(a.imported.some((p) => p.endsWith("b.ts"))).toBe(true);
    expect(b.importers.some((p) => p.endsWith("a.ts"))).toBe(true);
    expect(b.imported.some((p) => p.endsWith("c.ts"))).toBe(true);
    expect(c.importers.some((p) => p.endsWith("b.ts"))).toBe(true);
    expect(c.imported.length).toBe(0);
  });

  test("meta.getModuleInfo: 순환 의존 (A ↔ B) 양방향", async () => {
    const fixture = await createFixture({
      "a.ts": 'import { b } from "./b"; export const a = b + 1;',
      "b.ts": 'import { a } from "./a"; export const b = 1; export const ab = a;',
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["a.ts"], (info) => ({
      importers: info.importers,
      imported: info.importedIds,
    }));

    const a = [...seen.entries()].find(([k]) => k.endsWith("a.ts"))![1];
    const b = [...seen.entries()].find(([k]) => k.endsWith("b.ts"))![1];
    expect(a.imported.some((p) => p.endsWith("b.ts"))).toBe(true);
    expect(a.importers.some((p) => p.endsWith("b.ts"))).toBe(true);
    expect(b.imported.some((p) => p.endsWith("a.ts"))).toBe(true);
    expect(b.importers.some((p) => p.endsWith("a.ts"))).toBe(true);
  });

  test("meta.getModuleInfo: dynamic import 는 importedIds 에 포함 안 됨 (Rollup 스펙)", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { s } from "./static-dep";
        export async function load() { return (await import("./dynamic-dep")).default; }
        console.log(s);
      `,
      "static-dep.ts": "export const s = 1;",
      "dynamic-dep.ts": 'export default "DYNAMIC";',
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.importedIds);
    const entryIds = [...seen.entries()].find(([k]) => k.endsWith("entry.ts"))![1];
    expect(entryIds.some((p) => p.endsWith("static-dep.ts"))).toBe(true);
    expect(entryIds.some((p) => p.endsWith("dynamic-dep.ts"))).toBe(false);
  });

  test("meta.getModuleInfo: 엔트리가 자기 자신 조회 시 isEntry=true", async () => {
    const fixture = await createFixture({
      "entry.ts": "console.log(1);",
    });
    cleanup = fixture.cleanup;

    let entryIsEntry: boolean | undefined;
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          entryIsEntry = meta.getModuleInfo(id)?.isEntry;
        }
        return null;
      },
    });
    expect(entryIsEntry).toBe(true);
  });

  test("meta.getModuleInfo: 일부 모듈에서만 조회해도 나머지 정상 번들 (lazy 패턴)", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { a } from "./a";
        import { b } from "./b";
        import { c } from "./c";
        console.log(a, b, c);
      `,
      "a.ts": 'export const a = "A_MARK";',
      "b.ts": 'export const b = "B_MARK";',
      "c.ts": 'export const c = "C_MARK";',
    });
    cleanup = fixture.cleanup;

    // b.ts 에서만 meta.getModuleInfo 호출. 나머지는 touch 안 함.
    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("b.ts")) {
          void meta.getModuleInfo(id);
        }
        return null;
      },
    });

    const all = result.outputFiles!.map((o) => o.text).join("\n");
    expect(all).toContain("A_MARK");
    expect(all).toContain("B_MARK");
    expect(all).toContain("C_MARK");
  });

  test("meta.getModuleInfo: entry.dynamicallyImportedIds — entry 가 dynamic 으로 import 하는 것", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { s } from "./static-dep";
        export async function load() { return (await import("./dyn-dep")).default; }
        console.log(s);
      `,
      "static-dep.ts": "export const s = 1;",
      "dyn-dep.ts": "export default 42;",
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => ({
      imported: info.importedIds,
      dyn: info.dynamicallyImportedIds,
    }));
    const entry = [...seen.entries()].find(([k]) => k.endsWith("entry.ts"))![1];
    expect(entry.imported.some((p) => p.endsWith("static-dep.ts"))).toBe(true);
    expect(entry.imported.some((p) => p.endsWith("dyn-dep.ts"))).toBe(false);
    expect(entry.dyn.some((p) => p.endsWith("dyn-dep.ts"))).toBe(true);
    expect(entry.dyn.some((p) => p.endsWith("static-dep.ts"))).toBe(false);
  });

  test("meta.getModuleInfo: dynamic-dep.dynamicImporters — 누가 dynamic 으로 import 하는가", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        async function main() {
          const m = await import("./dyn-dep");
          console.log(m.default);
        }
        main();
      `,
      "dyn-dep.ts": 'export default "DYN_VALUE";',
    });
    cleanup = fixture.cleanup;

    // dyn-dep 은 resolver 호출에서 제외되는 dynamic entry 라 직접 조회가 안 된다.
    // 대신 entry resolver 안에서 entry.dynamicallyImportedIds 로 dyn-dep 의 실제 저장 경로를
    // 받아 그대로 조회 (macOS /private prefix 같은 경로 정규화 이슈 회피).
    const results: Array<{ importers: string[]; dynamicImporters: string[] }> = [];
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        if (!id.endsWith("entry.ts")) return null;
        const entryInfo = meta.getModuleInfo(id);
        if (!entryInfo) return null;
        const dynPath = entryInfo.dynamicallyImportedIds.find((p) => p.endsWith("dyn-dep.ts"));
        if (!dynPath) return null;
        const info = meta.getModuleInfo(dynPath);
        if (info) {
          results.push({ importers: info.importers, dynamicImporters: info.dynamicImporters });
        }
        return null;
      },
    });

    expect(results.length).toBe(1);
    expect(results[0].importers.length).toBe(0);
    expect(results[0].dynamicImporters.length).toBe(1);
    expect(results[0].dynamicImporters[0].endsWith("entry.ts")).toBe(true);
  });

  test("meta.getModuleInfo: external 모듈도 phantom 으로 graph 에 등록 + isExternal=true", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { x } from "external-pkg"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    const observed: { id: string; isExternal: boolean }[] = [];
    let entryImportedIds: string[] = [];
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["external-pkg"],
      splitting: true,
      manualChunks: (id, meta) => {
        const info = meta.getModuleInfo(id);
        if (info) observed.push({ id: info.id, isExternal: info.isExternal });
        if (id.endsWith("entry.ts") && info) entryImportedIds = info.importedIds;
        // external 도 직접 조회 가능해야 함
        const ext = meta.getModuleInfo("external-pkg");
        if (ext) observed.push({ id: ext.id, isExternal: ext.isExternal });
        return null;
      },
    });

    // external phantom 은 resolver 에 직접 안 옴 (modulesIterator 가 외부도 보지만
    // 정책상 chunk 배정 받지 않으므로 manual_chunks resolver loop 는 외부 가드 추가 가능 —
    // 일단 entry resolver 안에서 external-pkg 를 lookup 해 검증).
    const ext = observed.find((o) => o.id === "external-pkg");
    expect(ext).toBeDefined();
    expect(ext!.isExternal).toBe(true);

    // entry 의 importedIds 에 external-pkg 가 포함됨 (Rollup parity)
    expect(entryImportedIds.some((i) => i === "external-pkg")).toBe(true);
  });
});
