#!/usr/bin/env bun
/**
 * Bundle performance baseline runner.
 *
 * 결정론적 fixture 로 ZTS 번들 시간을 측정하고 baseline 과 비교.
 * 회귀 가드용 — manualChunks/external phantom 등 graph traversal 변경 후
 * "보이지 않는 perf 회귀" 가 누적되는 것 방지.
 *
 * 실행:
 *   bun run tests/benchmark/bundle-perf.ts          # baseline 과 비교
 *   bun run tests/benchmark/bundle-perf.ts --write  # baseline 갱신
 *
 * 측정 방법론:
 *   - 워밍업 5회 (mtime/dentry 캐시 워밍)
 *   - 측정 20회 — outlier (min/max) 1개씩 제거 → 18회 평균
 *   - threshold: median 의 ±15% (단일 PR 회귀 감지 + 머신간 변동 흡수)
 *
 * 머신 의존성:
 *   - 절대값은 머신마다 다름 — 같은 머신에서 PR 전후 비교 의미 있음
 *   - CI 통합 시엔 baseline 을 CI 머신에서 갱신 + 거기서만 회귀 체크
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const BASELINE_PATH = join(__dirname, "baselines", "bundle-perf.json");

const WARMUP = 5;
const ITERATIONS = 20;
const TOLERANCE = 0.15; // median ±15%

// ─── Fixture 생성 (결정론적) ───

function makeFixture(dir: string, moduleCount: number, externals: string[]): string {
  mkdirSync(dir, { recursive: true });
  const lines: string[] = [];
  for (let i = 0; i < moduleCount; i++) {
    lines.push(`import { v${i} } from "./mod${i}";`);
  }
  for (let i = 0; i < externals.length; i++) {
    lines.push(`import { x${i} } from "${externals[i]}";`);
  }
  const usages = [
    Array.from({ length: moduleCount }, (_, i) => `v${i}`).join(", "),
    Array.from({ length: externals.length }, (_, i) => `x${i}`).join(", "),
  ]
    .filter(Boolean)
    .join(", ");
  lines.push(`console.log(${usages});`);
  writeFileSync(join(dir, "entry.ts"), lines.join("\n"));
  for (let i = 0; i < moduleCount; i++) {
    writeFileSync(join(dir, `mod${i}.ts`), `export const v${i} = ${i};`);
  }
  return join(dir, "entry.ts");
}

// ─── 측정 ───

interface RunResult {
  total_ms: number;
  phases: Record<string, number>;
}

function runOne(entry: string, outDir: string, externals: string[]): RunResult {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const args = [
    "--bundle",
    "--format=esm",
    "--splitting",
    ...externals.map((e) => `--external=${e}`),
    entry,
    "--outdir",
    outDir,
    "--profile=all",
  ];
  const r = spawnSync(ZTS_BIN, args, { stdio: "pipe", timeout: 30000 });
  if (r.status !== 0) {
    throw new Error(`zts failed: ${r.stderr?.toString().slice(0, 400)}`);
  }
  // profile 출력은 stderr 로 — bundle 결과 정보(stdout) 와 섞이지 않음.
  const stdout = r.stdout.toString() + "\n" + r.stderr.toString();
  const phases: Record<string, number> = {};
  let total_ms = 0;
  for (const line of stdout.split("\n")) {
    const m = line.match(/^(\w+)\s+([\d.]+)ms\s+/);
    if (!m) continue;
    const [, phase, msStr] = m;
    const ms = parseFloat(msStr);
    if (phase === "total") total_ms = ms;
    else phases[phase] = ms;
  }
  if (total_ms === 0) {
    throw new Error(`no profile output. stdout head: ${stdout.slice(0, 400)}`);
  }
  return { total_ms, phases };
}

interface Stats {
  median: number;
  mean: number;
  min: number;
  max: number;
  p95: number;
  trimmed_mean: number; // min/max 제거한 평균
}

function computeStats(samples: number[]): Stats {
  const sorted = [...samples].sort((a, b) => a - b);
  const n = sorted.length;
  const median = n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
  const mean = samples.reduce((a, b) => a + b, 0) / n;
  const trimmed = sorted.slice(1, -1);
  const trimmed_mean = trimmed.reduce((a, b) => a + b, 0) / trimmed.length;
  const p95 = sorted[Math.min(Math.floor(n * 0.95), n - 1)];
  return { median, mean, min: sorted[0], max: sorted[n - 1], p95, trimmed_mean };
}

// ─── Fixture spec ───

interface FixtureSpec {
  name: string;
  module_count: number;
  externals: string[];
}

const FIXTURES: FixtureSpec[] = [
  { name: "small (10 modules, 0 ext)", module_count: 10, externals: [] },
  { name: "medium (100 modules, 3 ext)", module_count: 100, externals: ["react", "vue", "lodash"] },
  {
    name: "large (200 modules, 5 ext)",
    module_count: 200,
    externals: ["react", "vue", "lodash", "rxjs", "zod"],
  },
];

interface FixtureResult {
  name: string;
  module_count: number;
  externals: number;
  total_ms_stats: Stats;
  phase_median_ms: Record<string, number>;
}

interface BaselineFile {
  version: number;
  generated_at: string;
  zts_commit: string;
  fixtures: FixtureResult[];
}

// ─── 메인 ───

function buildBin() {
  if (existsSync(ZTS_BIN)) return;
  console.log("[bundle-perf] zts binary not found, building Release...");
  const r = spawnSync("zig", ["build", "-Doptimize=ReleaseFast"], {
    cwd: ROOT,
    stdio: "inherit",
  });
  if (r.status !== 0) throw new Error("zig build failed");
}

function getCommit(): string {
  const r = spawnSync("git", ["rev-parse", "--short", "HEAD"], { cwd: ROOT, stdio: "pipe" });
  return r.stdout.toString().trim() || "unknown";
}

async function measureFixture(spec: FixtureSpec): Promise<FixtureResult> {
  const tmp = mkdtempSync(join(tmpdir(), "zts-bundle-perf-"));
  const fixDir = join(tmp, "src");
  const outDir = join(tmp, "dist");
  const entry = makeFixture(fixDir, spec.module_count, spec.externals);

  // 워밍업
  for (let i = 0; i < WARMUP; i++) runOne(entry, outDir, spec.externals);

  // 측정
  const totals: number[] = [];
  const phaseSeries: Record<string, number[]> = {};
  for (let i = 0; i < ITERATIONS; i++) {
    const r = runOne(entry, outDir, spec.externals);
    totals.push(r.total_ms);
    for (const [k, v] of Object.entries(r.phases)) {
      (phaseSeries[k] ??= []).push(v);
    }
  }
  rmSync(tmp, { recursive: true, force: true });

  const phase_median_ms: Record<string, number> = {};
  for (const [k, arr] of Object.entries(phaseSeries)) {
    phase_median_ms[k] = computeStats(arr).median;
  }
  return {
    name: spec.name,
    module_count: spec.module_count,
    externals: spec.externals.length,
    total_ms_stats: computeStats(totals),
    phase_median_ms,
  };
}

function fmtMs(n: number): string {
  return n.toFixed(2) + "ms";
}

async function main(writeMode: boolean) {
  buildBin();
  console.log(`[bundle-perf] zts ${getCommit()} | warmup=${WARMUP} iter=${ITERATIONS}`);
  console.log();

  const results: FixtureResult[] = [];
  for (const spec of FIXTURES) {
    process.stdout.write(`  ${spec.name}... `);
    const r = await measureFixture(spec);
    console.log(
      `median=${fmtMs(r.total_ms_stats.median)} trimmed_mean=${fmtMs(r.total_ms_stats.trimmed_mean)} p95=${fmtMs(r.total_ms_stats.p95)}`,
    );
    results.push(r);
  }

  if (writeMode) {
    const baseline: BaselineFile = {
      version: 1,
      generated_at: new Date().toISOString(),
      zts_commit: getCommit(),
      fixtures: results,
    };
    writeFileSync(BASELINE_PATH, JSON.stringify(baseline, null, 2) + "\n");
    console.log(`\n[bundle-perf] baseline written: ${BASELINE_PATH}`);
    return;
  }

  if (!existsSync(BASELINE_PATH)) {
    console.log(`\n[bundle-perf] no baseline at ${BASELINE_PATH}`);
    console.log("Run with --write to create baseline.");
    process.exit(1);
  }

  const baseline = JSON.parse(readFileSync(BASELINE_PATH, "utf8")) as BaselineFile;
  console.log();
  console.log(`Compared against baseline (${baseline.zts_commit} @ ${baseline.generated_at}):`);
  let regressed = 0;
  for (const r of results) {
    const base = baseline.fixtures.find((f) => f.name === r.name);
    if (!base) {
      console.log(`  ${r.name}: NEW (no baseline)`);
      continue;
    }
    const baseMs = base.total_ms_stats.median;
    const curMs = r.total_ms_stats.median;
    const delta = curMs - baseMs;
    const pct = (delta / baseMs) * 100;
    const sign = pct > 0 ? "+" : "";
    const within = Math.abs(pct) <= TOLERANCE * 100;
    const tag = within ? "OK" : pct > 0 ? "REGRESS" : "IMPROVE";
    console.log(
      `  ${r.name}: ${fmtMs(curMs)} vs ${fmtMs(baseMs)} (${sign}${pct.toFixed(1)}%) [${tag}]`,
    );
    if (!within && pct > 0) regressed++;
  }

  if (regressed > 0) {
    console.log(`\n[bundle-perf] ${regressed} regression(s) — fail`);
    process.exit(1);
  }
  console.log("\n[bundle-perf] no regression");
}

await main(process.argv.slice(2).includes("--write"));
