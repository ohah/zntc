import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { resolveRnPolyfills, RN_GLOBAL_IDENTIFIERS, tryResolve } from './rn-constants.ts';

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'zntc-rn-constants-'));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function makePolyfillModule(rel: string, returnedPaths: string[]): void {
  const path = join(dir, rel);
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, `module.exports = function () { return ${JSON.stringify(returnedPaths)}; };`);
}

describe('tryResolve', () => {
  test('존재하는 패키지 — path 반환', () => {
    // node 빌트인 자체는 paths option 무시 — bun:test 가 require.resolve 'fs'
    // 같은 base 호출 가능. fixture 로 가짜 패키지 만들어 확실히 검증.
    makePolyfillModule('node_modules/sample-pkg/index.js', []);
    writeFileSync(
      join(dir, 'node_modules/sample-pkg/package.json'),
      JSON.stringify({ name: 'sample-pkg', main: 'index.js' }),
    );
    const resolved = tryResolve('sample-pkg', dir);
    expect(resolved).toBeTypeOf('string');
    expect(resolved).toContain('sample-pkg');
  });

  test('미존재 패키지 — null', () => {
    const resolved = tryResolve('definitely-not-installed-xyz-9999', dir);
    expect(resolved).toBeNull();
  });

  test('require.resolve 가 throw 하는 모든 케이스에 null', () => {
    // 잘못된 specifier (예: 빈 string) — Node 가 ERR_INVALID_MODULE_SPECIFIER throw
    expect(tryResolve('', dir)).toBeNull();
  });
});

describe('resolveRnPolyfills', () => {
  test('`react-native/rn-get-polyfills` 가 있으면 우선 사용', () => {
    const expected = ['/abs/console.js', '/abs/error-guard.js'];
    makePolyfillModule('node_modules/react-native/rn-get-polyfills.js', expected);
    writeFileSync(
      join(dir, 'node_modules/react-native/package.json'),
      JSON.stringify({ name: 'react-native' }),
    );
    expect(resolveRnPolyfills(dir)).toEqual(expected);
  });

  test('rn-get-polyfills 없으면 `@react-native/js-polyfills` fallback', () => {
    const expected = ['/abs/legacy-console.js'];
    mkdirSync(join(dir, 'node_modules/@react-native/js-polyfills'), { recursive: true });
    writeFileSync(
      join(dir, 'node_modules/@react-native/js-polyfills/index.js'),
      `module.exports = function () { return ${JSON.stringify(expected)}; };`,
    );
    writeFileSync(
      join(dir, 'node_modules/@react-native/js-polyfills/package.json'),
      JSON.stringify({ name: '@react-native/js-polyfills', main: 'index.js' }),
    );
    expect(resolveRnPolyfills(dir)).toEqual(expected);
  });

  test('두 candidate 모두 미설치 — console.warn + 빈 배열', () => {
    const warnSpy = spyOn(console, 'warn').mockImplementation(() => {});
    const result = resolveRnPolyfills(dir);
    expect(result).toEqual([]);
    expect(warnSpy).toHaveBeenCalledWith('[zntc] Could not resolve RN polyfills, skipping');
    warnSpy.mockRestore();
  });

  test('polyfill require 가 throw 하면 다음 candidate 로 fallback', () => {
    // rn-get-polyfills 의 module.exports 가 throw — js-polyfills 로 fallback
    mkdirSync(join(dir, 'node_modules/react-native'), { recursive: true });
    writeFileSync(
      join(dir, 'node_modules/react-native/rn-get-polyfills.js'),
      "throw new Error('boom');",
    );
    writeFileSync(
      join(dir, 'node_modules/react-native/package.json'),
      JSON.stringify({ name: 'react-native' }),
    );
    const fallback = ['/abs/fallback.js'];
    mkdirSync(join(dir, 'node_modules/@react-native/js-polyfills'), { recursive: true });
    writeFileSync(
      join(dir, 'node_modules/@react-native/js-polyfills/index.js'),
      `module.exports = function () { return ${JSON.stringify(fallback)}; };`,
    );
    writeFileSync(
      join(dir, 'node_modules/@react-native/js-polyfills/package.json'),
      JSON.stringify({ name: '@react-native/js-polyfills', main: 'index.js' }),
    );
    expect(resolveRnPolyfills(dir)).toEqual(fallback);
  });

  test('polyfill require 가 throw 하고 fallback 도 없으면 빈 배열', () => {
    mkdirSync(join(dir, 'node_modules/react-native'), { recursive: true });
    writeFileSync(
      join(dir, 'node_modules/react-native/rn-get-polyfills.js'),
      "throw new Error('boom');",
    );
    writeFileSync(
      join(dir, 'node_modules/react-native/package.json'),
      JSON.stringify({ name: 'react-native' }),
    );
    const warnSpy = spyOn(console, 'warn').mockImplementation(() => {});
    expect(resolveRnPolyfills(dir)).toEqual([]);
    expect(warnSpy).toHaveBeenCalled();
    warnSpy.mockRestore();
  });
});

describe('RN_GLOBAL_IDENTIFIERS', () => {
  test('핵심 identifier 모두 포함 (RN 0.83 기준)', () => {
    expect(RN_GLOBAL_IDENTIFIERS).toContain('Promise');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('fetch');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('setTimeout');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('clearTimeout');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('requestAnimationFrame');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('XMLHttpRequest');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('WebSocket');
    expect(RN_GLOBAL_IDENTIFIERS).toContain('regeneratorRuntime');
  });

  test('중복 없음', () => {
    const set = new Set(RN_GLOBAL_IDENTIFIERS);
    expect(set.size).toBe(RN_GLOBAL_IDENTIFIERS.length);
  });

  test('빈 string / 비-식별자 없음', () => {
    for (const name of RN_GLOBAL_IDENTIFIERS) {
      expect(name).toMatch(/^[A-Za-z_$][\w$]*$/);
    }
  });

  test('count >= 50 (RN 0.83 의 polyfill 분포 sanity)', () => {
    expect(RN_GLOBAL_IDENTIFIERS.length).toBeGreaterThanOrEqual(50);
  });
});
