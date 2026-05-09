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

function writePackage(
  pkgDir: string,
  manifest: { name: string; main?: string },
  mainContent?: string,
): string {
  mkdirSync(pkgDir, { recursive: true });
  writeFileSync(join(pkgDir, 'package.json'), JSON.stringify(manifest));
  if (manifest.main && mainContent !== undefined) {
    writeFileSync(join(pkgDir, manifest.main), mainContent);
  }
  return manifest.main ? join(pkgDir, manifest.main) : join(pkgDir, 'package.json');
}

function installExpoDevMiddleware(main: string, source: string): string {
  const expoDir = join(dir, 'node_modules/expo');
  const expoCliDir = join(expoDir, 'node_modules/@expo/cli');
  const devMiddlewareDir = join(expoCliDir, 'node_modules/@react-native/dev-middleware');
  writePackage(expoDir, { name: 'expo', main: 'index.js' }, 'module.exports = {};');
  writePackage(expoCliDir, { name: '@expo/cli', main: 'index.js' }, 'module.exports = {};');
  return writePackage(devMiddlewareDir, { name: '@react-native/dev-middleware', main }, source);
}

function installRnCliDevMiddleware(main: string, source: string): string {
  const rnDir = join(dir, 'node_modules/react-native');
  const cliPluginDir = join(rnDir, 'node_modules/@react-native/community-cli-plugin');
  const devMiddlewareDir = join(cliPluginDir, 'node_modules/@react-native/dev-middleware');
  writePackage(rnDir, { name: 'react-native' });
  writePackage(cliPluginDir, { name: '@react-native/community-cli-plugin' });
  return writePackage(devMiddlewareDir, { name: '@react-native/dev-middleware', main }, source);
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
    try {
      const result = await loadDevMiddleware({ port: 8123, projectRoot: dir });

      expect(Object.keys(result?.websocketEndpoints ?? {})).toEqual(['/expo-inspector']);
      expect(state.__zntcDevMiddlewareInput).toMatchObject({
        serverBaseUrl: 'http://localhost:8123',
        projectRoot: dir,
      });
    } finally {
      delete state.__zntcDevMiddlewareInput;
    }
  });
});

describe('resolveDevMiddlewarePath', () => {
  test('Expo 프로젝트는 @expo/cli 기준 @react-native/dev-middleware 를 RN CLI chain 보다 우선 사용', () => {
    const expoDevMiddlewarePath = installExpoDevMiddleware('expo-dev.js', 'module.exports = {};');
    installRnCliDevMiddleware('rn-cli-dev.js', 'module.exports = {};');

    expect(resolveDevMiddlewarePath(dir)).toBe(expoDevMiddlewarePath);
  });
});
