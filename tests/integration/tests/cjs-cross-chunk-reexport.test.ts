import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, writeOutputs } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// CJS 모듈을 cross-chunk(splitting) 경계 너머로 re-export(`export { default, named } from
// './cjslib.js'`)할 때의 정확성. 단일 번들은 정상이나 splitting 에서 interop 바인딩
// (`var x = __toESM(require_cjslib()).default`)이 CJS 모듈 청크가 아닌 consumer 청크에
// 오배치 → require_cjslib undefined / 중복 선언 / ESM 표현식 specifier SyntaxError 였다.
// (#4101 — CJS-default cross-chunk finalize)
//
// CJS 디폴트 = module.exports(여기선 함수), named = module.exports.named.

const CJSLIB = "module.exports = function(){ return 'D'; };\nmodule.exports.named = 9;";

// iife 브라우저 시뮬 드라이버 (entry + 모든 청크 로드, 다른 entry 제외).
function browserDriver(dir: string, entryFile: string, allJs: string[]): string {
  const drv = join(dir, '__cdrv.cjs');
  const others = allJs.filter((p) => p !== entryFile);
  writeFileSync(
    drv,
    `const fs=require("fs"),path=require("path");const here=${JSON.stringify(dir)};
function ev(f){(0,eval)(fs.readFileSync(path.join(here,f),"utf8"));}
globalThis.__zntc_public_path="";globalThis.define=undefined;
globalThis.document={createElement(){return {};},head:{appendChild(s){ev(s.src);if(s.onload)s.onload();}}};
${others.map((f) => `ev(${JSON.stringify(f)});`).join('\n')}
ev(${JSON.stringify(entryFile)});`,
  );
  return drv;
}

const jsPaths = (outs: { path: string }[]) =>
  outs.filter((o) => o.path.endsWith('.js')).map((o) => o.path);

describe('CJS cross-chunk re-export (#4101)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // 청크 내부 식별자/export 가 미정의·중복·표현식이면 SyntaxError/ReferenceError 로 즉시
  // throw 하므로 *실행 결과*가 곧 정확성 가드. 추가로 청크 텍스트도 검사.
  function assertNoBrokenChunk(outs: { path: string; text: string }[]): void {
    for (const o of outs) {
      if (!o.path.endsWith('.js')) continue;
      // ESM export 지정자에 표현식(괄호 호출) 금지: `export { foo() as x }` / `export { a.b as x }`.
      const esmExports = o.text.match(/export\s*\{[^}]*\}/g) ?? [];
      for (const stmt of esmExports) {
        const inner = stmt.replace(/export\s*\{|\}/g, '');
        for (const spec of inner.split(',')) {
          const local = (spec.includes(' as ') ? spec.split(' as ')[0] : spec).trim();
          if (!local) continue;
          expect(local).not.toMatch(/[().]/); // 식별자만 — `require_x().y` / `a.b` 불가
        }
      }
    }
  }

  // ── 정적(static) re-export ─────────────────────────────────────────────

  for (const format of ['esm', 'cjs'] as const) {
    test.todo(`${format}: 정적 — export { default, named } from CJS, 별도 entry 가 사용`, async () => {
      const fixture = await createFixture({
        'cjslib.js': CJSLIB,
        'Route.ts': "export { default, named } from './cjslib.js';",
        'a.ts':
          "import d, { named } from './Route';\nexport const ad = () => d();\nexport const an = named;",
        'main.ts': "import { ad, an } from './a';\nconsole.log('R', ad(), an);",
      });
      cleanup = fixture.cleanup;
      const result = await build({
        entryPoints: [join(fixture.dir, 'main.ts'), join(fixture.dir, 'a.ts')],
        rootDir: fixture.dir,
        platform: 'node',
        splitting: true,
        format,
      });
      expect(result.errors ?? []).toHaveLength(0);
      const outs = result.outputFiles!;
      assertNoBrokenChunk(outs);
      writeOutputs(fixture.dir, outs);
      const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
      const { stdout } = await runNode(join(fixture.dir, main.path));
      expect(stdout.trim()).toBe('R D 9');
    });
  }

  // ── 동적(dynamic) re-export ───────────────────────────────────────────

  test.todo('esm: 동적 — import("./Route") 가 CJS default/named 재export 를 받음', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { default, named } from './cjslib.js';",
      'main.ts':
        "async function run(){ const m = await import('./Route'); console.log('R', m.default(), m.named); }\nrun();",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    expect(result.errors ?? []).toHaveLength(0);
    const outs = result.outputFiles!;
    assertNoBrokenChunk(outs);
    writeOutputs(fixture.dir, outs);
    const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('R D 9');
  });

  test.todo('cjs: 동적 — import("./Route") 가 CJS default/named 재export 를 받음', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { default, named } from './cjslib.js';",
      'main.ts':
        "async function run(){ const m = await import('./Route'); console.log('R', m.default(), m.named); }\nrun();",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'cjs',
    });
    expect(result.errors ?? []).toHaveLength(0);
    const outs = result.outputFiles!;
    assertNoBrokenChunk(outs);
    writeOutputs(fixture.dir, outs);
    const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('R D 9');
  });

  // ── default 단독 / named 단독 ─────────────────────────────────────────

  test.todo('esm: default 단독 재export', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { default } from './cjslib.js';",
      'a.ts': "import d from './Route';\nexport const ad = () => d();",
      'main.ts': "import { ad } from './a';\nconsole.log('R', ad());",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts'), join(fixture.dir, 'a.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    expect(result.errors ?? []).toHaveLength(0);
    assertNoBrokenChunk(result.outputFiles!);
    writeOutputs(fixture.dir, result.outputFiles!);
    const main = result.outputFiles!.find(
      (o) => o.path.includes('main') && o.path.endsWith('.js'),
    )!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('R D');
  });

  test.todo('esm: named 단독 재export', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { named } from './cjslib.js';",
      'a.ts': "import { named } from './Route';\nexport const an = named;",
      'main.ts': "import { an } from './a';\nconsole.log('R', an);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts'), join(fixture.dir, 'a.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    expect(result.errors ?? []).toHaveLength(0);
    assertNoBrokenChunk(result.outputFiles!);
    writeOutputs(fixture.dir, result.outputFiles!);
    const main = result.outputFiles!.find(
      (o) => o.path.includes('main') && o.path.endsWith('.js'),
    )!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('R 9');
  });

  // ── renamed re-export (`export { default as foo }`) ───────────────────

  test.todo('esm: renamed — export { default as widget, named as n } from CJS', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { default as widget, named as n } from './cjslib.js';",
      'a.ts':
        "import { widget, n } from './Route';\nexport const aw = () => widget();\nexport const an = n;",
      'main.ts': "import { aw, an } from './a';\nconsole.log('R', aw(), an);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts'), join(fixture.dir, 'a.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    expect(result.errors ?? []).toHaveLength(0);
    assertNoBrokenChunk(result.outputFiles!);
    writeOutputs(fixture.dir, result.outputFiles!);
    const main = result.outputFiles!.find(
      (o) => o.path.includes('main') && o.path.endsWith('.js'),
    )!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('R D 9');
  });

  // ── 여러 consumer (재export 가 2 entry 에서 공유) ─────────────────────

  test.todo('esm: 두 entry 가 같은 CJS 재export 를 공유', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { default, named } from './cjslib.js';",
      'e1.ts': "import d, { named } from './Route';\nconsole.log('e1', d(), named);",
      'e2.ts': "import d, { named } from './Route';\nconsole.log('e2', d(), named);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'e1.ts'), join(fixture.dir, 'e2.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    expect(result.errors ?? []).toHaveLength(0);
    assertNoBrokenChunk(result.outputFiles!);
    writeOutputs(fixture.dir, result.outputFiles!);
    const e1 = result.outputFiles!.find((o) => o.path.includes('e1') && o.path.endsWith('.js'))!;
    const { stdout } = await runNode(join(fixture.dir, e1.path));
    expect(stdout.trim()).toBe('e1 D 9');
  });

  // ── iife (브라우저 시뮬) ──────────────────────────────────────────────

  test.todo('iife: 동적 — CJS default/named 재export', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'Route.ts': "export { default, named } from './cjslib.js';",
      'main.ts':
        "async function run(){ const m = await import('./Route'); console.log('R', m.default(), m.named); }\nrun();",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts')],
      rootDir: fixture.dir,
      platform: 'browser',
      splitting: true,
      format: 'iife',
    });
    expect(result.errors ?? []).toHaveLength(0);
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const main = outs.find((o) => o.path.includes('main') && o.path.endsWith('.js'))!;
    const drv = browserDriver(fixture.dir, main.path, jsPaths(outs));
    const { stdout } = await runNode(drv);
    expect(stdout.trim()).toBe('R D 9');
  });

  // ── 회귀 가드: ESM named import 인 CJS(인터롭) 가 일반 named 와 섞임 ──

  test.todo('esm: CJS named + ESM 모듈 named 혼합 재export 가 cross-chunk 정상', async () => {
    const fixture = await createFixture({
      'cjslib.js': CJSLIB,
      'esmlib.ts': "export const esmv = 'E';",
      'Route.ts': "export { named } from './cjslib.js';\nexport { esmv } from './esmlib';",
      'a.ts':
        "import { named, esmv } from './Route';\nexport const an = named;\nexport const ae = esmv;",
      'main.ts': "import { an, ae } from './a';\nconsole.log('R', an, ae);",
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'main.ts'), join(fixture.dir, 'a.ts')],
      rootDir: fixture.dir,
      platform: 'node',
      splitting: true,
      format: 'esm',
    });
    expect(result.errors ?? []).toHaveLength(0);
    assertNoBrokenChunk(result.outputFiles!);
    writeOutputs(fixture.dir, result.outputFiles!);
    const main = result.outputFiles!.find(
      (o) => o.path.includes('main') && o.path.endsWith('.js'),
    )!;
    const { stdout } = await runNode(join(fixture.dir, main.path));
    expect(stdout.trim()).toBe('R 9 E');
  });
});
