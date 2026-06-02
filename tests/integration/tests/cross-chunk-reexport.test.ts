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

  // `export * as ns` / `import * as ns; export {ns}` cross-chunk (#3321 후속).
  // 정의자 청크에 shared ns 객체를 선제 materialize(computeCrossChunkLinks 가
  // namespace 메타데이터보다 먼저 도는 timing seam 해결) + 멤버/객체를 정의자
  // 청크 export → 참조 청크 import 1급 심볼로 fan-out. entry/dynamic 청크는
  // buildFinalExports 가 ns_target_mod pair 의 local 을 ns_var 로 치환.
  async function runNsSplit(
    files: Record<string, string>,
    opts: Record<string, unknown>,
    expected: string,
  ) {
    const fixture = await createFixture(files);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      splitting: true,
      ...opts,
    });
    writeOutputs(fixture.dir, result.outputFiles!);
    const entry = result.outputFiles!.find(
      (o) => o.path.includes('index') && o.path.endsWith('.js'),
    )!;
    const { stdout } = await runNode(join(fixture.dir, entry.path));
    expect(stdout).toBe(expected);
  }

  test('export * as ns 직접형 — 정적 멤버 + 동적 re-import cross-chunk', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";\nexport const b = "B";`,
        'page.ts': `export * as inner from "./inner";\nexport const pv = "PV";`,
        'index.ts': `import { inner, pv } from "./page";\nasync function m(){ const d = await import("./page"); console.log(inner.a + " " + pv + " " + d.inner.b); }\nm();`,
      },
      { format: 'esm' },
      'A PV B',
    ));

  test('import * as ns; export {ns} — 정적 + 동적 cross-chunk', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";\nexport const b = "B";`,
        'page.ts': `import * as inner from "./inner";\nexport { inner };\nexport const pv = "PV";`,
        'index.ts': `import { inner, pv } from "./page";\nasync function m(){ const d = await import("./page"); console.log(inner.a + " " + pv + " " + d.inner.b); }\nm();`,
      },
      { format: 'esm' },
      'A PV B',
    ));

  test('export * as ns — 두 consumer 별도 청크', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";`,
        'page.ts': `export * as inner from "./inner";\nexport const pv = "PV";`,
        'c1.ts': `import { inner } from "./page";\nexport const r1 = () => inner.a;`,
        'index.ts': `import { r1 } from "./c1";\nimport { inner } from "./page";\nasync function m(){ const d = await import("./c1"); console.log(r1() + " " + inner.a + " " + d.r1()); }\nm();`,
      },
      { format: 'esm' },
      'A A A',
    ));

  test('export * as ns — manualChunks 강제 분리', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";\nexport const b = "B";`,
        'page.ts': `export * as inner from "./inner";\nexport const pv = "PV";`,
        'index.ts': `import { inner, pv } from "./page";\nconsole.log(inner.a + inner.b + pv);`,
      },
      {
        format: 'esm',
        manualChunks: (id: string) =>
          id.includes('inner') ? 'innerc' : id.includes('page') ? 'pagec' : null,
      },
      'ABPV',
    ));

  test('export * as ns — cjs format cross-chunk', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";\nexport const b = "B";`,
        'page.ts': `export * as inner from "./inner";\nexport const pv = "PV";`,
        'index.ts': `import { inner, pv } from "./page";\nasync function m(){ const d = await import("./page"); console.log(inner.a + " " + pv + " " + d.inner.b); }\nm();`,
      },
      { format: 'cjs' },
      'A PV B',
    ));

  // splitting:true 인데 동적 import 가 없어 단일 청크가 되는 경우 `export *
  // as ns` 를 whole-value(`Object.keys(ns)`)로 쓰면, chunked emit 의 shared
  // preamble 이 per-module metadata 보다 먼저 돌아 same-chunk ns 객체가
  // 미materialize 되던 버그(#3367). registerNamespaceRewrites 가
  // ns_preamble_chunked+isNsCrossChunk 로 same-chunk 는 비-shared
  // self-contained 경로(모듈 preamble 직접 emit) 선택 → 해소.
  test('export * as ns whole-value 단일청크 (#3367)', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";\nexport const b = "B";`,
        'page.ts': `export * as inner from "./inner";`,
        'index.ts': `import { inner } from "./page";\nconsole.log(Object.keys(inner).sort().join(","));`,
      },
      { format: 'esm' },
      'a,b',
    ));

  // [추적 — 별개 선재 이슈, #3368] 이번/이전 cross-chunk 배선과 무관한
  // 다른 서브시스템(tree-shaker) 버그. 루트커즈 규명 완료. 수정/회귀 시
  // loud 하도록 skip 유지.
  // 중첩 ns re-export 체인: `export {inner} from "./mid"` + mid
  // `export * as inner from "./inner"`. seedExport 가 `import * as z;
  // export {z}`(import_binding) 만 소스 시드하고 `export * as z from`
  // (re_export_namespace, export_binding) 은 미처리 → resolveExportChain
  // canonical=(mid,"inner") 에서 inner.ts 가 통째 tree-shaken 되던 버그.
  // seedExport 에 re_export_namespace 소스 시드 추가로 해소 (#3368).
  test('중첩 ns re-export 체인 (#3368)', () =>
    runNsSplit(
      {
        'inner.ts': `export const a = "A";`,
        'mid.ts': `export * as inner from "./inner";`,
        'page.ts': `export { inner } from "./mid";\nexport const pv = "PV";`,
        'index.ts': `import { inner, pv } from "./page";\nasync function m(){ const d = await import("./page"); console.log(inner.a + pv + d.inner.a); }\nm();`,
      },
      { format: 'esm' },
      'APVA',
    ));

  // #4096 lock: cross-chunk 으로 예약어 export 이름(`default`)을 가져오면 축약 바인딩
  // (`const { default }` / `import { default }`)이 예약어라 청크 전체 parse 실패였다.
  // iife/cjs/esm splitting 모두 반드시 alias(`default: _default` / `default as _default`)
  // 로 나와야 한다. dev_split 런타임 가드는 napi-lazy-dev-hmr 에 있고, 여기선 production
  // splitting 의 emit 형태(예약어 미축약)를 3포맷에서 잠근다.
  for (const format of ['iife', 'cjs', 'esm'] as const) {
    test(`${format}: export { default } from cjs — 예약어가 bare 아닌 유효 식별자로 emit (#4096)`, async () => {
      const fixture = await createFixture({
        'cjslib.js': "module.exports = function(){ return 'D'; };\nmodule.exports.named = 9;",
        'Route.ts': "export { default, named } from './cjslib.js';",
        'entry.ts':
          "import l from './cjslib.js';\nglobalThis.E = l;\nglobalThis.r = () => import('./Route');",
      });
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'entry.ts')],
        rootDir: fixture.dir,
        platform: 'browser',
        splitting: true,
        format,
      });
      expect(result.errors ?? []).toHaveLength(0);
      const route = (result.outputFiles ?? []).find(
        (o) => /Route-/.test(o.path) && o.path.endsWith('.js'),
      );
      expect(route).toBeDefined();
      // cross-chunk import 라인(`… = __zntc_require(…)` / `… = require(…)` / `… from "…"`)을
      // 찾아 예약어 default 가 유효 식별자로 바인딩됐는지 확인. 전역 네이밍(#4101)으로 deconflict
      // 된 식별자(`default$1`) 또는 #4096 alias(`default: _default`) 둘 다 유효 — 핵심은 bare 아님.
      const crossImport = route!.text
        .split('\n')
        .find((l) => /\bdefault\b/.test(l) && /(__zntc_require|require|from)\s*[("]/.test(l));
      expect(crossImport).toBeDefined();
      // 축약 바인딩(`{ default }` / `{ default, … }` / `{ …, default }`) 부재 = SyntaxError 없음.
      expect(/\bdefault\s*[},]/.test(crossImport!)).toBe(false);
      // iife/cjs 청크는 함수 본문으로 parse 검증(예약어 bare RHS/바인딩이면 throw). esm 은 불가.
      if (format !== 'esm') {
        expect(() => new Function('exports', 'module', 'require', route!.text)).not.toThrow();
      }
    });
  }

  // #C lock: production splitting 에서 default *import* 의 정의 모듈이 별도(shared) 청크면,
  // 그 청크가 `exports.default = <local>` 로 노출한다. local 을 export 명 `default`(예약어
  // 식별자)로 떨어뜨리면 `exports.default = default;` (RHS 예약어 = SyntaxError, 청크 parse
  // 실패)였다. canonical synthetic local(`_default`)로 해석돼 모든 청크가 parse 되는지 가드.
  for (const format of ['iife', 'cjs'] as const) {
    test(`${format}: default import 의 shared 청크가 SyntaxError 없이 노출 (#C)`, async () => {
      const fixture = await createFixture({
        'esmdep.ts': "export default function(){ return 'DEF'; }\nexport const tag = 'T';",
        'Card.ts': "import def from './esmdep';\nexport function card(){ return def(); }",
        'entry.ts':
          "import def from './esmdep';\nglobalThis.E = def();\nglobalThis.load = () => import('./Card');",
      });
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'entry.ts')],
        rootDir: fixture.dir,
        platform: 'browser',
        splitting: true,
        format,
      });
      expect(result.errors ?? []).toHaveLength(0);
      const jsChunks = (result.outputFiles ?? []).filter((o) => o.path.endsWith('.js'));
      expect(jsChunks.length).toBeGreaterThan(1); // entry + Card + shared(esmdep)
      for (const chunk of jsChunks) {
        // 예약어 RHS(`exports.default = default;` / `= default,`) 부재. `_default` 는 word
        // boundary 로 제외(= 정상). 있으면 = canonical 미해석 = SyntaxError 원인.
        expect(/=\s*\bdefault\b\s*[;,)]/.test(chunk.text)).toBe(false);
        // 함수 본문으로 감싸 parse 검증(실행 아님) — 예약어 RHS 면 throw.
        expect(() => new Function('exports', 'module', 'require', chunk.text)).not.toThrow();
      }
    });
  }

  // #4101 production 전역 네이밍(DONE): 서로 다른 모듈의 *같은* export 이름(두 `v`)이 한 shared
  // 청크에 묶이고 여러 entry 가 둘 다 import 해도, 전역 네이밍 pass(computeCrossChunkGlobalNames)
  // 가 (module, export_name) 별 owned 전역명을 deconflict → provider `export { v, v$1 }` +
  // consumer `import { v, v$1 }` 로 distinct. 예전엔 브리지 public=export 명이라 충돌 →
  // `export { v$1 as v }` 하나만 노출 + 소비자가 둘 다 public "v" 에 바인딩 → collapse(둘 다 한
  // 값)였다. dev_split 은 #4105, production 은 이 PR 에서 전역 네이밍 pass 를 production 으로
  // 확장(bundler.zig: code_splitting 게이트)해 해결.
  for (const format of ['esm', 'iife'] as const) {
    test(`${format}: 다른 모듈의 같은 export 둘을 여러 entry 가 import (전역 네이밍 production #4101)`, async () => {
      const fixture = await createFixture({
        'a.ts': "export const v = 'AV';",
        'b.ts': "export const v = 'BV';",
        'e1.ts':
          "import { v as a } from './a';\nimport { v as b } from './b';\nconsole.log('e1', a, b);",
        'e2.ts':
          "import { v as a } from './a';\nimport { v as b } from './b';\nconsole.log('e2', a, b);",
      });
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
        rootDir: fixture.dir,
        platform: 'node',
        splitting: true,
        format,
      });
      const outs = result.outputFiles!;
      writeOutputs(fixture.dir, outs);
      const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
      const e2 = outs.find((o) => o.path.includes('e2') && o.path.endsWith('.js'))!;
      const driver =
        format === 'esm'
          ? join(fixture.dir, e1.path)
          : browserDriver(
              fixture.dir,
              e1.path,
              // 다른 entry(e2)는 제외. entry 는 self-execute 하며 static cross-chunk import 를
              // 즉시 __zntc_require 하므로, 같은 글로벌에 섞이면 (a) e2 도 실행돼 stdout 오염
              // (b) chunk 미등록 시점에 require → throw. e1 + 공유 chunk 만 로드(실브라우저의
              // 페이지당 1 entry 와 동치) → e1 이 distinct 값을 받는지만 검증.
              outs.filter((o) => o.path.endsWith('.js') && o.path !== e2.path).map((o) => o.path),
            );
      const { stdout } = await runNode(driver);
      expect(stdout.trim()).toBe('e1 AV BV'); // 예전 'e1 BV BV' (collapse) → 전역 네이밍으로 distinct
    });
  }

  // #4101 회귀 방어: production 전역 네이밍을 모든 splitting 으로 확장하면서, consumer 는
  // 전역명으로 import 키를 바꾸는데 single-owner provider 경로는 export 名을 그대로 노출 →
  // 전역명≠export名(공유 `export default`, 분산 청크 동명)일 때 provider/consumer divergence
  // = `SyntaxError: does not provide an export named …`. provider single-owner 도 전역명을
  // public 으로 노출해야 일치. (collision owner_count>1 은 이미 전역명, common 은 global==name).

  // 회귀 1: `export default` 가 여러 entry 에 공유 → shared 청크가 default 를 cross-chunk
  // 노출. consumer 는 default 의 전역명(=local `thing`)으로 import → provider 도 그 전역명을
  // 노출해야 한다. 예전(이 회귀)엔 `export { thing as default }` 만 내 consumer `import { thing }`
  // 가 깨짐.
  test('esm: 공유 export default 가 consumer/provider 전역명 일치 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'shared.ts': "export default function thing(){ return 'D'; }",
      'e1.ts': "import f from './shared';\nconsole.log('e1', f());",
      'e2.ts': "import f from './shared';\nconsole.log('e2', f());",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 D');
  });

  test('iife: 공유 export default 가 consumer/provider 전역명 일치 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'shared.ts': "export default function thing(){ return 'D'; }",
      'e1.ts': "import f from './shared';\nconsole.log('e1', f());",
      'e2.ts': "import f from './shared';\nconsole.log('e2', f());",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'browser',
      splitting: true,
      format: 'iife',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const e2 = outs.find((o) => o.path.includes('e2') && o.path.endsWith('.js'))!;
    // e1 + 공유 chunk 만 (다른 entry e2 제외 — self-execute/조기 require 회피).
    const driver = browserDriver(
      fixture.dir,
      e1.path,
      outs.filter((o) => o.path.endsWith('.js') && o.path !== e2.path).map((o) => o.path),
    );
    const { stdout } = await runNode(driver);
    expect(stdout.trim()).toBe('e1 D');
  });

  // 회귀 2: 서로 다른 모듈의 동명 export 가 *서로 다른* 청크에 분산(각 owner_count==1).
  // 전역 deconflict 가 a.v→`v`, b.v→`v$1` 를 배정 → main 은 `import { v$1 } from chunk-b`
  // 하지만 chunk-b 는 single-owner 라 `export { v }` 만 냈다(divergence). provider 가 전역명
  // 을 노출하면 `export { v as v$1 }` → 일치.
  test('esm: 분산 청크 동명 export 가 consumer/provider 일치 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'a.ts': "export const v = 'AV';",
      'b.ts': "export const v = 'BV';",
      'route1.ts': "import { v } from './a';\nexport const r1 = v;",
      'route2.ts': "import { v } from './b';\nexport const r2 = v;",
      'main.ts':
        "import { v as av } from './a';\nimport { v as bv } from './b';\n" +
        "async function run(){ const m1=await import('./route1'); const m2=await import('./route2'); console.log('main', av, bv, m1.r1, m2.r2); }\nrun();",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('main AV BV AV BV');
  });

  // 회귀 3 (Angle A): 사용자 실제 export `v$1` 이 동명 collision 의 생성 전역명 `v$1` 과
  // 한 청크에서 겹치면 안 된다. 전역 deconflict 가 used set 으로 회피(사용자 v$1→`v$1$1`)
  // 하고, provider 가 전역명을 노출하면 중복 export(`export { v$1, v$1 }`) 없이 distinct.
  test('esm: 사용자 v$1 export 가 collision 생성 v$1 과 충돌 안 함 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'a.ts': "export const v = 'AV';",
      'b.ts': "export const v = 'BV';",
      'c.ts': "export const v$1 = 'C1';",
      'e1.ts':
        "import { v as a } from './a';\nimport { v as b } from './b';\nimport { v$1 as c } from './c';\nconsole.log('e1', a, b, c);",
      'e2.ts':
        "import { v as a } from './a';\nimport { v as b } from './b';\nimport { v$1 as c } from './c';\nconsole.log('e2', a, b, c);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    // 어떤 청크도 같은 export 명을 2번 내면 안 된다(중복 export = SyntaxError).
    for (const o of outs) {
      if (!o.path.endsWith('.js')) continue;
      const m = o.text.match(/export\s*\{([^}]*)\}/g) ?? [];
      for (const stmt of m) {
        const names = stmt
          .replace(/export\s*\{|\}/g, '')
          .split(',')
          .map((s) => (s.includes(' as ') ? s.split(' as ')[1] : s).trim())
          .filter(Boolean);
        expect(new Set(names).size).toBe(names.length); // 중복 public 없음
      }
    }
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 AV BV C1');
  });

  // 회귀 4(main 선재 버그 일반화): `export { local as exportName }`(local≠export명)이 여러
  // entry 에 공유되면 provider 는 실제 local 을 참조해야 한다. 예전엔 local_name 스캔이
  // 미-rename local 을 놓치고 export명으로 fallback → `export { renamed }`(main) /
  // `export { renamed as _x }`(전역명 도입 시) — 둘 다 미존재 local 참조 = SyntaxError.
  // getExportLocalName(권위 소스) 채택으로 해결.
  test('esm: renamed export(local≠export명) 공유가 실제 local 참조 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'util.ts': "const _x = 'X';\nexport { _x as renamed };",
      'e1.ts': "import { renamed } from './util';\nconsole.log('e1', renamed);",
      'e2.ts': "import { renamed } from './util';\nconsole.log('e2', renamed);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 X');
  });

  // 회귀 5: 단순 export + renamed export + re-export 가 한 shared 청크에 혼재해도 전부 정확.
  test('esm: 단순+renamed+re-export 혼재 shared 청크 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'inner.ts': "export const reexported = 'RX';",
      'util.ts':
        "const _x = 'X';\nexport { _x as renamed };\nexport const helper = 'H';\nexport { reexported } from './inner';",
      'e1.ts':
        "import { helper, renamed, reexported } from './util';\nconsole.log('e1', helper, renamed, reexported);",
      'e2.ts':
        "import { helper, renamed, reexported } from './util';\nconsole.log('e2', helper, renamed, reexported);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 H X RX');
  });

  // 회귀 6: 한 shared 청크에 collision(owner_count>1, `v`) 과 normal(owner_count==1, `only`)
  // 이 공존 → collision 블록과 single-owner 경로를 동시에 타도 둘 다 정확.
  test('esm: collision + normal export 가 한 청크에 공존 (#4101 회귀)', async () => {
    const fixture = await createFixture({
      'a.ts': "export const v = 'AV';\nexport const only = 'ONLY';",
      'b.ts': "export const v = 'BV';",
      'e1.ts':
        "import { v as a, only } from './a';\nimport { v as b } from './b';\nconsole.log('e1', a, b, only);",
      'e2.ts':
        "import { v as a, only } from './a';\nimport { v as b } from './b';\nconsole.log('e2', a, b, only);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 AV BV ONLY');
  });

  // collision 블록 일반화(이 PR)는 namespace re-export collision 의 **export emit** 을 고친다:
  // 예전 단순 해석은 미존재 `export { ns }` SyntaxError 였고, 일반화는 single-owner 와 같은
  // full resolution(nsReExportTarget→ensureSharedNsVar)으로 `export { x_ns as ns, y_ns as ns$1 }`
  // (실존 ns 변수)를 낸다. 다만 ns 자체 materialization(`y_ns = {get k(){return k}}` 가 자기
  // const `k$1` 이 아니라 다른 ns 의 `k` 참조) + 번들 consumer 의 멤버접근 collapse 는 export
  // emit 이 아니라 shared-namespace finalize 의 **별도 선재 버그**라 범위 밖 → todo 로 고정.
  test.todo('esm: namespace re-export collision 전체 동작 (ns materialize finalize 선재 버그)', async () => {
    const fixture = await createFixture({
      'x.ts': "export const k = 'XK';",
      'y.ts': "export const k = 'YK';",
      'a.ts': "export * as ns from './x';",
      'b.ts': "export * as ns from './y';",
      'e1.ts':
        "import { ns as na } from './a';\nimport { ns as nb } from './b';\nconsole.log('e1', na.k, nb.k);",
      'e2.ts':
        "import { ns as na } from './a';\nimport { ns as nb } from './b';\nconsole.log('e2', na.k, nb.k);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 XK YK');
  });

  // === 추가 커버리지: 포맷(cjs/iife) · shape(3-way, default+named) 확장 ===

  // 공유 export default 가 cjs 에서도 provider/consumer 전역명 일치.
  test('cjs: 공유 export default 가 consumer/provider 전역명 일치', async () => {
    const fixture = await createFixture({
      'shared.ts': "export default function thing(){ return 'D'; }",
      'e1.ts': "import f from './shared';\nconsole.log('e1', f());",
      'e2.ts': "import f from './shared';\nconsole.log('e2', f());",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'cjs',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 D');
  });

  // 분산 청크 동명 export 가 cjs(native require + 동적 import)에서도 일치.
  test('cjs: 분산 청크 동명 export 가 consumer/provider 일치', async () => {
    const fixture = await createFixture({
      'a.ts': "export const v = 'AV';",
      'b.ts': "export const v = 'BV';",
      'route1.ts': "import { v } from './a';\nexport const r1 = v;",
      'route2.ts': "import { v } from './b';\nexport const r2 = v;",
      'main.ts':
        "import { v as av } from './a';\nimport { v as bv } from './b';\n" +
        "async function run(){ const m1=await import('./route1'); const m2=await import('./route2'); console.log('main', av, bv, m1.r1, m2.r2); }\nrun();",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'cjs',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('main AV BV AV BV');
  });

  // 3개 모듈 동명 collision → v/v$1/v$2 모두 distinct(owner-iterating 루프가 N owner 처리).
  test('esm: 3-way 동명 collision 이 모두 distinct', async () => {
    const fixture = await createFixture({
      'a.ts': "export const v = 'A';",
      'b.ts': "export const v = 'B';",
      'c.ts': "export const v = 'C';",
      'e1.ts':
        "import { v as a } from './a';\nimport { v as b } from './b';\nimport { v as c } from './c';\nconsole.log('e1', a, b, c);",
      'e2.ts':
        "import { v as a } from './a';\nimport { v as b } from './b';\nimport { v as c } from './c';\nconsole.log('e2', a, b, c);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 A B C');
  });

  // 한 청크에 default collision(reserved export명) + named 동명 collision 동시 — full
  // resolution(예약어 default→local) 과 owner-iterating 이 함께 정상.
  test('esm: default + named 동명 collision 공존', async () => {
    const fixture = await createFixture({
      'a.ts': "export default 'AD';\nexport const s = 'AS';",
      'b.ts': "export default 'BD';\nexport const s = 'BS';",
      'e1.ts':
        "import da, { s as sa } from './a';\nimport db, { s as sb } from './b';\nconsole.log('e1', da, db, sa, sb);",
      'e2.ts':
        "import da, { s as sa } from './a';\nimport db, { s as sb } from './b';\nconsole.log('e2', da, db, sa, sb);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const e1 = outs.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 AD BD AS BS');
  });

  // 분산 청크 동명을 iife 에서도(브라우저 시뮬 + 동적 import).
  test('iife: 분산 청크 동명 export 가 consumer/provider 일치', async () => {
    const fixture = await createFixture({
      'a.ts': "export const v = 'AV';",
      'b.ts': "export const v = 'BV';",
      'route1.ts': "import { v } from './a';\nexport const r1 = v;",
      'route2.ts': "import { v } from './b';\nexport const r2 = v;",
      'main.ts':
        "import { v as av } from './a';\nimport { v as bv } from './b';\n" +
        "async function run(){ const m1=await import('./route1'); const m2=await import('./route2'); console.log('main', av, bv, m1.r1, m2.r2); }\nrun();",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts')],
      rootDir: fixture.dir,
      platform: 'browser',
      splitting: true,
      format: 'iife',
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
    const drv = browserDriver(fixture.dir, main.path, jsPaths(outs));
    const { stdout } = await runNode(drv);
    expect(stdout.trim()).toBe('main AV BV AV BV');
  });
});
