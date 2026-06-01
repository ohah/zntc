import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { createRequire } from 'node:module';
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import vm from 'node:vm';

import { APP_DEV_REACT_REFRESH_PATH } from '@zntc/server';

import { buildReactRefreshPreamble } from './react-refresh-preamble.ts';
import { injectAppDevReactRefreshPreamble } from './inject.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-rfr-'));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function installReactStub(): void {
  mkdirSync(join(dir, 'node_modules/react'), { recursive: true });
  writeFileSync(
    join(dir, 'node_modules/react/package.json'),
    '{"name":"react","version":"19.0.0","main":"index.js"}',
  );
  writeFileSync(join(dir, 'node_modules/react/index.js'), 'module.exports={};');
}

// 레포에 설치된 react-refresh 루트를 찾는다(repo root resolve → .bun glob fallback).
// transitive dep 라 hoist 안 됐을 수 있어 .bun 도 본다. 못 찾으면 null(테스트 graceful skip).
function findRepoReactRefresh(): string | null {
  const repoRoot = resolve(process.cwd(), '../..'); // packages/web → repo root
  try {
    return dirname(createRequire(join(repoRoot, 'x.js')).resolve('react-refresh/runtime'));
  } catch {
    /* fall through to .bun */
  }
  try {
    const bun = join(repoRoot, 'node_modules/.bun');
    const entry = readdirSync(bun)
      .filter((d) => d.startsWith('react-refresh@'))
      .sort()
      .pop();
    if (entry) return join(bun, entry, 'node_modules/react-refresh');
  } catch {
    /* none */
  }
  return null;
}

function installReactRefresh(rrRoot: string): void {
  cpSync(rrRoot, join(dir, 'node_modules/react-refresh'), { recursive: true });
}

describe('buildReactRefreshPreamble', () => {
  test('react 미설치(비-React 앱) → null (주입/서빙/경고 스킵)', () => {
    expect(buildReactRefreshPreamble(dir)).toBeNull();
  });

  test('react 있으나 react-refresh 미설치 → noop + 설치 경고', () => {
    installReactStub();
    const p = buildReactRefreshPreamble(dir);
    expect(p).not.toBeNull();
    expect(p!.includes('react-refresh not found')).toBe(true);
  });

  test('react + react-refresh 설치 → 런타임 번들 + injectIntoGlobalHook + __ReactRefresh', () => {
    const rrRoot = findRepoReactRefresh();
    if (!rrRoot) {
      // 레포 환경에 react-refresh 가 없으면 skip(이 케이스만 — 다른 케이스는 무관).
      console.warn(
        '[react-refresh-preamble.test] react-refresh not in repo — skipping real-preamble case',
      );
      return;
    }
    installReactStub();
    installReactRefresh(rrRoot);
    const p = buildReactRefreshPreamble(dir);
    expect(p).not.toBeNull();
    // 런타임이 글로벌에 노출되고 reconciler 패치를 호출.
    expect(p!.includes('g.__ReactRefresh=rt')).toBe(true); // resolveRefresh 단락의 핵심
    expect(p!.includes('injectIntoGlobalHook(g)')).toBe(true);
    expect(p!.includes('__zntc_react_refresh_preamble__')).toBe(true);
    // process 셰도우(dev cjs 의 NODE_ENV 가드 통과) + 런타임 본문 번들.
    expect(p!.includes('var process={env:{NODE_ENV:"development"}}')).toBe(true);
    expect(p!.includes('createSignatureFunctionForTransform')).toBe(true);
    // 실제 평가: 브라우저처럼 window/globalThis 만 있는 컨텍스트에서 깨지지 않고
    // __ReactRefresh.injectIntoGlobalHook 가 함수로 노출된다.
    const sandbox: Record<string, unknown> = { window: {}, console: { warn() {}, error() {} } };
    sandbox.globalThis = sandbox;
    vm.runInNewContext(p!, sandbox);
    expect(
      typeof (sandbox.__ReactRefresh as { injectIntoGlobalHook?: unknown })?.injectIntoGlobalHook,
    ).toBe('function');
  });
});

describe('injectAppDevReactRefreshPreamble', () => {
  function html(content: string): string {
    const out = join(dir, 'index.html');
    writeFileSync(out, content);
    return out;
  }

  test('첫 <script> 앞에 classic preamble script 를 삽입(앱 번들보다 먼저 실행)', () => {
    const p = html(
      '<!doctype html><head></head><body><script type="module" src="/src/main.tsx"></script></body>',
    );
    injectAppDevReactRefreshPreamble(dir);
    const out = readFileSync(p, 'utf8');
    const preIdx = out.indexOf(APP_DEV_REACT_REFRESH_PATH);
    const appIdx = out.indexOf('/src/main.tsx');
    expect(preIdx).toBeGreaterThanOrEqual(0);
    expect(preIdx).toBeLessThan(appIdx); // preamble 이 앱 script 보다 앞
    // classic(non-module) script 여야 동기 실행.
    expect(out.includes(`<script src="${APP_DEV_REACT_REFRESH_PATH}"></script>`)).toBe(true);
  });

  test('멱등 — 두 번 호출해도 1회만 삽입', () => {
    const p = html('<head></head><body><script src="/app.js"></script></body>');
    injectAppDevReactRefreshPreamble(dir);
    injectAppDevReactRefreshPreamble(dir);
    const out = readFileSync(p, 'utf8');
    const count = out.split(APP_DEV_REACT_REFRESH_PATH).length - 1;
    expect(count).toBe(1);
  });

  test('index.html 없으면 silent no-op (ENOENT)', () => {
    expect(() => injectAppDevReactRefreshPreamble(dir)).not.toThrow();
  });
});
