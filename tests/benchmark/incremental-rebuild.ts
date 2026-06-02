#!/usr/bin/env bun
/**
 * Incremental rebuild benchmark — ZNTC vs esbuild vs rolldown.
 *
 * Watch mode 시작 → entry 파일에 1 byte 추가 → output 파일 mtime 변화까지 시간 측정.
 * 도구별 stdout 마커 차이를 우회하기 위해 fs mtime 기준.
 *
 * 측정 의도: ZNTC의 2-phase + 모듈 캐싱이 incremental rebuild 에서 실제로
 * 경쟁사 대비 우위가 있는지. cold build 우위(4-26x, RN bench)는 별도 측정이며
 * 본 bench 는 *warm rebuild* 만 측정한다.
 *
 * 실행: bun run incremental-rebuild.ts
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { appendFileSync, existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const ROOT = resolve(__dirname, '../..');
// ⚠️ 실제 사용자 CLI = JS(`packages/core/bin/zntc.mjs`) — Node `fs.watch`(OS 네이티브:
// macOS FSEvents / Linux inotify) + `--watch-delay` debounce 를 쓴다. 내부 Zig 바이너리
// (`zig-out/bin/zntc`)는 500ms mtime 폴링 fallback 이라 watch 벤치에 쓰면 안 된다(폴링
// 지연이 측정을 지배 → "ZNTC 느림" 거짓 결론). esbuild/rolldown 도 진짜 CLI 라 공정 비교.
const ZNTC_CLI = join(ROOT, 'packages/core/bin/zntc.mjs');
const ESBUILD_BIN = join(__dirname, 'node_modules/.bin/esbuild');
const ROLLDOWN_BIN = join(__dirname, 'node_modules/.bin/rolldown');

const ITERATIONS = 10;
const INITIAL_BUILD_TIMEOUT_MS = 15_000;
const REBUILD_TIMEOUT_MS = 10_000;
const POLL_INTERVAL_MS = 2;
const POST_BUILD_SETTLE_MS = 200;

interface Fixture {
  name: string;
  description: string;
  build(dir: string): { entry: string };
}

const fixtures: Fixture[] = [
  {
    name: 'tiny',
    description: 'single 2-line file, no deps',
    build(dir) {
      const entry = join(dir, 'entry.ts');
      writeFileSync(entry, `export const x = 1;\nconsole.log(x);\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
  {
    name: 'medium',
    description: '10 local modules, mutual imports',
    build(dir) {
      for (let i = 0; i < 10; i++) {
        writeFileSync(
          join(dir, `m${i}.ts`),
          `export function fn${i}(x: number) { return x + ${i}; }\n`,
        );
      }
      const imports = Array.from(
        { length: 10 },
        (_, i) => `import { fn${i} } from './m${i}';`,
      ).join('\n');
      const calls = Array.from({ length: 10 }, (_, i) => `fn${i}(1)`).join(' + ');
      const entry = join(dir, 'entry.ts');
      writeFileSync(entry, `${imports}\nconsole.log(${calls});\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
  {
    name: 'lodash',
    description: 'lodash-es subset import (real npm dep, large dep graph)',
    build(dir) {
      // benchmark dir의 node_modules에 lodash-es가 있음 — symlink로 접근
      const benchNm = join(__dirname, 'node_modules');
      const localNm = join(dir, 'node_modules');
      try {
        require('node:fs').symlinkSync(benchNm, localNm, 'dir');
      } catch {}
      const entry = join(dir, 'entry.ts');
      writeFileSync(
        entry,
        `import { groupBy, sortBy, uniq, map, filter, reduce } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq, map, filter, reduce);\n`,
      );
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
];

interface ToolRunner {
  name: string;
  enabled: boolean;
  spawnWatch(dir: string, entry: string, outFile: string): ChildProcess;
}

import { basename } from 'node:path';

const tools: ToolRunner[] = [
  {
    name: 'zntc',
    enabled: existsSync(ZNTC_CLI),
    spawnWatch(dir, entry, outFile) {
      // 실제 사용자 CLI(JS) 를 그대로 실행 — `node zntc.mjs … --watch`. Node fs.watch
      // (FSEvents/inotify) 기반. --watch-delay=0: debounce 제거(측정 차감). outFile 은
      // watch 디렉토리(entry dir) 밖이라 self-trigger 피드백 루프 없음(아래 measureTool).
      return spawn(
        'node',
        [ZNTC_CLI, '--bundle', entry, '-o', outFile, '--watch', '--watch-delay=0'],
        { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] },
      );
    },
  },
  {
    name: 'esbuild',
    enabled: existsSync(ESBUILD_BIN),
    spawnWatch(dir, entry, outFile) {
      // `--watch=forever`: esbuild 는 stdin close 시 자동 stop 하므로 명시적 keep-alive.
      // outFile 은 절대경로(watch dir 밖) — zntc 와 동일 조건.
      return spawn(
        ESBUILD_BIN,
        [
          basename(entry),
          '--bundle',
          `--outfile=${outFile}`,
          '--watch=forever',
          '--loader:.ts=ts',
          '--format=iife',
        ],
        { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] },
      );
    },
  },
  {
    name: 'rolldown',
    enabled: existsSync(ROLLDOWN_BIN),
    spawnWatch(dir, entry, outFile) {
      return spawn(ROLLDOWN_BIN, [basename(entry), '-o', outFile, '--watch'], {
        cwd: dir,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    },
  },
];

async function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

async function waitForFile(path: string, timeoutMs: number): Promise<number> {
  const t0 = performance.now();
  while (performance.now() - t0 < timeoutMs) {
    if (existsSync(path)) return statSync(path).mtimeMs;
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error(`timeout waiting for ${path}`);
}

async function waitForMtimeChange(
  path: string,
  prevMtime: number,
  timeoutMs: number,
): Promise<number> {
  const t0 = performance.now();
  while (performance.now() - t0 < timeoutMs) {
    if (existsSync(path)) {
      const m = statSync(path).mtimeMs;
      if (m > prevMtime) return m;
    }
    await sleep(POLL_INTERVAL_MS);
  }
  throw new Error(`timeout waiting for mtime change on ${path} (prev=${prevMtime})`);
}

interface Stats {
  iters: number[];
  initialMs: number;
}

function summarize(arr: number[]): {
  min: number;
  max: number;
  median: number;
  mean: number;
} {
  const sorted = [...arr].sort((a, b) => a - b);
  const n = sorted.length;
  const median = n % 2 === 1 ? sorted[(n - 1) >> 1] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  const mean = sorted.reduce((a, b) => a + b, 0) / n;
  return { min: sorted[0], max: sorted[n - 1], median, mean };
}

async function measureTool(tool: ToolRunner, fx: Fixture): Promise<Stats | { error: string }> {
  const dir = mkdtempSync(join(tmpdir(), `inc-${tool.name}-${fx.name}-`));
  // 출력은 watch 디렉토리(entry dir) *밖* 별도 디렉토리로 — 실제 사용자 CLI 는
  // recursive fs.watch(entry dir)라, 출력이 watch dir 안이면 출력→재빌드 self-trigger
  // 피드백 루프가 생겨 측정이 왜곡된다(esbuild/rolldown 은 출력을 안 watch 해 무관하나
  // 조건 통일). entry-touch → output mtime 변화만 깨끗이 측정.
  const outDir = mkdtempSync(join(tmpdir(), `inc-out-${tool.name}-${fx.name}-`));
  const { entry } = fx.build(dir);
  const outFile = join(outDir, `${tool.name}.out.js`);

  const child = tool.spawnWatch(dir, entry, outFile);
  const stderrChunks: string[] = [];
  child.stderr?.on('data', (d) => stderrChunks.push(d.toString()));
  child.stdout?.on('data', () => {});

  try {
    const initStart = performance.now();
    let lastMtime: number;
    try {
      lastMtime = await waitForFile(outFile, INITIAL_BUILD_TIMEOUT_MS);
    } catch (e) {
      return {
        error: `initial build failed: ${stderrChunks.join('').slice(0, 300)}`,
      };
    }
    const initialMs = performance.now() - initStart;

    await sleep(POST_BUILD_SETTLE_MS);

    const iters: number[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      // touch *직전* 에 lastMtime 을 현재 출력 mtime 으로 refresh — settle(200ms) 동안
      // 일어난 noise rebuild(다중 fs.watch 이벤트 등)로 outFile mtime 이 앞서가 있으면,
      // 다음 touch 측정이 그 stale mtime 으로 즉시 반환(≈0ms artifact)되는 걸 차단.
      if (existsSync(outFile)) lastMtime = statSync(outFile).mtimeMs;
      // emit 결과물에 반영되는 변경 — esbuild 의 unchanged-skip 회피.
      // 변수 1개 추가 후 console.log 인자로 사용해 dead-code elim 도 회피.
      appendFileSync(entry, `export const _iter${i} = ${i};\nconsole.log(_iter${i});\n`);
      const t0 = performance.now();
      try {
        const newMtime = await waitForMtimeChange(outFile, lastMtime, REBUILD_TIMEOUT_MS);
        const dt = performance.now() - t0;
        iters.push(dt);
        lastMtime = newMtime;
      } catch (e) {
        return { error: `rebuild ${i} timeout` };
      }
      await sleep(POST_BUILD_SETTLE_MS);
    }

    return { iters, initialMs };
  } finally {
    child.kill('SIGTERM');
    await sleep(100);
    if (!child.killed) child.kill('SIGKILL');
    rmSync(dir, { recursive: true, force: true });
    rmSync(outDir, { recursive: true, force: true });
  }
}

function pad(s: string | number, n: number): string {
  return String(s).padStart(n);
}

function fmt(n: number): string {
  if (n < 10) return n.toFixed(2);
  if (n < 100) return n.toFixed(1);
  return n.toFixed(0);
}

async function main() {
  console.log('# Incremental rebuild benchmark\n');
  console.log(
    `Watch mode + file touch → output mtime 변화까지 시간 (ms).\n` +
      `Iterations per tool/fixture: ${ITERATIONS}, post-build settle: ${POST_BUILD_SETTLE_MS}ms.\n` +
      `폴링 간격 ${POLL_INTERVAL_MS}ms 가 측정 하한 (≈ noise floor).\n`,
  );

  if (!existsSync(ZNTC_CLI)) {
    console.error(`ZNTC CLI 없음: ${ZNTC_CLI}\n  먼저 \`bun run build:js\`(또는 napi 빌드) 실행`);
    process.exit(1);
  }

  for (const fx of fixtures) {
    console.log(`\n## ${fx.name} — ${fx.description}\n`);
    console.log(`| Tool     | Initial | Rebuild median | min   | max   | mean  |`);
    console.log(`|----------|--------:|---------------:|------:|------:|------:|`);
    for (const tool of tools) {
      if (!tool.enabled) {
        console.log(
          `| ${tool.name.padEnd(8)} | n/a     | n/a            | -     | -     | -     |`,
        );
        continue;
      }
      try {
        const r = await measureTool(tool, fx);
        if ('error' in r) {
          console.log(
            `| ${tool.name.padEnd(8)} | FAIL    | ${r.error.slice(0, 30).padEnd(14)} | -     | -     | -     |`,
          );
          continue;
        }
        const s = summarize(r.iters);
        console.log(
          `| ${tool.name.padEnd(8)} | ${pad(fmt(r.initialMs), 6)}ms | ${pad(fmt(s.median), 12)}ms | ${pad(fmt(s.min), 4)}ms | ${pad(fmt(s.max), 4)}ms | ${pad(fmt(s.mean), 4)}ms |`,
        );
      } catch (e) {
        console.log(
          `| ${tool.name.padEnd(8)} | ERROR   | ${String(e).slice(0, 20).padEnd(14)} | -     | -     | -     |`,
        );
      }
    }
  }
  console.log();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
