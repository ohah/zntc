import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  DEV_MIDDLEWARE_PATH_PREFIXES,
  isDevMiddlewareRoute,
  loadDevMiddleware,
  resolveDevMiddlewarePath,
} from './dev-middleware.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-rn-devmw-'));
  // 빈 package.json — projectRoot/package.json 이 createRequire 에 필요
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'test' }));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function writeJson(path: string, value: unknown): void {
  writeFileSync(path, JSON.stringify(value));
}

function installExpoDevMiddleware(main: string, source: string): string {
  const packageRoot = join(
    dir,
    'node_modules/expo/node_modules/@expo/cli/node_modules/@react-native/dev-middleware',
  );
  mkdirSync(packageRoot, { recursive: true });
  writeJson(join(dir, 'node_modules/expo/package.json'), { name: 'expo' });
  writeFileSync(join(dir, 'node_modules/expo/index.js'), 'module.exports = {};');
  writeJson(join(dir, 'node_modules/expo/node_modules/@expo/cli/package.json'), {
    name: '@expo/cli',
    main: 'index.js',
  });
  writeFileSync(
    join(dir, 'node_modules/expo/node_modules/@expo/cli/index.js'),
    'module.exports = {};',
  );
  writeJson(join(packageRoot, 'package.json'), {
    name: '@react-native/dev-middleware',
    main,
  });
  writeFileSync(join(packageRoot, main), source);
  return join(packageRoot, main);
}

function installRnCliDevMiddleware(main: string, source: string): string {
  const packageRoot = join(
    dir,
    'node_modules/react-native/node_modules/@react-native/community-cli-plugin/node_modules/@react-native/dev-middleware',
  );
  mkdirSync(packageRoot, { recursive: true });
  writeJson(join(dir, 'node_modules/react-native/package.json'), { name: 'react-native' });
  writeJson(
    join(
      dir,
      'node_modules/react-native/node_modules/@react-native/community-cli-plugin/package.json',
    ),
    { name: '@react-native/community-cli-plugin' },
  );
  writeJson(join(packageRoot, 'package.json'), {
    name: '@react-native/dev-middleware',
    main,
  });
  writeFileSync(join(packageRoot, main), source);
  return join(packageRoot, main);
}

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

  test('Expo 프로젝트의 @expo/cli 기준 dev-middleware 를 CJS require 로 로드', async () => {
    installExpoDevMiddleware(
      'index.cjs',
      `
        module.exports = {
          createDevMiddleware(input) {
            globalThis.__zntcDevMiddlewareInput = input;
            return {
              middleware(_req, _res, next) {
                next();
              },
              websocketEndpoints: {
                '/expo-inspector': {
                  handleUpgrade() {},
                  emit() {},
                },
              },
            };
          },
        };
      `,
    );

    const state = globalThis as { __zntcDevMiddlewareInput?: unknown };
    state.__zntcDevMiddlewareInput = undefined;
    const result = await loadDevMiddleware({ port: 8123, projectRoot: dir });

    expect(Object.keys(result?.websocketEndpoints ?? {})).toEqual(['/expo-inspector']);
    expect(state.__zntcDevMiddlewareInput).toMatchObject({
      serverBaseUrl: 'http://localhost:8123',
      projectRoot: dir,
    });
    delete state.__zntcDevMiddlewareInput;
  });
});

describe('resolveDevMiddlewarePath', () => {
  test('Expo 프로젝트는 @expo/cli 기준 @react-native/dev-middleware 를 RN CLI chain 보다 우선 사용', () => {
    const expoDevMiddlewarePath = installExpoDevMiddleware('expo-dev.js', 'module.exports = {};');
    installRnCliDevMiddleware('rn-cli-dev.js', 'module.exports = {};');

    expect(resolveDevMiddlewarePath(dir)).toBe(expoDevMiddlewarePath);
  });
});
