/**
 * `resolveAppPlugins` + `isEnvTruthy` 유닛 test — `runAppBuild` 의 default
 * plugin 주입 helper. (#2538 4-4 PR-3a)
 *
 * TDD: helper 미존재 상태에서 test 먼저 작성 → 구현 → green 확인.
 *
 * Vite parity: 사용자 config.plugins 외에 default css() 가 prepend (resolveId/
 * load/transform 순서상 우선). `ZNTC_NO_CSS_DEFAULTS=1` env 또는 명시
 * `disableDefaults: true` 옵션 (zntc.config 의 `appPlugins.disableDefaults`)
 * 으로 opt-out.
 */

import { describe, expect, test } from 'bun:test';

import { isEnvTruthy, resolveAppPlugins } from './app-default-plugins.mjs';

const cssDefault = { name: '@zntc/web/css', setup: () => {} };
const userPluginA = { name: 'user:a', setup: () => {} };
const userPluginB = { name: 'user:b', setup: () => {} };

describe('resolveAppPlugins', () => {
  test('user plugins 빈 배열 + default 활성 → [css()] 1개', () => {
    const result = resolveAppPlugins({
      userPlugins: [],
      disableDefaults: false,
      cssPlugin: cssDefault,
    });
    expect(result.length).toBe(1);
    expect(result[0]!.name).toBe('@zntc/web/css');
  });

  test('user plugins + default 활성 → [css(), ...user]', () => {
    const result = resolveAppPlugins({
      userPlugins: [userPluginA, userPluginB],
      disableDefaults: false,
      cssPlugin: cssDefault,
    });
    expect(result.length).toBe(3);
    expect(result[0]!.name).toBe('@zntc/web/css');
    expect(result[1]!.name).toBe('user:a');
    expect(result[2]!.name).toBe('user:b');
  });

  test('disableDefaults=true → user plugins 만 (default 미주입)', () => {
    const result = resolveAppPlugins({
      userPlugins: [userPluginA],
      disableDefaults: true,
      cssPlugin: cssDefault,
    });
    expect(result.length).toBe(1);
    expect(result[0]!.name).toBe('user:a');
  });

  test('disableDefaults=true + user plugins 빈 배열 → 빈 배열', () => {
    const result = resolveAppPlugins({
      userPlugins: [],
      disableDefaults: true,
      cssPlugin: cssDefault,
    });
    expect(result.length).toBe(0);
  });

  test('cssPlugin 인자가 null 일 때도 안전 — default 미주입', () => {
    const result = resolveAppPlugins({
      userPlugins: [userPluginA],
      disableDefaults: false,
      cssPlugin: null,
    });
    expect(result.length).toBe(1);
    expect(result[0]!.name).toBe('user:a');
  });

  test('user plugins 의 순서 보존 (a → b → c)', () => {
    const userPluginC = { name: 'user:c', setup: () => {} };
    const result = resolveAppPlugins({
      userPlugins: [userPluginA, userPluginB, userPluginC],
      disableDefaults: true,
      cssPlugin: cssDefault,
    });
    expect(result.map((p) => p.name)).toEqual(['user:a', 'user:b', 'user:c']);
  });

  test('ownership: 반환 array 가 userPlugins 와 다른 reference (caller mutate 안전)', () => {
    const userPlugins = [userPluginA];
    const result = resolveAppPlugins({ userPlugins, disableDefaults: true, cssPlugin: null });
    expect(result).not.toBe(userPlugins); // 새 array
    expect(result).toEqual(userPlugins); // content 동등
  });
});

describe('isEnvTruthy', () => {
  test('truthy values', () => {
    expect(isEnvTruthy('1')).toBe(true);
    expect(isEnvTruthy('true')).toBe(true);
    expect(isEnvTruthy('TRUE')).toBe(true);
    expect(isEnvTruthy('yes')).toBe(true);
    expect(isEnvTruthy('YES')).toBe(true);
    expect(isEnvTruthy('on')).toBe(true);
    expect(isEnvTruthy('ON')).toBe(true);
  });

  test('falsy values', () => {
    expect(isEnvTruthy('0')).toBe(false);
    expect(isEnvTruthy('false')).toBe(false);
    expect(isEnvTruthy('FALSE')).toBe(false);
    expect(isEnvTruthy('no')).toBe(false);
    expect(isEnvTruthy('off')).toBe(false);
    expect(isEnvTruthy('')).toBe(false);
    expect(isEnvTruthy(undefined)).toBe(false);
    expect(isEnvTruthy(null)).toBe(false);
  });
});
