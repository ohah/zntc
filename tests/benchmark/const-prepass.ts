#!/usr/bin/env bun
/**
 * Const prepass tree-shaking profile runner.
 *
 * This benchmark keeps the synthetic fixtures used while tuning
 * `shake.const.prepass` reproducible. It is intentionally profile-oriented:
 * compare the same machine before/after a tree-shaking change, then keep the
 * JSON output for trend tracking.
 *
 * Examples:
 *   bun run tests/benchmark/const-prepass.ts
 *   bun run tests/benchmark/const-prepass.ts --warmup=3 --iterations=9
 *   bun run tests/benchmark/const-prepass.ts --output /tmp/const-prepass.json
 */

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { computeMetricStats, formatMetric, type MetricStats } from "./stats";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");

const DEFAULT_WARMUP = 3;
const DEFAULT_ITERATIONS = 9;

const TARGET_PHASES = [
  "shake.const.prepass",
  "shake.const.prepass.numeric.propagate",
  "shake.const.prepass.numeric.seed.scan",
  "shake.const.prepass.numeric.queue",
  "shake.const.prepass.build.facts",
  "shake.const.prepass.candidate.gate",
  "shake.const.prepass.materialize",
  "shake.const.prepass.forbidden",
  "shake.const.prepass.reachable",
  "shake.const.prepass.replace",
  "shake.const.prepass.minify.resync",
  "shake.const.prepass.node.buffer",
  "shake.const.prepass.link.refresh",
] as const;

type TargetPhase = (typeof TARGET_PHASES)[number];

interface CliArgs {
  warmup: number;
  iterations: number;
  output: string | null;
}

interface FixtureSpec {
  name: string;
  size: number;
  write: (dir: string, size: number) => string;
}

interface ProfilePhase {
  total_ms: number;
  count: number;
  pct: number;
}

interface ProfileJson {
  profile_version: number;
  total_ms: number;
  level: string;
  phases: Record<string, ProfilePhase | undefined>;
}

interface PhaseResult {
  total_ms_stats: MetricStats;
  count_median: number;
}

interface FixtureResult {
  name: string;
  size: number;
  total_ms_stats: MetricStats;
  phases: Partial<Record<TargetPhase, PhaseResult>>;
}

interface RunReport {
  version: 1;
  generated_at: string;
  zts_commit: string;
  warmup: number;
  iterations: number;
  fixtures: FixtureResult[];
}

const FIXTURES: FixtureSpec[] = [
  { name: "flat-1000", size: 1000, write: writeFlatFixture },
  { name: "reexport-500", size: 500, write: writeReExportFixture },
  { name: "namespace-500", size: 500, write: writeNamespaceFixture },
];

function writeFlatFixture(dir: string, size: number): string {
  mkdirSync(dir, { recursive: true });
  const imports: string[] = [];
  const values: string[] = [];
  for (let i = 0; i < size; i++) {
    imports.push(`import { v${i} } from "./mod${i}";`);
    values.push(`v${i}`);
    writeFileSync(join(dir, `mod${i}.ts`), `export const v${i} = ${i} + 1;\n`);
  }
  writeFileSync(
    join(dir, "entry.ts"),
    `${imports.join("\n")}\nconsole.log(${values.join(" + ")});\n`,
  );
  return join(dir, "entry.ts");
}

function writeReExportFixture(dir: string, size: number): string {
  mkdirSync(dir, { recursive: true });
  const exports: string[] = [];
  const imports: string[] = [];
  const values: string[] = [];
  for (let i = 0; i < size; i++) {
    exports.push(`export { v${i} } from "./mod${i}";`);
    imports.push(`v${i}`);
    values.push(`v${i}`);
    writeFileSync(join(dir, `mod${i}.ts`), `export const v${i} = ${i} + 1;\n`);
  }
  writeFileSync(join(dir, "barrel.ts"), `${exports.join("\n")}\n`);
  writeFileSync(
    join(dir, "entry.ts"),
    `import { ${imports.join(", ")} } from "./barrel";\nconsole.log(${values.join(" + ")});\n`,
  );
  return join(dir, "entry.ts");
}

function writeNamespaceFixture(dir: string, size: number): string {
  mkdirSync(dir, { recursive: true });
  const exports: string[] = [];
  const imports: string[] = [];
  const values: string[] = [];
  for (let i = 0; i < size; i++) {
    exports.push(`export * as ns${i} from "./mod${i}";`);
    imports.push(`ns${i}`);
    values.push(`ns${i}.v${i}`);
    writeFileSync(join(dir, `mod${i}.ts`), `export const v${i} = ${i} + 1;\n`);
  }
  writeFileSync(join(dir, "barrel.ts"), `${exports.join("\n")}\n`);
  writeFileSync(
    join(dir, "entry.ts"),
    `import { ${imports.join(", ")} } from "./barrel";\nconsole.log(${values.join(" + ")});\n`,
  );
  return join(dir, "entry.ts");
}

function buildBin(): void {
  if (existsSync(ZTS_BIN)) return;
  console.log("[const-prepass] zts binary not found, building ReleaseFast...");
  const result = spawnSync("zig", ["build", "-Doptimize=ReleaseFast"], {
    cwd: ROOT,
    stdio: "inherit",
  });
  if (result.status !== 0) throw new Error("zig build failed");
}

function getCommit(): string {
  const result = spawnSync("git", ["rev-parse", "--short", "HEAD"], {
    cwd: ROOT,
    encoding: "utf8",
    stdio: "pipe",
  });
  return result.stdout.trim() || "unknown";
}

function runOne(entry: string, outDir: string): ProfileJson {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const result = spawnSync(
    ZTS_BIN,
    [
      "--bundle",
      entry,
      "--format=esm",
      "-o",
      join(outDir, "out.js"),
      "--profile=shake.const.prepass",
      "--profile-level=detailed",
      "--profile-format=json",
    ],
    {
      cwd: ROOT,
      encoding: "utf8",
      stdio: "pipe",
      timeout: 30000,
    },
  );
  if (result.status !== 0) {
    throw new Error(`zts failed: ${result.stderr.slice(0, 800)}`);
  }
  return parseProfileJson(`${result.stdout}\n${result.stderr}`);
}

function parseProfileJson(output: string): ProfileJson {
  const start = output.indexOf("{");
  const end = output.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error(`missing profile JSON output: ${output.slice(0, 800)}`);
  }
  return JSON.parse(output.slice(start, end + 1)) as ProfileJson;
}

function median(values: number[]): number {
  return computeMetricStats(values).median;
}

function measureFixture(spec: FixtureSpec, cli: CliArgs): FixtureResult {
  const tmp = mkdtempSync(join(tmpdir(), "zts-const-prepass-"));
  try {
    const srcDir = join(tmp, "src");
    const outDir = join(tmp, "dist");
    const entry = spec.write(srcDir, spec.size);

    for (let i = 0; i < cli.warmup; i++) runOne(entry, outDir);

    const totalSamples: number[] = [];
    const phaseTimeSamples: Partial<Record<TargetPhase, number[]>> = {};
    const phaseCountSamples: Partial<Record<TargetPhase, number[]>> = {};
    for (let i = 0; i < cli.iterations; i++) {
      const profile = runOne(entry, outDir);
      totalSamples.push(profile.total_ms);
      for (const phase of TARGET_PHASES) {
        const hit = profile.phases[phase];
        (phaseTimeSamples[phase] ??= []).push(hit?.total_ms ?? 0);
        (phaseCountSamples[phase] ??= []).push(hit?.count ?? 0);
      }
    }

    const phases: Partial<Record<TargetPhase, PhaseResult>> = {};
    for (const phase of TARGET_PHASES) {
      const times = phaseTimeSamples[phase] ?? [];
      const counts = phaseCountSamples[phase] ?? [];
      phases[phase] = {
        total_ms_stats: computeMetricStats(times),
        count_median: median(counts),
      };
    }

    return {
      name: spec.name,
      size: spec.size,
      total_ms_stats: computeMetricStats(totalSamples),
      phases,
    };
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

function fmtMs(n: number): string {
  return formatMetric(n, "ms");
}

function phaseMedian(result: FixtureResult, phase: TargetPhase): number {
  return result.phases[phase]?.total_ms_stats.median ?? 0;
}

function phaseCount(result: FixtureResult, phase: TargetPhase): number {
  return result.phases[phase]?.count_median ?? 0;
}

function parseArgs(argv: string[]): CliArgs {
  const args: CliArgs = {
    warmup: DEFAULT_WARMUP,
    iterations: DEFAULT_ITERATIONS,
    output: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--output") {
      args.output = argv[++i] ?? null;
    } else if (arg.startsWith("--output=")) {
      args.output = arg.slice("--output=".length);
    } else if (arg === "--warmup") {
      args.warmup = parsePositiveInt(argv[++i], "warmup");
    } else if (arg.startsWith("--warmup=")) {
      args.warmup = parsePositiveInt(arg.slice("--warmup=".length), "warmup");
    } else if (arg === "--iterations") {
      args.iterations = parsePositiveInt(argv[++i], "iterations");
    } else if (arg.startsWith("--iterations=")) {
      args.iterations = parsePositiveInt(arg.slice("--iterations=".length), "iterations");
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return args;
}

function parsePositiveInt(value: string | undefined, name: string): number {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`--${name} must be a positive integer`);
  }
  return parsed;
}

function printHelp(): void {
  console.log(`Usage: bun run tests/benchmark/const-prepass.ts [options]

Options:
  --warmup <n>       Warmup runs per fixture (default: ${DEFAULT_WARMUP})
  --iterations <n>   Measured runs per fixture (default: ${DEFAULT_ITERATIONS})
  --output <path>    Write JSON report
  -h, --help         Show this help
`);
}

async function main(cli: CliArgs): Promise<void> {
  buildBin();
  console.log(`[const-prepass] zts ${getCommit()} | warmup=${cli.warmup} iter=${cli.iterations}`);
  console.log();

  const results: FixtureResult[] = [];
  for (const spec of FIXTURES) {
    process.stdout.write(`  ${spec.name}... `);
    const result = measureFixture(spec, cli);
    results.push(result);
    console.log(
      `const=${fmtMs(phaseMedian(result, "shake.const.prepass"))} ` +
        `build.facts=${fmtMs(phaseMedian(result, "shake.const.prepass.build.facts"))} ` +
        `count=${phaseCount(result, "shake.const.prepass.build.facts")}`,
    );
  }

  const report: RunReport = {
    version: 1,
    generated_at: new Date().toISOString(),
    zts_commit: getCommit(),
    warmup: cli.warmup,
    iterations: cli.iterations,
    fixtures: results,
  };

  if (cli.output) {
    writeFileSync(cli.output, JSON.stringify(report, null, 2) + "\n");
    console.log(`\n[const-prepass] run report written: ${cli.output}`);
  }

  console.log();
  console.log("### const-prepass profile");
  console.log(
    "| Fixture | Total | Const prepass | Numeric propagate | Numeric queue | Build facts | Build count | Minify resync | Minify count |",
  );
  console.log("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(result.total_ms_stats.median)} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass.numeric.propagate"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass.numeric.queue"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass.build.facts"))} | ` +
        `${phaseCount(result, "shake.const.prepass.build.facts")} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass.minify.resync"))} | ` +
        `${phaseCount(result, "shake.const.prepass.minify.resync")} |`,
    );
  }
}

await main(parseArgs(process.argv.slice(2)));
