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

  // dedup — 사용자가 이미 @zntc/web/css 를 명시 전달한 경우 default 재주입 금지
  // (#3836 fix). 두 cssPlugin 동시 활성 시 같은 filter regex 가 두 onLoad 등록 →
  // PostCSS 가 같은 .css 에 2번 실행, 사용자 override 가 silent shadow 또는 double-run.
  test('user 가 이미 @zntc/web/css 를 명시 → default 미주입 (dedup)', () => {
    const userCssExplicit = { name: '@zntc/web/css', setup: () => {} };
    const result = resolveAppPlugins({
      userPlugins: [userPluginA, userCssExplicit, userPluginB],
      disableDefaults: false,
      cssPlugin: cssDefault,
    });
    // default cssPlugin 미주입 — userPlugins 그대로 (순서 보존)
    expect(result.length).toBe(3);
    expect(result.map((p) => p.name)).toEqual(['user:a', '@zntc/web/css', 'user:b']);
    // dedup 후 user 의 explicit css 가 그대로 (default 인스턴스 아님)
    expect(result[1]).toBe(userCssExplicit);
  });

  test('user 가 @zntc/web/css 명시 + 다른 user plugin 도 있음 → 회귀 가드 (default skip 만 영향)', () => {
    // 다른 name 의 user plugin 만 있을 때는 default 정상 prepend
    const resultA = resolveAppPlugins({
      userPlugins: [userPluginA, userPluginB],
      disableDefaults: false,
      cssPlugin: cssDefault,
    });
    expect(resultA.map((p) => p.name)).toEqual(['@zntc/web/css', 'user:a', 'user:b']);

    // 비교 — @zntc/web/css 가 user 에 포함되면 default skip
    const userCssExplicit = { name: '@zntc/web/css', setup: () => {} };
    const resultB = resolveAppPlugins({
      userPlugins: [userPluginA, userCssExplicit, userPluginB],
      disableDefaults: false,
      cssPlugin: cssDefault,
    });
    expect(resultB.map((p) => p.name)).toEqual(['user:a', '@zntc/web/css', 'user:b']);
  });

  test('dedup 은 name 정확 일치 — 비슷한 name (예: @zntc/web/css-modules) 은 영향 없음', () => {
    const userPluginLike = { name: '@zntc/web/css-modules', setup: () => {} };
    const result = resolveAppPlugins({
      userPlugins: [userPluginLike],
      disableDefaults: false,
      cssPlugin: cssDefault,
    });
    // userPluginLike 가 name 다르므로 default 정상 prepend
    expect(result.length).toBe(2);
    expect(result[0]!.name).toBe('@zntc/web/css');
    expect(result[1]!.name).toBe('@zntc/web/css-modules');
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
