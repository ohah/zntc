#!/usr/bin/env bun
/**
 * NAPI watch rebuild benchmark — `@zntc/core`의 `watch(options)` 측정.
 *
 * CLI `--bundle --watch` 는 500ms 폴링 (src/main.zig:904) → measurement 가
 * 폴링 대기에 묻힘. NAPI watch 는 별도 path — onReady/onRebuild 콜백 + worker
 * thread + 진짜 file watcher (kqueue/inotify 가능).
 *
 * 실행: bun run napi-watch.ts
 */

import { watch } from '../../packages/core/index.ts';
import { appendFileSync, mkdtempSync, rmSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const ROOT = resolve(__dirname, '../..');

const ITERATIONS = 10;
const READY_TIMEOUT_MS = 15_000;
const REBUILD_TIMEOUT_MS = 10_000;
const POST_BUILD_SETTLE_MS = 200;

interface Fixture {
  name: string;
  description: string;
  build(dir: string): { entry: string };
}

const fixtures: Fixture[] = [
  {
    name: 'tiny',
    description: 'single 2-line file',
    build(dir) {
      const entry = join(dir, 'entry.ts');
      writeFileSync(entry, `export const x = 1;\nconsole.log(x);\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
  {
    name: 'medium',
    description: '10 local modules',
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
    description: 'lodash-es subset',
    build(dir) {
      const benchNm = join(__dirname, 'node_modules');
      try {
        symlinkSync(benchNm, join(dir, 'node_modules'), 'dir');
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

async function sleep(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

function summarize(arr: number[]) {
  const sorted = [...arr].sort((a, b) => a - b);
  const n = sorted.length;
  const median = n % 2 === 1 ? sorted[(n - 1) >> 1] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  const mean = sorted.reduce((a, b) => a + b, 0) / n;
  return { min: sorted[0], max: sorted[n - 1], median, mean };
}

async function measureFixture(fx: Fixture): Promise<
  | {
      initialMs: number;
      iters: number[];
    }
  | { error: string }
> {
  const dir = mkdtempSync(join(tmpdir(), `napi-${fx.name}-`));
  const { entry } = fx.build(dir);
  const outFile = join(dir, 'out.js');

  let readyResolve!: () => void;
  const readyP = new Promise<void>((res, rej) => {
    readyResolve = res;
    setTimeout(() => rej(new Error('ready timeout')), READY_TIMEOUT_MS);
  });
  let rebuildResolve: (() => void) | null = null;
  let t0 = 0;
  const rebuildTimes: number[] = [];

  const initStart = performance.now();
  const handle = watch({
    entryPoints: [entry],
    outfile: outFile,
    bundle: true,
    write: true,
    onReady: () => readyResolve(),
    onRebuild: () => {
      if (rebuildResolve) {
        const dt = performance.now() - t0;
        rebuildTimes.push(dt);
        const r = rebuildResolve;
        rebuildResolve = null;
        r();
      }
    },
  });

  try {
    await readyP;
    const initialMs = performance.now() - initStart;
    await sleep(POST_BUILD_SETTLE_MS);

    for (let i = 0; i < ITERATIONS; i++) {
      const p = new Promise<void>((res, rej) => {
        rebuildResolve = res;
        setTimeout(() => {
          if (rebuildResolve) {
            rebuildResolve = null;
            rej(new Error(`rebuild ${i} timeout`));
          }
        }, REBUILD_TIMEOUT_MS);
      });
      appendFileSync(entry, `export const _iter${i} = ${i};\nconsole.log(_iter${i});\n`);
      t0 = performance.now();
      try {
        await p;
      } catch (e) {
        return { error: String(e) };
      }
      await sleep(POST_BUILD_SETTLE_MS);
    }

    return { initialMs, iters: rebuildTimes };
  } finally {
    try {
      handle.stop();
    } catch {}
    rmSync(dir, { recursive: true, force: true });
  }
}

function fmt(n: number): string {
  if (n < 10) return n.toFixed(2);
  if (n < 100) return n.toFixed(1);
  return n.toFixed(0);
}

function pad(s: string | number, n: number): string {
  return String(s).padStart(n);
}

async function main() {
  console.log('# NAPI watch rebuild benchmark\n');
  console.log(
    `@zntc/core 의 watch(opts) + onRebuild 콜백 측정 (in-process, CLI 와 다른 path).\n` +
      `Iterations: ${ITERATIONS}, settle: ${POST_BUILD_SETTLE_MS}ms.\n`,
  );

  console.log(`| Fixture  | Initial   | Rebuild median | min   | max   | mean  |`);
  console.log(`|----------|----------:|---------------:|------:|------:|------:|`);

  for (const fx of fixtures) {
    try {
      const r = await measureFixture(fx);
      if ('error' in r) {
        console.log(
          `| ${fx.name.padEnd(8)} | FAIL      | ${r.error.slice(0, 30).padEnd(14)} | -     | -     | -     |`,
        );
        continue;
      }
      const s = summarize(r.iters);
      console.log(
        `| ${fx.name.padEnd(8)} | ${pad(fmt(r.initialMs), 7)}ms | ${pad(fmt(s.median), 12)}ms | ${pad(fmt(s.min), 4)}ms | ${pad(fmt(s.max), 4)}ms | ${pad(fmt(s.mean), 4)}ms |`,
      );
    } catch (e) {
      console.log(
        `| ${fx.name.padEnd(8)} | ERROR     | ${String(e).slice(0, 30).padEnd(14)} | -     | -     | -     |`,
      );
    }
  }
  console.log();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
