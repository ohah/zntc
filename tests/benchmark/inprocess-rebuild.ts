#!/usr/bin/env node
/**
 * In-process rebuild benchmark — fair comparison.
 *
 * 모든 도구를 *programmatic API* 로 호출해 spawn/polling overhead 제거.
 *   - ZNTC: `@zntc/core` watch(opts) + onRebuild
 *   - esbuild: context().rebuild()
 *   - rolldown: watch().on('event')
 *
 * Bun 이 rolldown import 에서 crash → node 로 실행 (`bunfig.toml` 안 거치도록 .ts → .mjs 분리).
 *
 * 실행: node --import 'data:text/javascript,...' tests/benchmark/inprocess-rebuild.ts
 *   또는 tsx/ts-node — 본 파일은 ts 문법 사용. 실측 시 mjs 트랜스파일.
 *
 * Note: 이 파일을 `bun run` 으로 돌리면 rolldown 이 crash. node + tsx 또는 직접 mjs 사용.
 */

// 본 파일은 .mjs 변환 후 실행 — 사용:
//   bun build tests/benchmark/inprocess-rebuild.ts --target=node --outfile /tmp/inproc.mjs
//   node /tmp/inproc.mjs

import { watch as zntcWatch } from '../../packages/core/index.ts';
import { context as esbuildContext } from 'esbuild';
import { watch as rolldownWatch } from 'rolldown';
import { appendFileSync, mkdtempSync, rmSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const ITERATIONS = 10;
const READY_TIMEOUT_MS = 15_000;
const REBUILD_TIMEOUT_MS = 10_000;
const SETTLE_MS = 200;

interface Fixture {
  name: string;
  build(dir: string): { entry: string };
}

const fixtures: Fixture[] = [
  {
    name: 'tiny',
    build(dir) {
      const entry = join(dir, 'entry.ts');
      writeFileSync(entry, `export const x = 1;\nconsole.log(x);\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
  {
    name: 'medium',
    build(dir) {
      for (let i = 0; i < 10; i++) {
        writeFileSync(join(dir, `m${i}.ts`), `export function fn${i}(x){return x+${i};}\n`);
      }
      const entry = join(dir, 'entry.ts');
      const imps = Array.from({ length: 10 }, (_, i) => `import { fn${i} } from './m${i}';`).join(
        '\n',
      );
      const calls = Array.from({ length: 10 }, (_, i) => `fn${i}(1)`).join('+');
      writeFileSync(entry, `${imps}\nconsole.log(${calls});\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
  {
    name: 'lodash',
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

const sleep = (ms: number) => new Promise<void>((res) => setTimeout(res, ms));

function summarize(arr: number[]) {
  const s = [...arr].sort((a, b) => a - b);
  const n = s.length;
  const median = n % 2 === 1 ? s[(n - 1) >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2;
  const mean = s.reduce((a, b) => a + b, 0) / n;
  return { min: s[0], max: s[n - 1], median, mean };
}

async function measureZntc(fx: Fixture) {
  const dir = mkdtempSync(join(tmpdir(), `inp-zntc-${fx.name}-`));
  const { entry } = fx.build(dir);
  const out = join(dir, 'out.js');
  const iters: number[] = [];
  let t0 = 0;
  let rebuildResolve: (() => void) | null = null;
  let readyResolve!: () => void;
  const readyP = new Promise<void>((res, rej) => {
    readyResolve = res;
    setTimeout(() => rej(new Error('ready timeout')), READY_TIMEOUT_MS);
  });
  const initStart = performance.now();
  const handle = zntcWatch({
    entryPoints: [entry],
    outfile: out,
    bundle: true,
    write: true,
    onReady: () => readyResolve(),
    onRebuild: () => {
      if (rebuildResolve) {
        iters.push(performance.now() - t0);
        const r = rebuildResolve;
        rebuildResolve = null;
        r();
      }
    },
  });
  try {
    await readyP;
    const initialMs = performance.now() - initStart;
    await sleep(SETTLE_MS);
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
      appendFileSync(entry, `export const _i${i}=${i};console.log(_i${i});\n`);
      t0 = performance.now();
      await p;
      await sleep(SETTLE_MS);
    }
    return { initialMs, iters };
  } finally {
    try {
      handle.stop();
    } catch {}
    rmSync(dir, { recursive: true, force: true });
  }
}

async function measureEsbuild(fx: Fixture) {
  const dir = mkdtempSync(join(tmpdir(), `inp-esb-${fx.name}-`));
  const { entry } = fx.build(dir);
  const out = join(dir, 'out.js');
  const iters: number[] = [];
  const initStart = performance.now();
  const ctx = await esbuildContext({
    entryPoints: [entry],
    outfile: out,
    bundle: true,
    write: true,
    loader: { '.ts': 'ts' },
    format: 'iife',
  });
  await ctx.rebuild();
  const initialMs = performance.now() - initStart;
  try {
    await sleep(SETTLE_MS);
    for (let i = 0; i < ITERATIONS; i++) {
      appendFileSync(entry, `export const _i${i}=${i};console.log(_i${i});\n`);
      const t0 = performance.now();
      await ctx.rebuild();
      iters.push(performance.now() - t0);
      await sleep(SETTLE_MS);
    }
    return { initialMs, iters };
  } finally {
    await ctx.dispose();
    rmSync(dir, { recursive: true, force: true });
  }
}

async function measureRolldown(fx: Fixture) {
  const dir = mkdtempSync(join(tmpdir(), `inp-rd-${fx.name}-`));
  const { entry } = fx.build(dir);
  const out = join(dir, 'out.js');
  const iters: number[] = [];
  let t0 = 0;
  let rebuildResolve: (() => void) | null = null;
  let readyResolve!: () => void;
  const readyP = new Promise<void>((res, rej) => {
    readyResolve = res;
    setTimeout(() => rej(new Error('rolldown ready timeout')), READY_TIMEOUT_MS);
  });
  const initStart = performance.now();
  const watcher = rolldownWatch({
    input: entry,
    output: { file: out, format: 'esm' },
  });
  watcher.on('event', (e: any) => {
    if (e.code === 'BUNDLE_END' || e.code === 'END') {
      if (rebuildResolve) {
        iters.push(performance.now() - t0);
        const r = rebuildResolve;
        rebuildResolve = null;
        r();
      } else {
        readyResolve();
      }
    }
  });
  try {
    await readyP;
    const initialMs = performance.now() - initStart;
    await sleep(SETTLE_MS);
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
      appendFileSync(entry, `export const _i${i}=${i};console.log(_i${i});\n`);
      t0 = performance.now();
      await p;
      await sleep(SETTLE_MS);
    }
    return { initialMs, iters };
  } finally {
    try {
      await watcher.close();
    } catch {}
    rmSync(dir, { recursive: true, force: true });
  }
}

function fmt(n: number) {
  if (n < 10) return n.toFixed(2);
  if (n < 100) return n.toFixed(1);
  return n.toFixed(0);
}
function pad(s: string | number, n: number) {
  return String(s).padStart(n);
}

async function main() {
  console.log('# In-process rebuild benchmark (fair, no spawn/polling)\n');
  console.log(`Iter ${ITERATIONS}, settle ${SETTLE_MS}ms.\n`);
  for (const fx of fixtures) {
    console.log(`\n## ${fx.name}\n`);
    console.log(`| Tool      | Initial   | Rebuild median | min   | max   | mean  |`);
    console.log(`|-----------|----------:|---------------:|------:|------:|------:|`);
    for (const [name, fn] of [
      ['zntc(NAPI)', measureZntc],
      ['esbuild', measureEsbuild],
      ['rolldown', measureRolldown],
    ] as const) {
      try {
        const r = await fn(fx);
        const s = summarize(r.iters);
        console.log(
          `| ${name.padEnd(9)} | ${pad(fmt(r.initialMs), 7)}ms | ${pad(fmt(s.median), 12)}ms | ${pad(fmt(s.min), 4)}ms | ${pad(fmt(s.max), 4)}ms | ${pad(fmt(s.mean), 4)}ms |`,
        );
      } catch (e) {
        console.log(
          `| ${name.padEnd(9)} | FAIL      | ${String(e).slice(0, 30).padEnd(14)} | -     | -     | -     |`,
        );
      }
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
