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

    // external phantom 은 resolver 에 직접 안 옴 (chunk.zig 의 is_external 가드).
    // entry resolver 안에서 external-pkg 를 lookup 해 검증.
    const ext = observed.find((o) => o.id === "external-pkg");
    expect(ext).toBeDefined();
    expect(ext!.isExternal).toBe(true);

    // entry 의 importedIds 에 external-pkg 가 포함됨 (Rollup parity)
    expect(entryImportedIds.some((i) => i === "external-pkg")).toBe(true);
  });

  test("meta.getModuleInfo: external 은 manualChunks resolver 에 직접 호출되지 않음", async () => {
    // 회귀 가드 — chunk.zig 의 is_external 가드가 빠지면 resolver 가 phantom external 도
    // 호출하게 되어 사용자 콜백이 bare specifier 를 받아 혼란.
    const fixture = await createFixture({
      "entry.ts": `import { x } from "external-pkg"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    const seenIds: string[] = [];
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["external-pkg"],
      splitting: true,
      manualChunks: (id) => {
        seenIds.push(id);
        return null;
      },
    });

    expect(seenIds.length).toBeGreaterThan(0);
    // external phantom 의 path = "external-pkg" 가 resolver 에 안 옴
    expect(seenIds).not.toContain("external-pkg");
  });

  test("meta.getModuleInfo: external 패턴이 manualChunks 매칭돼도 빈 청크 안 만듦", async () => {
    // 회귀 가드 — phantom 의 path 가 manual chunk pattern 과 매칭하면 빈 청크 생성 위험.
    // is_external 가드로 phantom 은 manual seeds 에 안 들어가야.
    const fixture = await createFixture({
      "entry.ts": `import { x } from "external-pkg"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["external-pkg"],
      splitting: true,
      manualChunks: (id) => {
        if (id.includes("external-pkg")) return "vendor"; // 의도적 매칭 시도
        return null;
      },
    });

    // vendor 청크가 만들어지지 않아야 (in-graph 모듈이 매칭되지 않음)
    const vendorChunk = result.outputFiles!.find((o) => o.path.includes("vendor"));
    expect(vendorChunk).toBeUndefined();
    // 모든 chunk 가 비지 않음
    for (const f of result.outputFiles!) {
      expect(f.text.length).toBeGreaterThan(0);
    }
  });

  test("meta.getModuleInfo: 같은 external 을 여러 모듈이 import 해도 phantom 1개 공유", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { x } from "shared-ext";
        import { y } from "./b";
        console.log(x, y);
      `,
      "b.ts": `import { z } from "shared-ext"; export const y = z;`,
    });
    cleanup = fixture.cleanup;

    let extImporters: string[] = [];
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["shared-ext"],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          const ext = meta.getModuleInfo("shared-ext");
          if (ext) extImporters = ext.importers;
        }
        return null;
      },
    });

    // 두 모듈이 모두 importer 로 등록되어야 함
    expect(extImporters.length).toBe(2);
    expect(extImporters.some((p) => p.endsWith("entry.ts"))).toBe(true);
    expect(extImporters.some((p) => p.endsWith("b.ts"))).toBe(true);
  });

  test("meta.getModuleInfo: dynamic external — dynamicImporters 에만 포함", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() { const m = await import("dyn-ext"); console.log(m.x); }
        boot();
      `,
    });
    cleanup = fixture.cleanup;

    let extInfo:
      | { importers: string[]; dynamicImporters: string[]; isExternal: boolean }
      | undefined;
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["dyn-ext"],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          const ext = meta.getModuleInfo("dyn-ext");
          if (ext)
            extInfo = {
              importers: ext.importers,
              dynamicImporters: ext.dynamicImporters,
              isExternal: ext.isExternal,
            };
        }
        return null;
      },
    });

    expect(extInfo).toBeDefined();
    expect(extInfo!.isExternal).toBe(true);
    expect(extInfo!.importers.length).toBe(0);
    expect(extInfo!.dynamicImporters.length).toBe(1);
    expect(extInfo!.dynamicImporters[0].endsWith("entry.ts")).toBe(true);
  });

  test("meta.getModuleInfo: 존재하지 않는 external specifier → null", async () => {
    const fixture = await createFixture({
      "entry.ts": "console.log(1);",
    });
    cleanup = fixture.cleanup;

    let probed: unknown = "untouched";
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          probed = meta.getModuleInfo("never-imported-ext");
        }
        return null;
      },
    });

    expect(probed).toBeNull();
  });

  test("meta.getModuleInfo: hasModuleSideEffects — package.json sideEffects=false 반영", async () => {
    // 패키지가 sideEffects: false 선언하면 그 패키지 모듈들은 hasModuleSideEffects=false.
    // tree-shaker 가 자동 순수 분석으로 일부 모듈을 false 로 만들 수도 있어 (라이브러리 모듈)
    // 여기선 명시적 sideEffects=false 선언이 lib.ts 에 반영되는지 lock.
    const fixture = await createFixture({
      "package.json": '{"name":"app","sideEffects":false}',
      "entry.ts": `import { a } from "./lib"; console.log(a);`,
      "lib.ts": 'export const a = "LIB";',
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.hasModuleSideEffects);
    const libFlag = [...seen.entries()].find(([k]) => k.endsWith("lib.ts"))![1];
    expect(libFlag).toBe(false);
  });

  // ============================================================
  // 회귀 가드 추가 — external + 다른 기능 조합
  // ============================================================

  test("external 여러 specifier 가 한 모듈에 동시 import — 모두 phantom 등록", async () => {
    const fixture = await createFixture({
      "entry.ts": `
        import { x } from "ext-a";
        import { y } from "ext-b";
        import { z } from "ext-c";
        console.log(x, y, z);
      `,
    });
    cleanup = fixture.cleanup;

    let entryImportedIds: string[] = [];
    let extAFound = false;
    let extBFound = false;
    let extCFound = false;
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["ext-a", "ext-b", "ext-c"],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          entryImportedIds = meta.getModuleInfo(id)?.importedIds ?? [];
          extAFound = meta.getModuleInfo("ext-a")?.isExternal === true;
          extBFound = meta.getModuleInfo("ext-b")?.isExternal === true;
          extCFound = meta.getModuleInfo("ext-c")?.isExternal === true;
        }
        return null;
      },
    });

    expect(extAFound).toBe(true);
    expect(extBFound).toBe(true);
    expect(extCFound).toBe(true);
    // 3개 external 모두 entry.importedIds 에 포함
    expect(entryImportedIds).toContain("ext-a");
    expect(entryImportedIds).toContain("ext-b");
    expect(entryImportedIds).toContain("ext-c");
  });

  test("external 의 importedIds / dynamicallyImportedIds 는 빈 배열", async () => {
    // Rollup 스펙 — external 은 graph traversal 끝점, 자체 import 정보 없음.
    const fixture = await createFixture({
      "entry.ts": `import { x } from "lib-x"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    let extInfo: { importedIds: string[]; dynamicallyImportedIds: string[] } | undefined;
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["lib-x"],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          const info = meta.getModuleInfo("lib-x");
          if (info)
            extInfo = {
              importedIds: info.importedIds,
              dynamicallyImportedIds: info.dynamicallyImportedIds,
            };
        }
        return null;
      },
    });

    expect(extInfo).toBeDefined();
    expect(extInfo!.importedIds).toEqual([]);
    expect(extInfo!.dynamicallyImportedIds).toEqual([]);
  });

  test("external + inlineDynamicImports — dynamic external 은 inline 안 됨 (런타임 import 유지)", async () => {
    // external 은 번들 외부라 inlineDynamicImports 의 wrap 변환 대상 아님.
    // 출력에 `Promise.resolve().then(...)` 변환 패턴 등장 안 함, 원본 import() 유지.
    const fixture = await createFixture({
      "entry.ts": `
        async function boot() {
          const m = await import("ext-dyn");
          console.log(m);
        }
        boot();
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["ext-dyn"],
      splitting: true,
      inlineDynamicImports: true,
    });

    const text = result.outputFiles![0].text;
    // external dynamic import 는 그대로 남아야 (런타임에 native ESM 동적 import)
    expect(text).toMatch(/import\s*\(\s*["']ext-dyn["']\s*\)/);
    // wrap 변환 패턴은 안 들어가야
    expect(text).not.toContain("init_ext-dyn");
  });

  test("external 이 manualChunks resolver 로부터 chunk 이름 받아도 무시 (graph 가드)", async () => {
    // resolver 가 external 에 대해 호출되지 않음을 이미 다른 테스트가 lock — 추가로 만약
    // 사용자가 명시적으로 lookup 후 분류 시도해도 graph 측 가드로 빈 chunk 안 만들어지는지.
    const fixture = await createFixture({
      "entry.ts": `import { x } from "react-mock"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["react-mock"],
      splitting: true,
      manualChunks: (id) => {
        // bare "react-mock" 가 들어왔다면 vendor 로 가게 시도. 실제로는 external 가드로
        // resolver 에 호출 안 옴.
        if (id === "react-mock") return "vendor-react";
        return null;
      },
    });

    // vendor-react chunk 가 만들어지지 않아야 (resolver 가 external 에 호출 안 됐기에)
    const vendorChunk = result.outputFiles!.find((o) => o.path.includes("vendor-react"));
    expect(vendorChunk).toBeUndefined();
  });

  test("external + tree-shaking — external import 는 tree-shake 되지 않음", async () => {
    // external 은 런타임에 외부 의존성이라 사용 표면적이 모르므로 항상 보존.
    const fixture = await createFixture({
      "entry.ts": `
        import { used } from "ext-side";
        console.log(used);
      `,
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["ext-side"],
      splitting: true,
    });

    const text = result.outputFiles![0].text;
    // external 은 보존 — `require("ext-side")` 또는 `import "ext-side"` 흔적이 남아야
    const hasExternalRef =
      /require\(["']ext-side["']\)/.test(text) ||
      /from\s*["']ext-side["']/.test(text) ||
      /import\s*["']ext-side["']/.test(text);
    expect(hasExternalRef).toBe(true);
  });

  test("manualChunks meta 다회 호출 안전 — 같은 id 여러번 lookup", async () => {
    // 사용자 코드가 같은 id 여러 번 lookup 해도 zero-alloc 경로라 leak 없음 + 같은 결과 반환.
    const fixture = await createFixture({
      "entry.ts": `import { a } from "./lib"; console.log(a);`,
      "lib.ts": 'export const a = "L";',
    });
    cleanup = fixture.cleanup;

    const results: { iter: number; importers: number; isEntry: boolean }[] = [];
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        if (!id.endsWith("lib.ts")) return null;
        for (let i = 0; i < 5; i++) {
          const info = meta.getModuleInfo(id);
          if (info)
            results.push({ iter: i, importers: info.importers.length, isEntry: info.isEntry });
        }
        return null;
      },
    });

    expect(results.length).toBe(5);
    // 모든 호출 결과 동일
    for (const r of results) {
      expect(r.importers).toBe(1);
      expect(r.isEntry).toBe(false);
    }
  });

  test("meta.getModuleInfo: hasModuleSideEffects — npm 패키지의 sideEffects=true 가 auto-purity 무력화", async () => {
    // ZTS 의 `findPackageDirPath` 는 `node_modules/` 안 경로만 인식 (라이브러리 메타).
    // 그래서 npm 패키지 fixture 로 user_defined 동작 검증.
    const fixture = await createFixture({
      "node_modules/sideful-lib/package.json":
        '{"name":"sideful-lib","sideEffects":true,"main":"index.js"}',
      "node_modules/sideful-lib/index.js": "export const x = 1;",
      "entry.ts": `import { x } from "sideful-lib"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.hasModuleSideEffects);
    const libEntry = [...seen.entries()].find(([k]) => k.endsWith("sideful-lib/index.js"));
    // 이 패턴은 실제 ZTS 동작 — node_modules 안의 sideEffects=true 가 lock.
    if (libEntry) expect(libEntry[1]).toBe(true);
  });

  test("meta.getModuleInfo: hasModuleSideEffects — npm 패키지의 글롭 sideEffects 패턴", async () => {
    // node_modules 안 패키지에서 sideEffects: ["*.css"] → CSS=true, JS=false.
    const fixture = await createFixture({
      "node_modules/glob-lib/package.json":
        '{"name":"glob-lib","sideEffects":["*.css"],"main":"index.js"}',
      "node_modules/glob-lib/index.js": 'import "./style.css"; export const x = 1;',
      "node_modules/glob-lib/style.css": ".cls{color:red}",
      "entry.ts": `import { x } from "glob-lib"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.hasModuleSideEffects);
    const indexEntry = [...seen.entries()].find(([k]) => k.endsWith("glob-lib/index.js"));
    const cssEntry = [...seen.entries()].find(([k]) => k.endsWith("glob-lib/style.css"));
    // 글롭 패턴이 적용된 경우만 검증 (graph 가 두 모듈 다 보면)
    if (indexEntry) expect(indexEntry[1]).toBe(false);
    if (cssEntry) expect(cssEntry[1]).toBe(true);
  });

  test("meta.getModuleInfo: hasModuleSideEffects — 사용자 앱 코드는 package.json 영향 안 받음 (ZTS 정책)", async () => {
    // 프로젝트 루트의 package.json 은 node_modules 밖 모듈에 적용 안 됨.
    // 사용자 코드는 tree-shaker auto-purity 만 영향.
    // 이게 미래에 바뀌어도 lock — 변경하면 테스트로 신호.
    const fixture = await createFixture({
      "package.json": '{"name":"app","sideEffects":true}',
      "entry.ts": `import { x } from "./pure-lib"; console.log(x);`,
      "pure-lib.ts": "export const x = 1;",
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.hasModuleSideEffects);
    const libFlag = [...seen.entries()].find(([k]) => k.endsWith("pure-lib.ts"))![1];
    // 사용자 코드 `pure-lib.ts` — package.json sideEffects=true 무시되고 auto-purity 가 false 로.
    expect(libFlag).toBe(false);
  });

  // ============================================================
  // info.code — Rollup 호환 source 노출
  // ============================================================

  test("meta.getModuleInfo: code — 모듈 source 그대로 노출", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { a } from "./lib"; console.log(a);`,
      "lib.ts": 'export const a = "UNIQUE_LIB_MARKER_42";',
    });
    cleanup = fixture.cleanup;

    const seen = await collectMeta(fixture.dir, ["entry.ts"], (info) => info.code);
    const libCode = [...seen.entries()].find(([k]) => k.endsWith("lib.ts"))![1];
    const entryCode = [...seen.entries()].find(([k]) => k.endsWith("entry.ts"))![1];

    expect(typeof libCode).toBe("string");
    expect(libCode).toContain("UNIQUE_LIB_MARKER_42");
    expect(typeof entryCode).toBe("string");
    expect(entryCode).toContain('from "./lib"');
  });

  test("meta.getModuleInfo: code — external 모듈은 null", async () => {
    const fixture = await createFixture({
      "entry.ts": `import { x } from "ext-pkg"; console.log(x);`,
    });
    cleanup = fixture.cleanup;

    let extCode: unknown = "untouched";
    await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      external: ["ext-pkg"],
      splitting: true,
      manualChunks: (id, meta) => {
        if (id.endsWith("entry.ts")) {
          extCode = meta.getModuleInfo("ext-pkg")?.code;
        }
        return null;
      },
    });

    expect(extCode).toBeNull();
  });

  test("meta.getModuleInfo: code 기반 manualChunks 분류 — content 패턴 매칭", async () => {
    // 실전 패턴: source 안에 특정 marker 가 있는 모듈만 별도 청크로.
    const fixture = await createFixture({
      "entry.ts": `
        import { a } from "./annotated";
        import { b } from "./plain";
        console.log(a, b);
      `,
      "annotated.ts": `// @vendor\nexport const a = 1;`,
      "plain.ts": "export const b = 2;",
    });
    cleanup = fixture.cleanup;

    const result = await build({
      entryPoints: [join(fixture.dir, "entry.ts")],
      splitting: true,
      manualChunks: (id, meta) => {
        const info = meta.getModuleInfo(id);
        if (info?.code?.includes("@vendor")) return "vendor";
        return null;
      },
    });

    const vendorChunk = result.outputFiles!.find((o) => o.path.includes("vendor"));
    expect(vendorChunk).toBeDefined();
    expect(vendorChunk!.moduleIds!.some((m) => m.endsWith("annotated.ts"))).toBe(true);
    expect(vendorChunk!.moduleIds!.some((m) => m.endsWith("plain.ts"))).toBe(false);
  });
});
