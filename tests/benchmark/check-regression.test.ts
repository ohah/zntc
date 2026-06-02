import { describe, expect, test } from 'bun:test';
import {
  detectRegressions,
  renderWarning,
  type BenchJson,
  type Baseline,
} from './check-regression';

const baseline: Baseline = {
  tolerance: 0.15,
  runner: 'ubuntu-latest',
  ratios: {
    'bundle|large (5000 modules)': { esbuild: 0.65, Bun: 1.3 },
    'bundle|medium (1000 modules)': { esbuild: 0.62, Bun: 1.2 },
    'transpile|small (100 lines)': { esbuild: 0.75, Bun: 0.57 },
    'transpile|large (5K lines)': { esbuild: 6.7, Bun: 1.36 },
  },
};

function mk(rows: Array<[string, string, string, number]>): BenchJson {
  return {
    version: 1,
    platform: 'linux-x64',
    iterations: 5,
    results: rows.map(([tool, task, scale, median_ms]) => ({ tool, task, scale, median_ms })),
  };
}

describe('benchmark regression gate', () => {
  test('비율이 baseline*(1+tol) 를 넘으면 회귀로 flag (현재 main 의 +29% bundle)', () => {
    // bundle-large: ZNTC 198 / esbuild 238 = 0.83 > 0.65*1.15=0.7475 → flag
    const data = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', 198],
      ['esbuild', 'bundle', 'large (5000 modules)', 238],
      ['Bun', 'bundle', 'large (5000 modules)', 120],
    ]);
    const f = detectRegressions(data, baseline);
    expect(f).toHaveLength(1);
    expect(f[0].key).toBe('bundle|large (5000 modules)');
    expect(f[0].comp).toBe('esbuild');
    expect(f[0].cur).toBeCloseTo(0.832, 2);
    expect(f[0].pct).toBeGreaterThan(20);
    // Bun: 198/120=1.65 > 1.3*1.15=1.495 → 보강 true
    expect(f[0].bunCorroborated).toBe(true);
  });

  test('임계 이내면 flag 안 함 (healthy: pre-#4003 비율)', () => {
    // bundle-large: 145/227 = 0.639 < 0.7475 → 정상
    const data = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', 145],
      ['esbuild', 'bundle', 'large (5000 modules)', 227],
      ['Bun', 'bundle', 'large (5000 modules)', 112],
    ]);
    expect(detectRegressions(data, baseline)).toHaveLength(0);
  });

  test('경계값: 정확히 임계면 flag 안 함, 임계 초과부터 flag', () => {
    const thr = 0.65 * 1.15; // 0.7475
    // 정확히 임계 (cur == thr): esbuild=1 이면 ZNTC=thr 로 맞춤
    const atThr = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', thr],
      ['esbuild', 'bundle', 'large (5000 modules)', 1],
    ]);
    expect(detectRegressions(atThr, baseline)).toHaveLength(0);
    // 임계 초과
    const overThr = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', thr + 0.001],
      ['esbuild', 'bundle', 'large (5000 modules)', 1],
    ]);
    expect(detectRegressions(overThr, baseline)).toHaveLength(1);
  });

  test('transpile-large 의 6.7x 기존 격차는 회귀가 아니다 (baseline 이 격차를 담음)', () => {
    // ZNTC 14.6 / esbuild 2.2 = 6.64 < 6.7*1.15 → 정상 (절대 6.6배 느려도 회귀 아님)
    const data = mk([
      ['ZNTC', 'transpile', 'large (5K lines)', 14.6],
      ['esbuild', 'transpile', 'large (5K lines)', 2.2],
    ]);
    expect(detectRegressions(data, baseline)).toHaveLength(0);
  });

  test('esbuild 결과가 없으면 Bun 으로 폴백', () => {
    // bundle-medium: esbuild 없음, Bun 만. ZNTC 50 / Bun 24 = 2.08 > 1.2*1.15=1.38 → flag(Bun 기준)
    const data = mk([
      ['ZNTC', 'bundle', 'medium (1000 modules)', 50],
      ['Bun', 'bundle', 'medium (1000 modules)', 24],
    ]);
    const f = detectRegressions(data, baseline);
    expect(f).toHaveLength(1);
    expect(f[0].comp).toBe('Bun');
    expect(f[0].bunCorroborated).toBeNull(); // 1차가 Bun 이면 보강 비교 안 함
  });

  test('ZNTC 행이 없으면 skip (도구 누락에 robust)', () => {
    const data = mk([['esbuild', 'bundle', 'large (5000 modules)', 238]]);
    expect(detectRegressions(data, baseline)).toHaveLength(0);
  });

  test('corroboration: esbuild 만 초과하고 Bun 은 정상이면 flag 안 함 (오탐 방지)', () => {
    // ZNTC 0.78 / esbuild 1 = 0.78 > 0.7475 (esbuild 초과). 그러나 Bun: 0.78/0.7=1.11 <
    // 1.3*1.15=1.495 (Bun 정상). esbuild 가 그 run 에서 우연히 빨랐던 노이즈 패턴 → skip.
    const data = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', 0.78],
      ['esbuild', 'bundle', 'large (5000 modules)', 1],
      ['Bun', 'bundle', 'large (5000 modules)', 0.7],
    ]);
    expect(detectRegressions(data, baseline)).toHaveLength(0);
  });

  test('corroboration: esbuild·Bun 둘 다 초과해야 flag (둘 다 초과 → bunCorroborated=true)', () => {
    // ZNTC 0.9: esbuild 0.9/1=0.9>0.7475 AND Bun 0.9/0.6=1.5>1.495 → 둘 다 초과 → flag
    const data = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', 0.9],
      ['esbuild', 'bundle', 'large (5000 modules)', 1],
      ['Bun', 'bundle', 'large (5000 modules)', 0.6],
    ]);
    const f = detectRegressions(data, baseline);
    expect(f).toHaveLength(1);
    expect(f[0].bunCorroborated).toBe(true);
  });

  test('baseline 비율이 0/음수면 flag 안 함 (garbage baseline 방어, Infinity% 방지)', () => {
    const bad: Baseline = {
      tolerance: 0.15,
      runner: 'ubuntu-latest',
      ratios: { 'bundle|large (5000 modules)': { esbuild: 0, Bun: 0 } },
    };
    const data = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', 198],
      ['esbuild', 'bundle', 'large (5000 modules)', 238],
      ['Bun', 'bundle', 'large (5000 modules)', 120],
    ]);
    expect(detectRegressions(data, bad)).toHaveLength(0);
  });

  test('renderWarning: 회귀 없으면 ✅ 한 줄', () => {
    expect(renderWarning([], baseline)).toContain('✅');
    expect(renderWarning([], baseline)).not.toContain('⚠️');
  });

  test('renderWarning: 회귀 있으면 ⚠️ 표 + 악화율 내림차순', () => {
    const data = mk([
      ['ZNTC', 'bundle', 'large (5000 modules)', 198],
      ['esbuild', 'bundle', 'large (5000 modules)', 238],
      ['ZNTC', 'bundle', 'medium (1000 modules)', 35],
      ['esbuild', 'bundle', 'medium (1000 modules)', 47.6],
    ]);
    const md = renderWarning(detectRegressions(data, baseline), baseline);
    expect(md).toContain('⚠️');
    expect(md).toContain('bundle — large (5000 modules)');
    // large(+28%) 가 medium(+19%) 보다 위
    expect(md.indexOf('large (5000 modules)')).toBeLessThan(md.indexOf('medium (1000 modules)'));
  });
});
