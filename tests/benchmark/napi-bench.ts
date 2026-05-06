#!/usr/bin/env bun
/**
 * ZTS NAPI vs WASM vs CLI 벤치마크
 *
 * 세 가지 호출 방식의 트랜스파일 성능을 비교한다:
 *   - NAPI: .node addon in-process (C NAPI)
 *   - WASM: WebAssembly in-process
 *   - CLI: subprocess spawn (Zig 바이너리)
 *
 * WASM과 NAPI를 같은 프로세스에서 로드하면 심볼 충돌로 크래시하므로
 * 각 방식을 별도 프로세스로 실행한 뒤 결과를 취합한다.
 */

import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { computeMetricStats, formatMetric, type MetricStats } from './stats';

const ROOT = resolve(import.meta.dir, '../..');
const WARMUP = 3;
const ITERATIONS = 10;
const IS_WINDOWS = process.platform === 'win32';
const ZTS_BIN_NAME = IS_WINDOWS ? 'zts.exe' : 'zts';
const WASM_WRAPPER_URL = pathToFileURL(resolve(ROOT, 'packages/wasm/index.ts')).href;

// Windows 경로의 백슬래시는 템플릿 문자열에 그대로 삽입하면 이스케이프 시퀀스로
// 해석돼 잘못된 경로가 됨. JSON.stringify로 감싸 literal string으로 안전하게 주입.
function q(s: string): string {
  return JSON.stringify(s);
}

// ─── Fixture 생성 ───

function generateTS(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(`export const value${i}: number = ${i} * 2;`);
    if (i % 50 === 0) {
      parts.push(`export function compute${i}(x: number): number { return x * ${i}; }`);
    }
  }
  parts.push(`export default function main() { return value0; }`);
  return parts.join('\n');
}

// ─── 워커 스크립트 생성 ───

function createWorkerScript(method: 'napi' | 'wasm' | 'cli', sourceFile: string): string {
  const dir = mkdtempSync(resolve(tmpdir(), 'zts-bench-worker-'));

  if (method === 'napi') {
    const script = `
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const NAPI_PATH = ${q(resolve(ROOT, 'zig-out/lib/zts.node'))};
const native = require(NAPI_PATH);

const source = readFileSync(${q(sourceFile)}, "utf8");
const WARMUP = ${WARMUP};
const ITERATIONS = ${ITERATIONS};

function run() {
  native.transpile(source, "input.ts", "{}");
}

for (let i = 0; i < WARMUP; i++) run();
const times = [];
for (let i = 0; i < ITERATIONS; i++) {
  const start = Bun.nanoseconds();
  run();
  times.push((Bun.nanoseconds() - start) / 1000);
}
times.sort((a, b) => a - b);
console.log(JSON.stringify({ samplesUs: times }));
`;
    const path = resolve(dir, 'worker.ts');
    writeFileSync(path, script);
    return path;
  }

  if (method === 'wasm') {
    const script = `
import { readFileSync } from "node:fs";

const WASM_PATH = ${q(resolve(ROOT, 'zig-out/bin/zts.wasm'))};
const WASM_WRAPPER_URL = ${q(WASM_WRAPPER_URL)};
const { initSync, transpile } = await import(WASM_WRAPPER_URL);

const wasmBytes = readFileSync(WASM_PATH);
initSync(wasmBytes);

const source = readFileSync(${q(sourceFile)}, "utf8");
const WARMUP = ${WARMUP};
const ITERATIONS = ${ITERATIONS};

function run() {
  transpile(source, { filename: "input.ts" });
}

for (let i = 0; i < WARMUP; i++) run();
const times = [];
for (let i = 0; i < ITERATIONS; i++) {
  const start = Bun.nanoseconds();
  run();
  times.push((Bun.nanoseconds() - start) / 1000);
}
times.sort((a, b) => a - b);
console.log(JSON.stringify({ samplesUs: times }));
`;
    const path = resolve(dir, 'worker.ts');
    writeFileSync(path, script);
    return path;
  }

  // CLI
  const script = `
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ZTS_BIN = ${q(resolve(ROOT, 'zig-out/bin', ZTS_BIN_NAME))};
const source = readFileSync(${q(sourceFile)}, "utf8");
const WARMUP = ${WARMUP};
const ITERATIONS = ${ITERATIONS};

function run() {
  spawnSync(ZTS_BIN, ["-"], { input: source, stdio: ["pipe", "pipe", "pipe"] });
}

for (let i = 0; i < WARMUP; i++) run();
const times = [];
for (let i = 0; i < ITERATIONS; i++) {
  const start = Bun.nanoseconds();
  run();
  times.push((Bun.nanoseconds() - start) / 1000);
}
times.sort((a, b) => a - b);
console.log(JSON.stringify({ samplesUs: times }));
`;
  const path = resolve(dir, 'worker.ts');
  writeFileSync(path, script);
  return path;
}

// ─── 워커 실행 ───

interface BenchResult {
  method: string;
  scale: string;
  stats: MetricStats | null;
}

function runWorker(
  method: 'napi' | 'wasm' | 'cli',
  scale: string,
  sourceFile: string,
): BenchResult {
  const label =
    method === 'napi' ? 'NAPI (.node)' : method === 'wasm' ? 'WASM (.wasm)' : 'CLI (subprocess)';
  const workerPath = createWorkerScript(method, sourceFile);

  const result = spawnSync('bun', ['run', workerPath], {
    stdio: ['pipe', 'pipe', 'pipe'],
    timeout: 120000,
  });

  rmSync(resolve(workerPath, '..'), { recursive: true, force: true });

  if (result.status !== 0) {
    console.error(`  ${label}: FAILED`);
    if (result.stderr.length > 0)
      console.error(`  stderr: ${result.stderr.toString().slice(0, 200)}`);
    return { method: label, scale, stats: null };
  }

  const stdout = result.stdout.toString().trim();
  try {
    const data = JSON.parse(stdout);
    if (!Array.isArray(data.samplesUs)) {
      throw new Error('missing samplesUs');
    }
    return { method: label, scale, stats: computeMetricStats(data.samplesUs) };
  } catch {
    console.error(`  ${label}: parse error: ${stdout.slice(0, 200)}`);
    return { method: label, scale, stats: null };
  }
}

// ─── Main ───

console.log('ZTS NAPI vs WASM vs CLI Benchmark');
console.log(`  Warmup: ${WARMUP}, Iterations: ${ITERATIONS} (median, trimmed mean)`);
console.log(`  Platform: ${process.platform} ${process.arch}\n`);

const scales = [
  { name: 'small (100 lines)', lines: 100 },
  { name: 'medium (1K lines)', lines: 1000 },
  { name: 'large (5K lines)', lines: 5000 },
  { name: 'xlarge (10K lines)', lines: 10000 },
];

const results: BenchResult[] = [];

for (const scale of scales) {
  const source = generateTS(scale.lines);
  const sizeKB = (Buffer.byteLength(source) / 1024).toFixed(0);

  const tmpDir = mkdtempSync(resolve(tmpdir(), 'zts-bench-src-'));
  const sourceFile = resolve(tmpDir, 'input.ts');
  writeFileSync(sourceFile, source);

  console.log(`--- ${scale.name} (${sizeKB} KB) ---`);

  for (const method of ['napi', 'wasm', 'cli'] as const) {
    const label = method === 'napi' ? 'NAPI' : method === 'wasm' ? 'WASM' : 'CLI';
    process.stdout.write(`  ${label}... `);
    const r = runWorker(method, scale.name, sourceFile);
    if (r.stats !== null) {
      console.log(
        `${formatMetric(r.stats.median, 'us')} (min: ${formatMetric(r.stats.min, 'us')}, max: ${formatMetric(r.stats.max, 'us')})`,
      );
    }
    results.push(r);
  }

  rmSync(tmpDir, { recursive: true, force: true });
}

// ─── 결과 출력 ───

console.log('\n===== Results =====\n');

for (const scale of scales) {
  const group = results
    .filter((r) => r.scale === scale.name)
    .sort((a, b) => {
      if (a.stats === null) return 1;
      if (b.stats === null) return -1;
      return a.stats.median - b.stats.median;
    });

  const fastest = group.find((r) => r.stats !== null)?.stats?.median ?? 1;

  console.log(`### ${scale.name}`);
  console.log('| Method          | Median | Trimmed mean | Min | Max | p95 | vs fastest |');
  console.log('|-----------------|--------|--------------|-----|-----|-----|------------|');
  for (const r of group) {
    if (r.stats === null) {
      console.log(`| ${r.method.padEnd(15)} | FAIL | - | - | - | - | - |`);
      continue;
    }
    const ratio = `${(r.stats.median / fastest).toFixed(1)}x`;
    console.log(
      `| ${r.method.padEnd(15)} | ${formatMetric(r.stats.median, 'us')} | ${formatMetric(r.stats.trimmedMean, 'us')} | ${formatMetric(r.stats.min, 'us')} | ${formatMetric(r.stats.max, 'us')} | ${formatMetric(r.stats.p95, 'us')} | ${ratio.padStart(10)} |`,
    );
  }
  console.log();
}
