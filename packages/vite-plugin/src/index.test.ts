import { describe, expect, test } from 'bun:test';

import { shouldDisableEsbuildForVite } from './index';

describe('#4322 shouldDisableEsbuildForVite — Vite major 버전 게이트', () => {
  test('Vite 5 이하 → esbuild 비활성화(true)', () => {
    expect(shouldDisableEsbuildForVite('5.4.2')).toBe(true);
    expect(shouldDisableEsbuildForVite('5.0.0')).toBe(true);
    expect(shouldDisableEsbuildForVite('4.5.0')).toBe(true);
  });

  test('Vite 6 이상 → 비활성화 안 함(false)', () => {
    expect(shouldDisableEsbuildForVite('6.0.0')).toBe(false);
    expect(shouldDisableEsbuildForVite('6.0.0-beta.1')).toBe(false);
    expect(shouldDisableEsbuildForVite('7.1.3')).toBe(false);
  });

  test('파싱 불가 버전 → 보수적으로 false', () => {
    expect(shouldDisableEsbuildForVite('vite-5')).toBe(false);
    expect(shouldDisableEsbuildForVite('')).toBe(false);
    expect(shouldDisableEsbuildForVite('latest')).toBe(false);
  });
});
