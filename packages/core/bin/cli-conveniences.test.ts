/**
 * CLI 편의 flag 회귀 가드 — --version/-v, --no-config, --color/--no-color 파싱 및
 * banner.shouldUseColor() 의 NO_COLOR/FORCE_COLOR/TTY 우선순위.
 */
import { afterEach, describe, expect, test } from 'bun:test';

import { applyColorPreference, shouldUseColor } from './banner.mjs';
import { applyFlagAction, matchFlagFromRegistry } from './cli-flags.mjs';

function parseOne(arg) {
  const m = matchFlagFromRegistry(arg, [arg], 0);
  if (!m) return {};
  const opts = {};
  applyFlagAction(opts, m.spec, m.action);
  return opts;
}

describe('CLI 편의 flag 파싱', () => {
  test('--version → version=true', () => {
    expect(parseOne('--version').version).toBe(true);
  });
  test('-v 별칭 → version=true', () => {
    expect(parseOne('-v').version).toBe(true);
  });
  test('--no-config → noConfig=true', () => {
    expect(parseOne('--no-config').noConfig).toBe(true);
  });
  test('--color → color=true', () => {
    expect(parseOne('--color').color).toBe(true);
  });
  test('--no-color → color=false', () => {
    expect(parseOne('--no-color').color).toBe(false);
  });
});

describe('shouldUseColor — NO_COLOR/FORCE_COLOR/TTY 우선순위', () => {
  const savedNo = process.env.NO_COLOR;
  const savedForce = process.env.FORCE_COLOR;
  const savedTty = process.stdout.isTTY;

  afterEach(() => {
    if (savedNo === undefined) delete process.env.NO_COLOR;
    else process.env.NO_COLOR = savedNo;
    if (savedForce === undefined) delete process.env.FORCE_COLOR;
    else process.env.FORCE_COLOR = savedForce;
    process.stdout.isTTY = savedTty;
  });

  function setEnv({ no, force, tty }) {
    if (no === undefined) delete process.env.NO_COLOR;
    else process.env.NO_COLOR = no;
    if (force === undefined) delete process.env.FORCE_COLOR;
    else process.env.FORCE_COLOR = force;
    process.stdout.isTTY = tty;
  }

  test('NO_COLOR 가 비어있지 않으면 무조건 false (TTY/FORCE_COLOR 무시)', () => {
    setEnv({ no: '1', force: '1', tty: true });
    expect(shouldUseColor()).toBe(false);
  });
  test('FORCE_COLOR 설정 시 비-TTY 라도 true', () => {
    setEnv({ no: undefined, force: '1', tty: false });
    expect(shouldUseColor()).toBe(true);
  });
  test('FORCE_COLOR=0 → false', () => {
    setEnv({ no: undefined, force: '0', tty: true });
    expect(shouldUseColor()).toBe(false);
  });
  test('FORCE_COLOR=false → false', () => {
    setEnv({ no: undefined, force: 'false', tty: true });
    expect(shouldUseColor()).toBe(false);
  });
  test('env 없음 + TTY → true', () => {
    setEnv({ no: undefined, force: undefined, tty: true });
    expect(shouldUseColor()).toBe(true);
  });
  test('env 없음 + 비-TTY → false', () => {
    setEnv({ no: undefined, force: undefined, tty: false });
    expect(shouldUseColor()).toBe(false);
  });
  test("FORCE_COLOR='' (빈 문자열) → true (supports-color 관례)", () => {
    setEnv({ no: undefined, force: '', tty: false });
    expect(shouldUseColor()).toBe(true);
  });
});

describe('applyColorPreference — 명시 flag 가 반대편 env 제거 (override)', () => {
  test('--color (true): NO_COLOR 가 이미 set 돼 있어도 제거 + FORCE_COLOR set', () => {
    const env = { NO_COLOR: '1' };
    applyColorPreference(true, env);
    expect(env.NO_COLOR).toBeUndefined();
    expect(env.FORCE_COLOR).toBe('1');
  });
  test('--no-color (false): FORCE_COLOR 제거 + NO_COLOR set', () => {
    const env = { FORCE_COLOR: '1' };
    applyColorPreference(false, env);
    expect(env.FORCE_COLOR).toBeUndefined();
    expect(env.NO_COLOR).toBe('1');
  });
  test('미지정(undefined): env 무변경 (자동 판정 유지)', () => {
    const env = { NO_COLOR: '1', FORCE_COLOR: '1' };
    applyColorPreference(undefined, env);
    expect(env).toEqual({ NO_COLOR: '1', FORCE_COLOR: '1' });
  });
});
