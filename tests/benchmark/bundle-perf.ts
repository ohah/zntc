#!/usr/bin/env bun
/**
 * Bundle performance CI comparison runner.
 *
 * 결정론적 fixture 를 같은 CI 머신에서 ZTS / Rolldown / Rspack 으로 번들링해
 * wall time 을 비교한다. 체크인된 절대 baseline 은 사용하지 않는다.
 *
 * 실행:
 *   bun run tests/benchmark/bundle-perf.ts
 *   bun run tests/benchmark/bundle-perf.ts --output <path>
 *   bun run tests/benchmark/bundle-perf.ts --no-fail
 *
 * 측정 방법론:
 *   - 워밍업 5회 (mtime/dentry 캐시 워밍)
 *   - 측정 20회
 *   - 비교값은 CLI wall time median
 *   - ZTS `--profile=all` total 은 내부 phase 진단용으로 별도 기록
 */

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import {
  ROOT,
  ZTS_BIN,
  buildBin as buildBinShared,
  findNodeModulesBin,
  getCommit,
  parseProfileJson,
} from "./_runner";
import { computeMetricStats, formatMetric, type JsonStats, toJsonStats } from "./stats";

const WARMUP = 5;
const ITERATIONS = 20;

type ToolName = "zts" | "rolldown" | "rspack";

const TOOL_ORDER: ToolName[] = ["zts", "rolldown", "rspack"];

function toolLabel(tool: ToolName): string {
  switch (tool) {
    case "zts":
      return "ZTS";
    case "rolldown":
      return "Rolldown";
    case "rspack":
      return "Rspack";
  }
}

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
  wall_ms: number;
  zts_profile_total_ms?: number;
  phases?: Record<string, number>;
}

function runZts(entry: string, outDir: string, externals: string[]): RunResult {
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
    "--profile-format=json",
  ];
  const start = performance.now();
  const r = spawnSync(ZTS_BIN, args, { stdio: "pipe", timeout: 30000 });
  const wall_ms = performance.now() - start;
  if (r.status !== 0) {
    throw new Error(`zts failed: ${r.stderr?.toString().slice(0, 400)}`);
  }

  const stdout = r.stdout.toString() + "\n" + r.stderr.toString();
  const profile = parseProfileJson(stdout);
  const phases: Record<string, number> = {};
  for (const [phase, data] of Object.entries(profile.phases)) {
    if (data) phases[phase] = data.total_ms;
  }
  return { wall_ms, zts_profile_total_ms: profile.total_ms, phases };
}

function runRolldown(bin: string, entry: string, outDir: string, externals: string[]): RunResult {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const args = [entry, "--format=esm", "--dir", outDir];
  if (externals.length > 0) args.push("--external", externals.join(","));

  const start = performance.now();
  const r = spawnSync(bin, args, { stdio: "pipe", timeout: 30000 });
  const wall_ms = performance.now() - start;
  if (r.status !== 0) {
    throw new Error(`rolldown failed: ${r.stderr?.toString().slice(0, 600)}`);
  }
  return { wall_ms };
}

function writeRspackConfig(
  configPath: string,
  entry: string,
  outDir: string,
  externals: string[],
): void {
  writeFileSync(
    configPath,
    `module.exports = {
  mode: 'production',
  entry: ${JSON.stringify(entry)},
  output: { path: ${JSON.stringify(outDir)}, filename: 'rspack.js' },
  target: 'web',
  externals: ${JSON.stringify(externals)},
  resolve: { extensions: ['.ts', '.js'] },
  module: { rules: [{ test: /\\.ts$/, type: 'javascript/auto', use: { loader: 'builtin:swc-loader', options: { jsc: { parser: { syntax: 'typescript' } } } } }] },
};`,
  );
}

function runRspack(bin: string, configPath: string, outDir: string): RunResult {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });

  const start = performance.now();
  const r = spawnSync(bin, ["build", "--config", configPath], {
    cwd: ROOT,
    stdio: "pipe",
    timeout: 30000,
  });
  const wall_ms = performance.now() - start;
  if (r.status !== 0) {
    throw new Error(`rspack failed: ${r.stderr?.toString().slice(0, 800)}`);
  }
  return { wall_ms };
}

function computeStats(samples: number[]): JsonStats {
  return toJsonStats(computeMetricStats(samples));
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

interface ToolResult {
  tool: ToolName;
  wall_ms_stats: JsonStats | null;
  zts_profile_total_ms_stats?: JsonStats;
  phase_median_ms?: Record<string, number>;
  skipped?: string;
}

interface FixtureResult {
  name: string;
  module_count: number;
  externals: number;
  tools: ToolResult[];
}

interface RunReport {
  version: number;
  generated_at: string;
  zts_commit: string;
  warmup: number;
  iterations: number;
  fixtures: FixtureResult[];
}

// ─── 메인 ───

function buildBin() {
  buildBinShared("bundle-perf");
}

function createRunners(
  entry: string,
  tmp: string,
  externals: string[],
): Partial<Record<ToolName, () => RunResult>> {
  const rolldownBin = findNodeModulesBin("rolldown");
  const rspackBin = findNodeModulesBin("rspack");
  const rspackOut = join(tmp, "rspack-out");
  const rspackConfig = join(tmp, "rspack.config.cjs");
  writeRspackConfig(rspackConfig, entry, rspackOut, externals);

  return {
    zts: () => runZts(entry, join(tmp, "zts-out"), externals),
    rolldown: rolldownBin
      ? () => runRolldown(rolldownBin, entry, join(tmp, "rolldown-out"), externals)
      : undefined,
    rspack: rspackBin ? () => runRspack(rspackBin, rspackConfig, rspackOut) : undefined,
  };
}

async function measureFixture(spec: FixtureSpec): Promise<FixtureResult> {
  const tmp = mkdtempSync(join(tmpdir(), "zts-bundle-perf-"));
  const fixDir = join(tmp, "src");
  const entry = makeFixture(fixDir, spec.module_count, spec.externals);
  const runners = createRunners(entry, tmp, spec.externals);

  try {
    for (let i = 0; i < WARMUP; i++) {
      for (const tool of TOOL_ORDER) runners[tool]?.();
    }

    const wallSamples: Partial<Record<ToolName, number[]>> = {};
    const ztsProfileTotals: number[] = [];
    const phaseSeries: Record<string, number[]> = {};

    for (let i = 0; i < ITERATIONS; i++) {
      for (const tool of TOOL_ORDER) {
        const run = runners[tool];
        if (!run) continue;
        const r = run();
        (wallSamples[tool] ??= []).push(r.wall_ms);
        if (tool === "zts") {
          if (r.zts_profile_total_ms !== undefined) ztsProfileTotals.push(r.zts_profile_total_ms);
          for (const [k, v] of Object.entries(r.phases ?? {})) {
            (phaseSeries[k] ??= []).push(v);
          }
        }
      }
    }

    const phase_median_ms: Record<string, number> = {};
    for (const [k, arr] of Object.entries(phaseSeries)) {
      phase_median_ms[k] = computeStats(arr).median;
    }

    const tools: ToolResult[] = TOOL_ORDER.map((tool) => {
      const samples = wallSamples[tool];
      if (!samples || samples.length === 0) {
        return {
          tool,
          wall_ms_stats: null,
          skipped: tool === "zts" ? "missing zts runner" : `${tool} binary not found`,
        };
      }
      const result: ToolResult = {
        tool,
        wall_ms_stats: computeStats(samples),
      };
      if (tool === "zts") {
        result.zts_profile_total_ms_stats = computeStats(ztsProfileTotals);
        result.phase_median_ms = phase_median_ms;
      }
      return result;
    });

    return {
      name: spec.name,
      module_count: spec.module_count,
      externals: spec.externals.length,
      tools,
    };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

function fmtMarkdownMs(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return "-";
  return formatMetric(n, "ms");
}

function fmtRatio(
  numerator: number | null | undefined,
  denominator: number | null | undefined,
): string {
  if (
    numerator === null ||
    numerator === undefined ||
    denominator === null ||
    denominator === undefined ||
    denominator === 0
  ) {
    return "-";
  }
  return `${(numerator / denominator).toFixed(2)}x`;
}

function toolResult(fixture: FixtureResult, tool: ToolName): ToolResult | undefined {
  return fixture.tools.find((r) => r.tool === tool);
}

function medianWall(fixture: FixtureResult, tool: ToolName): number | null {
  return toolResult(fixture, tool)?.wall_ms_stats?.median ?? null;
}

function ztsProfileMedian(fixture: FixtureResult): number | null {
  return toolResult(fixture, "zts")?.zts_profile_total_ms_stats?.median ?? null;
}

function fastestTool(fixture: FixtureResult): string {
  const candidates = fixture.tools
    .filter((r): r is ToolResult & { wall_ms_stats: JsonStats } => r.wall_ms_stats !== null)
    .sort((a, b) => a.wall_ms_stats.median - b.wall_ms_stats.median);
  if (candidates.length === 0) return "-";
  const fastest = candidates[0];
  return `${toolLabel(fastest.tool)} (${fmtMarkdownMs(fastest.wall_ms_stats.median)})`;
}

function printReport(runReport: RunReport): void {
  console.log();
  console.log("### bundle-perf — CI tool comparison context");
  console.log("| Field | Value |");
  console.log("| --- | --- |");
  console.log(`| Current run commit | ${runReport.zts_commit} |`);
  console.log("| Baseline | none; same-run CI wall-time comparison |");
  console.log("| Tools | ZTS / Rolldown / Rspack |");
  console.log("| Primary metric | CLI wall time median |");
  console.log("| ZTS profile total | included only as internal phase diagnostic |");
  console.log(`| Warmup / iterations | ${runReport.warmup} / ${runReport.iterations} |`);
  console.log();
  console.log("### bundle-perf — CI wall-time tool comparison");
  console.log(
    "| Fixture | ZTS wall median | Rolldown wall median | Rspack wall median | Fastest | Rolldown / ZTS | Rspack / ZTS | ZTS profile total |",
  );
  console.log(
    "|---------|-----------------|----------------------|--------------------|---------|----------------|--------------|-------------------|",
  );
  for (const fixture of runReport.fixtures) {
    const zts = medianWall(fixture, "zts");
    const rolldown = medianWall(fixture, "rolldown");
    const rspack = medianWall(fixture, "rspack");
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(zts)} | ${fmtMarkdownMs(rolldown)} | ${fmtMarkdownMs(rspack)} | ${fastestTool(fixture)} | ${fmtRatio(rolldown, zts)} | ${fmtRatio(rspack, zts)} | ${fmtMarkdownMs(ztsProfileMedian(fixture))} |`,
    );
  }
  console.log();
  console.log("### bundle-perf — ZTS phase medians");
  console.log("| Fixture | Resolve | Graph | Link | Shake | Transform | Codegen | Emit |");
  console.log("|---------|---------|-------|------|-------|-----------|---------|------|");
  for (const fixture of runReport.fixtures) {
    const phases = toolResult(fixture, "zts")?.phase_median_ms ?? {};
    console.log(
      `| ${fixture.name} | ${fmtMarkdownMs(phases.resolve)} | ${fmtMarkdownMs(phases.graph)} | ${fmtMarkdownMs(phases.link)} | ${fmtMarkdownMs(phases.shake)} | ${fmtMarkdownMs(phases.transform)} | ${fmtMarkdownMs(phases.codegen)} | ${fmtMarkdownMs(phases.emit)} |`,
    );
  }
}

interface CliArgs {
  noFail: boolean;
  output: string | null;
}

function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = { noFail: false, output: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--no-fail") args.noFail = true;
    else if (a === "--output") args.output = argv[++i] ?? null;
  }
  return args;
}

async function main(cli: CliArgs) {
  buildBin();
  const available = TOOL_ORDER.filter((tool) => tool === "zts" || findNodeModulesBin(tool)).join(
    ",",
  );
  console.log(`[bundle-perf] zts ${getCommit()} | warmup=${WARMUP} iter=${ITERATIONS}`);
  console.log(`[bundle-perf] available tools: ${available}`);
  console.log();

  const fixtures: FixtureResult[] = [];
  for (const spec of FIXTURES) {
    process.stdout.write(`  ${spec.name}... `);
    const r = await measureFixture(spec);
    const zts = medianWall(r, "zts");
    const rolldown = medianWall(r, "rolldown");
    const rspack = medianWall(r, "rspack");
    console.log(
      `zts=${fmtMarkdownMs(zts)} rolldown=${fmtMarkdownMs(rolldown)} rspack=${fmtMarkdownMs(rspack)} zts_profile_total=${fmtMarkdownMs(ztsProfileMedian(r))}`,
    );
    fixtures.push(r);
  }

  const runReport: RunReport = {
    version: 2,
    generated_at: new Date().toISOString(),
    zts_commit: getCommit(),
    warmup: WARMUP,
    iterations: ITERATIONS,
    fixtures,
  };

  if (cli.output) {
    writeFileSync(cli.output, JSON.stringify(runReport, null, 2) + "\n");
    console.log(`\n[bundle-perf] run report written: ${cli.output}`);
  }

  printReport(runReport);
}

await main(parseArgs(process.argv.slice(2)));
