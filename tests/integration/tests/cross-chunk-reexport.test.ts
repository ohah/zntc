import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, writeOutputs } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// #3321 후속 버그픽스: cross-chunk re-export.
// `export { x } from "./y"` 에서 y 가 별도 청크면, 재-export 심볼이
// cross-chunk imports_from 으로 전파되지 않아 referrer 가 심볼 미바인딩
// → ReferenceError. esm/cjs/iife splitting 공통 선재 버그. 근본 원인:
//   (a) computeCrossChunkLinks 가 export_bindings(re-export)를 안 봄
//   (b) 심볼 canonical 청크가 직접 의존이 아니면 cross_chunk_imports 누락
//       → emitter 가 named import 를 못 냄
// 둘 다 수정. esm/cjs 는 Node 직접 실행, iife 는 브라우저 시뮬 실행.

function browserDriver(dir: string, entryFile: string, allJs: string[]): string {
  const others = allJs.filter((p) => p !== entryFile);
  const drv = join(dir, '__rxdrv.cjs');
  writeFileSync(
    drv,
    `const fs=require("fs"),path=require("path");const here=${JSON.stringify(dir)};
function ev(f){(0,eval)(fs.readFileSync(path.join(here,f),"utf8"));}
globalThis.__zntc_public_path="";
globalThis.document={createElement(){return {};},head:{appendChild(s){ev(s.src);if(s.onload)s.onload();}}};
${others.map((f) => `ev(${JSON.stringify(f)});`).join('\n')}
ev(${JSON.stringify(entryFile)});
`,
  );
  return drv;
}

const jsPaths = (outs: { path: string }[]) =>
  outs.filter((o) => o.path.endsWith('.js')).map((o) => o.path);

describe('cross-chunk re-export (#3321 follow-up bugfix)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // page 가 inner 를 re-export, index 가 page 에서 그 심볼을 정적 import +
  // page 를 동적 import. inner 는 별도 common 청크가 됨.
  const reexportFixture = {
    'inner.ts': `export const reexported = "RX";\nexport const other = "OT";`,
    'page.ts': `export { reexported } from "./inner";\nexport function pageOnly(){ return "PO"; }`,
    'index.ts': `
      import { reexported } from "./page";
      async function main(){
        const m = await import("./page");
        console.log("rx:" + reexported + " po:" + m.pageOnly());
      }
      main();
    `,
  };

  for (const format of ['esm', 'cjs', 'iife'] as const) {
    test(`${format}: re-export 심볼이 referrer·재-exporter 양쪽에 바인딩 + Node 실행`, async () => {
      const fixture = await createFixture(reexportFixture);
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'index.ts')],
        format,
        splitting: true,
        platform: format === 'iife' ? 'browser' : 'node',
      });
      const outs = result.outputFiles!;
      expect(jsPaths(outs).length).toBeGreaterThanOrEqual(3); // index, page, inner

      // 재-exporter(page) 청크는 re-export 심볼을 named 로 가져와야 함
      // (side-effect import 만 있으면 미바인딩).
      const page = outs.find((o) => o.path.includes('page') && o.path.endsWith('.js'))!;
      expect(page).toBeDefined();
      if (format === 'esm') {
        expect(page.text).toMatch(/import\s*\{[^}]*reexported[^}]*\}\s*from/);
      } else {
        expect(page.text).toMatch(/(reexported[^=]*=\s*(__zntc_)?require|__zntc_require)/);
      }

      writeOutputs(fixture.dir, outs);
      const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
      let stdout: string;
      if (format === 'iife') {
        const drv = browserDriver(fixture.dir, entry.path, jsPaths(outs));
        ({ stdout } = await runNode(drv));
      } else {
        ({ stdout } = await runNode(join(fixture.dir, entry.path)));
      }
      expect(stdout).toBe('rx:RX po:PO');
    });
  }

  // 정적 전용 gap (b): a 가 page 의 re-export 심볼 사용, manualChunks 로
  // inner 를 별도 청크 강제(동적 entry 아님 → 버그 B 무관). canonical
  // 청크(inner)가 a 의 직접 의존이 아님 — cross_chunk_imports 보장 회귀 가드.
  for (const format of ['esm', 'cjs'] as const) {
    test(`${format}: 정적 전용 re-export (canonical 청크 ≠ 직접 의존, manualChunks)`, async () => {
      const fixture = await createFixture({
        'inner.ts': `export const v = "INNER";`,
        'page.ts': `export { v } from "./inner";\nexport const pg = "PAGE";`,
        'a.ts': `import { v } from "./page";\nexport function useA(){ return "uA:" + v; }`,
        'index.ts': `import { useA } from "./a";\nimport { pg } from "./page";\nconsole.log(useA() + " " + pg);`,
      });
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'index.ts')],
        format,
        splitting: true,
        manualChunks: (id: string) =>
          id.includes('inner') ? 'innerchunk' : id.includes('page') ? 'pagechunk' : null,
      });
      const outs = result.outputFiles!;
      expect(jsPaths(outs).length).toBeGreaterThanOrEqual(2);
      writeOutputs(fixture.dir, outs);
      const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
      const { stdout } = await runNode(join(fixture.dir, entry.path));
      expect(stdout).toBe('uA:INNER PAGE');
    });
  }

  test('회귀: 단일 번들(splitting 아님) re-export 불변', async () => {
    const fixture = await createFixture({
      'inner.ts': `export const k = "K";`,
      'mid.ts': `export { k } from "./inner";`,
      'index.ts': `import { k } from "./mid";\nconsole.log("k:" + k);`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
    });
    writeOutputs(fixture.dir, result.outputFiles!);
    const out = result.outputFiles!.filter((o) => o.path.endsWith('.js'));
    expect(out.length).toBe(1);
    const { stdout } = await runNode(join(fixture.dir, out[0].path));
    expect(stdout).toBe('k:K');
  });

  // 버그 B (PR4): ESM 에서 한 심볼이 (re-export + 정적 cross-import) 이고
  // 그 청크가 *동적 entry* 이기도 하면 xchunk_exports 와 entry-final-exports
  // 가 같은 이름을 둘 다 `export {}` → `Duplicate export` SyntaxError.
  // ESM entry/dynamic 청크에서 entry 모듈 .local export 와 겹치는 이름을
  // xchunk 에서 제거(emitEsm 담당)하여 정확히 1회 emit.
  test('버그 B: ESM 동적-entry + 정적 cross-import + re-export 중복 export 없음', async () => {
    const fixture = await createFixture({
      'inner.ts': `export const v = "INNER";`,
      'page.ts': `export { v } from "./inner";\nexport const pg = "PAGE";`,
      'a.ts': `import { v } from "./page";\nexport function useA(){ return "uA:" + v; }`,
      'index.ts': `
        import { useA } from "./a";
        import { pg } from "./page";
        const dyn = import("./page");
        console.log(useA() + " " + pg, !!dyn);
      `,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
      splitting: true,
    });
    const outs = result.outputFiles!;
    const page = outs.find((o) => o.path.includes('page') && o.path.endsWith('.js'))!;
    expect(page).toBeDefined();
    // page 청크에 `export {` 가 정확히 1개(중복 export 문 금지).
    const exportStmts = page.text.match(/(^|\n)\s*export\s*\{/g) ?? [];
    expect(exportStmts.length).toBe(1);
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe('uA:INNER PAGE true');
  });

  test('버그 B 회귀: 일반 ESM 동적 import 청크 export 정상(단일)', async () => {
    const fixture = await createFixture({
      'dyn.ts': `export const a = 1;\nexport const b = 2;`,
      'index.ts': `async function m(){ const d = await import("./dyn"); console.log(d.a + d.b); }\nm();`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
      splitting: true,
    });
    const outs = result.outputFiles!;
    const dyn = outs.find((o) => o.path.includes('dyn') && o.path.endsWith('.js'))!;
    const exportStmts = dyn.text.match(/(^|\n)\s*export\s*\{/g) ?? [];
    expect(exportStmts.length).toBeLessThanOrEqual(1);
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe('3');
  });

  // 후속: `export * from "./y"` (star) — y 별도 청크. #3350 은 named
  // re-export 만 처리했고 star 는 미처리였음(소스 전체 export 미열거 →
  // 재-exporter 가 side-effect import 만 받아 미바인딩 link error).
  for (const format of ['esm', 'cjs'] as const) {
    test(`${format}: export * from (star) cross-chunk — 전체 재-export 바인딩 + Node 실행`, async () => {
      const fixture = await createFixture({
        'inner.ts': `export const ia = "IA";\nexport const ib = "IB";`,
        'page.ts': `export * from "./inner";\nexport const pv = "PV";`,
        'index.ts': `
          import { ia, pv } from "./page";
          async function main(){
            const m = await import("./page");
            console.log(ia + " " + pv + " " + m.ib + " " + m.ia);
          }
          main();
        `,
      });
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'index.ts')],
        format,
        splitting: true,
        platform: 'node',
      });
      const outs = result.outputFiles!;
      writeOutputs(fixture.dir, outs);
      const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
      const { stdout } = await runNode(join(fixture.dir, entry.path));
      expect(stdout).toBe('IA PV IB IA');
    });
  }

  test('star re-export: 체인 re-export(export {k1} from "./page") + manualChunks 분리 가드', async () => {
    // a 가 page 의 star-re-export 이름 k1 을 다시 re-export(import_binding
    // 없음). page 가 inner 의 `export *` 를 cross-chunk 바인딩·재노출하지
    // 못하면 a 의 k1 해석이 깨진다 → star 열거 경로 가드. manualChunks 로
    // inner/page 분리 강제. (namespace 객체 경로는 별도 후속 — 미사용.)
    const fixture = await createFixture({
      'inner.ts': `export const k1 = "K1";\nexport const k2 = "K2";`,
      'page.ts': `export * from "./inner";\nexport const pg = "PG";`,
      'a.ts': `export { k1 } from "./page";\nexport const av = "AV";`,
      'index.ts': `import { k1, av } from "./a";\nimport { pg } from "./page";\nconsole.log(k1 + " " + av + " " + pg);`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
      splitting: true,
      manualChunks: (id: string) =>
        id.includes('inner') ? 'innerc' : id.includes('page') ? 'pagec' : null,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe('K1 AV PG');
  });

  // [알려진 한계 — 깊은 후속, RFC §7] `export * as ns from "./y"`(y 별도
  // 청크) + `import { ns } from` cross-chunk 소비. 단일번들은 ns 객체를
  // 합성하지 않고 `ns.a`→`a` 멤버접근 elision 으로 동작 — cross-chunk 에선
  // importer 청크에 멤버 `a` 가 미바인딩(computeCrossChunkLinks 가
  // namespace-멤버-접근 resolution 을 소비 안 함) → link 실패. 다른 4개
  // re-export-family 버그(#3350/#3354/#3351/#3353)와 달리 bounded 아님 —
  // linker static-member resolution 연계 깊은 seam 필요. 수정/회귀 시
  // skip 해제하면 loud(추적용).
  test.skip('[KNOWN-LIMITATION] export * as ns cross-chunk → namespace 멤버 미바인딩', async () => {
    const fixture = await createFixture({
      'inner.ts': `export const a = "A";\nexport const b = "B";`,
      'page.ts': `export * as inner from "./inner";\nexport const pv = "PV";`,
      'index.ts': `import { inner, pv } from "./page";\nasync function m(){ const d = await import("./page"); console.log(inner.a + " " + pv + " " + d.inner.b); }\nm();`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
      splitting: true,
    });
    writeOutputs(fixture.dir, result.outputFiles!);
    const entry = result.outputFiles!.find(
      (o) => o.path.includes('index') && o.path.endsWith('.js'),
    )!;
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe('A PV B'); // 현재 실패(link error) — 수정 시 통과
  });
});
