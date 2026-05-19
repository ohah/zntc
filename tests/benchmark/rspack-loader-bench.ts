#!/usr/bin/env bun
/**
 * @zntc/rspack-loader vs builtin:swc-loader 벤치마크.
 *
 * 같은 rspack 빌드 위에서 loader 만 교체해 cold + warm 빌드 wall time 을
 * 비교. 결정론적 합성 TS 픽스처 (200 / 600 모듈) 로 TS strip + NAPI 호출
 * 부하를 측정한다.
 *
 * 실행:
 *   bun run tests/benchmark/rspack-loader-bench.ts
 *   bun run tests/benchmark/rspack-loader-bench.ts --iterations=10
 *
 * 측정:
 *   - 첫 빌드 (cold) 1 회 별도 보고
 *   - warm 빌드 N 회 (default 5) median/min/max
 *   - rspack instance 는 매 측정마다 새로 생성 (in-memory persistent cache 무력화)
 *
 * date-fns 픽스처 미사용 — date-fns 4.x 가 `.js` (ESM) 만 배포하는데 ZNTC
 * 코어가 `.js` 의 ESM 구문에 ParseError 를 내는 별개 버그가 있어 비교 불가.
 * `.mjs` / `.ts` 는 정상.
 */

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '../..');
const ZNTC_LOADER = resolve(ROOT, 'packages/rspack-loader/src/index.ts');
const ZNTC_CORE_DIST = resolve(ROOT, 'packages/core/dist/index.js');

const WARMUP = 2;
const ITERATIONS = parseArg('iterations', 5);

function parseArg(name: string, def: number): number {
  const m = process.argv.find((a) => a.startsWith(`--${name}=`));
  if (!m) return def;
  const v = parseInt(m.slice(name.length + 3), 10);
  return Number.isFinite(v) ? v : def;
}

interface LoaderConfig {
  name: string;
  rule: unknown;
}

const ZNTC_RULE: LoaderConfig = {
  name: '@zntc/rspack-loader',
  rule: {
    test: /\.(?:tsx?|jsx?|cjs|mjs)$/,
    loader: ZNTC_LOADER,
    options: { transpileOptions: { target: 'es2022' } },
  },
};

const SWC_RULE: LoaderConfig = {
  name: 'builtin:swc-loader',
  rule: {
    test: /\.(?:tsx?|jsx?|cjs|mjs)$/,
    loader: 'builtin:swc-loader',
    options: {
      jsc: {
        parser: { syntax: 'typescript', tsx: true },
        target: 'es2022',
      },
    },
  },
};

// ─── Fixtures ───

function makeSyntheticTsFixture(dir: string, moduleCount: number): string {
  mkdirSync(dir, { recursive: true });
  const importLines: string[] = [];
  const usageNames: string[] = [];
  for (let i = 0; i < moduleCount; i++) {
    importLines.push(`import { v${i} } from "./mod${i}";`);
    usageNames.push(`v${i}`);
  }
  writeFileSync(
    join(dir, 'entry.ts'),
    `${importLines.join('\n')}\nexport const total: number = ${usageNames.join(' + ')};\nconsole.log(total);\n`,
  );
  for (let i = 0; i < moduleCount; i++) {
    const body = [
      `interface Mod${i} { value: number; label: string; }`,
      `const m${i}: Mod${i} = { value: ${i}, label: "mod${i}" };`,
      `function transform${i}<T extends number>(x: T): T { return (x * 2) as T; }`,
      `export const v${i}: number = transform${i}(m${i}.value) + (m${i}.label.length as number);`,
    ];
    writeFileSync(join(dir, `mod${i}.ts`), body.join('\n') + '\n');
  }
  return join(dir, 'entry.ts');
}

// ─── Run ───

interface BuildOptions {
  entry: string;
  outDir: string;
  rule: unknown;
  modulesPaths: string[];
}

async function runRspackOnce(opts: BuildOptions): Promise<{ ms: number; modules: number }> {
  const { rspack } = (await import('@rspack/core')) as {
    rspack: (config: unknown, cb: (err: Error | null, stats?: unknown) => void) => unknown;
  };
  rmSync(opts.outDir, { recursive: true, force: true });
  mkdirSync(opts.outDir, { recursive: true });

  const t0 = performance.now();
  const stats = (await new Promise((res, rej) => {
    rspack(
      {
        mode: 'development',
        devtool: false,
        target: 'node',
        entry: opts.entry,
        output: {
          path: opts.outDir,
          filename: 'bundle.js',
          library: { type: 'commonjs2' },
        },
        resolve: {
          extensions: ['.ts', '.tsx', '.js', '.jsx', '.cjs', '.mjs'],
          modules: opts.modulesPaths,
          alias: { '@zntc/core': ZNTC_CORE_DIST },
        },
        module: { rules: [opts.rule] },
        cache: false,
        stats: 'errors-warnings',
      },
      (err, s) => {
        if (err) return rej(err);
        if ((s as { hasErrors(): boolean })?.hasErrors())
          return rej(
            new Error(
              (s as { toString(o: unknown): string }).toString({ errors: true, all: false }),
            ),
          );
        res(s);
      },
    );
  })) as { toJson(opts: unknown): { modules?: { length: number } } };
  const ms = performance.now() - t0;
  const json = stats.toJson({ all: false, modules: true });
  const modules = json.modules?.length ?? 0;
  return { ms, modules };
}

interface Sample {
  loader: string;
  fixture: string;
  cold_ms: number;
  warm_ms: number[];
  modules: number;
}

async function bench(
  fixtureName: string,
  entry: string,
  outDir: string,
  modulesPaths: string[],
  loader: LoaderConfig,
): Promise<Sample> {
  const opts: BuildOptions = {
    entry,
    outDir,
    rule: loader.rule,
    modulesPaths,
  };

  const cold = await runRspackOnce(opts);
  for (let i = 0; i < WARMUP; i++) await runRspackOnce(opts);
  const warm: number[] = [];
  for (let i = 0; i < ITERATIONS; i++) {
    const r = await runRspackOnce(opts);
    warm.push(r.ms);
  }
  return {
    loader: loader.name,
    fixture: fixtureName,
    cold_ms: cold.ms,
    warm_ms: warm,
    modules: cold.modules,
  };
}

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)] ?? 0;
}

function fmt(ms: number): string {
  return `${ms.toFixed(0).padStart(5)}ms`;
}

function summary(s: Sample): string {
  const med = median(s.warm_ms);
  const min = Math.min(...s.warm_ms);
  const max = Math.max(...s.warm_ms);
  return `${s.loader.padEnd(22)} cold=${fmt(s.cold_ms)} warm med=${fmt(med)} min=${fmt(min)} max=${fmt(max)} mods=${s.modules}`;
}

async function runFixture(label: string, modules: number, workRoot: string): Promise<void> {
  const fix = join(workRoot, `fix-${modules}`);
  const entry = makeSyntheticTsFixture(fix, modules);

  console.log(`\n## ${label} — ${modules} synthetic TS modules`);
  const swc = await bench(label, entry, join(workRoot, `out-swc-${modules}`), [], SWC_RULE);
  console.log(summary(swc));
  const zntc = await bench(label, entry, join(workRoot, `out-zntc-${modules}`), [], ZNTC_RULE);
  console.log(summary(zntc));
  const ratio = median(zntc.warm_ms) / median(swc.warm_ms);
  const verdict =
    ratio < 1.0
      ? `zntc 가 ${((1 / ratio - 1) * 100).toFixed(0)}% 빠름`
      : `swc 가 ${((ratio - 1) * 100).toFixed(0)}% 빠름`;
  console.log(`zntc / swc warm median = ${ratio.toFixed(2)}x  (${verdict})`);
}

async function main() {
  console.log(`# rspack-loader bench (warmup=${WARMUP}, iter=${ITERATIONS})`);
  const work = mkdtempSync(join(tmpdir(), 'zntc-rspack-bench-'));
  await runFixture('small', 200, work);
  await runFixture('large', 600, work);
  rmSync(work, { recursive: true, force: true });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
