import { describe, test, expect } from 'bun:test';
import {
  createFixture,
  createNdjsonTail,
  killAndWait,
  spawnWatchJson,
  waitForNdjsonLines,
  ZNTC_BIN,
} from './helpers';
import { join } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';

/**
 * Watch 메모리 누수 시뮬레이션 스트레스 테스트.
 *
 * 실시간 8시간+ 실측은 CI에 부적합하므로, 누수가 "실제 시간"보다 "rebuild 횟수"에
 * 비례한다는 전제로 압축하여 빠르게 N회 rebuild를 수행하고 RSS 궤적을 측정한다.
 */

/**
 * 프로세스 메모리(KB) 샘플링.
 *
 * macOS: `footprint` 의 phys_footprint (Activity Monitor 의 "메모리" 값). RSS 는 시스템
 * 메모리 압박 시 압축·회수된 페이지가 빠졌다가 다시 접근하면 돌아와 궤적이 출렁인다 —
 * 다른 무거운 프로세스와 함께 돌면 14→18→10→17MB 처럼 오르내려 누수 없이도 steady slope 가
 * 임계를 넘었다. phys_footprint 는 압축 메모리까지 포함해 그 영향을 받지 않는다.
 * 그 외: `ps -o rss=`.
 */
async function sampleMemoryKB(pid: number): Promise<number> {
  const darwin = process.platform === 'darwin';
  const proc = Bun.spawn({
    cmd: darwin ? ['footprint', String(pid)] : ['ps', '-o', 'rss=', '-p', String(pid)],
    stdout: 'pipe',
    stderr: 'pipe',
  });
  const stdout = await new Response(proc.stdout).text();
  await proc.exited;
  if (darwin) {
    const m = /Footprint:\s*([\d.]+)\s*(B|KB|MB|GB)/.exec(stdout);
    if (!m)
      throw new Error(
        `failed to parse footprint for pid ${pid}: ${JSON.stringify(stdout.slice(0, 200))}`,
      );
    const scale = { B: 1 / 1024, KB: 1, MB: 1024, GB: 1024 * 1024 }[
      m[2] as 'B' | 'KB' | 'MB' | 'GB'
    ];
    return Math.round(Number.parseFloat(m[1]) * scale);
  }
  const rss = Number.parseInt(stdout.trim(), 10);
  if (Number.isNaN(rss)) {
    throw new Error(`failed to parse RSS for pid ${pid}: ${JSON.stringify(stdout)}`);
  }
  return rss;
}

/** samples = [{x,y}...] 에서 최소제곱법 기울기(y per x). */
function linearSlope(samples: Array<{ x: number; y: number }>): number {
  const n = samples.length;
  const mx = samples.reduce((s, p) => s + p.x, 0) / n;
  const my = samples.reduce((s, p) => s + p.y, 0) / n;
  let num = 0;
  let den = 0;
  for (const p of samples) {
    num += (p.x - mx) * (p.y - my);
    den += (p.x - mx) * (p.x - mx);
  }
  return den === 0 ? 0 : num / den;
}

/**
 * Debug 빌드는 `std.heap.DebugAllocator` 를 쓴다(release 는 mimalloc). 같은 소스에서
 * Debug 바이너리는 메모리가 rebuild 마다 선형으로 늘지만(150회 3.4→21.5MB), ReleaseFast 는
 * 2.6MB 로 평탄했다 — 할당자 특성이지 누수가 아니다. 누수 판정은 release 바이너리에서만
 * 의미가 있다(CI 통합 테스트는 ReleaseFast). DebugAllocator 의 이중 해제 보고 문자열로 판별한다.
 */
const usesDebugAllocator = readFileSync(ZNTC_BIN).includes('Double free detected.');

describe('watch 메모리 스트레스 (시뮬레이션)', () => {
  test.skipIf(usesDebugAllocator)(
    '연속 rebuild N회 후 RSS 궤적이 임계값 내',
    { timeout: 10 * 60 * 1000 /* 10분 — CI 느린 러너 여유 */ },
    async () => {
      const ITERATIONS = 150;
      const SAMPLE_EVERY = 15;
      // 첫 ~40% 의 rebuild 는 cache warmup 구간 — slope 측정에서 제외 (아래 주석 참조).
      const WARMUP_FRACTION = 0.4;
      // 임계: 실측 0.05 KB/rebuild 대비 넉넉하되 누수는 탐지 가능한 범위.
      // 실제 누수 발생 시 수십 KB/회 수준이 통상.
      const SLOPE_THRESHOLD_KB = 2;
      const TOTAL_GROWTH_MAX_KB = 2048; // 2MB — warmup 후 정상 변동 흡수

      const { dir, cleanup } = await createFixture({
        'entry.ts': `export const v = 0;\nexport const extra = "padding";\n`,
      });
      const outFile = join(dir, 'out.js');
      const entryFile = join(dir, 'entry.ts');
      const jsonOut = join(dir, 'ndjson.txt');

      const proc = spawnWatchJson(['--bundle', entryFile, '-o', outFile, '--watch-json'], jsonOut);
      const tail = createNdjsonTail();

      try {
        await waitForNdjsonLines(jsonOut, 1, tail, { timeoutMs: 15000 });

        // spawnWatchJson 가 zntc 를 직접 spawn 하므로 proc.pid 가 곧 zntc PID.
        const zntcPid = proc.pid!;
        const samples: Array<{ x: number; y: number }> = [];
        samples.push({ x: 0, y: await sampleMemoryKB(zntcPid) });

        for (let i = 1; i <= ITERATIONS; i++) {
          // content hash 변화 유도 — 변수 값을 iter마다 바꿈
          writeFileSync(entryFile, `export const v = ${i};\nexport const extra = "padding";\n`);
          await waitForNdjsonLines(jsonOut, 1 + i, tail, { timeoutMs: 10000 });

          if (i % SAMPLE_EVERY === 0) {
            samples.push({ x: i, y: await sampleMemoryKB(zntcPid) });
          }
        }

        const first = samples[0].y;
        const last = samples[samples.length - 1].y;
        const max = Math.max(...samples.map((s) => s.y));
        // warmup 구간 동안 resolve/compiled cache·module store·intern table 가 차오르며
        // RSS 가 한 번 ramp 후 평탄해진다 (bounded). 전체 샘플에 linear fit 하면 이 ramp 가
        // slope 를 부풀려 false positive. 누수 판정은 warmup 이후 steady-state 구간의 slope 로
        // — 실제 누수면 평탄화되지 않고 steady-state 에서도 기울기가 남는다.
        const steadyState = samples.slice(Math.floor(samples.length * WARMUP_FRACTION));
        const slope = linearSlope(steadyState.length >= 2 ? steadyState : samples);
        const totalGrowth = max - first;

        const trace = samples.map((s) => `${s.x}:${s.y}KB`).join(', ');
        const summary = `iters=${ITERATIONS} first=${first}KB last=${last}KB max=${max}KB steadySlope=${slope.toFixed(2)}KB/rebuild growth=${totalGrowth}KB`;

        // 실패 시 디버깅 편의. 성공 시에도 CI 로그에 궤적 한 줄 남겨 트렌드 모니터링.
        console.log(`[watch-stress] ${summary}`);
        console.log(`[watch-stress] trace: ${trace}`);

        // 2가지 지표로 누수 판정 — 기울기 + 전체 성장량. 계단식 누수(한 번에 확 증가 후 평평)는
        // slope가 낮을 수 있어 totalGrowth도 함께 체크.
        if (slope >= SLOPE_THRESHOLD_KB || totalGrowth > TOTAL_GROWTH_MAX_KB) {
          throw new Error(`RSS 궤적이 임계값 초과\n${summary}\ntrace: ${trace}`);
        }
        expect(slope).toBeLessThan(SLOPE_THRESHOLD_KB);
        expect(totalGrowth).toBeLessThanOrEqual(TOTAL_GROWTH_MAX_KB);
      } finally {
        await killAndWait(proc);
        await cleanup();
      }
    },
  );
});
