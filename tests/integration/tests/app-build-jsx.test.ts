// app build (`zntc build` → buildAppSync) 의 JSX runtime 옵션 전달 회귀 가드.
//
// buildAppSync 가 jsx/jsxImportSource/jsxFactory/jsxFragment 를 buildApp 에 안
// 넘겨 항상 JsxConfig default(.classic)로 떨어지던 버그. pragma 없는 파일이
// `React.createElement` 로 변환되는데 automatic 모드 사용자는 React 를 import
// 하지 않아 런타임 `React is not defined`. (`zntc --bundle` 은 jsx 전달돼 정상,
// app build 만 누락했다.)

import { describe, test, expect, afterEach } from 'bun:test';
import { buildApp, buildAppSync, init } from '@zntc/core';
import { createFixture } from './helpers';
import { join } from 'node:path';
import { readFileSync, readdirSync } from 'node:fs';

init();

describe('app build — JSX runtime 옵션 전달 (#React-not-defined 회귀)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const REACT_STUB = {
    'node_modules/react/package.json': JSON.stringify({
      name: 'react',
      version: '19.0.0',
      exports: { './jsx-runtime': './jsx-runtime.js' },
    }),
    'node_modules/react/jsx-runtime.js':
      'export function jsx(t,p){return{t,p};}\nexport function jsxs(t,p){return{t,p};}\nexport const Fragment="F";\n',
  };

  async function buildApp(jsx: string): Promise<string> {
    const fx = await createFixture({
      'index.html':
        '<!doctype html><html><body><div id="root"></div><script type="module" src="/main.tsx"></script></body></html>',
      'main.tsx': 'export const App = () => <div>hi</div>;\nglobalThis.__App = App;\n',
      ...REACT_STUB,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'dist');
    buildAppSync({ root: fx.dir, outdir: out, entryHtml: 'index.html', publicDir: false, jsx });
    const jsName = readdirSync(out).find((f) => f.endsWith('.js'))!;
    return readFileSync(join(out, jsName), 'utf8');
  }

  test('jsx: automatic → react/jsx-runtime 사용, React.createElement 미생성', async () => {
    const code = await buildApp('automatic');
    expect(code).not.toMatch(/React\.createElement/);
    expect(code).toMatch(/jsx-runtime/);
  });

  test('jsx: classic → React.createElement 사용 (옵션 그대로 반영)', async () => {
    const code = await buildApp('classic');
    expect(code).toMatch(/React\.createElement/);
    expect(code).not.toMatch(/jsx-runtime/);
  });
});

// RFC #3833 v2-A — async `buildApp` 등가성 검증. buildAppSync 와 동일한
// 결과 (JSX runtime 처리 등) 를 내야 함. async path 도 회귀 가드.
describe('app build — buildApp (async, v2-A)', () => {
  let cleanup: (() => Promise<void>) | undefined;
  afterEach(async () => {
    await cleanup?.();
    cleanup = undefined;
  });

  const REACT_STUB = {
    'node_modules/react/package.json': JSON.stringify({
      name: 'react',
      version: '19.0.0',
      exports: { './jsx-runtime': './jsx-runtime.js' },
    }),
    'node_modules/react/jsx-runtime.js':
      'export function jsx(t,p){return{t,p};}\nexport function jsxs(t,p){return{t,p};}\nexport const Fragment="F";\n',
  };

  async function buildAppAsync(jsx: string): Promise<string> {
    const fx = await createFixture({
      'index.html':
        '<!doctype html><html><body><div id="root"></div><script type="module" src="/main.tsx"></script></body></html>',
      'main.tsx': 'export const App = () => <div>hi</div>;\nglobalThis.__App = App;\n',
      ...REACT_STUB,
    });
    cleanup = fx.cleanup;
    const out = join(fx.dir, 'dist');
    await buildApp({ root: fx.dir, outdir: out, entryHtml: 'index.html', publicDir: false, jsx });
    const jsName = readdirSync(out).find((f) => f.endsWith('.js'))!;
    return readFileSync(join(out, jsName), 'utf8');
  }

  test('async buildApp + jsx: automatic → buildAppSync 와 동등', async () => {
    const code = await buildAppAsync('automatic');
    expect(code).not.toMatch(/React\.createElement/);
    expect(code).toMatch(/jsx-runtime/);
  });

  test('async buildApp + jsx: classic → buildAppSync 와 동등', async () => {
    const code = await buildAppAsync('classic');
    expect(code).toMatch(/React\.createElement/);
    expect(code).not.toMatch(/jsx-runtime/);
  });
});
