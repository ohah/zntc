#!/usr/bin/env bun
/**
 * Tree-shaking profile runner.
 *
 * This benchmark keeps the synthetic fixtures used while tuning tree-shaking
 * reproducible. It is intentionally profile-oriented: compare the same machine
 * before/after a tree-shaking change, then keep the JSON output for trend
 * tracking.
 *
 * Examples:
 *   bun run tests/benchmark/const-prepass.ts
 *   bun run tests/benchmark/const-prepass.ts --warmup=3 --iterations=9
 *   bun run tests/benchmark/const-prepass.ts --output /tmp/tree-shake-profile.json
 */

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ROOT,
  ZTS_BIN,
  buildBin as buildBinShared,
  getCommit,
  parsePositiveInt,
  parseProfileJson,
  type ProfileJson,
} from "./_runner";
import { computeMetricStats, formatMetric, type MetricStats } from "./stats";

function buildBin(): void {
  buildBinShared("tree-shake-profile");
}

const DEFAULT_WARMUP = 3;
const DEFAULT_ITERATIONS = 9;

const TARGET_PHASES = [
  "shake",
  "shake.init",
  "shake.analyze",
  "shake.post.link.finalize",
  "shake.setup",
  "shake.purity",
  "shake.stmt.info",
  "shake.fixpoint",
  "shake.fixpoint.sym.to.ib",
  "shake.fixpoint.bfs",
  "shake.fixpoint.bfs.seed",
  "shake.fixpoint.bfs.queue",
  "shake.fixpoint.bfs.follow.import",
  "shake.fixpoint.bfs.seed.export",
  "shake.fixpoint.bfs.seed.export.direct",
  "shake.fixpoint.bfs.require.scan",
  "shake.fixpoint.bfs.final.mark.exports",
  "shake.fixpoint.bfs.enqueue.side.effects",
  "shake.fixpoint.bfs.seed.export.resolve",
  "shake.fixpoint.bfs.seed.export.mark",
  "shake.fixpoint.bfs.seed.export.cjs",
  "shake.fixpoint.bfs.seed.export.namespace.scan",
  "shake.fixpoint.bfs.seed.export.intermediate",
  "shake.fixpoint.bfs.seed.export.semantic.lookup",
  "shake.fixpoint.bfs.seed.export.enqueue.symbol",
  "shake.fixpoint.bfs.seed.export.opaque",
  "shake.fixpoint.process.imports",
  "shake.fixpoint.re.exports",
  "shake.fixpoint.re.exports.module",
  "shake.fixpoint.eval.deps",
  "shake.prune",
  "shake.const.prepass",
  "shake.const.prepass.numeric.propagate",
  "shake.const.prepass.numeric.seed.scan",
  "shake.const.prepass.numeric.queue",
  "shake.const.prepass.build.facts",
  "shake.const.prepass.build.facts.resolve",
  "shake.const.prepass.build.facts.lookup",
  "shake.const.prepass.candidate.gate",
  "shake.const.prepass.materialize",
  "shake.const.prepass.forbidden",
  "shake.const.prepass.reachable",
  "shake.const.prepass.replace",
  "shake.const.prepass.minify.resync",
  "shake.const.prepass.node.buffer",
  "shake.const.prepass.link.refresh",
  "shake.numeric.postpass",
  "shake.numeric.postpass.queue.seed",
  "shake.numeric.postpass.queue",
  "shake.numeric.postpass.build.facts",
  "shake.numeric.postpass.build.facts.resolve",
  "shake.numeric.postpass.build.facts.lookup",
  "shake.numeric.postpass.candidate.gate",
  "shake.numeric.postpass.materialize",
  "shake.numeric.postpass.forbidden",
  "shake.numeric.postpass.reachable",
  "shake.numeric.postpass.replace",
  "shake.numeric.postpass.minify.resync",
  "shake.numeric.postpass.minify",
  "shake.numeric.postpass.resync",
  "shake.numeric.postpass.minify.skip",
  "graph.resync",
  "graph.resync.const",
  "graph.resync.semantic",
  "graph.resync.stmt.info",
  "graph.resync.import.scan",
  "graph.resync.import.bindings",
  "graph.resync.export.bindings",
  "graph.resync.classify",
  "graph.resync.alias",
  "graph.resync.binding.refs",
  "shake.mirror",
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

interface PhaseResult {
  total_ms_stats: MetricStats;
  self_ms_stats: MetricStats;
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
  { name: "namespace-2000", size: 2000, write: writeNamespaceFixture },
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
      "--profile=shake,graph.resync",
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

function median(values: number[]): number {
  return computeMetricStats(values).median;
}

function measureFixture(spec: FixtureSpec, cli: CliArgs): FixtureResult {
  const tmp = mkdtempSync(join(tmpdir(), "zts-tree-shake-profile-"));
  try {
    const srcDir = join(tmp, "src");
    const outDir = join(tmp, "dist");
    const entry = spec.write(srcDir, spec.size);

    for (let i = 0; i < cli.warmup; i++) runOne(entry, outDir);

    const totalSamples: number[] = [];
    const phaseTimeSamples: Partial<Record<TargetPhase, number[]>> = {};
    const phaseSelfTimeSamples: Partial<Record<TargetPhase, number[]>> = {};
    const phaseCountSamples: Partial<Record<TargetPhase, number[]>> = {};
    for (let i = 0; i < cli.iterations; i++) {
      const profile = runOne(entry, outDir);
      totalSamples.push(profile.total_ms);
      for (const phase of TARGET_PHASES) {
        const hit = profile.phases[phase];
        (phaseTimeSamples[phase] ??= []).push(hit?.total_ms ?? 0);
        (phaseSelfTimeSamples[phase] ??= []).push(hit?.self_ms ?? hit?.total_ms ?? 0);
        (phaseCountSamples[phase] ??= []).push(hit?.count ?? 0);
      }
    }

    const phases: Partial<Record<TargetPhase, PhaseResult>> = {};
    for (const phase of TARGET_PHASES) {
      const times = phaseTimeSamples[phase] ?? [];
      const selfTimes = phaseSelfTimeSamples[phase] ?? [];
      const counts = phaseCountSamples[phase] ?? [];
      phases[phase] = {
        total_ms_stats: computeMetricStats(times),
        self_ms_stats: computeMetricStats(selfTimes),
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

function phaseSelfMedian(result: FixtureResult, phase: TargetPhase): number {
  return result.phases[phase]?.self_ms_stats.median ?? phaseMedian(result, phase);
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
      args.warmup = parsePositiveInt("--warmup", argv[++i]);
    } else if (arg.startsWith("--warmup=")) {
      args.warmup = parsePositiveInt("--warmup", arg.slice("--warmup=".length));
    } else if (arg === "--iterations") {
      args.iterations = parsePositiveInt("--iterations", argv[++i]);
    } else if (arg.startsWith("--iterations=")) {
      args.iterations = parsePositiveInt("--iterations", arg.slice("--iterations=".length));
    } else if (arg === "--help" || arg === "-h") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return args;
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
  console.log(
    `[tree-shake-profile] zts ${getCommit()} | warmup=${cli.warmup} iter=${cli.iterations}`,
  );
  console.log();

  const results: FixtureResult[] = [];
  for (const spec of FIXTURES) {
    process.stdout.write(`  ${spec.name}... `);
    const result = measureFixture(spec, cli);
    results.push(result);
    console.log(
      `shake=${fmtMs(phaseMedian(result, "shake"))} ` +
        `bfs=${fmtMs(phaseMedian(result, "shake.fixpoint.bfs"))} ` +
        `bfs.self=${fmtMs(phaseSelfMedian(result, "shake.fixpoint.bfs"))} ` +
        `seed=${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed"))} ` +
        `queue=${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.queue"))} ` +
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
    console.log(`\n[tree-shake-profile] run report written: ${cli.output}`);
  }

  console.log();
  console.log("### tree-shake profile");
  console.log(
    "| Fixture | Profile total | Shake | Shake self | Init | Analyze | Analyze self | Const prepass | Build facts | Build count | Fixpoint | BFS | BFS self | BFS seed | BFS queue | Final mark | Re-exports |",
  );
  console.log(
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(result.total_ms_stats.median)} | ` +
        `${fmtMs(phaseMedian(result, "shake"))} | ` +
        `${fmtMs(phaseSelfMedian(result, "shake"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.init"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.analyze"))} | ` +
        `${fmtMs(phaseSelfMedian(result, "shake.analyze"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass.build.facts"))} | ` +
        `${phaseCount(result, "shake.const.prepass.build.facts")} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs"))} | ` +
        `${fmtMs(phaseSelfMedian(result, "shake.fixpoint.bfs"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.queue"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.final.mark.exports"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.re.exports"))} |`,
    );
  }

  console.log();
  console.log("### const facts build profile");
  console.log("| Fixture | Resolve | Lookup |");
  console.log("| --- | ---: | ---: |");
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(phaseMedian(result, "shake.const.prepass.build.facts.resolve"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.const.prepass.build.facts.lookup"))} |`,
    );
  }

  console.log();
  console.log("### shake self profile");
  console.log(
    "| Fixture | Setup | Purity | Stmt info | Prune | Numeric postpass | Mirror | Post-link finalize |",
  );
  console.log("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(phaseMedian(result, "shake.setup"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.purity"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.stmt.info"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.prune"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.mirror"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.post.link.finalize"))} |`,
    );
  }

  console.log();
  console.log("### numeric postpass profile");
  console.log(
    "| Fixture | Queue seed | Queue | Build facts | Resolve | Lookup | Candidate | Materialize | Forbidden | Reachable | Replace | Minify resync | Minify | Resync | Skip count |",
  );
  console.log(
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(phaseMedian(result, "shake.numeric.postpass.queue.seed"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.queue"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.build.facts"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.build.facts.resolve"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.build.facts.lookup"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.candidate.gate"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.materialize"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.forbidden"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.reachable"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.replace"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.minify.resync"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.minify"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.numeric.postpass.resync"))} | ` +
        `${phaseCount(result, "shake.numeric.postpass.minify.skip")} |`,
    );
  }

  console.log();
  console.log("### numeric resync graph profile");
  console.log(
    "| Fixture | Graph resync | Const path | Semantic | Stmt info | Binding refs | Import scan | Import bindings | Export bindings | Classify | Alias |",
  );
  console.log("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |");
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(phaseMedian(result, "graph.resync"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.const"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.semantic"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.stmt.info"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.binding.refs"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.import.scan"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.import.bindings"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.export.bindings"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.classify"))} | ` +
        `${fmtMs(phaseMedian(result, "graph.resync.alias"))} |`,
    );
  }

  console.log();
  console.log("### fixpoint helper profile");
  console.log(
    "| Fixture | Sym to import | Process imports | Re-exports | Re-export modules | Eval deps |",
  );
  console.log("| --- | ---: | ---: | ---: | ---: | ---: |");
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(phaseMedian(result, "shake.fixpoint.sym.to.ib"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.process.imports"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.re.exports"))} | ` +
        `${phaseCount(result, "shake.fixpoint.re.exports.module")} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.eval.deps"))} |`,
    );
  }

  console.log();
  console.log("### nested bfs helper profile");
  console.log(
    "| Fixture | Follow import | Follow self | Seed export | Seed count | Seed export self | Direct local | Resolve | Mark | CJS | Namespace scan | Intermediate | Semantic lookup | Enqueue symbol | Opaque | Require scan | Require count | Side effects |",
  );
  console.log(
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const result of results) {
    console.log(
      `| ${result.name} | ${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.follow.import"))} | ` +
        `${fmtMs(phaseSelfMedian(result, "shake.fixpoint.bfs.follow.import"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export"))} | ` +
        `${phaseCount(result, "shake.fixpoint.bfs.seed.export")} | ` +
        `${fmtMs(phaseSelfMedian(result, "shake.fixpoint.bfs.seed.export"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.direct"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.resolve"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.mark"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.cjs"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.namespace.scan"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.intermediate"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.semantic.lookup"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.enqueue.symbol"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.seed.export.opaque"))} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.require.scan"))} | ` +
        `${phaseCount(result, "shake.fixpoint.bfs.require.scan")} | ` +
        `${fmtMs(phaseMedian(result, "shake.fixpoint.bfs.enqueue.side.effects"))} |`,
    );
  }
}

await main(parseArgs(process.argv.slice(2)));
