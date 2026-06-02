#!/usr/bin/env bun
/**
 * In-process **순수 incremental rebuild** 벤치 — 각 도구의 가장 빠른 programmatic rebuild
 * 경로(디바운스/watch latency 제외, 캐시 재사용)로 컴파일 속도만 비교:
 *   - ZNTC:    `@zntc/core` watch({ watchDelay: 0 }) + onRebuild — 디바운스 0(즉시 rebuild).
 *              직접 rebuild API 가 없어 watch 경유(kqueue 감지+콜백 dispatch 소량 포함).
 *   - esbuild: `context().rebuild()` — documented incremental(ctx 캐시 재사용).
 *   - rolldown:`rolldown()` 빌드 객체 재사용 + `generate()` 재호출(변경 re-read + incremental).
 *
 * ⚠️ watch latency(파일감지+디바운스 포함)는 *이* 벤치가 아니라 incremental-rebuild.ts(실제
 * CLI) / napi-watch.ts 가 잰다. 거기 zntc 53ms 는 컴파일이 아니라 NAPI watch 기본 50ms 디바운스
 * (이제 watchDelay 로 조절 가능). 본 벤치는 그 디바운스를 빼고 *순수 컴파일* 만 본다.
 *
 * 실행: bun run inprocess-rebuild.ts
 *
 * Note(이력): 예전엔 bun 이 rolldown import 에서 crash 해 node+mjs 우회가 필요했으나,
 * 현재 bun/rolldown 조합에선 `bun run` 으로 바로 동작한다. (node 로 직접 돌리면 `@zntc/core`
 * 의 extensionless ESM import 가 strict resolver 에서 막히고, `bun build` 로 번들하면 rolldown
 * 네이티브 바인딩 resolution 이 깨져 둘 다 부적합 → bun 직접 실행이 가장 단순.)
 */

import { watch as zntcWatch } from '../../packages/core/index.ts';
import { context as esbuildContext } from 'esbuild';
import { rolldown } from 'rolldown';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// 단일 rebuild 가 GC 로 run-to-run 변동이 커, median 샘플 수를 늘려 안정화(10→50). 50 샘플
// median 은 GC outlier 에 강건. 매 iteration 은 entry 를 append 가 아니라 baseSrc + 마커 1줄로
// in-place 덮어써 파일 크기를 일정 유지(append 면 누적으로 파일이 커져 rebuild 가 무거워지는 confound 제거).
const ITERATIONS = 50;
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
  {
    name: 'large100',
    build(dir) {
      for (let i = 0; i < 100; i++) {
        writeFileSync(join(dir, `m${i}.ts`), `export function fn${i}(x){return x+${i};}\n`);
      }
      const entry = join(dir, 'entry.ts');
      const imps = Array.from({ length: 100 }, (_, i) => `import { fn${i} } from './m${i}';`).join(
        '\n',
      );
      const calls = Array.from({ length: 100 }, (_, i) => `fn${i}(1)`).join('+');
      writeFileSync(entry, `${imps}\nconsole.log(${calls});\n`);
      writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'fx', type: 'module' }));
      return { entry };
    },
  },
];

// 참고: incremental 의 최대 합성 fixture 는 large100. large1000(1000-module) 은 cold-build 에만
// 둔다 — cold 는 build() 기반이라 안정적이나, incremental 은 watch(파일 1000개 감시) 경유라
// 50-iter rapid-rewrite 에서 NAPI watch worker 가 간헐 segfault → 재현 가능한 공개 벤치로 부적합.
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
  const baseSrc = readFileSync(entry, 'utf8');
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
    // 순수 rebuild 측정 — 디바운스 0 으로 끄고 incremental rebuild 컴파일만 잰다.
    // (zntc 는 직접 rebuild API 가 없어 watch 경유 — kqueue 감지+콜백 dispatch 소량 포함.)
    watchDelay: 0,
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
      writeFileSync(entry, `${baseSrc}\nexport const _b${i} = ${i};\nconsole.log(_b${i});\n`);
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
  const baseSrc = readFileSync(entry, 'utf8');
  const out = join(dir, 'out.js');
  const iters: number[] = [];
  // 순수 rebuild — esbuild 의 documented incremental API `ctx.rebuild()`(컨텍스트 캐시 재사용).
  const ctx = await esbuildContext({
    entryPoints: [entry],
    outfile: out,
    bundle: true,
    write: true,
    loader: { '.ts': 'ts' },
    format: 'iife',
  });
  const initStart = performance.now();
  await ctx.rebuild();
  const initialMs = performance.now() - initStart;
  try {
    await sleep(SETTLE_MS);
    for (let i = 0; i < ITERATIONS; i++) {
      writeFileSync(entry, `${baseSrc}\nexport const _b${i} = ${i};\nconsole.log(_b${i});\n`);
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
  const baseSrc = readFileSync(entry, 'utf8');
  const iters: number[] = [];
  // 순수 rebuild — rolldown() 빌드 객체 재사용 + generate() 재호출(변경 파일 re-read 후
  // incremental 재번들; lodash initial 20ms→re-gen 13ms 로 캐시 재사용 확인). watch 미경유.
  const bundle = await rolldown({ input: entry, cwd: dir });
  const initStart = performance.now();
  await bundle.generate({ format: 'esm' });
  const initialMs = performance.now() - initStart;
  try {
    await sleep(SETTLE_MS);
    for (let i = 0; i < ITERATIONS; i++) {
      writeFileSync(entry, `${baseSrc}\nexport const _b${i} = ${i};\nconsole.log(_b${i});\n`);
      const t0 = performance.now();
      await bundle.generate({ format: 'esm' });
      iters.push(performance.now() - t0);
      await sleep(SETTLE_MS);
    }
    return { initialMs, iters };
  } finally {
    try {
      await bundle.close?.();
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
  console.log('# In-process 순수 incremental rebuild (디바운스/watch latency 제외, 컴파일만)\n');
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
