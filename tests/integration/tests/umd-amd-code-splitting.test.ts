import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { createFixture, runNode, byContent, writeOutputs } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P3-B PR4: format=umd|amd + splitting. PR3 의 iife_split 레지스트리/
// self-register/env-loader 기계는 불변, entry 청크만 format_wrapper 의
// UMD/AMD 보편 wrapper 로 감싸고 bootstrap 을 `return __zntc_require(id)` 로.
// 디리스크 스파이크가 CJS require / global / AMD define 3모드 + 동적 청크
// 로드를 증명. 통합테스트는 결정적인 CJS-require·AMD-define 소비를 Node
// 실행으로 검증(global-script 는 스파이크+format_wrapper 단일파일 UMD 가
// 커버 — node 시뮬은 module 스코프 누출 아티팩트라 비결정적).
//
// 한계(문서화, RFC §7): 정적 cross-chunk dep 가 있는 entry 는 IIFE-split
// 과 동일 load-order 제약 — single require/define 소비는 sibling common
// 청크를 못 불러 미바인딩. → 동적-import 분할만 single-consume 안전.

describe('umd/amd + code splitting (P3-B PR4)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // 동적-only 분할(정적 cross-chunk dep 없음 → single-consume 안전).
  const dynFx = {
    'page.ts': `export function render(){ return "PAGE-OK"; }\nexport const tag = "T";`,
    'index.ts': `export const answer = 42;\nexport function load(){ return import("./page").then(m => m.render() + m.tag); }`,
  };

  test('가드 완화: umd + splitting 이 에러 아님 + 보편 wrapper 구조', async () => {
    const fixture = await createFixture(dynFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'umd',
      splitting: true,
      globalName: 'MyLib',
    });
    const outs = result.outputFiles!;
    expect(outs.filter((o) => o.path.endsWith('.js')).length).toBeGreaterThanOrEqual(2);
    const entry = byContent(outs, '__zntc_require')!;
    expect(entry.text).toMatch(/^\(function\(root, factory\) \{/m);
    expect(entry.text).toContain('module.exports = factory()');
    expect(entry.text).toContain('root.MyLib = factory()');
    expect(entry.text).toMatch(/return globalThis\.__zntc_require\("/);
    expect(entry.text.trimEnd()).toMatch(/\}\);$/); // epilogue
    // 비-entry(page) 청크는 보편 wrapper 없음(self-register IIFE 만)
    const page = outs.find((o) => o.path.includes('page') && o.path.endsWith('.js'))!;
    expect(page.text).not.toContain('(function(root, factory)');
    expect(page.text).toContain('__zntc_register');
  });

  test('umd: CJS require 소비 — entry exports + 동적 청크 로드 (Node)', async () => {
    const fixture = await createFixture(dynFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'umd',
      splitting: true,
      globalName: 'MyLib',
      publicPath: `${fixture.dir}/`,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const drv = join(fixture.dir, '__umd_cjs.cjs');
    writeFileSync(
      drv,
      `const L=require(${JSON.stringify(join(fixture.dir, entry.path))});
L.load().then(r=>{console.log("answer="+L.answer+",dyn="+r);},e=>{console.error(e&&e.message);process.exit(1);});`,
    );
    const { stdout } = await runNode(drv);
    expect(stdout).toBe('answer=42,dyn=PAGE-OKT');
  });

  test('umd: AMD define 소비 — entry exports + 동적 청크 로드 (Node)', async () => {
    const fixture = await createFixture(dynFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'umd',
      splitting: true,
      globalName: 'MyLib',
      publicPath: `${fixture.dir}/`,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const drv = join(fixture.dir, '__umd_amd.cjs');
    writeFileSync(
      drv,
      `let f;globalThis.define=function(d,fn){f=fn;};globalThis.define.amd={};
(0,eval)(require("fs").readFileSync(${JSON.stringify(join(fixture.dir, entry.path))},"utf8"));
const L=f();
L.load().then(r=>{console.log("answer="+L.answer+",dyn="+r);},e=>{console.error(e&&e.message);process.exit(1);});`,
    );
    const { stdout } = await runNode(drv);
    expect(stdout).toBe('answer=42,dyn=PAGE-OKT');
  });

  test('amd 포맷: define([], factory) wrapper + 동적 로드 (Node)', async () => {
    const fixture = await createFixture(dynFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'amd',
      splitting: true,
      publicPath: `${fixture.dir}/`,
    });
    const outs = result.outputFiles!;
    const entry = byContent(outs, '__zntc_require')!;
    expect(entry.text).toMatch(/^define\(\[\], function\(\) \{/m);
    expect(entry.text).toMatch(/return globalThis\.__zntc_require\("/);
    writeOutputs(fixture.dir, outs);
    const e2 = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const drv = join(fixture.dir, '__amd.cjs');
    writeFileSync(
      drv,
      `let f;globalThis.define=function(d,fn){f=fn;};
(0,eval)(require("fs").readFileSync(${JSON.stringify(join(fixture.dir, e2.path))},"utf8"));
const L=f();
L.load().then(r=>{console.log("dyn="+r);},e=>{console.error(e&&e.message);process.exit(1);});`,
    );
    const { stdout } = await runNode(drv);
    expect(stdout).toBe('dyn=PAGE-OKT');
  });

  test('회귀: iife + splitting 은 보편 wrapper 없음(bare bootstrap)', async () => {
    const fixture = await createFixture(dynFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
      globalName: 'MyLib',
    });
    const entry = byContent(result.outputFiles!, '__zntc_require')!;
    expect(entry.text).not.toContain('(function(root, factory)');
    expect(entry.text).not.toMatch(/return globalThis\.__zntc_require/);
    expect(entry.text).toMatch(/var MyLib\s*=\s*globalThis\.__zntc_require\(/);
  });

  test('회귀: 단일 UMD 번들(splitting 아님)은 불변', async () => {
    const fixture = await createFixture({
      'dep.ts': `export const dep = "DEP_X";`,
      'index.ts': `import { dep } from "./dep";\nexport const v = dep;`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'umd',
      globalName: 'Lib',
    });
    const single = byContent(result.outputFiles!, 'DEP_X')!;
    expect(single).toBeDefined();
    expect(single.text).not.toContain('__zntc_register');
    expect(single.text).toContain('(function(root, factory)');
  });
});
