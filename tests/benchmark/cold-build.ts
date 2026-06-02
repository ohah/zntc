#!/usr/bin/env bun
/**
 * In-process **cold build** 벤치 — 캐시 없는 초기 full build(parse+transform+bundle) 비교.
 * incremental rebuild(inprocess-rebuild.ts)와 짝 — 같은 fixture(tiny/medium/lodash), in-process
 * programmatic API, write 없이 in-memory.
 *   - ZNTC:    `@zntc/core` build({ write:false }) — 매 호출 full build(persistent cache 미사용).
 *   - esbuild: `esbuild.build({ write:false })` — 매 호출 one-shot full build.
 *   - rolldown:`rolldown()` + `generate()` + `close()` — 매 iter fresh bundle = cold.
 *
 * 각 도구는 측정 전 warmup(런타임 시작 비용 제외: esbuild 서비스/rolldown 네이티브/zntc napi
 * 로드). 이후 N회 fresh full build 의 median. (cold = 매번 캐시 없이 처음부터 — zntc build()는
 * 호출 간 캐시 미공유 확인: 같은소스 0.089ms ≈ 고유소스 0.090ms.)
 *
 * ⚠️ 해석: 작은 fixture 의 esbuild 수치(~4ms)는 컴파일이 아니라 Node↔Go **서비스 IPC 왕복**
 * 오버헤드가 지배(esbuild 의 Node API 구조적 비용). zntc/rolldown 은 napi(IPC 없음). lodash
 * 같은 실작업에선 IPC 비중이 줄어 컴파일 차이가 드러난다(zntc 11 vs esbuild 23 vs rolldown 13ms).
 *
 * 실행: bun run cold-build.ts
 */

import { build as zntcBuild } from '../../packages/core/index.ts';
import { build as esbuildBuild } from 'esbuild';
import { rolldown } from 'rolldown';
import { mkdtempSync, rmSync, writeFileSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const ITERATIONS = 10;
const WARMUP = 2;

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
      try {
        symlinkSync(join(__dirname, 'node_modules'), join(dir, 'node_modules'), 'dir');
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

function summarize(arr: number[]) {
  const s = [...arr].sort((a, b) => a - b);
  const n = s.length;
  const median = n % 2 === 1 ? s[(n - 1) >> 1] : (s[n / 2 - 1] + s[n / 2]) / 2;
  const mean = s.reduce((a, b) => a + b, 0) / n;
  return { min: s[0], max: s[n - 1], median, mean };
}

type BuildOnce = (entry: string, dir: string) => Promise<void>;

const zntcBuildOnce: BuildOnce = async (entry) => {
  await zntcBuild({ entryPoints: [entry], bundle: true, write: false, platform: 'node' });
};
const esbuildBuildOnce: BuildOnce = async (entry) => {
  await esbuildBuild({
    entryPoints: [entry],
    bundle: true,
    write: false,
    loader: { '.ts': 'ts' },
    format: 'iife',
    logLevel: 'silent',
  });
};
const rolldownBuildOnce: BuildOnce = async (entry, dir) => {
  const bundle = await rolldown({ input: entry, cwd: dir });
  await bundle.generate({ format: 'esm' });
  await bundle.close?.();
};

async function measure(buildOnce: BuildOnce, fx: Fixture) {
  const dir = mkdtempSync(join(tmpdir(), `cold-${fx.name}-`));
  const { entry } = fx.build(dir);
  try {
    for (let i = 0; i < WARMUP; i++) await buildOnce(entry, dir);
    const iters: number[] = [];
    for (let i = 0; i < ITERATIONS; i++) {
      const t0 = performance.now();
      await buildOnce(entry, dir);
      iters.push(performance.now() - t0);
    }
    return summarize(iters);
  } finally {
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
  console.log('# In-process cold build (캐시 없는 초기 full build, in-memory)\n');
  console.log(`Warmup ${WARMUP}, iter ${ITERATIONS}.\n`);
  for (const fx of fixtures) {
    console.log(`\n## ${fx.name}\n`);
    console.log(`| Tool     | median | min   | max   | mean  |`);
    console.log(`|----------|-------:|------:|------:|------:|`);
    for (const [name, fn] of [
      ['zntc', zntcBuildOnce],
      ['esbuild', esbuildBuildOnce],
      ['rolldown', rolldownBuildOnce],
    ] as const) {
      try {
        const s = await measure(fn, fx);
        console.log(
          `| ${name.padEnd(8)} | ${pad(fmt(s.median), 5)}ms | ${pad(fmt(s.min), 4)}ms | ${pad(fmt(s.max), 4)}ms | ${pad(fmt(s.mean), 4)}ms |`,
        );
      } catch (e) {
        console.log(`| ${name.padEnd(8)} | FAIL ${String(e).slice(0, 40)} |`);
      }
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
