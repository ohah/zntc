import { describe, test, expect } from "bun:test";
import {
  createFixture,
  createNdjsonTail,
  killAndWait,
  spawnWatchJson,
  waitForNdjsonLines,
} from "./helpers";
import { join } from "node:path";
import { writeFileSync } from "node:fs";

/**
 * Watch 메모리 누수 시뮬레이션 스트레스 테스트.
 *
 * 실시간 8시간+ 실측은 CI에 부적합하므로, 누수가 "실제 시간"보다 "rebuild 횟수"에
 * 비례한다는 전제로 압축하여 빠르게 N회 rebuild를 수행하고 RSS 궤적을 측정한다.
 */

/** `ps -o rss= -p <pid>`로 RSS(KB)를 샘플링. Linux/macOS 공용. */
async function sampleRSS(pid: number): Promise<number> {
  const proc = Bun.spawn({
    cmd: ["ps", "-o", "rss=", "-p", String(pid)],
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = await new Response(proc.stdout).text();
  await proc.exited;
  const rss = Number.parseInt(stdout.trim(), 10);
  if (Number.isNaN(rss)) {
    throw new Error(`failed to parse RSS for pid ${pid}: ${JSON.stringify(stdout)}`);
  }
  return rss;
}

/** shell 부모 PID의 자식(zts) 찾기. Linux/macOS 공용. */
async function findZtsChildPid(parentPid: number): Promise<number> {
  const proc = Bun.spawn({
    cmd: ["pgrep", "-P", String(parentPid), "zts"],
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = await new Response(proc.stdout).text();
  await proc.exited;
  const pid = Number.parseInt(stdout.trim().split("\n")[0], 10);
  if (Number.isNaN(pid)) {
    throw new Error(`failed to find zts child of pid ${parentPid}`);
  }
  return pid;
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

describe("watch 메모리 스트레스 (시뮬레이션)", () => {
  test(
    "연속 rebuild N회 후 RSS 궤적이 임계값 내",
    { timeout: 10 * 60 * 1000 /* 10분 — CI 느린 러너 여유 */ },
    async () => {
      const ITERATIONS = 150;
      const SAMPLE_EVERY = 15;
      // 임계: 실측 0.05 KB/rebuild 대비 넉넉하되 누수는 탐지 가능한 범위.
      // 실제 누수 발생 시 수십 KB/회 수준이 통상.
      const SLOPE_THRESHOLD_KB = 2;
      const TOTAL_GROWTH_MAX_KB = 2048; // 2MB — warmup 후 정상 변동 흡수

      const { dir, cleanup } = await createFixture({
        "entry.ts": `export const v = 0;\nexport const extra = "padding";\n`,
      });
      const outFile = join(dir, "out.js");
      const entryFile = join(dir, "entry.ts");
      const jsonOut = join(dir, "ndjson.txt");

      const proc = spawnWatchJson(["--bundle", entryFile, "-o", outFile, "--watch-json"], jsonOut);
      const tail = createNdjsonTail();

      try {
        await waitForNdjsonLines(jsonOut, 1, tail, { timeoutMs: 15000 });

        const ztsPid = await findZtsChildPid(proc.pid!);
        const samples: Array<{ x: number; y: number }> = [];
        samples.push({ x: 0, y: await sampleRSS(ztsPid) });

        for (let i = 1; i <= ITERATIONS; i++) {
          // content hash 변화 유도 — 변수 값을 iter마다 바꿈
          writeFileSync(entryFile, `export const v = ${i};\nexport const extra = "padding";\n`);
          await waitForNdjsonLines(jsonOut, 1 + i, tail, { timeoutMs: 10000 });

          if (i % SAMPLE_EVERY === 0) {
            samples.push({ x: i, y: await sampleRSS(ztsPid) });
          }
        }

        const first = samples[0].y;
        const last = samples[samples.length - 1].y;
        const max = Math.max(...samples.map((s) => s.y));
        const slope = linearSlope(samples);
        const totalGrowth = max - first;

        const trace = samples.map((s) => `${s.x}:${s.y}KB`).join(", ");
        const summary = `iters=${ITERATIONS} first=${first}KB last=${last}KB max=${max}KB slope=${slope.toFixed(2)}KB/rebuild growth=${totalGrowth}KB`;

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
