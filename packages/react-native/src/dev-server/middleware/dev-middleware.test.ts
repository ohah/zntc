import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DEV_MIDDLEWARE_PATH_PREFIXES,
  isDevMiddlewareRoute,
  loadDevMiddleware,
} from './dev-middleware.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zts-rn-devmw-'));
  // 빈 package.json — projectRoot/package.json 이 createRequire 에 필요
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'test' }));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe('DEV_MIDDLEWARE_PATH_PREFIXES', () => {
  test('4개 prefix — RN DevTools standard endpoints', () => {
    expect(DEV_MIDDLEWARE_PATH_PREFIXES).toEqual([
      '/json',
      '/open-debugger',
      '/debugger-frontend',
      '/launch-js-devtools',
    ]);
  });
});

describe('isDevMiddlewareRoute — 정확 경계 매칭 (#2605 audit)', () => {
  test('정확한 prefix 매칭 — true', () => {
    expect(isDevMiddlewareRoute('/json')).toBe(true);
    expect(isDevMiddlewareRoute('/open-debugger')).toBe(true);
    expect(isDevMiddlewareRoute('/debugger-frontend')).toBe(true);
    expect(isDevMiddlewareRoute('/launch-js-devtools')).toBe(true);
  });

  test('슬래시 경계 + tail — true', () => {
    expect(isDevMiddlewareRoute('/json/list')).toBe(true);
    expect(isDevMiddlewareRoute('/debugger-frontend/index.html')).toBe(true);
    expect(isDevMiddlewareRoute('/open-debugger/something')).toBe(true);
  });

  test('substring false-positive 방지 — `/jsonbomb` / `/jsonish` → false', () => {
    expect(isDevMiddlewareRoute('/jsonbomb')).toBe(false);
    expect(isDevMiddlewareRoute('/jsonish')).toBe(false);
    expect(isDevMiddlewareRoute('/open-debugger-x')).toBe(false);
    expect(isDevMiddlewareRoute('/debugger-frontends')).toBe(false);
  });

  test('비매치 path — false', () => {
    expect(isDevMiddlewareRoute('/')).toBe(false);
    expect(isDevMiddlewareRoute('/index.bundle')).toBe(false);
    expect(isDevMiddlewareRoute('/status')).toBe(false);
  });

  test('빈 string — false', () => {
    expect(isDevMiddlewareRoute('')).toBe(false);
  });
});

describe('loadDevMiddleware', () => {
  test('@react-native/dev-middleware 미설치 → null (graceful)', async () => {
    const result = await loadDevMiddleware({ port: 8081, projectRoot: dir });
    expect(result).toBeNull();
  });

  test('project 의 react-native 도 없음 → fallback chain 도 fail → null', async () => {
    // node_modules 비어있는 fixture
    mkdirSync(join(dir, 'node_modules'), { recursive: true });
    const result = await loadDevMiddleware({ port: 9000, projectRoot: dir });
    expect(result).toBeNull();
  });
});
