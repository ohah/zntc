import { describe, test, expect, beforeAll, afterAll, afterEach } from 'bun:test';
import { join } from 'node:path';
import { createFixture, runNode, byContent, writeOutputs, writeIifeDriver } from './helpers';
import { init, close, build } from '../../../packages/core/index';

// P3-B PR3 (#3321): format=iife + splitting=true — 런타임 require 레지스트리
// (`__zntc_*`) + self-register factory + `<script>` 동적 로더(RFC §4.1/§4.3).
// 디리스크 스파이크(RFC §6 IIFE)가 브라우저 시뮬레이션으로 증명한 행동을
// 빌더 산출물로 영구화. ESM/CJS splitting·단일 IIFE 번들은 불변(회귀).

// 드라이버 헬퍼는 helpers.ts 의 writeIifeDriver(dir, entry, allJs, env) 로 공용화.
const writeBrowserDriver = (dir: string, entryFile: string, allJs: string[]): string =>
  writeIifeDriver(dir, entryFile, allJs, 'dom');

const jsOf = (outs: { path: string }[]) =>
  outs.filter((o) => o.path.endsWith('.js')).map((o) => o.path);

describe('iife + code splitting (P3-B PR3)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  beforeAll(() => init());
  afterAll(() => close());
  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test('가드 완화: iife + splitting 이 에러 아님 + 다중 청크', async () => {
    const fixture = await createFixture({
      'index.ts': `export async function load(){ return (await import("./page")).render(); }\nload();`,
      'page.ts': `import { label } from "./shared";\nexport function render(){ return label; }`,
      'shared.ts': `export const label = "SHARED_OK";`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    expect(result.outputFiles).toBeDefined();
    expect(jsOf(result.outputFiles!).length).toBeGreaterThanOrEqual(2);
  });

  test('구조: 레지스트리 + self-register factory + 로더, ESM 누출 없음', async () => {
    const fixture = await createFixture({
      'index.ts': `import { v } from "./s";\nconst p = import("./d");\nconsole.log(v, p);`,
      's.ts': `export const v = "V";`,
      'd.ts': `export const d = 1;`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    const outs = result.outputFiles!;
    const entry = byContent(outs, '__zntc_require(')!;
    expect(entry).toBeDefined();
    // 엔트리: 해석 계층 + 부트스트랩
    expect(entry.text).toContain('globalThis.__zntc_public_path=');
    expect(entry.text).toMatch(/g\.__zntc_require\s*=\s*function/);
    expect(entry.text).toContain('document.createElement("script")');
    // self-register factory wrapper
    expect(entry.text).toContain('__zntc_register');
    expect(entry.text).toMatch(/function\s*\(exports,\s*module,\s*require\)/);
    // 동적 import → __zntc_load_chunk(...).then
    expect(entry.text).toMatch(/__zntc_load_chunk\("[^"]+"\)\.then\(/);
    // 정적 cross-chunk → __zntc_require, ESM import/export 없음
    for (const o of outs.filter((x) => x.path.endsWith('.js'))) {
      expect(o.text).not.toMatch(/^\s*import\s+[{*]/m);
      expect(o.text).not.toMatch(/^\s*export\s+[{*]/m);
    }
  });

  test('스파이크 시나리오: 정적 cross-chunk + 동적 로드 + 캐시 보존 (브라우저 시뮬 Node 실행)', async () => {
    const fixture = await createFixture({
      'index.ts': `
        import { bump, label } from "./shared";
        async function main() {
          const out = [];
          out.push("static:" + label + ":" + bump());   // count=1
          const page = await import("./page");
          out.push("dynamic:" + page.render());          // count=2
          out.push("again:" + page.render());            // count=3 (캐시)
          console.log(out.join("|"));
        }
        main();
      `,
      'shared.ts': `let count = 0;\nexport function bump(){ return ++count; }\nexport const label = "S";`,
      'page.ts': `import { bump, label } from "./shared";\nexport function render(){ return label + ":" + bump(); }`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const driver = writeBrowserDriver(fixture.dir, entry.path, jsOf(outs));
    const { stdout } = await runNode(driver);
    expect(stdout).toBe('static:S:1|dynamic:S:2|again:S:3');
  });

  test('default + named export 동적 import (factory-bound exports)', async () => {
    const fixture = await createFixture({
      'index.ts': `
        import { bump } from "./shared";
        async function main(){
          const o=[];
          o.push("st:"+bump());
          const p=await import("./page");
          o.push("def:"+p.default());
          o.push("tag:"+p.tag);
          o.push("again:"+p.default());
          console.log(o.join("|"));
        }
        main();
      `,
      'shared.ts': `let c=0;\nexport function bump(){ return ++c; }`,
      'page.ts': `import { bump } from "./shared";\nexport default function(){ return "D"+bump(); }\nexport const tag = "PG";`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const driver = writeBrowserDriver(fixture.dir, entry.path, jsOf(outs));
    const { stdout } = await runNode(driver);
    expect(stdout).toBe('st:1|def:D2|tag:PG|again:D3');
  });

  test('global_name: 엔트리 결과를 전역 var 로 노출', async () => {
    const fixture = await createFixture({
      'index.ts': `export const answer = 42;\nexport function hello(){ return "hi"; }`,
      'd.ts': `export const d = 1;`,
      'use.ts': `export async function load(){ return import("./d"); }`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
      globalName: 'MyLib',
    });
    const entry = result.outputFiles!.find(
      (o) => o.path.includes('index') && o.path.endsWith('.js'),
    )!;
    expect(entry.text).toMatch(/var MyLib\s*=\s*globalThis\.__zntc_require\("/);
  });

  test('minify: 단일행 레지스트리/factory 도 브라우저 시뮬에서 동작', async () => {
    const fixture = await createFixture({
      'index.ts': `
        import { tag } from "./shared";
        async function main(){ const p = await import("./page"); console.log(tag + "|" + p.go()); }
        main();
      `,
      'shared.ts': `export const tag = "T";`,
      'page.ts': `import { tag } from "./shared";\nexport function go(){ return "GO:" + tag; }`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
      minifyWhitespace: true,
    });
    const outs = result.outputFiles!;
    // min: 레지스트리 런타임에 개행 없음(연속 emit 안전)
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    expect(entry.text).toContain('__zntc_require');
    writeOutputs(fixture.dir, outs);
    const driver = writeBrowserDriver(fixture.dir, entry.path, jsOf(outs));
    const { stdout } = await runNode(driver);
    expect(stdout).toBe('T|GO:T');
  });

  test('다중 동적 청크: 각각 독립 로드 + 공유 common 캐시', async () => {
    const fixture = await createFixture({
      'index.ts': `
        import { base } from "./shared";
        async function main(){
          const a = await import("./a");
          const b = await import("./b");
          console.log(base + "|" + a.ay() + "|" + b.by());
        }
        main();
      `,
      'shared.ts': `let n=0;\nexport const base="B";\nexport function tick(){ return ++n; }`,
      'a.ts': `import { tick } from "./shared";\nexport function ay(){ return "A" + tick(); }`,
      'b.ts': `import { tick } from "./shared";\nexport function by(){ return "B" + tick(); }`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    const outs = result.outputFiles!;
    expect(jsOf(outs).length).toBeGreaterThanOrEqual(3);
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    const driver = writeBrowserDriver(fixture.dir, entry.path, jsOf(outs));
    const { stdout } = await runNode(driver);
    // shared 의 tick 카운터가 a,b 동적 청크 간에 공유(common 캐시)
    expect(stdout).toBe('B|A1|B2');
  });

  test('회귀: esm + splitting 은 native import() 그대로 (레지스트리 없음)', async () => {
    const fixture = await createFixture({
      'index.ts': `export async function load(){ return (await import("./d")).v; }`,
      'd.ts': `export const v = 1;`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'esm',
      splitting: true,
    });
    const idx = byContent(result.outputFiles!, 'load')!;
    expect(idx.text).not.toContain('__zntc_require');
    expect(idx.text).not.toContain('__zntc_load_chunk');
  });

  test('회귀: cjs + splitting 은 native require (레지스트리 미사용)', async () => {
    const fixture = await createFixture({
      'index.ts': `import { v } from "./s";\nconst p = import("./d");\nconsole.log(v, p);`,
      's.ts': `export const v = "V";`,
      'd.ts': `export const d = 1;`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'cjs',
      splitting: true,
    });
    const entry = byContent(result.outputFiles!, 'require(')!;
    expect(entry.text).toContain('require(');
    expect(entry.text).not.toContain('__zntc_require');
  });

  test('회귀: 단일 IIFE 번들(splitting 아님)은 불변', async () => {
    const fixture = await createFixture({
      'dep.ts': `export const dep = "DEP_X";`,
      'index.ts': `import { dep } from "./dep";\nconsole.log(dep);`,
    });
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
    });
    const single = byContent(result.outputFiles!, 'DEP_X')!;
    expect(single).toBeDefined();
    expect(single.text).not.toContain('__zntc_register');
    expect(single.text).not.toContain('__zntc_load_chunk');
  });

  // PR4: 비-DOM 로더 폴백. PR3 로더는 `document.createElement` 만 써
  // worker/Deno/Node-ESM 에서 `document is not defined`. 환경 감지로
  // worker→importScripts, 그 외→`import(url)` 폴백 추가.
  const splitFx = {
    'shared.ts': `let n=0;\nexport function tick(){ return ++n; }\nexport const lbl="L";`,
    'page.ts': `import { tick, lbl } from "./shared";\nexport function render(){ return lbl + tick(); }`,
    'index.ts': `
      import { tick } from "./shared";
      async function main(){ tick(); const p = await import("./page"); console.log("R:" + p.render()); }
      main();
    `,
  };

  test('비-DOM: Web Worker(importScripts) 환경에서 동적 청크 로드', async () => {
    const fixture = await createFixture(splitFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    // document 없음 + importScripts 만 정의 → 로더가 importScripts 분기 사용.
    const drv = writeIifeDriver(fixture.dir, entry.path, jsOf(outs), 'worker');
    const { stdout } = await runNode(drv);
    expect(stdout).toBe('R:L2');
  });

  test('비-DOM: document/importScripts 없음 → 동적 import(url) 폴백', async () => {
    const fixture = await createFixture(splitFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
      // import() 는 해석 가능한 URL 필요 — file:// public path 베이크.
      publicPath: `file://${fixture.dir}/`,
    });
    const outs = result.outputFiles!;
    writeOutputs(fixture.dir, outs);
    const entry = outs.find((o) => o.path.includes('index') && o.path.endsWith('.js'))!;
    // document 도 importScripts 도 없음 → 로더가 import(file://...) 분기.
    const drv = writeIifeDriver(fixture.dir, entry.path, jsOf(outs), 'nondom');
    const { stdout } = await runNode(drv);
    expect(stdout).toBe('R:L2');
  });

  test('구조: 로더가 환경 3분기(document / importScripts / import) 포함', async () => {
    const fixture = await createFixture(splitFx);
    cleanup = fixture.cleanup;
    const result = await build({
      entryPoints: [join(fixture.dir, 'index.ts')],
      format: 'iife',
      splitting: true,
    });
    const entry = byContent(result.outputFiles!, '__zntc_load_chunk')!;
    expect(entry.text).toMatch(/typeof document\s*!==\s*["']undefined["']/);
    expect(entry.text).toMatch(/typeof importScripts\s*===\s*["']function["']/);
    expect(entry.text).toMatch(/import\(url\)/);
  });
});
