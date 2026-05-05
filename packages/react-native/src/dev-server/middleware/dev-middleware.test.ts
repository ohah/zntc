import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { DEV_MIDDLEWARE_PATH_PREFIXES, loadDevMiddleware } from './dev-middleware.ts';

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
