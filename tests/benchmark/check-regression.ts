#!/usr/bin/env bun
/**
 * Benchmark 회귀 게이트 (SOFT — 경고만, merge 차단 안 함)
 *
 * ubuntu-latest 한 runner 의 `bench.ts --json` 결과를 읽어, ZNTC/esbuild·ZNTC/Bun
 * median 비율을 체크인된 baseline(bench-ratio-baseline.json) 과 비교한다.
 * 비율이 baseline * (1 + tolerance) 를 넘으면 회귀 의심으로 표시한다.
 *
 * 절대 ms 대신 비율을 쓰는 이유는 baseline JSON 의 _doc 참고: GitHub 공유 runner 의
 * 큰 run-to-run 노이즈에 강하다(같은 머신·같은 입력의 esbuild 가 통제군).
 *
 * 사용:
 *   bun run check-regression.ts <bench-results.json> [--baseline <path>] [--out <md>]
 *
 * 출력: 회귀 의심 시 마크다운 경고 섹션을 stdout(및 --out 파일)에 쓴다. 회귀가 없으면
 * 짧은 "✅ 회귀 없음" 라인만. exit code 는 항상 0 (SOFT). 비교 불가(파일 없음/도구
 * 누락)는 조용히 skip — 게이트가 깨져도 댓글 자체는 항상 나가야 한다.
 *
 * 핵심 탐지 로직(detectRegressions)은 순수 함수로 분리 — check-regression.test.ts 가 검증.
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export interface BenchRow {
  tool: string;
  task: string;
  scale: string;
  median_ms: number;
}
export interface BenchJson {
  version: number;
  platform: string;
  iterations: number;
  results: BenchRow[];
}
export interface Baseline {
  tolerance: number;
  runner: string;
  ratios: Record<string, Record<string, number>>;
}
export interface Finding {
  key: string; // "task|scale"
  comp: string; // 1차 기준 도구 (보통 esbuild)
  cur: number; // 현재 ZNTC/comp 비율
  base: number; // baseline 비율
  thr: number; // 임계 = base * (1 + tol)
  pct: number; // baseline 대비 증가율(%)
  bunCorroborated: boolean | null; // Bun 대비도 악화? (null = Bun 비교 불가)
}

/**
 * 순수 탐지 함수: bench 결과 + baseline → 회귀 의심 목록.
 * - 1차 기준은 esbuild(가장 안정적인 통제군), 없으면 Bun 폴백.
 * - **corroboration 요구(오탐 방지)**: 1차가 esbuild 이고 Bun 도 측정됐으면, 두 비율이
 *   *모두* baseline*(1+tol) 를 넘을 때만 finding. 진짜 ZNTC 회귀는 ZNTC 자체가 느려져
 *   esbuild·Bun 두 비율을 함께 올리지만, esbuild 가 그 run 에서 우연히 빨랐던 노이즈는
 *   esbuild 비율만 올리고 Bun 비율은 그대로다 → esbuild 단독 초과는 skip(전형적 오탐 제거).
 *   Bun 이 없으면(폴백 포함) 1차 단독으로 판정(차선).
 * - 한계: tol(기본 15%) 미만의 ZNTC-단독 회귀는 구조적으로 미탐(false negative). 게이트는
 *   '큰 단발 회귀' 검출용이며 통과 == 무회귀가 아니다. 누적 소회귀는 baseline 재생성으로 흡수됨.
 */
export function detectRegressions(data: BenchJson, baseline: Baseline): Finding[] {
  const tol = baseline.tolerance ?? 0.15;

  const byKeyTool = new Map<string, Map<string, number>>();
  for (const r of data.results) {
    const key = `${r.task}|${r.scale}`;
    if (!byKeyTool.has(key)) byKeyTool.set(key, new Map());
    byKeyTool.get(key)!.set(r.tool, r.median_ms);
  }

  // 양수 비율만 유효(baseline=0/음수 또는 도구 median=0 은 garbage → 무한대/항상-flag 방지).
  const exceeds = (
    tools: Map<string, number>,
    tool: string,
    baseRatio: number | undefined,
    zntc: number,
  ) => {
    const m = tools.get(tool);
    if (m == null || m <= 0 || baseRatio == null || baseRatio <= 0) return null; // 비교 불가
    return zntc / m > baseRatio * (1 + tol);
  };

  const findings: Finding[] = [];
  for (const [key, baseRatios] of Object.entries(baseline.ratios)) {
    const tools = byKeyTool.get(key);
    if (!tools) continue;
    const zntc = tools.get('ZNTC');
    if (zntc == null || zntc <= 0) continue;

    const esbOk =
      baseRatios.esbuild != null && baseRatios.esbuild > 0 && (tools.get('esbuild') ?? 0) > 0;
    const primary = esbOk ? 'esbuild' : 'Bun';
    const compMed = tools.get(primary);
    const baseRatio = baseRatios[primary];
    if (compMed == null || compMed <= 0 || baseRatio == null || baseRatio <= 0) continue;

    const curRatio = zntc / compMed;
    if (curRatio <= baseRatio * (1 + tol)) continue; // 1차 통제군은 회귀 안 봄

    // corroboration: 1차가 esbuild 이고 Bun 도 비교 가능하면 Bun 도 초과해야 flag.
    let bunCorroborated: boolean | null = null;
    if (primary === 'esbuild') {
      const bunExceeds = exceeds(tools, 'Bun', baseRatios.Bun, zntc);
      if (bunExceeds === false) continue; // esbuild 단독 초과 = 노이즈 가능 → skip
      bunCorroborated = bunExceeds; // true(둘 다 초과) 또는 null(Bun 비교 불가 → 단독 판정)
    }

    findings.push({
      key,
      comp: primary,
      cur: curRatio,
      base: baseRatio,
      thr: baseRatio * (1 + tol),
      pct: (curRatio / baseRatio - 1) * 100,
      bunCorroborated,
    });
  }
  return findings;
}

/** finding 목록 → PR 댓글용 마크다운. 회귀 없으면 한 줄 ✅. */
export function renderWarning(findings: Finding[], baseline: Baseline): string {
  const tol = baseline.tolerance ?? 0.15;
  if (findings.length === 0) {
    return `> ✅ 회귀 게이트(${baseline.runner}, tolerance ${(tol * 100).toFixed(0)}%): ZNTC/경쟁도구 비율이 baseline 이내. 회귀 없음.`;
  }
  // corroboration 결과는 판정 전제(esbuild 단독 초과는 이미 skip) — true=esbuild+Bun 둘 다,
  // null=단일 통제군(Bun 비교 불가)으로 판정.
  const bunNote = (f: Finding) =>
    f.bunCorroborated === true ? 'esbuild+Bun 둘 다 ↑' : '단일 통제군(Bun 비교 불가)';
  const lines = [
    `### ⚠️ 성능 회귀 의심 (soft warning, ${baseline.runner})`,
    '',
    `> ZNTC 의 경쟁도구 대비 비율이 baseline 보다 **${(tol * 100).toFixed(0)}% 이상** 악화. ` +
      `절대 ms 가 아니라 같은 머신의 esbuild/Bun 대비 비율이라 runner 노이즈에 강함(가능하면 ` +
      `esbuild·Bun 두 통제군이 모두 악화해야 flag). merge 는 막지 않음 — 의도된 변경이면 baseline 갱신.`,
    '',
    '| 벤치마크 | 기준 도구 | 현재 비율 | baseline | 임계 | 악화 | 보강 |',
    '|---|---|---|---|---|---|---|',
  ];
  for (const f of [...findings].sort((a, b) => b.pct - a.pct)) {
    lines.push(
      `| ${f.key.replace('|', ' — ')} | ${f.comp} | ${f.cur.toFixed(2)}x | ${f.base}x | ${f.thr.toFixed(2)}x | +${f.pct.toFixed(0)}% | ${bunNote(f)} |`,
    );
  }
  lines.push('');
  lines.push(
    '> baseline 파일: `tests/benchmark/baselines/bench-ratio-baseline.json` · 의도된 회귀라면 해당 값을 갱신하세요.',
  );
  return lines.join('\n');
}

// ============================================================
// CLI (import.meta.main 일 때만 — 테스트가 import 해도 실행 안 됨)
// ============================================================

function main() {
  // --baseline/--out 은 다음 인자를 값으로 소비하고, 첫 positional 을 results 경로로 쓴다.
  // (단순 indexOf+1 은 플래그가 마지막이면 undefined, find 는 플래그 값을 results 로 오인할 수 있음.)
  const argv = process.argv.slice(2);
  let resultsPath = '';
  let baselinePath = join(__dirname, 'baselines', 'bench-ratio-baseline.json');
  let outPath: string | null = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--baseline') baselinePath = argv[++i] ?? baselinePath;
    else if (a === '--out') outPath = argv[++i] ?? null;
    else if (!a.startsWith('--') && !resultsPath) resultsPath = a;
  }

  const emit = (md: string) => {
    const out = md.endsWith('\n') ? md : md + '\n';
    process.stdout.write(out);
    if (outPath) writeFileSync(outPath, out);
  };

  // 비교 불가 상황은 게이트를 조용히 통과 (댓글은 항상 나가야 함 — emit 으로 한 줄은 항상 남긴다).
  if (!resultsPath || !existsSync(resultsPath)) {
    emit(`> ℹ️ 회귀 게이트: 결과 JSON(${resultsPath || 'unset'}) 없음 — skip.`);
    return;
  }
  if (!existsSync(baselinePath)) {
    emit(`> ℹ️ 회귀 게이트: baseline(${baselinePath}) 없음 — skip.`);
    return;
  }

  // JSON 이 깨졌어도(부분 업로드/쓰기 중단) 크래시 대신 skip 한 줄을 남긴다 — '댓글은 항상' 불변식.
  let data: BenchJson;
  let baseline: Baseline;
  try {
    data = JSON.parse(readFileSync(resultsPath, 'utf8'));
    baseline = JSON.parse(readFileSync(baselinePath, 'utf8'));
  } catch (e) {
    emit(`> ℹ️ 회귀 게이트: JSON 파싱 실패 (${(e as Error).message}) — skip.`);
    return;
  }
  emit(renderWarning(detectRegressions(data, baseline), baseline));
}

if (import.meta.main) main();
