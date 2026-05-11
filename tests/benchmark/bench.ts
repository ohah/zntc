#!/usr/bin/env bun
/**
 * ZNTC Benchmark Suite — 공정한 다규모 성능 비교
 *
 * 모든 도구를 CLI 바이너리 직접 호출 (npx 오버헤드 제거).
 * 소규모/중규모/대규모 시나리오로 스케일 특성 측정.
 */

import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, mkdirSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { computeMetricStats, formatMetric, type MetricStats } from './stats';

const ROOT = resolve(__dirname, '../..');
const ZNTC_BIN = join(ROOT, 'zig-out/bin/zntc');
const BIN = join(ROOT, 'node_modules/.bin');
const ITERATIONS = 5;

// ============================================================
// CLI 바이너리 경로
// ============================================================

function findBin(name: string): string | null {
  const local = join(__dirname, 'node_modules/.bin', name);
  if (existsSync(local)) return local;
  const root = join(BIN, name);
  if (existsSync(root)) return root;
  return null;
}

// ============================================================
// Fixture generation
// ============================================================

function generateTS(lines: number): string {
  const parts: string[] = ['import { helper } from "./helper";', ''];
  for (let i = 0; i < lines; i++) {
    parts.push(`export const value${i}: number = ${i} + helper(${i});`);
    if (i % 50 === 0) {
      parts.push(`export function compute${i}(x: number): number { return x * ${i}; }`);
    }
  }
  parts.push(`export default function main() { return value0; }`);
  return parts.join('\n');
}

function generateHelper(): string {
  return `export function helper(n: number): number { return n * 2; }\n`;
}

function generateProject(dir: string, fileCount: number) {
  mkdirSync(join(dir, 'src'), { recursive: true });

  // Fan-out tree: mod_i imports mod_{i*5+1} … mod_{i*5+5} (if in range).
  // entry → mod0 → 자연스럽게 fileCount 모듈 fan-out. 일반 코드 패턴 (parent
  // imports children) 에 가깝고, 한 파일의 import / statement 개수가 fan-out
  // (5) 으로 제한돼 webpack/rspack 의 거대 entry 한계를 피함.
  const fanOut = 5;
  for (let i = 0; i < fileCount; i++) {
    const childStart = i * fanOut + 1;
    const childEnd = Math.min(childStart + fanOut, fileCount);
    const childIndices: number[] = [];
    for (let c = childStart; c < childEnd; c++) childIndices.push(c);
    const importLines = childIndices
      .map((c) => `import { val${c}, fn${c} } from './mod${c}';`)
      .join('\n');
    const sumExpr = childIndices.length
      ? ' + ' + childIndices.map((c) => `fn${c}(val${c})`).join(' + ')
      : '';
    const body =
      (importLines ? `${importLines}\n` : '') +
      `export const val${i} = ${i};\n` +
      `export function fn${i}(x: number): number { return x + ${i}${sumExpr}; }\n`;
    writeFileSync(join(dir, 'src', `mod${i}.ts`), body);
  }

  writeFileSync(
    join(dir, 'src', 'index.ts'),
    `import { val0, fn0 } from './mod0';\nconsole.log(fn0(val0));\n`,
  );

  writeFileSync(
    join(dir, 'tsconfig.json'),
    JSON.stringify({
      compilerOptions: {
        target: 'es2020',
        module: 'esnext',
        moduleResolution: 'bundler',
        strict: true,
      },
      include: ['src'],
    }),
  );
}

// ============================================================
// Runner
// ============================================================

interface BenchResult {
  tool: string;
  task: string;
  scale: string;
  stats: MetricStats | null;
}

function runBench(name: string, task: string, scale: string, fn: () => void): BenchResult {
  const times: number[] = [];

  try {
    fn();
  } catch {
    return { tool: name, task, scale, stats: null };
  }

  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    try {
      fn();
    } catch {
      return { tool: name, task, scale, stats: null };
    }
    times.push(performance.now() - start);
  }

  return {
    tool: name,
    task,
    scale,
    stats: computeMetricStats(times),
  };
}

function execBin(bin: string, args: string[], cwd?: string) {
  spawnSync(bin, args, { cwd, stdio: 'pipe', timeout: 600000 });
}

// ============================================================
// Transpile benchmarks (소/중/대)
// ============================================================

function benchTranspile(): BenchResult[] {
  const results: BenchResult[] = [];
  const scales = [
    { name: 'small (100 lines)', lines: 100 },
    { name: 'medium (1K lines)', lines: 1000 },
    { name: 'large (5K lines)', lines: 5000 },
  ];

  const esbuildBin = findBin('esbuild');
  const swcBin = findBin('swc');

  for (const scale of scales) {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bench-'));
    const inputFile = join(dir, 'input.ts');
    writeFileSync(inputFile, generateTS(scale.lines));
    writeFileSync(join(dir, 'helper.ts'), generateHelper());

    console.log(`\n--- Transpile: ${scale.name} ---`);

    results.push(
      runBench('ZNTC', 'transpile', scale.name, () => {
        execBin(ZNTC_BIN, [inputFile, '-o', join(dir, 'out-zntc.js')]);
      }),
    );

    if (esbuildBin) {
      results.push(
        runBench('esbuild', 'transpile', scale.name, () => {
          execBin(esbuildBin, [
            inputFile,
            `--outfile=${join(dir, 'out-esbuild.js')}`,
            '--loader=ts',
          ]);
        }),
      );
    }

    if (swcBin) {
      results.push(
        runBench('SWC', 'transpile', scale.name, () => {
          execBin(swcBin, [inputFile, '-o', join(dir, 'out-swc.js')]);
        }),
      );
    }

    results.push(
      runBench('oxc (node)', 'transpile', scale.name, () => {
        execBin('node', [
          '-e',
          `const {transformSync}=require('oxc-transform');const fs=require('fs');` +
            `const code=fs.readFileSync(${JSON.stringify(inputFile)},'utf8');` +
            `transformSync('input.ts',code,{sourceType:'module'})`,
        ]);
      }),
    );

    // Bun (transpile via bun build --no-bundle)
    results.push(
      runBench('Bun', 'transpile', scale.name, () => {
        execBin('bun', ['build', inputFile, '--no-bundle', '--outfile', join(dir, 'out-bun.js')]);
      }),
    );

    rmSync(dir, { recursive: true, force: true });
  }

  return results;
}

// ============================================================
// Bundle benchmarks (소/중/대)
// ============================================================

function benchBundle(): BenchResult[] {
  const results: BenchResult[] = [];
  const scales = [
    { name: 'small (10 modules)', files: 10 },
    { name: 'medium (1000 modules)', files: 1000 },
    { name: 'large (5000 modules)', files: 5000 },
  ];

  const esbuildBin = findBin('esbuild');
  const rolldownBin = findBin('rolldown');
  const webpackBin = findBin('webpack');
  const rspackBin = findBin('rspack');

  const benchModules = join(__dirname, 'node_modules');

  for (const scale of scales) {
    const dir = mkdtempSync(join(tmpdir(), 'zntc-bench-bundle-'));
    generateProject(dir, scale.files);
    const entry = join(dir, 'src', 'index.ts');
    const outDir = join(dir, 'dist');
    mkdirSync(outDir, { recursive: true });

    // webpack / rspack 의 ts-loader · swc-loader resolution 을 위해
    // fixture 디렉토리에 tests/benchmark/node_modules 를 symlink.
    try {
      symlinkSync(benchModules, join(dir, 'node_modules'), 'dir');
    } catch {
      // 이미 있으면 무시.
    }

    console.log(`\n--- Bundle: ${scale.name} ---`);

    results.push(
      runBench('ZNTC', 'bundle', scale.name, () => {
        execBin(ZNTC_BIN, ['--bundle', entry, '-o', join(outDir, 'zntc.js')]);
      }),
    );

    if (esbuildBin) {
      results.push(
        runBench('esbuild', 'bundle', scale.name, () => {
          execBin(esbuildBin, [
            entry,
            '--bundle',
            `--outfile=${join(outDir, 'esbuild.js')}`,
            '--loader:.ts=ts',
          ]);
        }),
      );
    }

    // Bun bundle
    results.push(
      runBench('Bun', 'bundle', scale.name, () => {
        execBin('bun', ['build', entry, '--outfile', join(outDir, 'bun.js')]);
      }),
    );

    if (rolldownBin) {
      results.push(
        runBench('rolldown', 'bundle', scale.name, () => {
          execBin(rolldownBin, [entry, '--dir', join(outDir, 'rolldown')]);
        }),
      );
    }

    // webpack / rspack — 큰 스케일에서는 시간이 길어지지만 사용자 요청으로
    // 전 스케일에서 측정. timeout 안에 못 끝나면 FAIL 로 노출.
    if (webpackBin) {
      const config = join(dir, 'webpack.config.js');
      writeFileSync(
        config,
        `module.exports = {
  mode: 'production', entry: '${entry}',
  output: { path: '${outDir}', filename: 'webpack.js' },
  resolve: { extensions: ['.ts', '.js'] },
  resolveLoader: { modules: ['${benchModules}'] },
  module: { rules: [{ test: /\\.ts$/, use: 'ts-loader', exclude: /node_modules/ }] },
};`,
      );
      results.push(
        runBench('webpack', 'bundle', scale.name, () => {
          execBin(webpackBin, ['--config', config], dir);
        }),
      );
    }

    if (rspackBin) {
      const config = join(dir, 'rspack.config.js');
      writeFileSync(
        config,
        `module.exports = {
  mode: 'production', entry: '${entry}',
  output: { path: '${outDir}', filename: 'rspack.js' },
  resolve: { extensions: ['.ts', '.js'] },
  module: { rules: [{ test: /\\.ts$/, type: 'javascript/auto', use: { loader: 'builtin:swc-loader', options: { jsc: { parser: { syntax: 'typescript' } } } } }] },
};`,
      );
      results.push(
        runBench('rspack', 'bundle', scale.name, () => {
          execBin(rspackBin, ['build', '--config', config], dir);
        }),
      );
    }

    rmSync(dir, { recursive: true, force: true });
  }

  return results;
}

// ============================================================
// Output
// ============================================================

function printResults(results: BenchResult[]) {
  const tasks = [...new Set(results.map((r) => r.task))];
  for (const task of tasks) {
    const scales = [...new Set(results.filter((r) => r.task === task).map((r) => r.scale))];
    for (const scale of scales) {
      const group = results
        .filter((r) => r.task === task && r.scale === scale)
        .sort((a, b) => {
          if (a.stats === null) return 1;
          if (b.stats === null) return -1;
          return a.stats.median - b.stats.median;
        });

      console.log(`\n### ${task} — ${scale}`);
      console.log('| Tool | Median | Trimmed mean | Min | Max | p95 | vs fastest |');
      console.log('|------|--------|--------------|-----|-----|-----|------------|');
      const fastest = group.find((r) => r.stats !== null)?.stats?.median ?? 1;
      for (const r of group) {
        if (r.stats === null) {
          console.log(`| ${r.tool} | FAIL | - | - | - | - | - |`);
          continue;
        }
        const ratio = `${(r.stats.median / fastest).toFixed(1)}x`;
        console.log(
          `| ${r.tool} | ${formatMetric(r.stats.median)} | ${formatMetric(r.stats.trimmedMean)} | ${formatMetric(r.stats.min)} | ${formatMetric(r.stats.max)} | ${formatMetric(r.stats.p95)} | ${ratio} |`,
        );
      }
    }
  }
}

// ============================================================
// Main
// ============================================================

const args = process.argv.slice(2);
const doTranspile = args.includes('--transpile') || args.includes('--all') || args.length === 0;
const doBundle = args.includes('--bundle') || args.includes('--all') || args.length === 0;

console.log('ZNTC Benchmark Suite');
console.log(`  Iterations: ${ITERATIONS} (median, trimmed mean)`);
console.log('  Method: CLI binary direct execution (no npx overhead)');
console.log(`  Platform: ${process.platform} ${process.arch}`);

const allResults: BenchResult[] = [];

if (doTranspile) allResults.push(...benchTranspile());
if (doBundle) allResults.push(...benchBundle());

console.log('\n===== Results =====');
printResults(allResults);
