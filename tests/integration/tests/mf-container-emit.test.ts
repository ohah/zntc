import { describe, test, expect, afterEach } from 'bun:test';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { runConfigBundle, writeOutputs, runNode } from './helpers';

// P1-3 (#3385): webpack-style container emit (remoteEntry).
//   - entry 청크의 eager bootstrap(`var X=__zntc_require("id")`)을
//     container 객체(`init(shareScope,initScope)` / `get(id):Promise<factory>`,
//     globalName 대입)로 wrap. exposed 모듈은 자기 lazy 청크.
//   - get(expose) = `__zntc_load_chunk(stem).then(()=>__zntc_require(fed_id))`
//     (P3-B 동적 import wrapper 재사용 — exposed 번들 eval 은 get() 까지 지연).
//   - 비-목표: shareScopeMap/shared→async 협상(P1-4), 별도 manifest 파일(P1-5).
describe('MF P1-3: webpack-style container emit', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  test('container 형태: init/get + globalName 대입, eager bootstrap 제거', async () => {
    const r = await runConfigBundle({
      files: {
        'index.ts': `export const sentinel = "remote-entry";`,
        'Widget.ts': `export default function Widget() { return "WIDGET-OK"; }`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
        }),
      },
      args: ['--format=iife'],
      outDir: 'out',
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);

    const files = readdirSync(r.outDir!);
    const entryFile = files.find(
      (f) =>
        f.endsWith('.js') &&
        readFileSync(join(r.outDir!, f), 'utf8').includes('__zntc_mf_container'),
    );
    expect(entryFile).toBeDefined();
    const entry = readFileSync(join(r.outDir!, entryFile!), 'utf8');

    // container 객체 + globalName 대입 (mf.name='app' → 유효 식별자 → g.app=)
    expect(entry).toMatch(/\bg\.app\s*=\s*__zntc_mf_container\b/);
    expect(entry).toContain('init:');
    expect(entry).toContain('get:');
    // MF2 runtime 계약(실 @module-federation/runtime interop 검증으로 포착):
    //  ① 기본 키 globalThis["__FEDERATION_<name>:custom__"]
    //  ② loadScriptNode(Node) 는 module.exports 를 container 로 읽음
    expect(entry).toContain('"__FEDERATION_app:custom__"]=__zntc_mf_container');
    expect(entry).toMatch(/module\.exports\s*=\s*__zntc_mf_container/);
    // get(expose) ⇒ Promise<factory>, factory()⇒Module (MF2 thunk 계약)
    expect(entry).toMatch(/"\.\/Widget"\s*:\s*function/);
    expect(entry).toMatch(
      /__zntc_load_chunk\([^)]*\)\.then\(function\(\)\{return function\(\)\{return __zntc_require\(/,
    );
    // eager bootstrap 제거 — container 는 자기실행 금지(host 가 init/get 구동)
    expect(entry).not.toMatch(/var\s+\w+\s*=\s*globalThis\.__zntc_require\(/);
  });

  test('interop 계약: init→get 으로 exposed 모듈 lazy 도달 (S1/S3 형태)', async () => {
    const r = await runConfigBundle({
      files: {
        // exposed 모듈은 import 시 side-effect — get() 전엔 평가 안 됨(lazy) 검증용
        'Widget.ts': `globalThis.__widget_evaluated = true;\nexport default function Widget() { return "WIDGET-42"; }`,
        'index.ts': `export const sentinel = "remote-entry";`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
        }),
      },
      args: ['--format=iife'],
      outDir: 'out',
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);

    const outs = readdirSync(r.outDir!).map((f) => ({
      path: f,
      text: readFileSync(join(r.outDir!, f), 'utf8'),
    }));
    writeOutputs(r.dir, outs);
    const entryFile = outs.find((o) => o.text.includes('__zntc_mf_container'))!.path;

    // 동적 청크 로더(nondom: import(url)) → publicPath = file://<dir>/
    // entry(remoteEntry) 가 자기 __zntc_public_path 를 "" 로 초기화하므로,
    // 표준 MF 패턴대로 entry import *후* host 가 publicPath 주입.
    const driver = `
      await import(${JSON.stringify('file://' + join(r.dir, entryFile))});
      globalThis.__zntc_public_path = ${JSON.stringify('file://' + r.dir + '/')};
      const c = globalThis.app;
      if (typeof c.init !== 'function' || typeof c.get !== 'function')
        throw new Error('container 계약 위반: init/get 없음');
      // init-before-get: init() 후 get(). get 전엔 Widget 미평가(lazy).
      c.init({});
      if (globalThis.__widget_evaluated) throw new Error('lazy 위반: get 전 Widget 평가됨');
      const factory = await c.get('./Widget');
      const mod = factory();
      const Widget = mod.default ?? mod;
      console.log('RESULT=' + Widget());
      console.log('EVALUATED=' + !!globalThis.__widget_evaluated);
    `;
    const driverPath = join(r.dir, 'driver.mjs');
    require('node:fs').writeFileSync(driverPath, driver);
    const { stdout, stderr } = await runNode(driverPath);
    expect(stderr).toBe('');
    expect(stdout).toContain('RESULT=WIDGET-42');
    expect(stdout).toContain('EVALUATED=true');
  });

  // 갭 보강(레퍼런스 api.spec 'same name → same instance' 대비): container
  // init 멱등(`__zntc_mf_inited` Promise-cache) — 재호출 시 같은 Promise,
  // 부수효과 1회. 반복 get 도 동일 모듈. 기존 테스트는 init/get 1회씩만.
  test('멱등: init 2회=같은 Promise, get 2회=동일 모듈, 부수효과 1회', async () => {
    const r = await runConfigBundle({
      files: {
        'Widget.ts':
          `globalThis.__evN = (globalThis.__evN || 0) + 1;\n` +
          `export default function Widget() { return "W"; }`,
        'index.ts': `export const sentinel = "remote-entry";`,
        'zntc.config.json': JSON.stringify({
          mf: { name: 'app', exposes: { './Widget': './Widget.ts' } },
        }),
      },
      args: ['--format=iife'],
      outDir: 'out',
    });
    cleanup = r.cleanup;
    expect(r.exitCode).toBe(0);
    const outs = readdirSync(r.outDir!).map((f) => ({
      path: f,
      text: readFileSync(join(r.outDir!, f), 'utf8'),
    }));
    writeOutputs(r.dir, outs);
    const entryFile = outs.find((o) => o.text.includes('__zntc_mf_container'))!.path;
    const driver = `
      await import(${JSON.stringify('file://' + join(r.dir, entryFile))});
      globalThis.__zntc_public_path = ${JSON.stringify('file://' + r.dir + '/')};
      const c = globalThis.app;
      const p1 = c.init({}); const p2 = c.init({});
      console.log('INIT_SAME=' + (p1 === p2));   // 같은 Promise 재반환(멱등)
      await p1;
      const m1 = (await c.get('./Widget'))();
      const m2 = (await c.get('./Widget'))();
      console.log('GET_SAME=' + (m1 === m2 || m1.default === m2.default));
      console.log('SIDE_EFFECT=' + globalThis.__evN); // factory 1회만 평가
    `;
    const driverPath = join(r.dir, 'driver.mjs');
    require('node:fs').writeFileSync(driverPath, driver);
    const { stdout, stderr } = await runNode(driverPath);
    expect(stderr).toBe('');
    expect(stdout).toContain('INIT_SAME=true');
    expect(stdout).toContain('GET_SAME=true');
    expect(stdout).toContain('SIDE_EFFECT=1');
  });
});
