/**
 * CLI flag 파싱 유닛 테스트 — matchFlagFromRegistry + applyFlagAction.
 *
 * 본 PR 에서 추가한 엔진-옵션 노출 flag (config·NAPI 에는 이미 있었으나 CLI 부재)
 * 의 파싱 정확성을 회귀 가드. string-bool toggle, 명시적 `--no-*` negation,
 * key-value, array, int 각 kind 의 동작과 default=true 옵션의 비활성 경로를 검증.
 */
import { describe, expect, test } from 'bun:test';

import { applyFlagAction, matchFlagFromRegistry, normalizeFallback } from './cli-flags.mjs';

/** 단일 토큰을 registry 로 매칭 후 빈 opts 에 적용한 결과 반환. */
function parseOne(arg, next) {
  const args = next === undefined ? [arg] : [arg, next];
  const m = matchFlagFromRegistry(arg, args, 0);
  if (!m) return { matched: false, opts: {} };
  const opts = {};
  applyFlagAction(opts, m.spec, m.action);
  return { matched: true, opts, consumed: m.consumed };
}

describe('엔진-옵션 노출 flag — string-bool toggle (default=true)', () => {
  for (const [flag, key] of [
    ['--tree-shaking', 'treeShaking'],
    ['--scope-hoist', 'scopeHoist'],
    ['--emit-disk-sourcemap', 'emitDiskSourcemap'],
  ]) {
    test(`${flag} 단독 → ${key}=true`, () => {
      expect(parseOne(flag).opts[key]).toBe(true);
    });
    test(`${flag}=false → ${key}=false`, () => {
      expect(parseOne(`${flag}=false`).opts[key]).toBe(false);
    });
    test(`${flag}=true → ${key}=true`, () => {
      expect(parseOne(`${flag}=true`).opts[key]).toBe(true);
    });
  }
});

describe('엔진-옵션 노출 flag — 명시적 --no-* negation', () => {
  for (const [flag, key] of [
    ['--no-tree-shaking', 'treeShaking'],
    ['--no-scope-hoist', 'scopeHoist'],
    ['--no-emit-disk-sourcemap', 'emitDiskSourcemap'],
  ]) {
    test(`${flag} → ${key}=false`, () => {
      expect(parseOne(flag).opts[key]).toBe(false);
    });
  }
});

describe('--fallback — key-value 파싱 (false 강제는 normalizeFallback, 여기선 string)', () => {
  test('--fallback:crypto=crypto-browserify → fallback 객체', () => {
    expect(parseOne('--fallback:crypto=crypto-browserify').opts.fallback).toEqual({
      crypto: 'crypto-browserify',
    });
  });
  test('--fallback:fs=false → 문자열 "false" (boolean 변환은 normalizeFallback 책임)', () => {
    expect(parseOne('--fallback:fs=false').opts.fallback).toEqual({ fs: 'false' });
  });
});

describe('normalizeFallback — "false" → boolean false 강제 + boolean 보존', () => {
  test('빈 dict → undefined (NAPI 미전달)', () => {
    expect(normalizeFallback({})).toBeUndefined();
  });
  test('CLI string "false" → boolean false (빈-모듈 대체)', () => {
    expect(normalizeFallback({ fs: 'false' })).toEqual({ fs: false });
  });
  test('config 가 준 실제 boolean false 보존', () => {
    expect(normalizeFallback({ fs: false })).toEqual({ fs: false });
  });
  test('일반 specifier 문자열은 그대로', () => {
    expect(normalizeFallback({ crypto: 'crypto-browserify' })).toEqual({
      crypto: 'crypto-browserify',
    });
  });
  test('혼합 — string/false/specifier 동시', () => {
    expect(normalizeFallback({ a: 'false', b: false, c: 'x' })).toEqual({
      a: false,
      b: false,
      c: 'x',
    });
  });
});

describe('--block-list — array push (반복 누적)', () => {
  test('--block-list=node_modules/foo → blockList 배열', () => {
    expect(parseOne('--block-list=node_modules/foo').opts.blockList).toEqual(['node_modules/foo']);
  });
  test('반복 지정 누적', () => {
    const opts = {};
    for (const arg of ['--block-list=a', '--block-list=b']) {
      const m = matchFlagFromRegistry(arg, [arg], 0);
      applyFlagAction(opts, m.spec, m.action);
    }
    expect(opts.blockList).toEqual(['a', 'b']);
  });
});

describe('--min-chunk-size — int', () => {
  test('--min-chunk-size=1024 → 숫자 1024', () => {
    expect(parseOne('--min-chunk-size=1024').opts.minChunkSize).toBe(1024);
  });
  test('비숫자 → invalid-int (parseError 경로)', () => {
    const m = matchFlagFromRegistry('--min-chunk-size=abc', ['--min-chunk-size=abc'], 0);
    const opts = {};
    applyFlagAction(opts, m.spec, m.action);
    expect(opts.parseError).toBe(true);
  });
});
