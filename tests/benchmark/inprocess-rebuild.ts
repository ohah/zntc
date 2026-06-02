#!/usr/bin/env bun
/**
 * In-process rebuild benchmark — fair comparison.
 *
 * 모든 도구를 in-process programmatic API 의 **file-watch 경로**로 동일하게 측정:
 * 파일 touch → 각 도구의 watch 콜백/이벤트 fire 까지의 시간(감지+rebuild+콜백 dispatch).
 *   - ZNTC: `@zntc/core` watch(opts) + onRebuild (NAPI worker thread)
 *   - esbuild: context().watch() + onEnd 플러그인
 *   - rolldown: watch().on('event')
 *
 * ⚠️ esbuild 를 `ctx.rebuild()`(watch 미경유 직접 호출)로 재면 파일감지/콜백 오버헤드를
 * 건너뛰어 zntc/rolldown(file-watch)보다 부당하게 빨라진다 → 반드시 watch 로 통일.
 * (zntc 는 incremental rebuild 를 watch() 로만 노출 — 직접 rebuild API 없음.)
 *
 * ⚠️ 결과 해석: zntc(NAPI) rebuild ~53ms floor(tiny≈medium, 모듈 수 무관)는 *컴파일* 이
 * 아니라 NAPI watch 의 **고정 50ms 디바운스**(napi/watch.zig `watch_debounce_ms`). 세 도구
 * 모두 watch 디바운스가 있으나 zntc 의 50ms 가 esbuild/rolldown 보다 커 더 느리게 보인다.
 * 실제 컴파일 속도는 incremental-rebuild.ts(CLI, 디바운스 0)의 ~16ms 가 더 가깝다.
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
  // ⚠️ 공정성: zntc/rolldown 은 file-watch(touch→onRebuild)로 재므로 esbuild 도 직접
  // `ctx.rebuild()`(watch 미경유, 감지/콜백 오버헤드 0) 대신 **watch API**(`ctx.watch()` +
  // onEnd 플러그인)로 측정한다. 안 그러면 esbuild 만 파일감지 latency 를 건너뛰어 유리.
  let onEndResolve: (() => void) | null = null;
  const ctx = await esbuildContext({
    entryPoints: [entry],
    outfile: out,
    bundle: true,
    write: true,
    loader: { '.ts': 'ts' },
    format: 'iife',
    plugins: [
      {
        name: 'bench-onend',
        setup(build) {
          build.onEnd(() => {
            if (onEndResolve) {
              const r = onEndResolve;
              onEndResolve = null;
              r();
            }
          });
        },
      },
    ],
  });
  const firstBuild = new Promise<void>((res) => {
    onEndResolve = res;
  });
  const initStart = performance.now();
  await ctx.watch(); // 초기 빌드 트리거 → onEnd
  await firstBuild;
  const initialMs = performance.now() - initStart;
  try {
    await sleep(SETTLE_MS);
    for (let i = 0; i < ITERATIONS; i++) {
      const p = new Promise<void>((res, rej) => {
        onEndResolve = res;
        setTimeout(() => {
          if (onEndResolve) {
            onEndResolve = null;
            rej(new Error(`rebuild ${i} timeout`));
          }
        }, REBUILD_TIMEOUT_MS);
      });
      appendFileSync(entry, `export const _i${i}=${i};console.log(_i${i});\n`);
      const t0 = performance.now();
      await p;
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
