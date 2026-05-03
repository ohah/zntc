#!/usr/bin/env bun
/**
 * Synthetic monorepo bundle benchmark (#1749).
 *
 * 수천 모듈 + 여러 workspace package.json 조합에서 graph discovery/link phase가
 * 선형으로 증가하는지 확인하기 위한 측정 스크립트다.
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { makeSyntheticMonorepo, parseProfileOutput, type ProfileRun } from "./monorepo-fixture";
import { computeMetricStats, formatMetric, type MetricStats } from "./stats";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const WARMUP = 2;
const ITERATIONS = 5;

interface CliArgs {
  packages: number;
  modulesPerPackage: number;
  warmup: number;
  iterations: number;
  compare: boolean;
  output: string | null;
  keepFixture: string | null;
}

interface RunReport {
  version: number;
  generated_at: string;
  zts_commit: string;
  fixture: {
    packages: number;
    modules_per_package: number;
    module_count: number;
  };
  wall_ms_stats: JsonStats;
  profile_total_ms_stats: JsonStats;
  phase_median_ms: Record<string, number>;
  top_phases: Array<{ phase: string; median_ms: number; percent_of_total: number }>;
  tool_comparison?: ToolResult[];
}

interface JsonStats {
  median: number;
  mean: number;
  min: number;
  max: number;
  p95: number;
  trimmed_mean: number;
}

interface ToolResult {
  tool: string;
  wall_ms_stats: JsonStats | null;
  ratio_vs_zts: number | null;
}

interface ZtsRun extends ProfileRun {
  wallMs: number;
}

interface WallRun {
  wallMs: number;
}

function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = {
    packages: 50,
    modulesPerPackage: 100,
    warmup: WARMUP,
    iterations: ITERATIONS,
    compare: false,
    output: null,
    keepFixture: null,
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--packages") args.packages = parsePositiveInt(a, argv[++i]);
    else if (a.startsWith("--packages="))
      args.packages = parsePositiveInt("--packages", a.slice(11));
    else if (a === "--modules-per-package") args.modulesPerPackage = parsePositiveInt(a, argv[++i]);
    else if (a.startsWith("--modules-per-package=")) {
      args.modulesPerPackage = parsePositiveInt("--modules-per-package", a.slice(22));
    } else if (a === "--warmup") args.warmup = parseNonNegativeInt(a, argv[++i]);
    else if (a.startsWith("--warmup=")) args.warmup = parseNonNegativeInt("--warmup", a.slice(9));
    else if (a === "--iterations") args.iterations = parsePositiveInt(a, argv[++i]);
    else if (a.startsWith("--iterations="))
      args.iterations = parsePositiveInt("--iterations", a.slice(13));
    else if (a === "--output") args.output = argv[++i] ?? null;
    else if (a.startsWith("--output=")) args.output = a.slice(9);
    else if (a === "--compare") args.compare = true;
    else if (a === "--keep-fixture") args.keepFixture = argv[++i] ?? null;
    else if (a.startsWith("--keep-fixture=")) args.keepFixture = a.slice(15);
    else throw new Error(`unknown arg: ${a}`);
  }

  return args;
}

function findBin(name: string): string | null {
  const local = join(__dirname, "node_modules", ".bin", name);
  if (existsSync(local)) return local;
  const root = join(ROOT, "node_modules", ".bin", name);
  if (existsSync(root)) return root;
  return null;
}

function parsePositiveInt(name: string, raw: string | undefined): number {
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) throw new Error(`${name} must be a positive integer`);
  return n;
}

function parseNonNegativeInt(name: string, raw: string | undefined): number {
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0) throw new Error(`${name} must be a non-negative integer`);
  return n;
}

function buildBin() {
  if (existsSync(ZTS_BIN)) return;
  console.log("[monorepo-perf] zts binary not found, building Release...");
  const r = spawnSync("zig", ["build", "-Doptimize=ReleaseFast"], { cwd: ROOT, stdio: "inherit" });
  if (r.status !== 0) throw new Error("zig build failed");
}

function getCommit(): string {
  const r = spawnSync("git", ["rev-parse", "--short", "HEAD"], { cwd: ROOT, stdio: "pipe" });
  return r.stdout.toString().trim() || "unknown";
}

function runZts(entry: string, outDir: string, profile: boolean): ZtsRun {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const args = ["--bundle", "--format=esm", "--splitting", entry, "--outdir", outDir];
  if (profile) args.push("--profile=all");
  const start = performance.now();
  const r = spawnSync(ZTS_BIN, args, { stdio: "pipe", timeout: 120000 });
  const wallMs = performance.now() - start;
  if (r.status !== 0) {
    throw new Error(`zts failed: ${r.stderr.toString().slice(0, 800)}`);
  }
  const parsed = profile
    ? parseProfileOutput(`${r.stdout.toString()}\n${r.stderr.toString()}`)
    : { totalMs: 0, phases: {} };
  return { ...parsed, wallMs };
}

function runTool(tool: "zts" | "esbuild" | "rolldown", entry: string, outDir: string): WallRun {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });

  const bin = tool === "zts" ? ZTS_BIN : findBin(tool);
  if (!bin) throw new Error(`${tool} binary not found`);

  const start = performance.now();
  const r =
    tool === "zts"
      ? spawnSync(bin, ["--bundle", "--format=esm", "--splitting", entry, "--outdir", outDir], {
          stdio: "pipe",
          timeout: 120000,
        })
      : tool === "esbuild"
        ? spawnSync(bin, [entry, "--bundle", "--format=esm", "--splitting", `--outdir=${outDir}`], {
            stdio: "pipe",
            timeout: 120000,
          })
        : spawnSync(bin, [entry, "--dir", outDir], { stdio: "pipe", timeout: 120000 });
  if (r.status !== 0) {
    throw new Error(`${tool} failed: ${r.stderr.toString().slice(0, 500)}`);
  }
  return { wallMs: performance.now() - start };
}

function toJsonStats(stats: MetricStats): JsonStats {
  return {
    median: stats.median,
    mean: stats.mean,
    min: stats.min,
    max: stats.max,
    p95: stats.p95,
    trimmed_mean: stats.trimmedMean,
  };
}

function topPhases(
  phaseMedianMs: Record<string, number>,
  totalMedianMs: number,
): Array<{ phase: string; median_ms: number; percent_of_total: number }> {
  return Object.entries(phaseMedianMs)
    .map(([phase, median_ms]) => ({
      phase,
      median_ms,
      percent_of_total: totalMedianMs === 0 ? 0 : (median_ms / totalMedianMs) * 100,
    }))
    .sort((a, b) => b.median_ms - a.median_ms)
    .slice(0, 12);
}

function printMarkdown(report: RunReport) {
  console.log("\n### monorepo-perf — synthetic workspace");
  console.log(
    "| Packages | Modules/pkg | Total modules | Wall median | Wall trimmed mean | Wall p95 | Profile total median |",
  );
  console.log(
    "|----------|-------------|---------------|-------------|-------------------|----------|----------------------|",
  );
  console.log(
    `| ${report.fixture.packages} | ${report.fixture.modules_per_package} | ${report.fixture.module_count} | ${formatMetric(report.wall_ms_stats.median)} | ${formatMetric(report.wall_ms_stats.trimmed_mean)} | ${formatMetric(report.wall_ms_stats.p95)} | ${formatMetric(report.profile_total_ms_stats.median)} |`,
  );

  console.log("\n| Top phase | Median | % of total |");
  console.log("|-----------|--------|------------|");
  for (const p of report.top_phases) {
    console.log(
      `| ${p.phase} | ${formatMetric(p.median_ms)} | ${p.percent_of_total.toFixed(1)}% |`,
    );
  }

  if (report.tool_comparison) {
    console.log("\n| Tool | Median | Trimmed mean | p95 | vs ZTS |");
    console.log("|------|--------|--------------|-----|--------|");
    for (const tool of report.tool_comparison) {
      if (!tool.wall_ms_stats) {
        console.log(`| ${tool.tool} | FAIL | - | - | - |`);
        continue;
      }
      console.log(
        `| ${tool.tool} | ${formatMetric(tool.wall_ms_stats.median)} | ${formatMetric(tool.wall_ms_stats.trimmed_mean)} | ${formatMetric(tool.wall_ms_stats.p95)} | ${tool.ratio_vs_zts?.toFixed(2)}x |`,
      );
    }
  }
}

function measureComparisonTool(
  tool: "zts" | "esbuild" | "rolldown",
  entry: string,
  outDir: string,
  warmup: number,
  iterations: number,
  ztsMedianMs: number,
): ToolResult {
  try {
    for (let i = 0; i < warmup; i++) runTool(tool, entry, outDir);
    const times: number[] = [];
    for (let i = 0; i < iterations; i++) {
      times.push(runTool(tool, entry, outDir).wallMs);
    }
    const stats = computeMetricStats(times);
    return {
      tool,
      wall_ms_stats: toJsonStats(stats),
      ratio_vs_zts: ztsMedianMs === 0 ? null : stats.median / ztsMedianMs,
    };
  } catch (err) {
    console.error(
      `[monorepo-perf] ${tool} skipped: ${err instanceof Error ? err.message : String(err)}`,
    );
    return { tool, wall_ms_stats: null, ratio_vs_zts: null };
  }
}

async function main(cli: CliArgs) {
  buildBin();
  const tmp = cli.keepFixture ?? mkdtempSync(join(tmpdir(), "zts-monorepo-perf-"));
  if (cli.keepFixture) mkdirSync(tmp, { recursive: true });

  try {
    const fixture = makeSyntheticMonorepo(tmp, {
      packageCount: cli.packages,
      modulesPerPackage: cli.modulesPerPackage,
    });
    const outDir = join(tmp, "dist");

    console.log(
      `[monorepo-perf] zts ${getCommit()} | packages=${cli.packages} modules/pkg=${cli.modulesPerPackage} total_modules=${fixture.moduleCount} warmup=${cli.warmup} iter=${cli.iterations}`,
    );

    for (let i = 0; i < cli.warmup; i++) runZts(fixture.entry, outDir, false);

    const wallTotals: number[] = [];
    const profileTotals: number[] = [];
    const phaseSeries: Record<string, number[]> = {};
    for (let i = 0; i < cli.iterations; i++) {
      const r = runZts(fixture.entry, outDir, false);
      wallTotals.push(r.wallMs);
      console.log(`  run ${i + 1}/${cli.iterations}: wall=${formatMetric(r.wallMs)}`);
    }

    const wallStats = computeMetricStats(wallTotals);

    const profileRun = runZts(fixture.entry, join(tmp, "dist-profile"), true);
    profileTotals.push(profileRun.totalMs);
    for (const [phase, ms] of Object.entries(profileRun.phases)) {
      (phaseSeries[phase] ??= []).push(ms);
    }
    const profileTotalStats = computeMetricStats(profileTotals);
    const phaseMedianMs: Record<string, number> = {};
    for (const [phase, series] of Object.entries(phaseSeries)) {
      phaseMedianMs[phase] = computeMetricStats(series).median;
    }

    const report: RunReport = {
      version: 1,
      generated_at: new Date().toISOString(),
      zts_commit: getCommit(),
      fixture: {
        packages: cli.packages,
        modules_per_package: cli.modulesPerPackage,
        module_count: fixture.moduleCount,
      },
      wall_ms_stats: toJsonStats(wallStats),
      profile_total_ms_stats: toJsonStats(profileTotalStats),
      phase_median_ms: phaseMedianMs,
      top_phases: topPhases(phaseMedianMs, profileTotalStats.median),
    };

    if (cli.compare) {
      report.tool_comparison = [
        measureComparisonTool(
          "zts",
          fixture.entry,
          join(tmp, "dist-zts-compare"),
          cli.warmup,
          cli.iterations,
          wallStats.median,
        ),
        measureComparisonTool(
          "esbuild",
          fixture.entry,
          join(tmp, "dist-esbuild"),
          cli.warmup,
          cli.iterations,
          wallStats.median,
        ),
        measureComparisonTool(
          "rolldown",
          fixture.entry,
          join(tmp, "dist-rolldown"),
          cli.warmup,
          cli.iterations,
          wallStats.median,
        ),
      ];
    }

    printMarkdown(report);

    if (cli.output) {
      writeFileSync(cli.output, JSON.stringify(report, null, 2) + "\n");
      console.log(`\n[monorepo-perf] report written: ${cli.output}`);
    }
    if (cli.keepFixture) {
      console.log(`[monorepo-perf] fixture kept: ${tmp}`);
    }
  } finally {
    if (!cli.keepFixture) rmSync(tmp, { recursive: true, force: true });
  }
}

await main(parseArgs(process.argv.slice(2)));
